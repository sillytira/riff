import Foundation
import Observation

enum PlaylistSource: Codable, Sendable {
    case local(UUID)
    case online(OnlineTrack)
    case file(LocalFileReference)
}

struct PlaylistEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let source: PlaylistSource
    init(id: UUID = UUID(), source: PlaylistSource) { self.id = id; self.source = source }
}

struct SavedPlaylist: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var entries: [PlaylistEntry]
    var description: String? = nil
    var cover: String? = nil
}

struct PlaybackQueue {
    var entries: [PlaylistEntry] = []
    var currentID: UUID?

    mutating func advance(automatic: Bool, shuffle: Bool, repeatMode: String) -> PlaylistEntry? {
        guard !entries.isEmpty else { return nil }
        let index = entries.firstIndex { $0.id == currentID }
        let selected: PlaylistEntry
        if automatic && repeatMode == "one", let index { selected = entries[index] }
        else if shuffle, let next = entries.filter({ $0.id != currentID }).randomElement() { selected = next }
        else if let index {
            if index + 1 < entries.count { selected = entries[index + 1] }
            else if repeatMode == "all" { selected = entries[0] }
            else { return nil }
        } else { selected = entries[0] }
        currentID = selected.id
        return selected
    }

    mutating func previous(repeatMode: String) -> PlaylistEntry? {
        guard !entries.isEmpty else { return nil }
        let index = entries.firstIndex { $0.id == currentID } ?? 0
        let target = index > 0 ? index - 1 : (repeatMode == "all" ? entries.count - 1 : 0)
        currentID = entries[target].id
        return entries[target]
    }
}

func movingEntries<T>(_ entries: [T], from offsets: IndexSet, to destination: Int) -> [T] {
    let valid = offsets.filter { entries.indices.contains($0) }
    let moving = valid.map { entries[$0] }
    var remaining = entries.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
    let insertion = max(0, min(remaining.count, destination - valid.filter { $0 < destination }.count))
    remaining.insert(contentsOf: moving, at: insertion)
    return remaining
}

@MainActor @Observable
final class PlaylistStore {
    private(set) var playlists: [SavedPlaylist] = []
    var error: String?
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var writable = true

    init(root: URL = URL.documentsDirectory.appending(path: "Riff")) {
        file = root.appending(path: "playlists.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) {
                playlists = try JSONDecoder().decode([SavedPlaylist].self, from: Data(contentsOf: file))
            }
        } catch { self.error = error.localizedDescription; writable = false }
    }

    @discardableResult
    func create(name: String, entries: [PlaylistEntry] = []) -> UUID? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { error = "Give the playlist a name."; return nil }
        let playlist = SavedPlaylist(id: UUID(), name: title, entries: entries)
        guard commit(playlists + [playlist]) else { return nil }
        return playlist.id
    }

    @discardableResult
    func importFile(_ data: Data) throws -> Int {
        let imported = try PortablePlaylists.read(data)
        guard commit(playlists + imported) else { throw ExtractionError(message: error ?? "The playlists could not be saved.") }
        return imported.count
    }

    func rename(_ id: UUID, to name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { error = "Give the playlist a name."; return }
        update(id) { $0.name = title }
    }
    func delete(_ ids: Set<UUID>) { _ = commit(playlists.filter { !ids.contains($0.id) }) }
    func append(_ entries: [PlaylistEntry], to id: UUID) { update(id) { $0.entries += entries } }
    func remove(from id: UUID, offsets: IndexSet) {
        update(id) { playlist in playlist.entries = playlist.entries.enumerated().filter { !offsets.contains($0.offset) }.map(\.element) }
    }
    func move(in id: UUID, from offsets: IndexSet, to destination: Int) {
        update(id) { $0.entries = movingEntries($0.entries, from: offsets, to: destination) }
    }
    func remapLocal(_ ids: Set<UUID>, replacements: [UUID: OnlineTrack]) {
        let updated = playlists.map { playlist in
            var result = playlist
            result.entries = playlist.entries.compactMap { entry in
                guard case .local(let id) = entry.source, ids.contains(id) else { return entry }
                guard let replacement = replacements[id] else { return nil }
                return PlaylistEntry(id: entry.id, source: .online(replacement))
            }
            return result
        }
        _ = commit(updated)
    }
    private func update(_ id: UUID, change: (inout SavedPlaylist) -> Void) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        var updated = playlists
        change(&updated[index])
        _ = commit(updated)
    }
    private func commit(_ updated: [SavedPlaylist]) -> Bool {
        guard writable else { error = "The playlist index is unreadable. Its original data has been preserved."; return false }
        do {
            try JSONEncoder().encode(updated).write(to: file, options: .atomic)
            playlists = updated
            error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
