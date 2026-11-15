import XCTest
@testable import Riff

@MainActor
final class AudioLibraryTests: XCTestCase {
    func testImportCopiesAudioAndRestoresItAfterRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "silence", withExtension: "wav"))
        let source = root.appending(path: "original.wav")
        let storage = root.appending(path: "library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: source)
        let library = AudioLibrary(root: storage)
        await library.importFiles([source])
        XCTAssertNil(library.error)
        let track = try XCTUnwrap(library.tracks.first)
        try FileManager.default.removeItem(at: source)
        let restored = AudioLibrary(root: storage)
        XCTAssertEqual(restored.tracks.first?.id, track.id)
        XCTAssertEqual(try Data(contentsOf: storage.appending(path: track.filename)), try Data(contentsOf: fixture))
    }

    func testAudioEffectsPersistAcrossRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = AudioLibrary(root: root)
        library.effects.pitch = 5
        library.effects.gains[3] = 3
        let restored = AudioLibrary(root: root)
        XCTAssertEqual(restored.effects.pitch, 5)
        XCTAssertEqual(restored.effects.gains[3], 3)
        restored.resetEffects()
        XCTAssertEqual(AudioLibrary(root: root).effects, AudioEffectSettings())
    }

    func testInvalidAudioIsRejectedWithoutLeavingAnEntryOrCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "broken.mp3")
        let storage = root.appending(path: "library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("invalid audio".utf8).write(to: source)
        let library = AudioLibrary(root: storage)
        await library.importFiles([source])
        XCTAssertTrue(library.tracks.isEmpty)
        XCTAssertNotNil(library.error)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storage.path).isEmpty)
        XCTAssertEqual(library.activeImports, 0)
        XCTAssertEqual(library.importFailures.count, 1)
        XCTAssertTrue(library.importFailures[0].message.contains("broken.mp3"))
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ui-tone", withExtension: "wav"))
        await library.importFiles([fixture])
        XCTAssertEqual(library.tracks.count, 1)
        XCTAssertTrue(library.importFailures.isEmpty)
        XCTAssertNil(library.error)
    }

    func testCorruptManifestIsReportedAndPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = root.appending(path: "library.json")
        let original = Data("corrupt".utf8)
        try original.write(to: manifest)
        let library = AudioLibrary(root: root)
        XCTAssertTrue(library.tracks.isEmpty)
        XCTAssertNotNil(library.error)
        XCTAssertEqual(try Data(contentsOf: manifest), original)
    }

    func testManifestRestoresStableTrackIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let track = LocalTrack(id: UUID(), name: "Song", filename: "song.wav")
        try JSONEncoder().encode([track]).write(to: root.appending(path: "library.json"))
        let library = AudioLibrary(root: root)
        XCTAssertEqual(library.tracks.first?.id, track.id)
        XCTAssertEqual(library.tracks.first?.name, "Song")
    }
    func testOnlineSelectionUsesSavedAudioWithoutExtractionAndPreservesQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ui-session", withExtension: "m4a"))
        let library = AudioLibrary(root: root)
        defer { library.stop() }
        // These URLs cannot resolve. Successful playback proves the saved copy was used.
        let original = OnlineTrack(id: "offline", title: "Saved song", artist: "Riff", webpageURL: "https://www.youtube.com/watch?v=abcdefghijk", artworkURL: nil, duration: 180, provider: "YouTube")
        let alias = OnlineTrack(id: "alias", title: "Saved song", artist: "Riff", webpageURL: "https://music.youtube.com/watch?v=abcdefghijk", artworkURL: nil, duration: 180, provider: "YouTube Music")
        let next = OnlineTrack(id: "next", title: "Next song", artist: "Riff", webpageURL: "https://example.invalid/next", artworkURL: nil, duration: 180, provider: "Generic")
        try await library.importDownload(fixture, media: ResolvedMedia(track: original, streamURL: "", headers: [:], ext: "m4a", protocol: "https"))
        let saved = try XCTUnwrap(library.tracks.first)
        XCTAssertTrue(library.hasOfflineSource(alias.webpageURL))
        library.listening.record(.online(original))
        library.toggleFavorite(.online(original))
        XCTAssertTrue(library.isFavorite(.local(saved.id)))
        XCTAssertTrue(library.isFavorite(.online(alias)))
        await library.playOnline(alias, queue: [alias, next], startingAt: 12)
        XCTAssertEqual(library.current?.id, saved.id)
        XCTAssertTrue(library.isPlaying)
        XCTAssertNil(library.onlineCurrent)
        XCTAssertEqual(library.listening.history.count, 1)
        XCTAssertEqual(library.elapsed, 12, accuracy: 1)
        XCTAssertEqual(library.playbackQueue.entries.count, 2)
        XCTAssertEqual(library.playbackQueue.currentID, library.playbackQueue.entries.first?.id)
        XCTAssertNil(library.error)
        library.toggleFavorite(.local(saved.id))
        XCTAssertFalse(library.isFavorite(.online(original)))
        let restored = AudioLibrary(root: root)
        XCTAssertFalse(restored.isFavorite(.online(alias)))
        library.stop()
        try FileManager.default.removeItem(at: root.appending(path: saved.filename))
        XCTAssertFalse(library.hasOfflineSource(alias.webpageURL))
    }

    func testShuffleAndRepeatRestoreWithoutOverwritingCorruptPreferences() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = AudioLibrary(root: root)
        library.shuffleEnabled = true
        library.repeatMode = .one
        let restored = AudioLibrary(root: root)
        XCTAssertTrue(restored.shuffleEnabled)
        XCTAssertEqual(restored.repeatMode, .one)
        let file = root.appending(path: "playback-preferences.json")
        let corrupt = Data("unreadable preferences".utf8)
        try corrupt.write(to: file)
        let damaged = AudioLibrary(root: root)
        XCTAssertNotNil(damaged.error)
        damaged.repeatMode = .off
        damaged.shuffleEnabled = true
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

}
