import Foundation

/// A TV (or media device) found on the local network.
///
/// Identity is **stable**: `id` is derived from the discovery source and a
/// source-provided unique value (SSDP USN/LOCATION, or Bonjour name + type),
/// so a device keeps the same identity across re-resolves and re-scans.
/// Never generate a fresh UUID for a discovered device — that breaks list
/// identity and loses the user's selection when the address resolves.
struct TVDevice: Identifiable, Hashable {
    enum Brand: String {
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

    /// Human-readable address line for the list.
    var addressLine: String {
        if let host { return host }
        return "Resolving address…"
    }

    init(id: String, name: String, brand: Brand, host: String? = nil, port: Int = 0,
         model: String? = nil, manufacturer: String? = nil, source: Source) {
        self.id = id
        self.name = name
        self.brand = brand
        self.host = host
        self.port = port
        self.model = model
        self.manufacturer = manufacturer
        self.source = source
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
