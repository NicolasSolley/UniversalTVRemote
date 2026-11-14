import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// SSDP (Simple Service Discovery Protocol) discovery over UDP multicast.
///
/// Sends `M-SEARCH` to 239.255.255.250:1900 in several rounds and collects
/// the unicast replies. This is the primary discovery path: unlike Bonjour,
/// SSDP is not gated by LiveContainer's host `NSBonjourServices` list, so it
/// works for guest apps. Only real responses are reported — nothing is
/// invented. Each response's `LOCATION` is fetched and its device-description
/// XML parsed for friendly name, manufacturer and model.
struct SSDPDevice {
    let usn: String
    let location: String
    let name: String
    let brand: TVDevice.Brand
    let host: String
    let port: Int
    let model: String?
    let manufacturer: String?
}

final class SSDPDiscovery {
    /// Search targets sent each round. `ssdp:all` plus the targets that
    /// identify the TV platforms we control.
    private static let searchTargets = [
        "ssdp:all",
        "urn:dial-multiscreen-org:device:dial:1",
        "urn:roku-com:device:player:1-0",
        "urn:samsung.com:device:RemoteControlReceiver:1",
        "urn:lge-com:service:webos-second-screen:1",
    ]

    private let queue = DispatchQueue(label: "com.nicolassolley.universaltvremote.ssdp")
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var seenLocations = Set<String>()
    private var isRunning = false
    /// Bumped on every start/stop so timers from an earlier scan cannot
    /// finish or send for a later one.
    private var generation = 0

    var onDevice: ((SSDPDevice) -> Void)?
    var onFinished: (() -> Void)?

    /// Run a scan: `rounds` M-SEARCH bursts spaced `roundInterval` apart,
    /// listening for `totalDuration` seconds in total.
    func start(rounds: Int = 3, roundInterval: TimeInterval = 1.5,
               totalDuration: TimeInterval = 7.0) {
        stop()
        generation += 1
        let gen = generation
        isRunning = true
        seenLocations.removeAll()

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { finish(); return }
        socketFD = fd

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        // Non-blocking so the read source can drain the queue.
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        var bindAddr = sockaddr_in()
        bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = 0 // ephemeral; M-SEARCH replies come back unicast to this port
        bindAddr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult = withUnsafePointer(to: &bindAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { finish(); return }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drainSocket() }
        source.setCancelHandler { close(fd) }
        source.resume()
        readSource = source

        for round in 0..<rounds {
            queue.asyncAfter(deadline: .now() + roundInterval * Double(round)) { [weak self] in
                guard self?.generation == gen else { return }
                self?.sendSearches()
            }
        }
        queue.asyncAfter(deadline: .now() + totalDuration) { [weak self] in
            guard self?.generation == gen else { return }
            self?.finish()
        }
    }

    func stop() {
        guard isRunning else { return }
        generation += 1
        isRunning = false
        readSource?.cancel()
        readSource = nil
        socketFD = -1
    }

    private func finish() {
        stop()
        DispatchQueue.main.async { [weak self] in self?.onFinished?() }
    }

    private func sendSearches() {
        guard isRunning, socketFD >= 0 else { return }
        var mcast = sockaddr_in()
        mcast.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        mcast.sin_family = sa_family_t(AF_INET)
        mcast.sin_port = UInt16(1900).bigEndian
        mcast.sin_addr = in_addr(s_addr: inet_addr("239.255.255.250"))
        for target in Self.searchTargets {
            let message = "M-SEARCH * HTTP/1.1\r\n" +
                "HOST: 239.255.255.250:1900\r\n" +
                "MAN: \"ns=01\"\r\n" +
                "MX: 3\r\n" +
                "ST: \(target)\r\n" +
                "USER-AGENT: UniversalTVRemote/1.0\r\n" +
                "\r\n"
            guard let data = message.data(using: .utf8) else { continue }
            data.withUnsafeBytes { raw in
                withUnsafePointer(to: &mcast) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { addr in
                        _ = sendto(socketFD, raw.baseAddress, data.count, 0, addr,
                                   socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    private func drainSocket() {
        guard socketFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { ptr in
                recvfrom(socketFD, ptr.baseAddress, ptr.count, 0, nil, nil)
            }
            guard count > 0 else { return }
            let text = String(decoding: buffer.prefix(count), as: UTF8.self)
            handleResponse(text)
        }
    }

    private func handleResponse(_ text: String) {
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        guard let location = headers["LOCATION"], !location.isEmpty else { return }
        guard !seenLocations.contains(location) else { return }
        seenLocations.insert(location)
        let usn = headers["USN"] ?? ""
        let server = headers["SERVER"] ?? ""
        let searchTarget = headers["ST"] ?? ""
        fetchDescription(location: location, usn: usn, server: server, searchTarget: searchTarget)
    }

    private func fetchDescription(location: String, usn: String, server: String,
                                  searchTarget: String) {
        guard let url = URL(string: location),
              let host = url.host else { return }
        let port = url.port ?? 80
        Task {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 3
                let (data, _) = try await URLSession.shared.data(for: request)
                let parsed = SSDPDescriptionParser.parse(data)
                let brand = TVDevice.brand(
                    manufacturer: parsed.manufacturer ?? server,
                    modelName: parsed.modelName,
                    friendlyName: parsed.friendlyName,
                    searchTarget: searchTarget)
                let name = parsed.friendlyName ?? parsed.modelName ?? host
                let device = SSDPDevice(
                    usn: usn, location: location, name: name, brand: brand,
                    host: host, port: port, model: parsed.modelName,
                    manufacturer: parsed.manufacturer)
                DispatchQueue.main.async { [weak self] in self?.onDevice?(device) }
            } catch {
                // Description fetch failed — still report the device with what
                // the SSDP headers told us, using the host as the name.
                let brand = TVDevice.brand(manufacturer: server, modelName: nil,
                                           friendlyName: nil, searchTarget: searchTarget)
                let device = SSDPDevice(
                    usn: usn, location: location, name: host, brand: brand,
                    host: host, port: port, model: nil, manufacturer: nil)
                DispatchQueue.main.async { [weak self] in self?.onDevice?(device) }
            }
        }
    }
}

/// Minimal XML parser for UPnP device-description documents.
private enum SSDPDescriptionParser {
    static func parse(_ data: Data) -> (friendlyName: String?, manufacturer: String?,
                                         modelName: String?, modelNumber: String?) {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return (delegate.friendlyName, delegate.manufacturer,
                delegate.modelName, delegate.modelNumber)
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        var friendlyName: String?
        var manufacturer: String?
        var modelName: String?
        var modelNumber: String?
        private var currentElement: String?
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
            let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "friendlyName": friendlyName = value.isEmpty ? nil : value
            case "manufacturer": manufacturer = value.isEmpty ? nil : value
            case "modelName": modelName = value.isEmpty ? nil : value
            case "modelNumber": modelNumber = value.isEmpty ? nil : value
            default: break
            }
            currentElement = nil
            currentText = ""
        }
    }
}
