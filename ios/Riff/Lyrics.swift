import Foundation

struct LyricLine: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let time: Double
    let text: String
}

struct LyricsDocument: Codable, Sendable {
    let plainText: String
    let lines: [LyricLine]
    var source: String? = nil
    var timingMatches = true

    static func parse(_ text: String) -> LyricsDocument {
        let timestamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d{2})(?:[.:](\d{1,3}))?\]"#)
        let offsetPattern = try! NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#, options: .caseInsensitive)
        let fullRange = NSRange(text.startIndex..., in: text)
        var offset = 0.0
        if let match = offsetPattern.firstMatch(in: text, range: fullRange), let range = Range(match.range(at: 1), in: text) {
            offset = (Double(text[range]) ?? 0) / 1000
        }
        var parsed: [(Double, String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let matches = timestamp.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
            guard !matches.isEmpty else { continue }
            let content = timestamp.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "").trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minutesRange = Range(match.range(at: 1), in: raw), let secondsRange = Range(match.range(at: 2), in: raw) else { continue }
                let minutes = Double(raw[minutesRange]) ?? 0
                let seconds = Double(raw[secondsRange]) ?? 0
                guard seconds < 60 else { continue }
                let fraction: Double
                if let range = Range(match.range(at: 3), in: raw) { fraction = Double("0." + raw[range]) ?? 0 }
                else { fraction = 0 }
                parsed.append((max(0, minutes * 60 + seconds + fraction + offset), content))
            }
        }
        // Swift's sort is stable, preserving source order for simultaneous lines.
        parsed.sort { $0.0 < $1.0 }
        let lines = parsed.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
        return LyricsDocument(plainText: text, lines: lines)
    }

    func activeLine(at seconds: Double) -> Int? {
        lines.last(where: { $0.time <= seconds })?.id
    }
}

struct LyricsIdentity: Hashable, Sendable {
    let title: String
    let artist: String
    var alternateRecording = false

    static func candidates(title: String, artist: String) -> [LyricsIdentity] {
        let cleanArtist = artist.replacingOccurrences(of: #"(?i)\s*-\s*Topic$|VEVO$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        func clean(_ title: String, musical: Bool = false) -> String {
            let labels = musical ? "official|audio|video|lyrics?|visualizer|mashup|remix|slowed|reverb|edit|mix" : "official|audio|video|lyrics?|visualizer"
            return title.replacingOccurrences(of: "(?i)[(\\[][^)\\]]*(?:" + labels + ")[^)\\]]*[)\\]]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var identities = [LyricsIdentity(title: title, artist: cleanArtist), LyricsIdentity(title: clean(title), artist: cleanArtist)]
        if let range = title.range(of: #"\s+[-–—]\s+"#, options: .regularExpression) {
            let inferredArtist = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let inferredTitle = String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            identities.append(LyricsIdentity(title: clean(inferredTitle), artist: inferredArtist))
            let baseTitle = clean(inferredTitle, musical: true)
            if baseTitle != clean(inferredTitle) { identities.append(LyricsIdentity(title: baseTitle, artist: inferredArtist, alternateRecording: true)) }
        } else {
            let baseTitle = clean(title, musical: true)
            if baseTitle != clean(title) { identities.append(LyricsIdentity(title: baseTitle, artist: cleanArtist, alternateRecording: true)) }
        }
        var seen: Set<LyricsIdentity> = []
        return identities.filter { !$0.title.isEmpty && seen.insert($0).inserted }
    }
}

struct LyricsMatch: Decodable, Identifiable, Sendable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String?
    let duration: Double?
    let syncedLyrics: String?
    let plainLyrics: String?

    var hasLyrics: Bool { !(syncedLyrics ?? "").isEmpty || !(plainLyrics ?? "").isEmpty }
}

enum LyricsMatching {
    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined()
    }
    static func isStrongMatch(_ match: LyricsMatch, identity: LyricsIdentity) -> Bool {
        let title = normalized(identity.title), artist = normalized(identity.artist)
        guard !title.isEmpty, normalized(match.trackName) == title else { return false }
        // Compare explicit feature credits as well as punctuation/spacing variants.
        let candidateArtist = match.artistName.replacingOccurrences(of: #"(?i)\s+(?:feat\.?|ft\.?|featuring)\s+.*$"#, with: "", options: .regularExpression)
        let requestedArtist = identity.artist.replacingOccurrences(of: #"(?i)\s+(?:feat\.?|ft\.?|featuring)\s+.*$"#, with: "", options: .regularExpression)
        return !artist.isEmpty && normalized(candidateArtist) == normalized(requestedArtist)
    }
    static func document(_ match: LyricsMatch, duration: Double, forcePlain: Bool = false) -> LyricsDocument {
        let timingMatches = !forcePlain && (duration <= 0 || match.duration == nil || abs((match.duration ?? duration) - duration) <= max(12, duration * 0.08))
        var document: LyricsDocument
        if timingMatches, let synced = match.syncedLyrics, !synced.isEmpty { document = .parse(synced) }
        else {
            let plain = match.plainLyrics ?? LyricsDocument.parse(match.syncedLyrics ?? "").lines.map(\.text).joined(separator: "\n")
            document = LyricsDocument(plainText: plain, lines: [])
        }
        document.source = match.artistName + " — " + match.trackName
        document.timingMatches = timingMatches
        return document
    }
}

actor LyricsService {
    static let shared = LyricsService()

    func search(title: String, artist: String) async throws -> [LyricsMatch] {
        var url = URLComponents(string: "https://lrclib.net/api/search")!
        url.queryItems = [URLQueryItem(name: "q", value: [artist, title].filter { !$0.isEmpty }.joined(separator: " "))]
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 10
        request.setValue("Riff/0.7.5 (https://github.com/sillytira/riff)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ExtractionError(message: "The lyrics service is unavailable. Try again shortly or import an LRC file.")
        }
        return try JSONDecoder().decode([LyricsMatch].self, from: data).filter(\.hasLyrics)
    }

    func lookup(title: String, artist: String, duration: Double) async throws -> LyricsDocument {
        var plainFallback: LyricsDocument?
        for identity in LyricsIdentity.candidates(title: title, artist: artist) {
            try Task.checkCancellation()
            let matches = try await search(title: identity.title, artist: identity.artist)
                .filter { LyricsMatching.isStrongMatch($0, identity: identity) }
                .sorted { abs(($0.duration ?? duration) - duration) < abs(($1.duration ?? duration) - duration) }
            for match in matches {
                let document = LyricsMatching.document(match, duration: duration, forcePlain: identity.alternateRecording)
                if document.timingMatches { return document }
                if plainFallback == nil { plainFallback = document }
            }
        }
        if let plainFallback { return plainFallback }
        throw ExtractionError(message: "No matching lyrics were found. Try a different title or artist, or import an LRC file.")
    }
}
