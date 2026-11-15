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

extension OnlineTrack {
    func enriched(with details: OnlineTrack) -> OnlineTrack {
        OnlineTrack(id: id, title: title.isEmpty ? details.title : title,
                    artist: artist.isEmpty ? details.artist : artist, webpageURL: webpageURL,
                    artworkURL: details.artworkURL ?? artworkURL,
                    duration: details.duration ?? duration, provider: provider,
                    album: album ?? details.album)
    }
}

struct ResolvedMedia: Decodable, Sendable {
    var track: OnlineTrack
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

    private init() {
        // Remove disposable jars left by an interrupted app process.
        let directory = FileManager.default.temporaryDirectory
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix("riff-auth-") && file.pathExtension == "txt" {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

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
        var payload = values
        let savedCookies = try? YouTubeCredentials.read()
        var cookieFile: URL?
        defer { if let cookieFile { try? FileManager.default.removeItem(at: cookieFile) } }
        if let savedCookies, CookieFile.hasYouTubeLogin(savedCookies) {
            let file = FileManager.default.temporaryDirectory.appending(path: "riff-auth-" + UUID().uuidString + ".txt")
            cookieFile = file
            try savedCookies.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
            payload["cookiefile"] = file.path
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let response = RiffPythonRequest(Bundle.main.bundlePath, String(decoding: data, as: UTF8.self))
        if let savedCookies, let cookieFile,
           let updated = try? Data(contentsOf: cookieFile), CookieFile.hasYouTubeLogin(updated) {
            try? YouTubeCredentials.refresh(updated, replacing: savedCookies)
        }
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
