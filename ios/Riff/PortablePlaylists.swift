import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A portable reference never grants access to the path in an imported file.
struct LocalFileReference: Codable, Sendable {
    let filename: String
    let title: String
    let artist: String
    let album: String?
    let duration: Double?
    var key: String { "file:" + filename + "\n" + artist + "\n" + title }
}

struct PlaylistFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

enum PortablePlaylists {
    static let maximumBytes = 8 * 1024 * 1024

    static func read(_ data: Data) throws -> [SavedPlaylist] {
        guard data.count <= maximumBytes else { throw invalid("The playlist file is larger than 8 MB.") }
        let json = try JSONSerialization.jsonObject(with: data)
        let list: [[String: Any]]
        if let object = json as? [String: Any] {
            if let playlists = object["playlists"] as? [[String: Any]] { list = playlists }
            else if object["tracks"] is [Any] { list = [object] }
            else { throw invalid("This JSON file does not contain playlists.") }
        } else if let array = json as? [[String: Any]] {
            if array.first?["tracks"] != nil || array.first?["name"] != nil { list = array }
            else { list = [["name": "Imported Playlist", "tracks": array]] }
        } else { throw invalid("This JSON file does not contain playlists.") }
        guard !list.isEmpty, list.count <= 200 else { throw invalid("Choose a file containing between 1 and 200 playlists.") }
        var count = 0
        return try list.map { item in
            guard let raw = item["tracks"] as? [[String: Any]] else { throw invalid("A playlist has an invalid track list.") }
            count += raw.count
            guard count <= 50_000 else { throw invalid("Import at most 50,000 songs at a time.") }
            let name = try string(item["name"] ?? item["title"], fallback: "Imported Playlist")
            let entries = try raw.map { PlaylistEntry(source: try source($0)) }
            return SavedPlaylist(id: UUID(), name: name, entries: entries,
                                 description: try optionalString(item["description"]), cover: httpURL(item["cover"]))
        }
    }

    private static func source(_ item: [String: Any]) throws -> PlaylistSource {
        let title = try string(item["title"], fallback: "Untitled song")
        let artist = try string(item["artist"], fallback: "")
        let album = try optionalString(item["album"])
        let provider = try string(item["platform"] ?? item["source"], fallback: "Generic")
        let id = (item["id"] as? String) ?? (item["id"] as? NSNumber)?.stringValue ?? ""
        var url = (item["url"] as? String) ?? (item["webpageURL"] as? String) ?? ""
        let duration: Double?
        if let value = item["duration"] as? NSNumber { duration = value.doubleValue }
        else if let value = item["duration"] as? String { duration = Double(value) }
        else { duration = nil }
        if let duration, !duration.isFinite || duration < 0 || duration > 7 * 86400 { throw invalid("A song has an invalid duration.") }
        if provider.lowercased() == "local" || item["isLocal"] as? Bool == true || url.hasPrefix("file:") {
            let original = (item["filePath"] as? String) ?? (item["path"] as? String) ?? (url.isEmpty ? id : url)
            let filename = original.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
            return .file(LocalFileReference(filename: filename, title: title, artist: artist, album: album, duration: duration))
        }
        if url.isEmpty, ["youtube", "ytmusic", "youtube music"].contains(provider.lowercased()),
           id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil { url = "https://music.youtube.com/watch?v=" + id }
        guard let validated = httpURL(url) else { throw invalid("\(title) has no playable web link or local-file reference. Its playlist was not imported.") }
        return .online(OnlineTrack(id: id.isEmpty ? validated : id, title: title, artist: artist, webpageURL: validated,
                                   artworkURL: httpURL(item["cover"]) ?? httpURL(item["thumbnail"]), duration: duration,
                                   provider: provider, album: album))
    }

    @MainActor static func write(_ playlists: [SavedPlaylist], library: AudioLibrary) throws -> Data {
        guard !playlists.isEmpty else { throw invalid("There are no playlists to export.") }
        let objects: [[String: Any]] = try playlists.map { playlist in
            let tracks: [[String: Any]] = try playlist.entries.map { entry in
                switch entry.source {
                case .online(let track): return onlineObject(track)
                case .local(let id):
                    guard let track = library.tracks.first(where: { $0.id == id }) else { throw invalid("A local song is missing. Remove its unavailable entry before exporting.") }
                    if let online = track.onlineEquivalent { return onlineObject(online) }
                    return fileObject(LocalFileReference(filename: track.filename, title: track.name, artist: track.artist ?? "", album: track.album, duration: track.duration))
                case .file(let reference): return fileObject(reference)
                }
            }
            var object: [String: Any] = ["name": playlist.name, "description": playlist.description ?? "", "tracks": tracks]
            if let cover = playlist.cover { object["cover"] = cover }
            return object
        }
        let result = try JSONSerialization.data(withJSONObject: ["app": "Riff", "appVersion": "0.7.5", "exportedAt": ISO8601DateFormatter().string(from: .now), "playlists": objects], options: [.prettyPrinted, .sortedKeys])
        guard result.count <= maximumBytes else { throw invalid("Export fewer playlists at a time to stay below 8 MB.") }
        return result
    }
    private static func onlineObject(_ track: OnlineTrack) -> [String: Any] {
        let provider: String
        switch track.provider.lowercased() { case "youtube": provider = "youtube"; case "youtube music": provider = "ytmusic"; case "soundcloud": provider = "soundcloud"; default: provider = track.provider }
        var object: [String: Any] = ["id": track.id, "title": track.title, "artist": track.artist, "album": track.album ?? "", "url": track.webpageURL, "source": provider, "platform": provider]
        if let duration = track.duration, duration.isFinite { object["duration"] = duration }
        if let cover = httpURL(track.artworkURL) { object["cover"] = cover; object["thumbnail"] = cover }
        return object
    }
    private static func fileObject(_ reference: LocalFileReference) -> [String: Any] {
        var object: [String: Any] = ["id": reference.filename, "url": reference.filename, "title": reference.title, "artist": reference.artist, "album": reference.album ?? "", "source": "local", "platform": "local", "isLocal": true]
        if let duration = reference.duration, duration.isFinite { object["duration"] = duration }
        return object
    }
    private static func httpURL(_ value: Any?) -> String? {
        guard let text = value as? String, text.count <= 8192, let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return text
    }
    private static func string(_ value: Any?, fallback: String) throws -> String {
        guard value == nil || value is NSNull || value is String else { throw invalid("A playlist text field is invalid.") }
        let result = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallback
        guard result.count <= 8192 else { throw invalid("A playlist text field is too long.") }
        return result.isEmpty ? fallback : result
    }
    private static func optionalString(_ value: Any?) throws -> String? {
        let result = try string(value, fallback: "")
        return result.isEmpty ? nil : result
    }
    private static func invalid(_ message: String) -> ExtractionError { ExtractionError(message: message) }
}
