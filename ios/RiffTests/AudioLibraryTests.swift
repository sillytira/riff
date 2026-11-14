import XCTest
@testable import Riff

@MainActor
final class AudioLibraryTests: XCTestCase {
    func testImportCopiesAudioAndRestoresItAfterRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "silence", withExtension: "wav"))
        let source = root.appending(path: "original.wav")
        let storage = root.appending(path: "library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: source)
        let library = AudioLibrary(root: storage)
        library.importFiles([source])
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
