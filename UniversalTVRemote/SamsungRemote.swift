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
        case wakeSignalSent
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .denied:
                return "The TV refused the connection. Allow this app on the TV and try again."
            case .timeout:
                return "The TV didn't answer in time. Make sure it's on and accept the prompt on the TV."
            case .notConnected:
                return "Couldn't connect to the TV."
            case .wakeSignalSent:
                return "Wake-up signal sent. Give the TV a moment to turn on, then try again."
            case .invalidResponse:
                return "The TV sent an unexpected reply."
            }
        }
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
        case info = "KEY_INFO"
        case menu = "KEY_MENU"
        case play = "KEY_PLAY"
        case pause = "KEY_PAUSE"
        case stop = "KEY_STOP"
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

    init() {
        let delegate = TrustAllDelegate()
        session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Connection

    func connect(to host: String) async throws {
        if connectedHost == host, task != nil, !connectionLost { return }
        disconnect()

        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.port = 8002
        components.path = "/api/v2/channels/samsung.remote.control"
        var items = [URLQueryItem(name: "name",
                                  value: Data(clientName.utf8).base64EncodedString())]
        if let token = storedToken(for: host) {
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
            disconnect()
            throw error
        }

        // Drain incoming events in the background (keeps the socket healthy;
        // also notices if the TV later revokes access).
        drainTask = Task { [weak self] in
            await self?.drainEvents()
        }
        // Best effort: learn the TV's MAC for Wake-on-LAN power-on.
        Task { await self.fetchAndStoreMAC(for: host) }
    }

    func disconnect() {
        drainTask?.cancel()
        drainTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connectedHost = nil
        connectionLost = false
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
                if let token, let host = connectedHost {
                    storeToken(token, for: host)
                }
                return
            case .unauthorized:
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
                guard case .string(let text) = message,
                      let event = parseEvent(text) else { continue }
                switch event {
                case .unauthorized, .timedOut:
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
        try await connect(to: host)
        guard let task else { throw SamsungError.notConnected }
        try await throttle()
        let payload: [String: Any] = [
            "method": "ms.remote.control",
            "params": [
                "Cmd": "Click",
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

    /// Power: normal key while the TV is reachable; if the TV is off and its
    /// MAC is known, send Wake-on-LAN instead and report it.
    func sendPower(to host: String) async throws {
        do {
            try await sendKey(.power, to: host)
        } catch {
            if let mac = storedMAC(for: host) {
                Self.sendMagicPacket(mac: mac)
                throw SamsungError.wakeSignalSent
            }
            throw error
        }
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
        guard let url = URL(string: "http://\(host):8001/api/v2/") else { return }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let device = json["device"] as? [String: Any],
                  let mac = device["wifiMac"] as? String, !mac.isEmpty else { return }
            UserDefaults.standard.set(mac, forKey: macKey(for: host))
        } catch {
            // MAC is a best-effort bonus; power-off via the socket still works.
        }
    }

    private static func sendMagicPacket(mac: String) {
        let bytes = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return }
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var broadcast: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast,
                   socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(9).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("255.255.255.255"))
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

/// URLSession delegate that accepts the TV's self-signed certificate.
/// This session is used only for the Samsung TV WebSocket.
private final class TrustAllDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
