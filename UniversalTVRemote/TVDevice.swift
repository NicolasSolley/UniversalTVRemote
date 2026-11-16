import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A TV (or media device) found on the local network.
///
/// Identity is **stable**: `id` is derived from the discovery source and a
/// source-provided unique value (SSDP USN/LOCATION, or Bonjour name + type),
/// so a device keeps the same identity across re-resolves and re-scans.
/// Never generate a fresh UUID for a discovered device — that breaks list
/// identity and loses the user's selection when the address resolves.
struct TVDevice: Identifiable, Hashable {
    enum Brand: String, Codable {
        case roku = "Roku"
        case samsung = "Samsung"
        case lg = "LG"
        case androidTV = "Google / Android TV"
        case airPlay = "AirPlay-compatible"
        case other = "Other TV / media device"

        /// Whether this app can actually send remote commands to the brand.
        /// Only brands with a fully implemented control protocol are `true`.
        var supportsControl: Bool {
            switch self {
            case .roku, .samsung, .lg, .androidTV: return true
            case .airPlay, .other: return false
            }
        }
    }

    enum Source {
        case ssdp
        case sweep
        case bonjour
        /// A TV the app connected to before, kept from the remembered
        /// store (v1.0.47) — it stays listed while asleep.
        case remembered
    }

    /// Stable identity, e.g. "ssdp:<usn>" or "bonjour:<name>|<type>".
    let id: String
    var name: String
    var brand: Brand
    var host: String?
    var port: Int
    var model: String?
    var manufacturer: String?
    var source: Source
    /// The TV's MAC, when a driver has reported it (Samsung /api/v2/
    /// wifiMac, Roku device-info wifi-mac). The magic packet needs
    /// it — without it a sleeping TV cannot be woken (v1.0.47).
    var macAddress: String?
    /// A remembered TV the current scan has not found live: asleep,
    /// not gone. Cleared the moment any discovery path finds it.
    var isSleeping: Bool = false

    /// Whether this TV can be woken from standby: Samsung and Roku
    /// report their MAC, which the magic packet needs. LG and
    /// Android TV have no verified MAC source (v1.0.47).
    var canWake: Bool {
        (brand == .samsung || brand == .roku) && macAddress != nil
    }

    /// Human-readable address line for the list.
    var addressLine: String {
        if let host { return host }
        return "Resolving address…"
    }

    init(id: String, name: String, brand: Brand, host: String? = nil, port: Int = 0,
         model: String? = nil, manufacturer: String? = nil, source: Source,
         macAddress: String? = nil, isSleeping: Bool = false) {
        self.id = id
        self.name = name
        self.brand = brand
        self.host = host
        self.port = port
        self.model = model
        self.manufacturer = manufacturer
        self.source = source
        self.macAddress = macAddress
        self.isSleeping = isSleeping
    }

    /// Convenience init for Bonjour-discovered services.
    init(bonjourName name: String, serviceType: String, host: String? = nil, port: Int = 0) {
        self.id = "bonjour:\(name)|\(serviceType)"
        self.name = name
        self.brand = Self.brand(forServiceType: serviceType)
        self.host = host
        self.port = port
        self.source = .bonjour
    }

    /// Convenience init for SSDP-discovered devices.
    init(ssdpUSN usn: String, location: String, name: String, brand: Brand,
         host: String? = nil, port: Int = 0, model: String? = nil, manufacturer: String? = nil) {
        self.id = "ssdp:\(usn.isEmpty ? location : usn)"
        self.name = name
        self.brand = brand
        self.host = host
        self.port = port
        self.model = model
        self.manufacturer = manufacturer
        self.source = .ssdp
    }

    static func brand(forServiceType serviceType: String) -> Brand {
        let s = serviceType.lowercased()
        if s.contains("roku") { return .roku }
        if s.contains("samsung") { return .samsung }
        if s.contains("lg") { return .lg }
        if s.contains("googlecast") || s.contains("androidtvremote") { return .androidTV }
        if s.contains("airplay") { return .airPlay }
        return .other
    }

    /// Brand inferred from SSDP device-description fields.
    static func brand(manufacturer: String?, modelName: String?, friendlyName: String?,
                      searchTarget: String?) -> Brand {
        let hay = [manufacturer, modelName, friendlyName, searchTarget]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        if hay.contains("roku") { return .roku }
        if hay.contains("samsung") { return .samsung }
        if hay.contains("lg") || hay.contains("webos") { return .lg }
        if hay.contains("amazon") || hay.contains("fire tv") { return .other }
        if hay.contains("google") || hay.contains("chromecast") || hay.contains("android tv")
            || hay.contains("androidtv") || hay.contains("dial-multiscreen") {
            return .androidTV
        }
        if hay.contains("apple") || hay.contains("airplay") { return .airPlay }
        return .other
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: TVDevice, rhs: TVDevice) -> Bool { lhs.id == rhs.id }
}

// MARK: - Remembered TVs (v1.0.47)

/// Posted when a session connects to a TV, so the discovery list
/// can mark that TV awake even though no scan ran (a woken TV must
/// not keep saying "Sleeping" when the user comes back to the list).
extension Notification.Name {
    static let tvDidConnect = Notification.Name("com.nicolassolley.universaltvremote.tvDidConnect")
}

/// A TV the app has connected to before, kept so it stays listed
/// when it is asleep and the scan cannot find it (v1.0.47): a
/// sleeping TV answers nothing, so without a remembered entry there
/// would be nothing to tap to wake it. Keyed by host address —
/// home DHCP is sticky, and a changed address just re-records.
struct RememberedTV: Codable {
    var name: String
    var brand: TVDevice.Brand
    var host: String
    var port: Int
    var model: String?
    var manufacturer: String?
    var macAddress: String?
    var lastSeen: Date

    /// The list entry: sleeping until a scan finds it live.
    func asSleepingDevice() -> TVDevice {
        TVDevice(id: "remembered:\(host)", name: name, brand: brand, host: host, port: port,
                 model: model, manufacturer: manufacturer, source: .remembered,
                 macAddress: macAddress, isSleeping: true)
    }
}

/// Remembered TVs (v1.0.47): the TVs the app has connected to, in
/// UserDefaults as JSON. The devices list is seeded from here, so a
/// sleeping TV stays listed and tappable.
enum RememberedTVStore {
    private static let key = "rememberedTVs"

    static func load() -> [RememberedTV] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([RememberedTV].self, from: data) else { return [] }
        return list
    }

    private static func save(_ list: [RememberedTV]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Record a TV the app just connected to (upsert by host).
    static func record(_ device: TVDevice) {
        guard let host = device.host else { return }
        var list = load()
        let entry = RememberedTV(name: device.name, brand: device.brand, host: host,
                                 port: device.port, model: device.model,
                                 manufacturer: device.manufacturer,
                                 macAddress: device.macAddress, lastSeen: Date())
        if let i = list.firstIndex(where: { $0.host == host }) {
            // Keep a MAC the new record doesn't have (the driver
            // learns it in the background after connect).
            var merged = entry
            if merged.macAddress == nil { merged.macAddress = list[i].macAddress }
            list[i] = merged
        } else {
            list.append(entry)
        }
        save(list)
    }

    /// A driver learned a MAC after connect — attach it to the
    /// record so the TV can be woken next time it sleeps.
    static func updateMAC(host: String, mac: String) {
        var list = load()
        guard let i = list.firstIndex(where: { $0.host == host }) else { return }
        list[i].macAddress = mac
        list[i].lastSeen = Date()
        save(list)
    }
}

// MARK: - Wake-on-LAN (v1.0.47)

/// Wake-on-LAN: the magic packet — 6 × 0xFF followed by 16 copies
/// of the TV's MAC — sent to the TV's last-known address AND
/// broadcast, on ports 9 and 7. Moved here from SamsungRemote so
/// every brand's wake uses the same sender. iOS blocks broadcast
/// without the multicast entitlement, so the unicast copy is what
/// usually works in LiveContainer.
enum WakeOnLAN {
    static func sendMagicPacket(mac: String, host: String) {
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
