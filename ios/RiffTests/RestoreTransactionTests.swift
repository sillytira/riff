import XCTest
@testable import Riff

@MainActor
final class RestoreTransactionTests: XCTestCase {
    func testRestoreCommitsLibraryAndLyricsWithoutTouchingAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = Data("Existing owned audio".utf8)
        try audio.write(to: root.appending(path: "song.mp3"))
        let lyrics = root.appending(path: "lyrics")
        let filename = String(repeating: "a", count: 64) + ".json"
        let store = RestoreTransaction(libraryRoot: root, lyricsRoot: lyrics)
        try await store.apply([.init(area: .library, filename: "playlists.json", data: Data("[]".utf8)), .init(area: .lyrics, filename: filename, data: Data("lyrics".utf8))])
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "song.mp3")), audio)
        XCTAssertEqual(try Data(contentsOf: lyrics.appending(path: filename)), Data("lyrics".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "restore-journal.json").path))
    }
    func testInterruptedRestoreRollsBackEveryChangedFileAndRemovesNewFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Data("original playlists".utf8)
        let playlist = root.appending(path: "playlists.json"), effects = root.appending(path: "effects.json")
        try original.write(to: playlist)
        let store = RestoreTransaction(libraryRoot: root, lyricsRoot: root.appending(path: "lyrics"))
        let changes: [RestoreTransaction.Change] = [.init(area: .library, filename: "playlists.json", data: Data("new playlists".utf8)), .init(area: .library, filename: "effects.json", data: Data("new effects".utf8))]
        try await store.prepare(changes)
        // Emulate process termination after some destination writes, before commit.
        try Data("partial new playlists".utf8).write(to: playlist)
        try Data("new effects".utf8).write(to: effects)
        let relaunched = RestoreTransaction(libraryRoot: root, lyricsRoot: root.appending(path: "lyrics"))
        try await relaunched.recover()
        XCTAssertEqual(try Data(contentsOf: playlist), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: effects.path))
    }
    func testRestoreRejectsPathsAndPreservesAnUnreadableJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = RestoreTransaction(libraryRoot: root, lyricsRoot: root.appending(path: "lyrics"))
        for name in ["../outside.json", "song.mp3", "/private/file.json"] {
            do { try await store.apply([.init(area: .library, filename: name, data: Data())]); XCTFail("A restore must stay inside its allowed metadata files") }
            catch { }
        }
        let journal = root.appending(path: "restore-journal.json"), bytes = Data("corrupt journal".utf8)
        try bytes.write(to: journal)
        do { try await store.recover(); XCTFail("A corrupt journal must not be discarded") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: journal), bytes)
    }
}
