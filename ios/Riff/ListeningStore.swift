import Foundation
import Observation

struct ListeningEntry: Codable, Identifiable, Sendable {
    let id: String
    let source: PlaylistSource
    var playedAt: Date?

    static func key(for source: PlaylistSource) -> String {
        switch source {
        case .local(let id): "local:" + id.uuidString
        case .online(let track): "source:" + track.webpageURL
        }
    }
}

@MainActor @Observable
final class ListeningStore {
    private struct Snapshot: Codable {
        var favorites: [ListeningEntry] = []
        var history: [ListeningEntry] = []
    }
    private var snapshot = Snapshot()
    private(set) var error: String?
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var writable = true
    var favorites: [ListeningEntry] { snapshot.favorites }
    var history: [ListeningEntry] { snapshot.history }

    init(root: URL) {
        file = root.appending(path: "listening.json")
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
            }
        } catch { self.error = error.localizedDescription; writable = false }
    }

    func isFavorite(_ source: PlaylistSource) -> Bool {
        favorites.contains { $0.id == ListeningEntry.key(for: source) }
    }
    func toggleFavorite(_ source: PlaylistSource) {
        let id = ListeningEntry.key(for: source)
        var updated = snapshot
        if updated.favorites.contains(where: { $0.id == id }) { updated.favorites.removeAll { $0.id == id } }
        else { updated.favorites.insert(ListeningEntry(id: id, source: source), at: 0) }
        commit(updated)
    }
    func record(_ source: PlaylistSource, at date: Date = .now) {
        let id = ListeningEntry.key(for: source)
        var updated = snapshot
        updated.history.removeAll { $0.id == id }
        updated.history.insert(ListeningEntry(id: id, source: source, playedAt: date), at: 0)
        updated.history = Array(updated.history.prefix(500))
        commit(updated)
    }
    func remapLocal(_ ids: Set<UUID>, replacements: [UUID: OnlineTrack]) {
        func remap(_ entries: [ListeningEntry]) -> [ListeningEntry] {
            var seen = Set<String>()
            return entries.compactMap { entry in
                let source: PlaylistSource
                if case .local(let id) = entry.source, ids.contains(id) {
                    guard let replacement = replacements[id] else { return nil }
                    source = .online(replacement)
                } else { source = entry.source }
                let key = ListeningEntry.key(for: source)
                guard seen.insert(key).inserted else { return nil }
                return ListeningEntry(id: key, source: source, playedAt: entry.playedAt)
            }
        }
        var updated = snapshot
        updated.favorites = remap(updated.favorites)
        updated.history = remap(updated.history)
        commit(updated)
    }
    func clearHistory() {
        var updated = snapshot
        updated.history = []
        commit(updated)
    }
    private func commit(_ updated: Snapshot) {
        guard writable else { error = "Listening data could not be read. Its original data has been preserved."; return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: file, options: .atomic)
            snapshot = updated
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
