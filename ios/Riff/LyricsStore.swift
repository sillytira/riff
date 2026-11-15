import Foundation
import CryptoKit

struct StoredLyrics: Codable, Sendable {
    let document: LyricsDocument
    var offset: Double
}

actor LyricsStore {
    static let shared = LyricsStore()
    private let root: URL
    init(root: URL = URL.applicationSupportDirectory.appending(path: "Riff/Lyrics")) { self.root = root }
    private func file(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: hash + ".json")
    }
    func read(_ key: String) throws -> StoredLyrics? {
        let url = file(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(StoredLyrics.self, from: Data(contentsOf: url))
    }
    func save(_ document: LyricsDocument, key: String, offset: Double = 0) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(StoredLyrics(document: document, offset: offset.isFinite ? offset : 0)).write(to: file(key), options: .atomic)
    }
    func setOffset(_ offset: Double, key: String) throws {
        guard offset.isFinite, let stored = try read(key) else { return }
        try save(stored.document, key: key, offset: offset)
    }
}
