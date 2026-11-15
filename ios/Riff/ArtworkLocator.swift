import Foundation

actor ArtworkLocator {
    static let shared = ArtworkLocator()
    static func youtubeThumbnail(for source: String) -> String? {
        guard let components = URLComponents(string: source), let host = components.host?.lowercased() else { return nil }
        let id: String?
        if host == "youtu.be" { id = components.path.split(separator: "/").first.map(String.init) }
        else if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            id = components.queryItems?.first(where: { $0.name == "v" })?.value
        } else { return nil }
        guard let id, id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else { return nil }
        return "https://i.ytimg.com/vi/" + id + "/hqdefault.jpg"
    }
    func cover(for source: String) async throws -> String? {
        if let youtube = Self.youtubeThumbnail(for: source) { return youtube }
        guard let host = URL(string: source)?.host?.lowercased(), host == "soundcloud.com" || host.hasSuffix(".soundcloud.com") else { return nil }
        var url = URLComponents(string: "https://soundcloud.com/oembed")!
        url.queryItems = [URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "url", value: source)]
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        struct Response: Decodable { let thumbnail_url: String? }
        return try JSONDecoder().decode(Response.self, from: data).thumbnail_url
    }
}
