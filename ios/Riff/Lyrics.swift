import Foundation

struct LyricLine: Identifiable, Equatable, Sendable {
    let id: Int
    let time: Double
    let text: String
}

struct LyricsDocument: Sendable {
    let plainText: String
    let lines: [LyricLine]

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

actor LyricsService {
    static let shared = LyricsService()
    private struct Result: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let duration: Double?
    }

    func lookup(title: String, artist: String, duration: Double) async throws -> LyricsDocument {
        var url = URLComponents(string: "https://lrclib.net/api/search")!
        url.queryItems = [URLQueryItem(name: "q", value: [artist, title].filter { !$0.isEmpty }.joined(separator: " "))]
        var request = URLRequest(url: url.url!)
        request.setValue("Riff/0.7.5 (https://github.com/sillytira/riff)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ExtractionError(message: "The lyrics service is unavailable.")
        }
        let results = try JSONDecoder().decode([Result].self, from: data)
        let sorted = results.sorted { abs(($0.duration ?? duration) - duration) < abs(($1.duration ?? duration) - duration) }
        let text = sorted.compactMap(\.syncedLyrics).first(where: { !$0.isEmpty }) ?? sorted.compactMap(\.plainLyrics).first(where: { !$0.isEmpty })
        guard let text else { throw ExtractionError(message: "No lyrics were found. You can import an LRC or text file.") }
        return .parse(text)
    }
}
