import Foundation

struct Site: Identifiable, Codable, Sendable {
    var id = UUID()
    var name: String
    var address: String
    var automatic = false
}
struct Probe: Sendable {
    var code: Int?
    var title: String?
    var milliseconds: Int = 0
    var checked = Date()
    var online: Bool { code != nil }
    var healthy: Bool { if let code { return code < 400 }; return false }
}
enum LocalURL {
    static func parse(_ text: String) -> URL? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: raw.contains("://") ? raw : "http://" + raw),
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              let host = c.host?.lowercased(), c.user == nil, c.password == nil else { return nil }
        let pieces = host.split(separator: ".")
        let ipv4 = pieces.count == 4 && pieces.first == "127" && pieces.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
        guard host == "localhost" || host == "[::1]" || host == "::1" || ipv4 else { return nil }
        if let port = c.port, !(1...65535).contains(port) { return nil }
        c.fragment = nil
        if c.path.isEmpty { c.path = "/" }
        return c.url
    }
}
final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
enum Network {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()
    static func probe(_ address: String) async -> Probe {
        guard let url = LocalURL.parse(address) else { return Probe() }
        let start = Date()
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("LocalWatch/1.0", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return Probe() }
            var data = Data()
            let html = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("text/html")
            if html {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count >= 32768 { break }
                    if byte == 62, String(decoding: data.suffix(8), as: UTF8.self).lowercased() == "</title>" { break }
                }
            }
            return Probe(code: http.statusCode, title: title(String(decoding: data, as: UTF8.self)), milliseconds: Int(Date().timeIntervalSince(start) * 1000))
        } catch { return Probe() }
    }
    static func title(_ html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<title[^>]*>(.*?)</title>", options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        var text = String(html[range]).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        for (a,b) in [("&amp;","&"),("&lt;","<"),("&gt;",">"),("&quot;","\""),("&#39;","'")] { text = text.replacingOccurrences(of: a, with: b) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(90))
    }
    static func listeningPorts() -> [Int] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-u", NSUserName(), "-iTCP", "-sTCP:LISTEN", "-Fpcn"]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        var command = ""; var ports = Set<Int>()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.first == "c" { command = String(line.dropFirst()) }
            if line.first == "n", !["ControlCenter", "rapportd", "moomoo_OpenD"].contains(command),
               let part = line.split(separator: ":").last, let port = Int(part), port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }
}
