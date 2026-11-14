import XCTest
@testable import Riff

@MainActor
final class AudioLibraryTests: XCTestCase {
    func testInvalidAudioIsRejectedWithoutLeavingAnEntryOrCopy() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "broken.mp3")
        let storage = root.appending(path: "library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("invalid audio".utf8).write(to: source)
        let library = AudioLibrary(root: storage)
        library.importFiles([source])
        XCTAssertTrue(library.tracks.isEmpty)
        XCTAssertNotNil(library.error)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storage.path).isEmpty)
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
}
