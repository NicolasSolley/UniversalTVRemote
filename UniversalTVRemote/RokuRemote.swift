import Foundation

/// Roku External Control Protocol (ECP) — plain HTTP on port 8060, no auth.
///
/// Endpoints used (Roku ECP docs):
/// - POST /keypress/<Key> — press a remote key
/// - POST /keypress/Lit_<char> — type a character (URL-encoded)
/// - GET  /query/apps — list installed apps (XML)
/// - POST /launch/<appId> — launch an app
/// - GET  /query/device-info — model / firmware (XML)
enum RokuRemote {
    /// A Roku-side error with a user-facing message. A 403 means the
    /// Roku is blocking remote apps (fork's RokuDriver.enqueue) — the
    /// user can fix it in the Roku's settings.
    enum RokuError: Error, LocalizedError {
        case blocked
        case badResponse

        /// Whether this error means the connection itself is gone
        /// (v1.0.53): neither is — the Roku answered, it just
        /// blocked the request or sent something unexpected — so
        /// the session stays connected.
        var isConnectionLevel: Bool { false }

        var errorDescription: String? {
            switch self {
            case .blocked:
                return "Your Roku is blocking remote apps. On the Roku, go to Settings → System → Advanced system settings → Control by mobile apps and set Network access to Default or Permissive."
            case .badResponse:
                return "The Roku sent an unexpected response."
            }
        }
    }

    struct RokuApp: Identifiable, Hashable {
        let id: String
        let name: String
        let version: String?
        /// `query/icon/<id>` — the app's icon, for the shortcut cards.
        let iconURL: URL?
    }

    static let defaultPort = 8060

    /// Serial keypress chain (fork's `enqueue`): each press awaits the
    /// previous one so the Roku receives keys in order. Main-actor
    /// state — every caller goes through RemoteSession (main actor).
    @MainActor private static var queue: Task<Void, Error>?
    /// Generation guard: presses queued before a reset (disconnect /
    /// reconnect) are dropped instead of firing late.
    @MainActor private static var generation = 0

    /// Drops queued presses and invalidates the chain — call on
    /// connect and disconnect (fork bumps generation in both).
    @MainActor static func resetQueue() {
        generation += 1
        queue?.cancel()
        queue = nil
    }

    @MainActor static func send(key: String, to host: String, port: Int = defaultPort) async throws {
        try await enqueue(path: "keypress/\(key)", to: host, port: port).value
    }

    /// True key hold (v1.0.25): ECP `/keydown/<Key>` / `/keyup/<Key>`
    /// — the same serial queue as a press, so down/up stay ordered
    /// against any other key.
    @MainActor static func sendKeyDown(key: String, to host: String, port: Int = defaultPort) async throws {
        try await enqueue(path: "keydown/\(key)", to: host, port: port).value
    }

    @MainActor static func sendKeyUp(key: String, to host: String, port: Int = defaultPort) async throws {
        try await enqueue(path: "keyup/\(key)", to: host, port: port).value
    }

    /// Enqueues one POST behind the previous press. A failed press does
    /// not block the chain (`try?` on the predecessor); the current
    /// press's own error propagates to its awaiter.
    @MainActor @discardableResult
    private static func enqueue(path: String, to host: String, port: Int) -> Task<Void, Error> {
        let previous = queue
        let token = generation
        let operation = Task<Void, Error> { @MainActor in
            _ = try? await previous?.value
            guard !Task.isCancelled, token == generation else { return }
            try await post(path: path, to: host, port: port)
        }
        queue = operation
        return operation
    }

    /// POST with the fork's status handling: 200/202/204 are success,
    /// 403 is the Roku blocking remote apps, anything else is a bad
    /// response.
    private static func post(path: String, to host: String, port: Int) async throws {
        guard let url = URL(string: "http://\(host):\(port)/\(path)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RokuError.badResponse
        }
        switch http.statusCode {
        case 200, 202, 204:
            return
        case 403:
            throw RokuError.blocked
        default:
            throw RokuError.badResponse
        }
    }

    /// Type text into the focused field: one `Lit_` keypress per character.
    /// Every non-alphanumeric character is percent-encoded (space is
    /// `Lit_%20`); `/` must be encoded or it would split the URL path.
    static func sendText(_ text: String, to host: String, port: Int = defaultPort) async throws {
        for character in text {
            let encoded = String(character)
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            try await send(key: "Lit_\(encoded)", to: host, port: port)
            // Small gap so the Roku keeps up with rapid keypresses.
            try await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    /// Installed apps, best effort — returns [] if the query fails.
    /// Only `<app type="appl">` entries (fork's RokuAppsParser): the
    /// TV tuner and HDMI inputs are not launchable apps.
    static func apps(on host: String, port: Int = defaultPort) async -> [RokuApp] {
        guard let url = URL(string: "http://\(host):\(port)/query/apps") else { return [] }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return []
            }
            return RokuAppsParser.parse(data, host: host, port: port)
        } catch {
            return []
        }
    }

    static func launch(appId: String, on host: String, port: Int = defaultPort) async throws {
        try await enqueue(path: "launch/\(appId)", to: host, port: port).value
    }

    /// Device name + model from /query/device-info. The name is
    /// `user-device-name` when the user renamed the Roku, else
    /// `friendly-device-name` (fork's connect()). `mac` is the
    /// Wi-Fi (else Ethernet) MAC for Wake-on-LAN (v1.0.47).
    struct RokuDeviceInfo {
        let name: String?
        let model: String?
        let mac: String?
    }

    static func deviceInfo(on host: String, port: Int = defaultPort) async -> RokuDeviceInfo? {
        guard let url = URL(string: "http://\(host):\(port)/query/device-info") else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            let fields = RokuDeviceInfoParser.fields(from: data)
            return RokuDeviceInfo(name: fields["user-device-name"] ?? fields["friendly-device-name"],
                                  model: fields["model-name"],
                                  mac: fields["wifi-mac"] ?? fields["ethernet-mac"])
        } catch {
            return nil
        }
    }

    /// Wake-on-LAN for Roku (v1.0.47): the MAC comes from
    /// /query/device-info and is stored per host like Samsung's, so
    /// a sleeping Roku can be woken on tap. Untested — no Roku here
    /// to try it on; if device-info has no MAC field, wake stays off.
    private static func macKey(for host: String) -> String { "roku.mac.\(host)" }
    static func macAddress(for host: String) -> String? {
        UserDefaults.standard.string(forKey: macKey(for: host))
    }
    static func storeMAC(_ mac: String, for host: String) {
        UserDefaults.standard.set(mac, forKey: macKey(for: host))
    }

    /// Send the magic packet and retry device-info until the TV
    /// answers (up to 5 attempts, 3 s apart — the Samsung wake
    /// cadence). True when the TV is back.
    static func wakeAndCheck(host: String) async -> Bool {
        guard let mac = macAddress(for: host) else { return false }
        for _ in 1...5 {
            WakeOnLAN.sendMagicPacket(mac: mac, host: host)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if await deviceInfo(on: host) != nil { return true }
        }
        return false
    }

    /// Friendly model name from /query/device-info, e.g. "TCL Model 55S405".
    static func modelName(on host: String, port: Int = defaultPort) async -> String? {
        await deviceInfo(on: host, port: port)?.model
    }
}

private enum RokuAppsParser {
    static func parse(_ data: Data, host: String, port: Int) -> [RokuRemote.RokuApp] {
        let delegate = ParserDelegate(host: host, port: port)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.apps
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        var apps: [RokuRemote.RokuApp] = []
        private let host: String
        private let port: Int
        private var currentId: String?
        private var currentVersion: String?
        private var currentText = ""

        init(host: String, port: Int) {
            self.host = host
            self.port = port
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            currentText = ""
            if elementName == "app" {
                // Skip system entries like the TV tuner and HDMI inputs.
                currentId = attributeDict["type"] == "appl" ? attributeDict["id"] : nil
                currentVersion = attributeDict["version"]
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "app", let id = currentId {
                let name = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                let iconURL = URL(string: "http://\(host):\(port)/query/icon/\(id)")
                apps.append(RokuRemote.RokuApp(id: id, name: name, version: currentVersion, iconURL: iconURL))
                currentId = nil
                currentVersion = nil
            }
            currentText = ""
        }
    }
}

private enum RokuDeviceInfoParser {
    static func fields(from data: Data) -> [String: String] {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.fields
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        var fields: [String: String] = [:]
        private var currentElement: String?
        private var currentText = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            currentElement = ["user-device-name", "friendly-device-name", "model-name",
                              "wifi-mac", "ethernet-mac"].contains(elementName)
                ? elementName : nil
            currentText = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard currentElement != nil else { return }
            currentText += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if let element = currentElement, element == elementName {
                let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, fields[element] == nil {
                    fields[element] = value
                }
            }
            currentElement = nil
            currentText = ""
        }
    }
}
