import Foundation

struct OnlineTrack: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let artist: String
    let webpageURL: String
    let artworkURL: String?
    let duration: Double?
    let provider: String
    var album: String? = nil
}

struct ResolvedMedia: Decodable, Sendable {
    let track: OnlineTrack
    let streamURL: String
    let headers: [String: String]
    let ext: String?
    let `protocol`: String?
}

struct ExtractorHealth: Decodable, Sendable {
    let python: String
    let extractor: String
    let tls: String
    let javascript: Bool
    let javascriptResult: String?
}

/// Actor serialization plus the Python GIL permits network work away from the UI.
actor MediaExtractor {
    static let shared = MediaExtractor()

    func health() throws -> ExtractorHealth {
        try request(["operation": "health"])
    }

    func search(_ query: String, provider: String) throws -> [OnlineTrack] {
        struct Response: Decodable { let tracks: [OnlineTrack] }
        let response: Response = try request(["operation": "search", "query": query, "provider": provider])
        return response.tracks
    }

    func resolve(_ url: String) throws -> ResolvedMedia {
        try request(["operation": "resolve", "url": url])
    }

    func playlist(_ url: String) throws -> ImportedPlaylist {
        try request(["operation": "playlist", "url": url])
    }

    struct ImportedPlaylist: Decodable, Sendable {
        let title: String
        let tracks: [OnlineTrack]
    }

    private func request<T: Decodable>(_ values: [String: String]) throws -> T {
        try Task.checkCancellation()
        let data = try JSONSerialization.data(withJSONObject: values)
        let response = RiffPythonRequest(Bundle.main.bundlePath, String(decoding: data, as: UTF8.self))
        let encoded = Data(response.utf8)
        if let failure = try? JSONDecoder().decode(ExtractionFailure.self, from: encoded) {
            throw ExtractionError(message: failure.error)
        }
        return try JSONDecoder().decode(T.self, from: encoded)
    }
}

struct ExtractionError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private struct ExtractionFailure: Decodable { let error: String }
