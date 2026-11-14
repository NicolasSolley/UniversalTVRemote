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
    struct RokuApp: Identifiable, Hashable {
        let id: String
        let name: String
        let version: String?
    }

    static let defaultPort = 8060

    static func send(key: String, to host: String, port: Int = defaultPort) async throws {
        guard let url = URL(string: "http://\(host):\(port)/keypress/\(key)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
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
    static func apps(on host: String, port: Int = defaultPort) async -> [RokuApp] {
        guard let url = URL(string: "http://\(host):\(port)/query/apps") else { return [] }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return []
            }
            return RokuAppsParser.parse(data)
        } catch {
            return []
        }
    }

    static func launch(appId: String, on host: String, port: Int = defaultPort) async throws {
        guard let url = URL(string: "http://\(host):\(port)/launch/\(appId)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    /// Friendly model name from /query/device-info, e.g. "TCL Model 55S405".
    static func modelName(on host: String, port: Int = defaultPort) async -> String? {
        guard let url = URL(string: "http://\(host):\(port)/query/device-info") else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return RokuDeviceInfoParser.modelName(from: data)
        } catch {
            return nil
        }
    }
}

private enum RokuAppsParser {
    static func parse(_ data: Data) -> [RokuRemote.RokuApp] {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.apps
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        var apps: [RokuRemote.RokuApp] = []
        private var currentId: String?
        private var currentVersion: String?
        private var currentText = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            currentText = ""
            if elementName == "app" {
                currentId = attributeDict["id"]
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
                apps.append(RokuRemote.RokuApp(id: id, name: name, version: currentVersion))
                currentId = nil
                currentVersion = nil
            }
            currentText = ""
        }
    }
}

private enum RokuDeviceInfoParser {
    static func modelName(from data: Data) -> String? {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.modelName
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        var modelName: String?
        private var currentElement = ""
        private var currentText = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            currentElement = elementName
            currentText = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "model-name" {
                let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { modelName = value }
            }
            currentElement = ""
            currentText = ""
        }
    }
}
