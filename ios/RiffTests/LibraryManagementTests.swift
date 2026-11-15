import AVFoundation
import MediaPlayer
import XCTest
@testable import Riff

@MainActor
final class LibraryManagementTests: XCTestCase {
    func testManualMetadataSurvivesPendingIndexerAndRelaunchAndCanReloadTags() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "tagged", withExtension: "m4a"))
        let library = AudioLibrary(root: root)
        library.importFiles([fixture])
        let id = try XCTUnwrap(library.tracks.first?.id)
        try library.updateMetadata(id, title: "My title", artist: "My artist", album: "My album")
        for _ in 0..<100 {
            if library.tracks.first?.metadataIndexed == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(library.tracks.first?.name, "My title")
        XCTAssertEqual(library.tracks.first?.artist, "My artist")
        XCTAssertNotNil(library.tracks.first?.artworkURL)
        let restored = AudioLibrary(root: root)
        XCTAssertEqual(restored.tracks.first?.album, "My album")
        XCTAssertTrue(restored.tracks.first?.metadataCustomized == true)
        try restored.rescanMetadata(try XCTUnwrap(restored.tracks.first))
        for _ in 0..<100 {
            if restored.tracks.first?.metadataIndexed == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(restored.tracks.first?.name, "Metadata Test Song")
        XCTAssertEqual(restored.tracks.first?.artist, "Riff Test Artist")
        XCTAssertEqual(restored.tracks.first?.album, "Metadata Test Album")
    }

    func testRemovalStopsPlaybackAndPreservesOnlinePlaylistAndFavorites() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ui-tone", withExtension: "wav"))
        let originalBytes = try Data(contentsOf: input)
        let online = OnlineTrack(id: "song", title: "Song", artist: "Artist", webpageURL: "https://example.com/song", artworkURL: nil, duration: 2, provider: "Generic")
        let library = AudioLibrary(root: root)
        try library.importDownload(input, media: ResolvedMedia(track: online, streamURL: "https://example.com/audio.wav", headers: [:], ext: "wav", protocol: "https"))
        let track = try XCTUnwrap(library.tracks.first)
        let store = PlaylistStore(root: root)
        let entryID = UUID()
        let playlistID = try XCTUnwrap(store.create(name: "Favorites", entries: [PlaylistEntry(id: entryID, source: .local(track.id))]))
        library.listening.toggleFavorite(.online(online))
        library.listening.toggleFavorite(.local(track.id))
        library.play(track)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(library.isPlaying)
        try library.removeTracks([track.id], playlists: store)
        XCTAssertNil(library.playingTitle)
        XCTAssertFalse(library.isPlaying)
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertTrue(library.playbackQueue.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: track.filename).path))
        XCTAssertEqual(try Data(contentsOf: input), originalBytes)
        XCTAssertTrue(AudioLibrary(root: root).tracks.isEmpty)
        let restoredPlaylist = try XCTUnwrap(PlaylistStore(root: root).playlists.first { $0.id == playlistID })
        XCTAssertEqual(restoredPlaylist.entries.first?.id, entryID)
        guard case .online(let replacement)? = restoredPlaylist.entries.first?.source else { return XCTFail("The playlist must keep its online source") }
        XCTAssertEqual(replacement.webpageURL, online.webpageURL)
        let restoredListening = ListeningStore(root: root)
        XCTAssertEqual(restoredListening.favorites.count, 1)
        XCTAssertTrue(restoredListening.isFavorite(.online(online)))
        XCTAssertEqual(restoredListening.history.first?.id, ListeningEntry.key(for: .online(online)))
    }

    func testRemovalRefusesPathsOutsideOwnedStorage() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let storage = root.appending(path: "library")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "outside.wav")
        let bytes = Data("Preserve this file".utf8)
        try bytes.write(to: original)
        let track = LocalTrack(id: UUID(), name: "Unsafe entry", filename: "../outside.wav", metadataIndexed: true)
        try JSONEncoder().encode([track]).write(to: storage.appending(path: "library.json"))
        let library = AudioLibrary(root: storage)
        XCTAssertThrowsError(try library.removeTracks([track.id]))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(library.tracks.count, 1)
    }
}
