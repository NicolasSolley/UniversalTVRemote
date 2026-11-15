import Foundation
import Security

// MARK: - LG webOS remote
//
// Protocol: WebSocket to wss://<host>:3001 (newer firmware) with a
// self-signed certificate, falling back to ws://<host>:3000 (pre-2018).
// First message is a `register` with the simple manifest (fork's
// LGDriver); the signed sample manifest is kept as a fallback for old
// firmware. The TV shows a pairing prompt and replies `registered`
// with a client-key, which is stored and reused on later connects —
// on BOTH transports, so pre-2018 TVs (plain ws only) do not
// re-prompt on every connect. Control requests are ssap:// URIs;
// D-pad/buttons go over a second WebSocket (the pointer input socket)
// as plain text `type:button\nname:UP\n\n`.
//
// Sources: hobbyquaker/lgtv2 pairing.json via mazen-salah
// `lib/services/lg/lg_pairing.dart` (manifest below, verbatim), and the
// ssap URI list in the project's protocol research notes. The `signed`
// block is covered by the manifest's signature and must not be edited.
// Power-on is Wake-on-LAN only on webOS and there is no verified MAC
// source, so it is not implemented; system/turnOff handles power-off.
//
// This file was never tested against a live TV — only compile-verified.

/// Errors specific to the LG webOS remote.
enum LGError: Error, LocalizedError {
    case notConnected
    case pairingDenied
    case pairingTimeout
    case certificateChanged
    case timeout
    case invalidResponse
    case remoteError(String)
    /// Internal: the TV rejected the signed manifest. Retried once with the
    /// unsigned variant. Never surfaced to the user.
    case blacklistOrSignature

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the TV."
        case .pairingDenied: return "Pairing was rejected on the TV. Check the TV screen and try again."
        case .pairingTimeout: return "The TV didn't answer the pairing prompt in time. Check the TV screen and try again."
        case .certificateChanged: return "This TV's security certificate changed. Forget the TV in the app and pair it again."
        case .timeout: return "The TV didn't respond in time."
        case .invalidResponse: return "The TV sent an unexpected response."
        case .remoteError(let message): return message
        case .blacklistOrSignature: return "The TV rejected the pairing manifest."
        }
    }
}

/// An installed LG app, as returned by listLaunchPoints.
struct LGApp: Identifiable, Hashable {
    let id: String
    let name: String
    let iconURL: URL?
}

/// LG webOS remote control over a WebSocket connection.
actor LGRemote {
    // MARK: - Manifests (verbatim, from hobbyquaker/lgtv2 pairing.json)

    /// Signed sample manifest. Sent verbatim in the register message.
    private static let signedManifestJSON = #"""
{
    "manifestVersion": 1,
    "appVersion": "1.1",
    "signed": {
      "created": "20140509",
      "appId": "com.lge.test",
      "vendorId": "com.lge",
      "localizedAppNames": {
        "": "LG Remote App",
        "ko-KR": "리모컨 앱",
        "zxx-XX": "ЛГ Rэмotэ AПП"
      },
      "localizedVendorNames": {
        "": "LG Electronics"
      },
      "permissions": [
        "TEST_SECURE",
        "CONTROL_INPUT_TEXT",
        "CONTROL_MOUSE_AND_KEYBOARD",
        "READ_INSTALLED_APPS",
        "READ_LGE_SDX",
        "READ_NOTIFICATIONS",
        "SEARCH",
        "WRITE_SETTINGS",
        "WRITE_NOTIFICATION_ALERT",
        "CONTROL_POWER",
        "READ_CURRENT_CHANNEL",
        "READ_RUNNING_APPS",
        "READ_UPDATE_INFO",
        "UPDATE_FROM_REMOTE_APP",
        "READ_LGE_TV_INPUT_EVENTS",
        "READ_TV_CURRENT_TIME"
      ],
      "serial": "2f930e2d2cfe083771f68e4fe7bb07"
    },
    "permissions": [
      "LAUNCH",
      "LAUNCH_WEBAPP",
      "APP_TO_APP",
      "CLOSE",
      "TEST_OPEN",
      "TEST_PROTECTED",
      "CONTROL_AUDIO",
      "CONTROL_DISPLAY",
      "CONTROL_INPUT_JOYSTICK",
      "CONTROL_INPUT_MEDIA_RECORDING",
      "CONTROL_INPUT_MEDIA_PLAYBACK",
      "CONTROL_INPUT_TV",
      "CONTROL_POWER",
      "READ_APP_STATUS",
      "READ_CURRENT_CHANNEL",
      "READ_INPUT_DEVICE_LIST",
      "READ_NETWORK_STATE",
      "READ_RUNNING_APPS",
      "READ_TV_CHANNEL_LIST",
      "WRITE_NOTIFICATION_TOAST",
      "READ_POWER_STATE",
      "READ_COUNTRY_INFO",
      "READ_SETTINGS",
      "CONTROL_TV_SCREEN",
      "CONTROL_TV_STANBY",
      "CONTROL_FAVORITE_GROUP",
      "CONTROL_USER_INFO",
      "CHECK_BLUETOOTH_DEVICE",
      "CONTROL_BLUETOOTH",
      "CONTROL_TIMER_INFO",
      "STB_INTERNAL_CONNECTION",
      "CONTROL_RECORDING",
      "READ_RECORDING_STATE",
      "WRITE_RECORDING_LIST",
      "READ_RECORDING_LIST",
      "READ_RECORDING_SCHEDULE",
      "WRITE_RECORDING_SCHEDULE",
      "READ_STORAGE_DEVICE_LIST",
      "READ_TV_PROGRAM_INFO",
      "CONTROL_BOX_CHANNEL",
      "READ_TV_ACR_AUTH_TOKEN",
      "READ_TV_CONTENT_STATE",
      "READ_TV_CURRENT_TIME",
      "ADD_LAUNCHER_CHANNEL",
      "SET_CHANNEL_SKIP",
      "RELEASE_CHANNEL_SKIP",
      "CONTROL_CHANNEL_BLOCK",
      "DELETE_SELECT_CHANNEL",
      "CONTROL_CHANNEL_GROUP",
      "SCAN_TV_CHANNELS",
      "CONTROL_TV_POWER",
      "CONTROL_WOL"
    ],
    "signatures": [
      {
        "signatureVersion": 1,
        "signature": "eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pbmctY2VydCIsInNpZ25hdHVyZVZlcnNpb24iOjF9.hrVRgjCwXVvE2OOSpDZ58hR+59aFNwYDyjQgKk3auukd7pcegmE2CzPCa0bJ0ZsRAcKkCTJrWo5iDzNhMBWRyaMOv5zWSrthlf7G128qvIlpMT0YNY+n/FaOHE73uLrS/g7swl3/qH/BGFG2Hu4RlL48eb3lLKqTt2xKHdCs6Cd4RMfJPYnzgvI4BNrFUKsjkcu+WD4OO2A27Pq1n50cMchmcaXadJhGrOqH5YmHdOCj5NSHzJYrsW0HPlpuAx/ECMeIZYDh6RMqaFM2DXzdKX9NmmyqzJ3o/0lkk/N97gfVRLW5hA29yeAwaCViZNCP8iC9aO0q9fQojoa7NQnAtw=="
      }
    ]
  }
"""#

    /// Simple manifest (fork's LGDriver.register): appVersion 1.1,
    /// manifestVersion 1, 37 permissions, no `signed` block, no
    /// signatures. This is the PRIMARY manifest — it is what current
    /// firmware expects. The signed manifest below is kept as the
    /// fallback for old firmware.
    private static let simpleManifestJSON = #"""
{
  "appVersion": "1.1",
  "manifestVersion": 1,
  "permissions": [
    "APP_TO_APP",
    "CLOSE",
    "CONTROL_AUDIO",
    "CONTROL_DISPLAY",
    "CONTROL_INPUT_JOYSTICK",
    "CONTROL_INPUT_MEDIA_PLAYBACK",
    "CONTROL_INPUT_MEDIA_RECORDING",
    "CONTROL_INPUT_TEXT",
    "CONTROL_INPUT_TV",
    "CONTROL_MOUSE_AND_KEYBOARD",
    "CONTROL_POWER",
    "CONTROL_TV_SCREEN",
    "LAUNCH",
    "LAUNCH_WEBAPP",
    "READ_APP_STATUS",
    "READ_COUNTRY_INFO",
    "READ_CURRENT_CHANNEL",
    "READ_INPUT_DEVICE_LIST",
    "READ_INSTALLED_APPS",
    "READ_LGE_SDX",
    "READ_LGE_TV_INPUT_EVENTS",
    "READ_NETWORK_STATE",
    "READ_NOTIFICATIONS",
    "READ_POWER_STATE",
    "READ_RUNNING_APPS",
    "READ_SETTINGS",
    "READ_TV_CHANNEL_LIST",
    "READ_TV_CURRENT_TIME",
    "READ_UPDATE_INFO",
    "SEARCH",
    "TEST_OPEN",
    "TEST_PROTECTED",
    "TEST_SECURE",
    "UPDATE_FROM_REMOTE_APP",
    "WRITE_NOTIFICATION_ALERT",
    "WRITE_NOTIFICATION_TOAST",
    "WRITE_SETTINGS"
  ]
}
"""#

    // MARK: - State

    private let host: String
    private var session: URLSession?
    private var socketTask: URLSessionWebSocketTask?
    private var pointerTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pointerReceiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    /// Next request id.
    private var requestId = 0
    /// In-flight ssap requests, keyed by id.
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    /// Continuation waiting for the `registered` reply.
    private var registerContinuation: CheckedContinuation<Void, Error>?
    /// Whether the client-key was accepted this session.
    private(set) var isRegistered = false
    /// Whether we connected over the secure port (3001).
    private var isSecureConnection = false

    init(host: String) {
        self.host = host
    }

    // MARK: - Public API

    /// Connects and registers. First connect shows a pairing prompt on the
    /// TV; the user has up to 60 seconds to accept it. On later connects the
    /// stored client-key is reused and no prompt appears.
    /// Throws `LGError.pairingDenied` / `.pairingTimeout` /
    /// `.certificateChanged` on the respective failures.
    func connect() async throws {
        disconnect()
        UserDefaults.standard.removeObject(forKey: mismatchKey)

        // Try the secure port first, then the legacy plaintext port.
        do {
            try await openSocket(urlString: "wss://\(host):3001")
            isSecureConnection = true
        } catch LGError.certificateChanged {
            throw LGError.certificateChanged
        } catch {
            try await openSocket(urlString: "ws://\(host):3000")
            isSecureConnection = false
        }

        do {
            try await register(simple: true)
        } catch LGError.blacklistOrSignature {
            // One retry with the signed manifest, for old firmware.
            try await register(simple: false)
        }
        isRegistered = true
        startPing()
    }

    /// Disconnects the main and pointer sockets.
    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        pointerReceiveTask?.cancel()
        pointerReceiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
        pointerTask?.cancel(with: .goingAway, reason: nil)
        pointerTask = nil
        session?.invalidateAndCancel()
        session = nil
        for (_, continuation) in pending {
            continuation.resume(throwing: LGError.notConnected)
        }
        pending.removeAll()
        registerContinuation?.resume(throwing: LGError.notConnected)
        registerContinuation = nil
        isRegistered = false
        isSecureConnection = false
    }

    // MARK: Keys (via the pointer input socket)

    func dpadUp() async throws { try await sendButton("UP") }
    func dpadDown() async throws { try await sendButton("DOWN") }
    func dpadLeft() async throws { try await sendButton("LEFT") }
    func dpadRight() async throws { try await sendButton("RIGHT") }
    func enter() async throws { try await sendButton("ENTER") }
    func back() async throws { try await sendButton("BACK") }
    func home() async throws { try await sendButton("HOME") }
    func menu() async throws { try await sendButton("MENU") }
    func info() async throws { try await sendButton("INFO") }
    func exit() async throws { try await sendButton("EXIT") }

    func digit(_ digit: Int) async throws {
        guard (0...9).contains(digit) else { return }
        try await sendButton("\(digit)")
    }

    // MARK: Volume / channel / media

    /// Volume/channel/mute go over the pointer socket's buttons
    /// (fork's buttonName), with the ssap URI as fallback when the
    /// pointer path fails.
    func volumeUp() async throws {
        do { try await sendButton("VOLUMEUP") } catch { try await sendCommand(uri: "ssap://audio/volumeUp") }
    }
    func volumeDown() async throws {
        do { try await sendButton("VOLUMEDOWN") } catch { try await sendCommand(uri: "ssap://audio/volumeDown") }
    }
    func channelUp() async throws {
        do { try await sendButton("CHANNELUP") } catch { try await sendCommand(uri: "ssap://tv/channelUp") }
    }
    func channelDown() async throws {
        do { try await sendButton("CHANNELDOWN") } catch { try await sendCommand(uri: "ssap://tv/channelDown") }
    }

    /// Toggles mute: pointer MUTE button first, ssap read-then-set as fallback.
    func toggleMute() async throws {
        do {
            try await sendButton("MUTE")
        } catch {
            let state = try await request(uri: "ssap://audio/getVolume")
            let muted = state["muted"] as? Bool ?? false
            try await sendCommand(uri: "ssap://audio/setMute", payload: ["mute": !muted])
        }
    }

    func play() async throws { try await sendCommand(uri: "ssap://media.controls/play") }
    func pause() async throws { try await sendCommand(uri: "ssap://media.controls/pause") }
    func stop() async throws { try await sendCommand(uri: "ssap://media.controls/stop") }
    func rewind() async throws { try await sendCommand(uri: "ssap://media.controls/rewind") }
    func fastForward() async throws { try await sendCommand(uri: "ssap://media.controls/fastForward") }

    /// Power off. Power-on is not available (Wake-on-LAN only, no verified MAC source).
    func powerOff() async throws { try await sendCommand(uri: "ssap://system/turnOff") }

    /// Text input (native webOS text fields): insert, then submit with
    /// Enter (fork's sendText + sendEnterKey).
    func sendText(_ text: String) async throws {
        try await sendCommand(uri: "ssap://com.webos.service.ime/insertText",
                              payload: ["text": text, "replace": 0])
        try await sendCommand(uri: "ssap://com.webos.service.ime/sendEnterKey")
    }

    /// Backspace: delete one character (fork's send(.backspace)).
    func deleteCharacters() async throws {
        try await sendCommand(uri: "ssap://com.webos.service.ime/deleteCharacters",
                              payload: ["count": 1])
    }

    // MARK: - Apps

    /// Installed apps via listLaunchPoints (4 s timeout, fork).
    /// Returns nil when not connected or on timeout.
    func installedApps() async -> [LGApp]? {
        guard socketTask != nil else { return nil }
        do {
            let payload = try await request(uri: "ssap://com.webos.applicationManager/listLaunchPoints",
                                            timeout: 4)
            let points = payload["launchPoints"] as? [[String: Any]] ?? []
            return points.compactMap { point -> LGApp? in
                guard let id = point["id"] as? String,
                      let title = point["title"] as? String else { return nil }
                let icon = (point["largeIcon"] as? String ?? point["icon"] as? String)
                    .flatMap(URL.init(string:))
                return LGApp(id: id, name: title, iconURL: icon)
            }
        } catch {
            return nil
        }
    }

    /// Launches an app by id (fork's launch()).
    func launch(_ app: LGApp) async throws {
        try await sendCommand(uri: "ssap://system.launcher/launch", payload: ["id": app.id])
    }

    // MARK: - Socket plumbing

    private var clientKeyKey: String { "lg.clientkey.\(host)" }
    private var certPinKey: String { "lg.certpin.\(host)" }
    private var certFingerprintKey: String { "lg.certfp.\(host)" }
    private var mismatchKey: String { "lg.certmismatch.\(host)" }

    /// Opens the main WebSocket and starts the receive loop. Throws
    /// `LGError.certificateChanged` if the stored certificate pin mismatches.
    private func openSocket(urlString: String) async throws {
        guard let url = URL(string: urlString) else { throw LGError.invalidResponse }
        let delegate = LGTrustDelegate(host: host)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: url)
        socketTask = task
        task.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        // Wait for the handshake to settle — but fail fast when the
        // socket closes before opening (fork's onClose-driven
        // fallback): a refused wss connection fails in milliseconds,
        // so the caller can retry plaintext immediately instead of
        // waiting out a blind 3 s sleep. The 3 s bound stays: a
        // handshake still in flight at the deadline proceeds to
        // register, as before.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if UserDefaults.standard.bool(forKey: mismatchKey) {
                throw LGError.certificateChanged
            }
            guard task.state != .completed else { throw LGError.notConnected }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if UserDefaults.standard.bool(forKey: mismatchKey) {
            throw LGError.certificateChanged
        }
        guard task.state == .running else { throw LGError.notConnected }
    }

    // MARK: - Continuation bookkeeping

    /// The `withCheckedThrowingContinuation` bodies and the timeout tasks
    /// are nonisolated, so they cannot touch actor state directly. These
    /// actor-isolated helpers let them hand continuations to the actor
    /// with `await` instead. Taking (rather than reading) a continuation
    /// clears its slot atomically, so exactly one side — the TV's reply
    /// or the timeout — can resume it.
    private func storeRegisterContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        registerContinuation = continuation
    }

    private func takeRegisterContinuation() -> CheckedContinuation<Void, Error>? {
        let continuation = registerContinuation
        registerContinuation = nil
        return continuation
    }

    private func storePendingContinuation(id: String, continuation: CheckedContinuation<[String: Any], Error>) {
        pending[id] = continuation
    }

    private func takePendingContinuation(id: String) -> CheckedContinuation<[String: Any], Error>? {
        pending.removeValue(forKey: id)
    }

    /// Sends the register message and waits for the `registered` reply
    /// (up to 60 seconds for the user to accept the TV prompt).
    private func register(simple: Bool) async throws {
        var payloadParts: [String] = [
            "\"forcePairing\":false",
            "\"pairingType\":\"PROMPT\"",
        ]
        // Send the stored client-key on BOTH transports: on pre-2018
        // TVs (plain ws://:3000 only) omitting it re-triggers the
        // pairing prompt on every connect (fork's register()).
        if let key = UserDefaults.standard.string(forKey: clientKeyKey) {
            payloadParts.append("\"client-key\":\(jsonString(key))")
        }
        let manifest = simple ? Self.simpleManifestJSON : Self.signedManifestJSON
        payloadParts.append("\"manifest\":\(manifest)")
        let message = "{\"type\":\"register\",\"id\":\"reg\",\"payload\":{\(payloadParts.joined(separator: ","))}}"

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    Task {
                        // Store before sending: the TV's reply can only
                        // arrive after the register message goes out, so
                        // the reply handler always finds the continuation.
                        await self.storeRegisterContinuation(continuation)
                        do {
                            try await self.sendRaw(message)
                        } catch {
                            if let stored = await self.takeRegisterContinuation() {
                                stored.resume(throwing: error)
                            }
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                if let continuation = await self.takeRegisterContinuation() {
                    continuation.resume(throwing: LGError.pairingTimeout)
                }
                throw LGError.pairingTimeout
            }
            try await group.next()!
            group.cancelAll()
        }
    }

    /// Sends an ssap request and waits for its response (up to
    /// `timeout` seconds, default 5).
    private func request(uri: String, payload: [String: Any]? = nil,
                         timeout: TimeInterval = 5) async throws -> [String: Any] {
        requestId += 1
        let id = "\(requestId)"
        var message: [String: Any] = ["id": id, "type": "request", "uri": uri]
        if let payload { message["payload"] = payload }

        return try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
                    Task {
                        // Store before sending, as in register(): the
                        // response can only arrive after the request does.
                        await self.storePendingContinuation(id: id, continuation: continuation)
                        try? await self.sendJSON(message)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let continuation = await self.takePendingContinuation(id: id) {
                    continuation.resume(throwing: LGError.timeout)
                }
                throw LGError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Fire-and-forget ssap command (volume, media, power). No response awaited.
    private func sendCommand(uri: String, payload: [String: Any]? = nil) async throws {
        guard socketTask != nil else { throw LGError.notConnected }
        requestId += 1
        var message: [String: Any] = ["id": "\(requestId)", "type": "request", "uri": uri]
        if let payload { message["payload"] = payload }
        try await sendJSON(message)
    }

    /// Sends a button press over the pointer input socket, opening it first
    /// if needed. Waits up to 4 s for the pointer socket to be ready
    /// (fork's sendInteractive deadline) before sending.
    private func sendButton(_ name: String) async throws {
        let pointer = try await pointerSocket()
        try await waitForPointerReady(pointer)
        try await pointer.send(.string("type:button\nname:\(name)\n\n"))
    }

    /// Bounded readiness wait for the pointer socket. URLSession
    /// WebSocketTask has no open callback — sends queue until the
    /// handshake completes — so this is a liveness check, not a
    /// handshake wait: fail fast if the socket died, return at once
    /// once it is running.
    private func waitForPointerReady(_ pointer: URLSessionWebSocketTask) async throws {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if pointer.state == .completed { throw LGError.notConnected }
            if pointer.state == .running { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Returns the open pointer input socket, opening it first if needed.
    private func pointerSocket() async throws -> URLSessionWebSocketTask {
        if let pointerTask { return pointerTask }
        guard socketTask != nil else { throw LGError.notConnected }
        let response = try await request(uri: "ssap://com.webos.service.networkinput/getPointerInputSocket")
        guard let socketPath = response["socketPath"] as? String,
              let url = URL(string: socketPath),
              let session else { throw LGError.invalidResponse }
        let task = session.webSocketTask(with: url)
        pointerTask = task
        task.resume()
        pointerReceiveTask = Task { [weak self] in
            await self?.pointerReceiveLoop()
        }
        return task
    }

    // MARK: - Sending

    private func sendJSON(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { throw LGError.invalidResponse }
        try await sendRaw(text)
    }

    private func sendRaw(_ text: String) async throws {
        guard let socketTask else { throw LGError.notConnected }
        try await socketTask.send(.string(text))
    }

    /// JSON-encodes a string value (with quotes).
    private func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return text
    }

    // MARK: - Receiving

    private func receiveLoop() async {
        guard let socketTask else { return }
        while !Task.isCancelled {
            do {
                let message = try await socketTask.receive()
                switch message {
                case .string(let text):
                    handleMainMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleMainMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                // Socket closed or failed; stop the loop.
                break
            }
        }
    }

    private func pointerReceiveLoop() async {
        guard let pointerTask else { return }
        // The pointer socket sends nothing we need; just drain it so the
        // connection stays healthy.
        while !Task.isCancelled {
            do {
                _ = try await pointerTask.receive()
            } catch {
                break
            }
        }
    }

    /// Dispatches a message received on the main socket.
    private func handleMainMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }

        switch type {
        case "registered":
            // Promote the fingerprint we just saw to the stored pin, and
            // store the client-key for later connects.
            if let payload = object["payload"] as? [String: Any],
               let key = payload["client-key"] as? String {
                UserDefaults.standard.set(key, forKey: clientKeyKey)
            }
            if isSecureConnection,
               let fingerprint = UserDefaults.standard.data(forKey: certFingerprintKey) {
                UserDefaults.standard.set(fingerprint, forKey: certPinKey)
            }
            registerContinuation?.resume()
            registerContinuation = nil

        case "response":
            guard let id = object["id"] as? String,
                  let continuation = pending.removeValue(forKey: id) else { return }
            continuation.resume(returning: object["payload"] as? [String: Any] ?? [:])

        case "error":
            if let id = object["id"] as? String,
               let continuation = pending.removeValue(forKey: id) {
                let message = object["error"] as? String ?? "The TV reported an error."
                continuation.resume(throwing: LGError.remoteError(message))
            } else {
                // An error with no in-flight request is a registration failure.
                let message = object["error"] as? String ?? ""
                let lower = message.lowercased()
                if lower.contains("blacklist") || lower.contains("signature") {
                    registerContinuation?.resume(throwing: LGError.blacklistOrSignature)
                } else if lower.contains("denied") || lower.contains("cancel") || lower.contains("reject") {
                    registerContinuation?.resume(throwing: LGError.pairingDenied)
                } else {
                    registerContinuation?.resume(throwing: LGError.remoteError(message.isEmpty ? "Registration failed." : message))
                }
                registerContinuation = nil
            }

        default:
            break
        }
    }

    // MARK: - Keep-alive

    private func startPing() {
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, let task = await self.socketTask else { return }
                task.sendPing { _ in }
            }
        }
    }
}

// MARK: - Trust delegate (self-signed certificate + pinning)

/// URLSession delegate for the LG wss connection. The TV uses a self-signed
/// certificate, so we trust whatever it presents — but we pin the SHA-256
/// fingerprint next to the client-key and refuse a changed certificate
/// (never fall back to plaintext on a pin mismatch).
private final class LGTrustDelegate: NSObject, URLSessionDelegate {
    private let host: String

    init(host: String) {
        self.host = host
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecTrustGetCertificateAtIndex(trust, 0) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let der = SecCertificateCopyData(certificate) as Data
        let fingerprint = X509.sha256Fingerprint(certificateDER: der)
        UserDefaults.standard.set(fingerprint, forKey: "lg.certfp.\(host)")
        if let pin = UserDefaults.standard.data(forKey: "lg.certpin.\(host)"),
           pin != fingerprint {
            UserDefaults.standard.set(true, forKey: "lg.certmismatch.\(host)")
            completionHandler(.cancelAuthenticationChallenge, nil)
        } else {
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
}
