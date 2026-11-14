import Foundation
import Combine

@MainActor
final class DiscoveryManager: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var devices: [TVDevice] = []
    @Published var isScanning = false
    @Published var status = "Ready to scan your Wi-Fi network"

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private let types = [
        "_roku-ecp._tcp.",
        "_samsungmsf._tcp.",
        "_airplay._tcp.",
        "_googlecast._tcp.",
        "_lg-smart-tv._tcp."
    ]

    override init() {
        super.init()
        browser.delegate = self
    }

    func scan() {
        stop()
        devices.removeAll()
        services.removeAll()
        isScanning = true
        status = "Searching for TVs on your local network…"
        for type in types {
            browser.searchForServices(ofType: type, inDomain: "local.")
        }
        // Browsing remains active until Stop is pressed.
    }

    func stop() {
        browser.stop()
        isScanning = false
        if devices.isEmpty { status = "Scan stopped. No compatible devices found yet." }
        else { status = "Found \(devices.count) device(s)." }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard !services.contains(where: { $0.name == service.name && $0.type == service.type }) else { return }
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
        let device = TVDevice(name: service.name, serviceType: service.type, port: service.port)
        if !devices.contains(where: { $0.name == device.name && $0.serviceType == device.serviceType }) {
            devices.append(device)
            status = "Found \(devices.count) device(s). Resolving addresses…"
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let host = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) 
        if let index = devices.firstIndex(where: { $0.name == sender.name && $0.serviceType == sender.type }) {
            let old = devices[index]
            devices[index] = TVDevice(name: old.name, serviceType: old.serviceType, host: host, port: sender.port)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        status = "Found \(devices.count) device(s); some addresses could not be resolved."
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        status = "Network scan error: \(errorDict[NetService.errorCode]?.stringValue ?? "unknown")"
        isScanning = false
    }
}
