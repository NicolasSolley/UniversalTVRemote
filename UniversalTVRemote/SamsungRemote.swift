import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Samsung Smart TV (Tizen, 2016+) remote control over WebSocket.
///
/// Verified protocol (reverse-engineered, corroborated by samsungtvws,
/// Home Assistant `samsungtv`, and the `msf-server` binary strings):
/// - `wss://<host>:8002/api/v2/channels/samsung.remote.control?name=<base64(clientName)>&token=<token>`
///   The TV presents a self-signed certificate, so TLS verification is
///   skipped for this session only.
/// - First connect (no token): the TV shows an Allow/Deny prompt. On Allow it
///   sends `{"event":"ms.channel.connect","data":{"token":"..."}}` — the token
///   is stored in UserDefaults and reused on later connects (no prompt).
///   On Deny it sends `{"event":"ms.channel.unauthorized"}`.
/// - Keys: `{"method":"ms.remote.control","params":{"Cmd":"Click","DataOfCmd":"KEY_POWER","Option":"false","TypeOfRemote":"SendRemoteKey"}}`
/// - Text (native Tizen fields only): `SendInputString` with base64 text,
///   then `SendInputEnd`.
/// - Power-on over the socket is unreliable when the TV is fully off; a
///   Wake-on-LAN magic packet is sent as a fallback when the TV's MAC is
///   known (fetched from `GET http://<host>:8001/api/v2/`).
actor SamsungRemote {
    enum SamsungError: Error, LocalizedError {
        case denied
        case timeout
        case notConnected
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .denied:
                return "The TV denied access. You can allow it under Settings → General → External Device Manager → Device Connection Manager."
            case .timeout:
                return "The TV didn't answer in time. Make sure it's on and accept the prompt on the TV."
            case .notConnected:
                return "Couldn't connect to the TV."
            case .invalidResponse:
                return "The TV sent an unexpected reply."
            }
        }
    }

    /// An installed Samsung app, as returned by `ed.installedApp.get`.
    /// `actionType` is `NATIVE_LAUNCH` when `app_type == 4`, else
    /// `DEEP_LINK` (fork's SamsungDriver).
    struct SamsungApp: Identifiable, Hashable {
        let id: String
        let name: String
        let actionType: String
    }

    enum Key: String {
        case power = "KEY_POWER"
        case volumeUp = "KEY_VOLUP"
        case volumeDown = "KEY_VOLDOWN"
        case mute = "KEY_MUTE"
        case channelUp = "KEY_CHUP"
        case channelDown = "KEY_CHDOWN"
        case up = "KEY_UP"
        case down = "KEY_DOWN"
        case left = "KEY_LEFT"
        case right = "KEY_RIGHT"
        case enter = "KEY_ENTER"
        case back = "KEY_RETURN"
        case home = "KEY_HOME"
        case exit = "KEY_EXIT"
        case info = "KEY_INFO"
        case menu = "KEY_MENU"
        case play = "KEY_PLAY"
        case pause = "KEY_PAUSE"
        case stop = "KEY_STOP"
        case source = "KEY_SOURCE"
        case rewind = "KEY_REWIND"
        case fastForward = "KEY_FF"
        case digit0 = "KEY_0"
        case digit1 = "KEY_1"
        case digit2 = "KEY_2"
        case digit3 = "KEY_3"
        case digit4 = "KEY_4"
        case digit5 = "KEY_5"
        case digit6 = "KEY_6"
        case digit7 = "KEY_7"
        case digit8 = "KEY_8"
        case digit9 = "KEY_9"

        static func digit(_ n: Int) -> Key? {
            switch n {
            case 0: return .digit0
            case 1: return .digit1
            case 2: return .digit2
            case 3: return .digit3
            case 4: return .digit4
            case 5: return .digit5
            case 6: return .digit6
            case 7: return .digit7
            case 8: return .digit8
            case 9: return .digit9
            default: return nil
            }
        }
    }

    private let clientName = "UniversalTVRemote"
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var connectedHost: String?
    private var connectionLost = false
    private var drainTask: Task<Void, Never>?
    private var lastSend = Date.distantPast
    /// Keys pressed while (re)connecting, sent once the TV lets us in
    /// (fork's pendingKeys, cap 10).
    private var pendingKeys: [Key] = []
    /// App to launch once connected (fork's pendingLaunch).
    private var pendingLaunch: SamsungApp?
    /// Continuation waiting for the `ed.installedApp.get` reply.
    private var appsContinuation: CheckedContinuation<[SamsungApp]?, Never>?
    /// Generation counter so a late timeout only cancels its own request.
    private var appsRequest = 0

    init() {
        let delegate = SamsungTrustDelegate()
        session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Connection

    func connect(to host: String) async throws {
        if connectedHost == host, task != nil, !connectionLost { return }
        resetConnectionState()

        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.port = 8002
        components.path = "/api/v2/channels/samsung.remote.control"
        var items = [URLQueryItem(name: "name",
                                  value: Data(clientName.utf8).base64EncodedString())]
        // Only append the token when it is non-empty: older models never
        // issue tokens, and an empty `token=` param is not the same as
        // no token (fork's SamsungDriver).
        if let token = storedToken(for: host), !token.isEmpty {
            items.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = items
        guard let url = components.url else { throw URLError(.badURL) }

        let webSocket = session.webSocketTask(with: url)
        task = webSocket
        connectedHost = host
        connectionLost = false
        webSocket.resume()

        do {
            try await waitForConnectEvent()
        } catch {
            resetConnectionState()
            throw error
        }

        // Flush keys / an app queued while disconnected (fork flushes
        // these on ms.channel.connect).
        await flushPending()

        // Drain incoming events in the background (keeps the socket healthy;
        // also notices if the TV later revokes access).
        drainTask = Task { [weak self] in
            await self?.drainEvents()
        }
        // Best effort: learn the TV's MAC for Wake-on-LAN power-on.
        Task { await self.fetchAndStoreMAC(for: host) }
    }

    /// Explicit disconnect (user leaving the remote): clears the
    /// queued keys/launch too. A reconnect via connect() keeps the
    /// queue — that is what makes a queued key survive a reconnect.
    func disconnect() {
        resetConnectionState()
        pendingKeys = []
        pendingLaunch = nil
        appsContinuation?.resume(returning: nil)
        appsContinuation = nil
    }

    /// Resets the socket without dropping queued keys/launches (the
    /// fork's open() never clears the queue; only disconnect does).
    private func resetConnectionState() {
        drainTask?.cancel()
        drainTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connectedHost = nil
        connectionLost = false
    }

    /// Sends queued keys (in order) and a queued app launch, now that
    /// the TV has let us in. Failures are swallowed: the queue is
    /// best-effort, like the fork's flush.
    private func flushPending() async {
        let queued = pendingKeys
        pendingKeys = []
        for key in queued {
            try? await sendKeyPayload(key, cmd: "Click")
        }
        if let app = pendingLaunch {
            pendingLaunch = nil
            try? await sendLaunchPayload(app)
        }
    }

    /// Waits for `ms.channel.connect` (or an error event), racing a 25 s timeout.
    private func waitForConnectEvent() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.receiveUntilConnectEvent() }
            group.addTask {
                try await Task.sleep(nanoseconds: 25_000_000_000)
                throw SamsungError.timeout
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func receiveUntilConnectEvent() async throws {
        guard let task else { throw SamsungError.notConnected }
        while !Task.isCancelled {
            let message = try await task.receive()
            guard case .string(let text) = message else { continue }
            guard let event = parseEvent(text) else { continue }
            switch event {
            case .connected(let token):
                if let host = connectedHost {
                    // Older models never issue tokens; store an empty
                    // string as the "we've been allowed" marker, and
                    // keep a stored token when the TV sends none (fork).
                    storeToken(token ?? storedToken(for: host) ?? "", for: host)
                }
                return
            case .unauthorized:
                if let host = connectedHost {
                    UserDefaults.standard.removeObject(forKey: tokenKey(for: host))
                }
                throw SamsungError.denied
            case .timedOut:
                throw SamsungError.timeout
            case .other:
                continue
            }
        }
        throw CancellationError()
    }

    private func drainEvents() async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                guard case .string(let text) = message else { continue }
                if let apps = parseInstalledApps(text) {
                    appsContinuation?.resume(returning: apps)
                    appsContinuation = nil
                    continue
                }
                guard let event = parseEvent(text) else { continue }
                switch event {
                case .unauthorized, .timedOut:
                    if let host = connectedHost {
                        UserDefaults.standard.removeObject(forKey: tokenKey(for: host))
                    }
                    connectionLost = true
                    return
                default:
                    continue
                }
            } catch {
                connectionLost = true
                return
            }
        }
    }

    /// Parses an `ed.installedApp.get` reply into apps, or nil when the
    /// message is any other event. The app list sits at
    /// `data.data` in the message JSON (fork's SamsungDriver).
    private func parseInstalledApps(_ text: String) -> [SamsungApp]? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["event"] as? String == "ed.installedApp.get" else { return nil }
        let list = (json["data"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return list.compactMap { entry -> SamsungApp? in
            guard let id = entry["appId"] as? String,
                  let name = entry["name"] as? String else { return nil }
            let type = entry["app_type"] as? Int
            return SamsungApp(id: id, name: name,
                              actionType: type == 4 ? "NATIVE_LAUNCH" : "DEEP_LINK")
        }
    }

    private enum ConnectEvent {
        case connected(token: String?)
        case unauthorized
        case timedOut
        case other
    }

    private func parseEvent(_ text: String) -> ConnectEvent? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? String else { return nil }
        switch event {
        case "ms.channel.connect":
            let token = (json["data"] as? [String: Any])?["token"] as? String
            return .connected(token: token)
        case "ms.channel.unauthorized":
            return .unauthorized
        case "ms.channel.timeOut":
            return .timedOut
        default:
            return .other
        }
    }

    // MARK: - Keys

    func sendKey(_ key: Key, to host: String) async throws {
        do {
            try await connect(to: host)
        } catch {
            // Queue the press (cap 10) so it fires on the next
            // successful connect instead of being lost (fork's
            // pendingKeys). A later disconnect drops the queue.
            if pendingKeys.count < 10 { pendingKeys.append(key) }
            throw error
        }
        try await sendKeyPayload(key, cmd: "Click")
    }

    /// Sends one key on the open socket (connect first — use
    /// sendKey(_:to:) for the full connect-or-queue path).
    private func sendKeyPayload(_ key: Key, cmd: String) async throws {
        guard let task else { throw SamsungError.notConnected }
        try await throttle()
        let payload: [String: Any] = [
            "method": "ms.remote.control",
            "params": [
                "Cmd": cmd,
                "DataOfCmd": key.rawValue,
                "Option": "false",
                "TypeOfRemote": "SendRemoteKey",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        do {
            try await task.send(.string(String(decoding: data, as: UTF8.self)))
        } catch {
            connectionLost = true
            throw error
        }
        lastSend = Date()
    }

    /// Power: normal key while the TV is reachable. When it is not,
    /// check whether the TV is awake first (fork's powerOnOrQueue):
    /// if it is, our socket just dropped — reconnect and send power
    /// as usual. If it is asleep, wake it with Wake-on-LAN and retry
    /// the connection; deliberately do NOT send KEY_POWER after waking
    /// (it would switch the TV straight back off). Replaces the old
    /// throw-`wakeSignalSent` two-tap flow.
    func sendPower(to host: String) async throws {
        if connectedHost == host, task != nil, !connectionLost {
            try await sendKey(.power, to: host)
            return
        }
        if await isAwake(host: host) {
            try await connect(to: host)
            try await sendKey(.power, to: host)
            return
        }
        guard let mac = storedMAC(for: host) else {
            // No MAC to wake with: try a plain connect so the user
            // gets a real error instead of silence.
            try await sendKey(.power, to: host)
            return
        }
        try await wakeAndReconnect(mac: mac, host: host)
    }

    /// Wake the TV and reconnect, re-sending the wake packet + a
    /// connect attempt every 3 s, up to 5 attempts (fork's wake /
    /// retryAfterWake). Returns with the TV on and connected — the
    /// caller must NOT send KEY_POWER afterwards.
    private func wakeAndReconnect(mac: String, host: String) async throws {
        var lastError: Error = SamsungError.notConnected
        for _ in 1...5 {
            Self.sendMagicPacket(mac: mac, host: host)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            do {
                try await connect(to: host)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Power off: hold KEY_POWER for 3 s. A short press only toggles
    /// Art Mode on The Frame (fork's holdPower).
    func sendPowerOff(to host: String) async throws {
        try await connect(to: host)
        try await sendKeyPayload(.power, cmd: "Press")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        try await sendKeyPayload(.power, cmd: "Release")
    }

    /// Installed apps via `ed.installedApp.get` (4 s timeout, fork).
    /// Returns nil when not connected or on timeout.
    func installedApps(on host: String) async -> [SamsungApp]? {
        guard connectedHost == host, task != nil, !connectionLost else { return nil }
        appsContinuation?.resume(returning: nil)
        appsContinuation = nil
        appsRequest += 1
        let request = appsRequest
        return await withCheckedContinuation { (continuation: CheckedContinuation<[SamsungApp]?, Never>) in
            appsContinuation = continuation
            Task {
                do {
                    try await self.sendInstalledAppsRequest()
                } catch {
                    await self.timeoutInstalledApps(request: request)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await self.timeoutInstalledApps(request: request)
            }
        }
    }

    /// Only times out our own request, not a newer one that replaced it.
    private func timeoutInstalledApps(request: Int) {
        guard request == appsRequest else { return }
        appsContinuation?.resume(returning: nil)
        appsContinuation = nil
    }

    private func sendInstalledAppsRequest() async throws {
        guard let task else { return }
        let payload: [String: Any] = [
            "method": "ms.channel.emit",
            "params": ["event": "ed.installedApp.get", "to": "host"],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    /// Launches an app (`ed.apps.launch`); when not connected the app
    /// is queued and launched once the TV lets us in (fork's
    /// pendingLaunch).
    func launch(_ app: SamsungApp, to host: String) async throws {
        if connectedHost == host, task != nil, !connectionLost {
            try await sendLaunchPayload(app)
            return
        }
        pendingLaunch = app
        try await connect(to: host) // flushes pendingLaunch on connect
    }

    private func sendLaunchPayload(_ app: SamsungApp) async throws {
        guard let task else { throw SamsungError.notConnected }
        let payload: [String: Any] = [
            "method": "ms.channel.emit",
            "params": [
                "event": "ed.apps.launch",
                "to": "host",
                "data": ["appId": app.id, "action_type": app.actionType],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    /// Type into a native Tizen text field that is open and focused.
    /// Does not work inside streaming apps' own search screens.
    func sendText(_ text: String, to host: String) async throws {
        try await connect(to: host)
        guard let task else { throw SamsungError.notConnected }
        try await throttle()
        let base64 = Data(text.utf8).base64EncodedString()
        let input: [String: Any] = [
            "method": "ms.remote.control",
            "params": ["Cmd": base64, "DataOfCmd": "base64", "TypeOfRemote": "SendInputString"],
        ]
        let inputData = try JSONSerialization.data(withJSONObject: input)
        try await task.send(.string(String(decoding: inputData, as: UTF8.self)))
        lastSend = Date()
        try await throttle()
        let end: [String: Any] = [
            "method": "ms.remote.control",
            "params": ["TypeOfRemote": "SendInputEnd"],
        ]
        let endData = try JSONSerialization.data(withJSONObject: end)
        try await task.send(.string(String(decoding: endData, as: UTF8.self)))
        lastSend = Date()
    }

    /// Keys must be ≥200 ms apart or the TV may coalesce them.
    private func throttle() async throws {
        let gap = Date().timeIntervalSince(lastSend)
        if gap < 0.2 {
            try await Task.sleep(nanoseconds: UInt64((0.2 - gap) * 1_000_000_000))
        }
    }

    // MARK: - Token / MAC storage (UserDefaults; low-risk pairing tokens)

    private func tokenKey(for host: String) -> String { "samsung.token.\(host)" }
    private func macKey(for host: String) -> String { "samsung.mac.\(host)" }

    private func storedToken(for host: String) -> String? {
        UserDefaults.standard.string(forKey: tokenKey(for: host))
    }

    private func storeToken(_ token: String, for host: String) {
        UserDefaults.standard.set(token, forKey: tokenKey(for: host))
    }

    private func storedMAC(for host: String) -> String? {
        UserDefaults.standard.string(forKey: macKey(for: host))
    }

    /// GET http://<host>:8001/api/v2/ returns device.wifiMac for Wake-on-LAN.
    private func fetchAndStoreMAC(for host: String) async {
        if storedMAC(for: host) != nil { return }
        guard let info = await deviceInfo(host: host),
              let mac = info["wifiMac"] as? String, !mac.isEmpty else { return }
        UserDefaults.standard.set(mac, forKey: macKey(for: host))
    }

    /// The TV's `device` object from GET http://<host>:8001/api/v2/,
    /// or nil when the TV does not answer.
    private func deviceInfo(host: String, timeout: TimeInterval = 3) async -> [String: Any]? {
        guard let url = URL(string: "http://\(host):8001/api/v2/") else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return json["device"] as? [String: Any]
        } catch {
            return nil
        }
    }

    /// Older models don't report PowerState; if they answer at all, they're on.
    private func isAwake(host: String) async -> Bool {
        guard let info = await deviceInfo(host: host, timeout: 1.5) else { return false }
        let power = info["PowerState"] as? String
        return power == nil || power == "on"
    }

    /// Wake-on-LAN magic packet, sent to the TV's last-known address
    /// AND broadcast, on ports 9 and 7 (fork's WakeOnLAN). iOS blocks
    /// broadcast without the multicast entitlement, so the unicast copy
    /// is what usually works in LiveContainer.
    private static func sendMagicPacket(mac: String, host: String) {
        guard let bytes = macBytes(mac) else { return }
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        for target in [host, "255.255.255.255"] {
            for port: UInt16 in [9, 7] {
                sendUDPPacket(packet, to: target, port: port)
            }
        }
    }

    /// Parses "aa:bb:cc:dd:ee:ff" or "aa-bb-cc-dd-ee-ff".
    private static func macBytes(_ mac: String) -> [UInt8]? {
        let parts = mac.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        return bytes.count == 6 ? bytes : nil
    }

    private static func sendUDPPacket(_ packet: [UInt8], to host: String, port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var broadcast: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast,
                   socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return }
        packet.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    _ = sendto(fd, raw.baseAddress, packet.count, 0, ptr,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}

/// URLSession delegate for the Samsung wss connection. The TV uses a
/// self-signed certificate, so trust is relaxed — but only for
/// private-network addresses (fork's LocalTrustDelegate). A public
/// host falls back to default handling. Used only for the Samsung TV
/// WebSocket session.
private final class SamsungTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge,
                        _ completion: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = space.serverTrust,
           Self.isPrivateAddress(space.host) {
            completion(.useCredential, URLCredential(trust: trust))
        } else {
            completion(.performDefaultHandling, nil)
        }
    }

    /// 10/8, 172.16/12, 192.168/16, 169.254 link-local, `.local`
    /// names, and IPv6 link-local / ULA (fork's
    /// LocalNetwork.isPrivateAddress).
    static func isPrivateAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        return host.hasSuffix(".local") || host.hasPrefix("fe80") || host.hasPrefix("fd")
    }
}
