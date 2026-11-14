import Foundation

enum RokuRemote {
    static func send(key: String, to host: String, port: Int = 8060) async throws {
        guard let url = URL(string: "http://\(host):\(port)/keypress/\(key)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
