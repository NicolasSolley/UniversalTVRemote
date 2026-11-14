import Foundation
import Combine

/// Discovers TVs on the local network, scan-only.
///
/// Primary path is SSDP (UDP multicast M-SEARCH): it works inside
/// LiveContainer, where Bonjour browsing is gated by the host app's
/// `NSBonjourServices` list. Bonjour (`NetServiceBrowser`) runs as a
/// secondary path for devices SSDP misses. There is no manual IP entry —
/// if a TV does not answer the scan, it simply does not appear.
///
/// Devices are merged by host address: the same TV found via both paths
/// appears once, and entries are updated in place so a selection survives
/// address resolution.
@MainActor
final class DiscoveryManager: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var devices: [TVDevice] = []
    @Published var isScanning = false
    @Published var status = "Ready to scan your Wi-Fi network"

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private let ssdp = SSDPDiscovery()
    private var ssdpDone = false
    private var bonjourDone = false

    /// Bonjour service types browsed as a secondary path.
    private let types = [
        "_roku-ecp._tcp.",
        "_samsungmsf._tcp.",
        "_airplay._tcp.",
        "_googlecast._tcp.",
        "_lg-smart-tv._tcp.",
        "_lg-mrt._tcp.",
        "_androidtvremote2._tcp.",
    ]

    override init() {
        super.init()
        browser.delegate = self
        ssdp.onDevice = { [weak self] device in
            Task { @MainActor in self?.mergeSSDP(device) }
        }
        ssdp.onFinished = { [weak self] in
            Task { @MainActor in self?.ssdpFinished() }
        }
    }

    func scan() {
        stop()
        devices.removeAll()
        services.removeAll()
        ssdpDone = false
        bonjourDone = false
        isScanning = true
        status = "Scanning your Wi-Fi network…"
        ssdp.start(rounds: 3, roundInterval: 1.5, totalDuration: 7.0)
        for type in types {
            browser.searchForServices(ofType: type, inDomain: "local.")
        }
    }

    func stop() {
        browser.stop()
        ssdp.stop()
        isScanning = false
        if devices.isEmpty {
            status = "No TVs found. Make sure your TV is on and on the same Wi-Fi network, then scan again."
        } else {
            status = "Found \(devices.count) device\(devices.count == 1 ? "" : "s")."
        }
    }

    // MARK: - Merging

    /// Merge an SSDP result: update the existing entry for the same host in
    /// place (keeping its stable id), or append a new device.
    private func mergeSSDP(_ found: SSDPDevice) {
        if let index = devices.firstIndex(where: { $0.host == found.host }) {
            var existing = devices[index]
            // SSDP carries richer info (model/manufacturer); prefer it.
            existing.name = found.name
            existing.brand = found.brand
            existing.model = found.model ?? existing.model
            existing.manufacturer = found.manufacturer ?? existing.manufacturer
            existing.source = .ssdp
            existing.port = found.port
            devices[index] = existing
            return
        }
        let device = TVDevice(ssdpUSN: found.usn, location: found.location,
                              name: found.name, brand: found.brand,
                              host: found.host, port: found.port,
                              model: found.model, manufacturer: found.manufacturer)
        devices.append(device)
        sortDevices()
        status = "Found \(devices.count) device\(devices.count == 1 ? "" : "s")."
    }

    private func ssdpFinished() {
        ssdpDone = true
        maybeFinish()
    }

    private func maybeFinish() {
        guard ssdpDone else { return }
        // Bonjour keeps browsing in the background; the SSDP pass is the
        // timed scan. End the scanning state once SSDP completes.
        if isScanning {
            isScanning = false
            if devices.isEmpty {
                status = "No TVs found. Make sure your TV is on and on the same Wi-Fi network, then scan again."
            } else {
                status = "Found \(devices.count) device\(devices.count == 1 ? "" : "s")."
            }
        }
    }

    private func sortDevices() {
        devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Bonjour (secondary path)

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard !services.contains(where: { $0.name == service.name && $0.type == service.type }) else { return }
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
        let device = TVDevice(bonjourName: service.name, serviceType: service.type, port: service.port)
        // Only add if no entry exists for this name+type yet.
        if !devices.contains(where: { $0.id == device.id }) {
            devices.append(device)
            sortDevices()
            status = "Found \(devices.count) device\(devices.count == 1 ? "" : "s")."
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0.name == service.name && $0.type == service.type }
        let id = "bonjour:\(service.name)|\(service.type)"
        // Only remove Bonjour-only entries; an SSDP entry for the same host stays.
        if let index = devices.firstIndex(where: { $0.id == id }) {
            devices.remove(at: index)
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        // Resolve the host from the resolved addresses (hostName may be a
        // .local name; prefer a dotted-quad address when available).
        let host = resolvedHost(for: sender)
            ?? sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let id = "bonjour:\(sender.name)|\(sender.type)"
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        // If an SSDP entry already covers this host, drop the Bonjour duplicate.
        if let host, let ssdpIndex = devices.firstIndex(where: { $0.host == host && $0.source == .ssdp }) {
            if ssdpIndex != index { devices.remove(at: index) }
            return
        }
        // Update in place — same stable id, so selection and list identity survive.
        devices[index].host = host
        devices[index].port = sender.port
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        // Resolution failure is non-fatal; the entry stays listed without an address.
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        // Bonjour errors are non-fatal: SSDP is the primary path.
        // Keep scanning state; the SSDP pass will finish the scan.
    }

    /// Extract a dotted-quad IPv4 address from the resolved service addresses.
    private func resolvedHost(for service: NetService) -> String? {
        guard let addresses = service.addresses else { return nil }
        for data in addresses {
            var addr = sockaddr_in()
            guard data.count >= MemoryLayout<sockaddr_in>.size else { continue }
            data.withUnsafeBytes { ptr in
                addr = ptr.load(as: sockaddr_in.self)
            }
            guard addr.sin_family == sa_family_t(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var copy = addr.sin_addr
            guard inet_ntop(AF_INET, &copy, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let host = String(cString: buffer)
            if !host.isEmpty && host != "0.0.0.0" { return host }
        }
        return nil
    }
}
