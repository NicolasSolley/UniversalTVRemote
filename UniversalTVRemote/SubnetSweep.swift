import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A TV (or Cast target) found by the unicast subnet sweep.
struct SweptDevice {
    let name: String
    let brand: TVDevice.Brand
    let host: String
    let port: Int
    let model: String?
    let manufacturer: String?
}

/// Unicast subnet-sweep discovery: the PRIMARY discovery path.
///
/// Why this exists: inside LiveContainer, the other two paths are dead.
/// Bonjour browsing is gated by the host app's `NSBonjourServices` list
/// (the guest's list is ignored), and SSDP multicast M-SEARCH needs
/// Apple's `com.apple.developer.networking.multicast` entitlement, which
/// the sideloaded LiveContainer host does not have — the packets never go
/// out. v1.0.2 proved it in the field: zero TVs found (TCL Google TV and
/// Samsung, both on, both found by a signed App Store remote app).
///
/// This sweep uses only plain unicast HTTP/TCP to addresses on the
/// phone's own Wi-Fi subnet — ordinary local networking, which works
/// from a LiveContainer guest. It is still a scan: no manual IP entry.
///
/// How it works: the phone's Wi-Fi IPv4 address + netmask come from
/// `getifaddrs` (interface `en0`). Hosts are probed in chunks of 32 with
/// short timeouts, so a full /24 finishes in a few seconds. Each host
/// gets up to five concurrent probes; the first decisive one wins:
///
/// - Roku: `GET http://<ip>:8060/query/device-info` (ECP device-info XML)
/// - Samsung: `GET http://<ip>:8001/api/v2/` (device JSON)
/// - DIAL: `GET http://<ip>:8008/ssdp/device-desc.xml` (UPnP description;
///   identifies LG by manufacturer, Samsung as a fallback, and any
///   Cast-capable display)
/// - Android TV Remote service: TCP connect to 6466 (control) / 6467
///   (pairing) — the discriminator for real Android/Google TV
/// - LG webOS: TCP connect to 3001 (wss) as a fallback signal
///
/// Classification is conservative: a plain Chromecast dongle also serves
/// the DIAL description, but it does NOT listen on 6466/6467, so it is
/// branded `.other` (discovery only) — never claimed as a controllable
/// Android TV. A DIAL responder is only branded `.androidTV` when the
/// remote-service port is open, or when the port alone answers. The
/// pairing/control handshake still confirms a device when the user taps
/// it; nothing here claims control that was not verified on the wire.
final class SubnetSweep {
    /// Short timeouts keep the whole sweep to a few seconds.
    private static let httpTimeout: TimeInterval = 0.7
    private static let tcpTimeout: TimeInterval = 0.5
    /// Hosts probed at once. 32 in flight × ~0.7 s worst case per host
    /// means a /24 (254 hosts, 8 chunks) finishes in ~6 s worst case and
    /// ~1–3 s typically, since most hosts refuse connections instantly.
    private static let chunkSize = 32
    /// Never sweep more than one /24, even on a wider subnet (a /16 has
    /// 65k addresses). The /24 containing the phone is where home TVs live.
    private static let maxHosts = 254

    /// Ephemeral session with short timeouts, used for all HTTP probes.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = httpTimeout
        config.timeoutIntervalForResource = 1.0
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    var onDevice: ((SweptDevice) -> Void)?
    var onFinished: (() -> Void)?
    /// e.g. "192.168.1.0/24" — set synchronously by `start()`, nil when
    /// the phone has no Wi-Fi address (sweep then finishes immediately).
    private(set) var subnetLabel: String?

    private var sweepTask: Task<Void, Never>?
    private var generation = 0

    /// Start a sweep. Safe to call while a previous sweep is running —
    /// the old one is cancelled. Called from `DiscoveryManager` (main
    /// actor), so `start`/`stop` always run on the main thread.
    func start() {
        stop()
        generation += 1
        let gen = generation
        guard let subnet = Self.wifiSubnet() else {
            subnetLabel = nil
            // No Wi-Fi subnet to scan — finish at once so the scan does
            // not wait on us; SSDP/Bonjour still run. Generation-guarded
            // like every other completion, so a stale finish can never
            // end a later scan early.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == gen else { return }
                self.onFinished?()
            }
            return
        }
        subnetLabel = subnet.label
        sweepTask = Task { [weak self] in
            await self?.run(hosts: subnet.hosts, generation: gen)
        }
    }

    /// Cancel the in-flight sweep. Stale completions are also guarded by
    /// the generation counter, so a finished sweep can never report into
    /// a later scan.
    func stop() {
        generation += 1
        sweepTask?.cancel()
        sweepTask = nil
    }

    // MARK: - Sweep driver

    private func run(hosts: [String], generation gen: Int) async {
        var index = 0
        while index < hosts.count {
            if Task.isCancelled { break }
            let end = min(index + Self.chunkSize, hosts.count)
            let chunk = Array(hosts[index..<end])
            index = end
            await withTaskGroup(of: SweptDevice?.self) { group in
                for host in chunk {
                    group.addTask { await Self.probe(host: host) }
                }
                for await found in group {
                    guard let device = found, !Task.isCancelled else { continue }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == gen else { return }
                        self.onDevice?(device)
                    }
                }
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == gen else { return }
            self.onFinished?()
        }
    }

    // MARK: - Per-host probe

    /// Runs all five probes for one host concurrently and returns the
    /// first decisive identification, in priority order. `async let`
    /// children are cancelled when this scope exits early.
    private static func probe(host: String) async -> SweptDevice? {
        async let roku = probeRoku(host: host)
        async let samsung = probeSamsung(host: host)
        async let dial = probeDIAL(host: host)
        async let androidPorts = probeAndroidTVPorts(host: host)
        async let lgPort = probeLGPort(host: host)

        if let found = await roku { return found }
        if let found = await samsung { return found }
        let dialInfo = await dial
        let portsOpen = await androidPorts
        if let info = dialInfo {
            return classifyDIAL(info, host: host, androidTVPortsOpen: portsOpen)
        }
        if portsOpen {
            return SweptDevice(name: host, brand: .androidTV, host: host,
                               port: 6466, model: nil, manufacturer: nil)
        }
        if await lgPort {
            return SweptDevice(name: host, brand: .lg, host: host,
                               port: 3001, model: nil, manufacturer: nil)
        }
        return nil
    }

    // MARK: - HTTP probes

    /// Roku ECP: a 200 from /query/device-info with a model or friendly
    /// name is a Roku, full stop — nothing else serves that endpoint.
    private static func probeRoku(host: String) async -> SweptDevice? {
        guard let url = URL(string: "http://\(host):8060/query/device-info"),
              let data = await httpGet(url: url) else { return nil }
        let fields = XMLFields.parse(data, wanted: ["friendly-device-name", "model-name", "vendor-name"])
        guard fields["model-name"] != nil || fields["friendly-device-name"] != nil else { return nil }
        let name = fields["friendly-device-name"] ?? fields["model-name"] ?? host
        return SweptDevice(name: name, brand: .roku, host: host, port: 8060,
                           model: fields["model-name"], manufacturer: fields["vendor-name"] ?? "Roku")
    }

    /// Samsung Tizen: a 200 from /api/v2/ with a `device` object is a
    /// Samsung TV — the same endpoint the Samsung remote itself reads.
    private static func probeSamsung(host: String) async -> SweptDevice? {
        guard let url = URL(string: "http://\(host):8001/api/v2/"),
              let data = await httpGet(url: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = json["device"] as? [String: Any] else { return nil }
        let name = (device["name"] as? String) ?? (json["name"] as? String) ?? host
        let model = (device["modelName"] as? String) ?? (device["model"] as? String)
        return SweptDevice(name: name, brand: .samsung, host: host, port: 8001,
                           model: model, manufacturer: "Samsung")
    }

    /// DIAL device description, served by Google/Android TV, LG webOS,
    /// Samsung Tizen, Chromecast dongles and other Cast targets on :8008.
    /// The description alone does not prove controllability — that is
    /// decided in `classifyDIAL` together with the remote-service ports.
    private static func probeDIAL(host: String) async -> DIALInfo? {
        guard let url = URL(string: "http://\(host):8008/ssdp/device-desc.xml"),
              let data = await httpGet(url: url) else { return nil }
        let fields = XMLFields.parse(data, wanted: ["friendlyName", "manufacturer", "modelName"])
        guard fields["friendlyName"] != nil || fields["manufacturer"] != nil || fields["modelName"] != nil else {
            return nil
        }
        return DIALInfo(friendlyName: fields["friendlyName"],
                        manufacturer: fields["manufacturer"],
                        modelName: fields["modelName"])
    }

    /// Classify a DIAL responder. LG and Samsung are identified by
    /// manufacturer. Anything else is only an Android TV when the
    /// Android TV Remote service port is open — a plain Chromecast
    /// dongle serves DIAL but never listens on 6466/6467, so without
    /// the port it is `.other`, never a claimed remote.
    private static func classifyDIAL(_ info: DIALInfo, host: String,
                                     androidTVPortsOpen: Bool) -> SweptDevice {
        let hay = [info.manufacturer, info.modelName, info.friendlyName]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        let name = info.friendlyName ?? info.modelName ?? host
        if hay.contains("lg") {
            return SweptDevice(name: name, brand: .lg, host: host, port: 8008,
                               model: info.modelName, manufacturer: info.manufacturer)
        }
        if hay.contains("samsung") {
            return SweptDevice(name: name, brand: .samsung, host: host, port: 8008,
                               model: info.modelName, manufacturer: info.manufacturer)
        }
        if androidTVPortsOpen {
            return SweptDevice(name: name, brand: .androidTV, host: host, port: 6466,
                               model: info.modelName, manufacturer: info.manufacturer)
        }
        return SweptDevice(name: name, brand: .other, host: host, port: 8008,
                           model: info.modelName, manufacturer: info.manufacturer)
    }

    // MARK: - TCP probes

    /// Android TV Remote service: control on 6466, pairing on 6467.
    /// Either open means a real Android/Google TV is listening; the
    /// pairing/control handshake confirms it when the user taps the TV.
    /// (The two results are awaited into locals first: `||` takes its
    /// operands as autoclosures, and an `async let` variable cannot be
    /// captured in an autoclosure.)
    private static func probeAndroidTVPorts(host: String) async -> Bool {
        async let control = tcpPortOpen(host: host, port: 6466)
        async let pairing = tcpPortOpen(host: host, port: 6467)
        let controlOpen = await control
        let pairingOpen = await pairing
        return controlOpen || pairingOpen
    }

    /// LG webOS wss port, as a fallback when the TV's DIAL server does
    /// not answer. Port 3001 is webOS-specific; the pairing handshake
    /// confirms it when the user taps the TV.
    private static func probeLGPort(host: String) async -> Bool {
        await tcpPortOpen(host: host, port: 3001)
    }

    /// TCP connect with a hard timeout, via a non-blocking connect +
    /// `poll`. Runs on a global-queue thread (never a cooperative-pool
    /// thread) so a slow host cannot stall the sweep's task tree.
    private static func tcpPortOpen(host: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: tcpConnectBlocking(host: host, port: port))
            }
        }
    }

    private static func tcpConnectBlocking(host: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr(host))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, Int32(tcpTimeout * 1000))
        guard ready > 0, (pfd.revents & Int16(POLLOUT)) != 0 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 else { return false }
        return err == 0
    }

    // MARK: - HTTP plumbing

    /// GET with a short timeout; nil on any failure or non-2xx status.
    private static func httpGet(url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = httpTimeout
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - Subnet enumeration

    /// The phone's Wi-Fi subnet: host addresses to sweep plus a label
    /// like "192.168.1.0/24". Returns nil when the phone has no Wi-Fi
    /// IPv4 address. Wider masks are capped to the /24 containing the
    /// phone (at most 254 hosts); narrower masks sweep the whole subnet.
    private static func wifiSubnet() -> (hosts: [String], label: String)? {
        guard let (address, netmask) = wifiIPv4() else { return nil }
        let ip = UInt32(bigEndian: address.s_addr)
        let mask = UInt32(bigEndian: netmask.s_addr)
        let prefix = mask.nonzeroBitCount
        let network: UInt32
        let count: Int
        if prefix < 24 {
            // Wider than a /24 (e.g. /16): sweep only the phone's /24.
            network = ip & 0xFFFFFF00
            count = maxHosts
        } else {
            network = ip & mask
            count = min((1 << (32 - prefix)) - 2, maxHosts)
        }
        guard count > 0 else { return nil }
        var hosts: [String] = []
        hosts.reserveCapacity(count)
        for offset in 1...count {
            let value = network + UInt32(offset)
            guard value != ip else { continue } // skip the phone itself
            hosts.append(dottedQuad(value))
        }
        return (hosts, "\(dottedQuad(network))/\(prefix < 24 ? 24 : prefix)")
    }

    /// The IPv4 address + netmask of interface `en0` (Wi-Fi).
    private static func wifiIPv4() -> (address: in_addr, netmask: in_addr)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let node = cursor {
            cursor = node.pointee.ifa_next
            guard let name = node.pointee.ifa_name,
                  String(cString: name) == "en0",
                  let addrPtr = node.pointee.ifa_addr,
                  addrPtr.pointee.sa_family == sa_family_t(AF_INET),
                  let maskPtr = node.pointee.ifa_netmask else { continue }
            let address = addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr
            }
            let netmask = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr
            }
            return (address, netmask)
        }
        return nil
    }

    private static func dottedQuad(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }
}

/// The fields that matter from a DIAL device-description document.
private struct DIALInfo {
    let friendlyName: String?
    let manufacturer: String?
    let modelName: String?
}

/// Minimal XML parser that collects the text of a few named elements.
private enum XMLFields {
    static func parse(_ data: Data, wanted: Set<String>) -> [String: String] {
        let delegate = ParserDelegate(wanted: wanted)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.fields
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        let wanted: Set<String>
        var fields: [String: String] = [:]
        private var currentElement: String?
        private var currentText = ""

        init(wanted: Set<String>) {
            self.wanted = wanted
            super.init()
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            currentElement = wanted.contains(elementName) ? elementName : nil
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
