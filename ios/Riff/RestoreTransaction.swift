import Foundation

/// The caller pauses other library writers before applying or recovering a restore.
/// Journal paths are relative to these trusted roots, never paths from a backup.
actor RestoreTransaction {
    enum Area: String, Codable, Sendable { case library, lyrics }
    struct Change: Sendable {
        let area: Area
        let filename: String
        let data: Data
    }
    private struct Original: Codable {
        let area: Area
        let filename: String
        let data: Data?
    }
    private struct Journal: Codable {
        let id: UUID
        var committed: Bool
        let originals: [Original]
    }
    private let libraryRoot: URL
    private let lyricsRoot: URL
    private let journalURL: URL
    private let libraryNames: Set<String> = ["library.json", "playlists.json", "listening.json", "effects.json", "playback-preferences.json", "restored-audio.json", "desktop-account.json"]

    init(libraryRoot: URL, lyricsRoot: URL) {
        self.libraryRoot = libraryRoot
        self.lyricsRoot = lyricsRoot
        journalURL = libraryRoot.appending(path: "restore-journal.json")
    }

    func apply(_ changes: [Change]) throws {
        let id = try prepare(changes)
        do {
            for change in changes {
                try Task.checkCancellation()
                try write(change.data, to: location(change.area, change.filename))
            }
            var journal = try readJournal()
            guard journal.id == id else { throw BackupError.invalid }
            journal.committed = true
            try write(JSONEncoder().encode(journal), to: journalURL)
            // The restore is committed. Cleanup can be retried at next launch.
            try? FileManager.default.removeItem(at: journalURL)
        } catch {
            let originalError = error
            try recover()
            throw originalError
        }
    }

    /// Durable preparation is separate so interrupted work can always roll back.
    @discardableResult func prepare(_ changes: [Change]) throws -> UUID {
        try recover()
        var seen: Set<String> = []
        var originals: [Original] = []
        for change in changes {
            let key = change.area.rawValue + "/" + change.filename
            guard seen.insert(key).inserted else { throw BackupError.invalid }
            let target = try location(change.area, change.filename)
            let existing = FileManager.default.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil
            originals.append(Original(area: change.area, filename: change.filename, data: existing))
        }
        let journal = Journal(id: UUID(), committed: false, originals: originals)
        try write(JSONEncoder().encode(journal), to: journalURL)
        return journal.id
    }

    func recover() throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        // Decode and validate every path before changing any files. A corrupt
        // journal is retained for recovery instead of being treated as empty.
        var journal = try readJournal()
        for original in journal.originals { _ = try location(original.area, original.filename) }
        if !journal.committed {
            for original in journal.originals {
                let target = try location(original.area, original.filename)
                if let data = original.data { try write(data, to: target) }
                else if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            }
        }
        if !journal.committed {
            journal.committed = true
            try write(JSONEncoder().encode(journal), to: journalURL)
        }
        try? FileManager.default.removeItem(at: journalURL)
    }

    private func readJournal() throws -> Journal {
        try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
    }
    private func location(_ area: Area, _ filename: String) throws -> URL {
        switch area {
        case .library: guard libraryNames.contains(filename) else { throw BackupError.invalid }
        case .lyrics:
            guard filename.range(of: "^[a-f0-9]{64}\\.json$", options: .regularExpression) != nil else { throw BackupError.invalid }
        }
        let root = area == .library ? libraryRoot : lyricsRoot
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let target = base.appending(path: filename).standardizedFileURL.resolvingSymlinksInPath()
        guard target.path.hasPrefix(base.path + "/"), target.lastPathComponent == filename else { throw BackupError.invalid }
        return target
    }
    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
