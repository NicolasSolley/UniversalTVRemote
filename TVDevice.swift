import Foundation

struct TVDevice: Identifiable, Hashable {
    let id: UUID
    var name: String
    var serviceType: String
    var host: String?
    var port: Int
    var brand: String

    init(name: String, serviceType: String, host: String? = nil, port: Int = 0) {
        self.id = UUID()
        self.name = name
        self.serviceType = serviceType
        self.host = host
        self.port = port
        let s = serviceType.lowercased()
        if s.contains("roku") { brand = "Roku" }
        else if s.contains("samsung") { brand = "Samsung" }
        else if s.contains("lg") { brand = "LG" }
        else if s.contains("googlecast") || s.contains("android") { brand = "Google / Android TV" }
        else if s.contains("airplay") { brand = "AirPlay-compatible" }
        else { brand = "Unknown TV / media device" }
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: TVDevice, rhs: TVDevice) -> Bool { lhs.id == rhs.id }
}
