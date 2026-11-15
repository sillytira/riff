import XCTest
@testable import Riff

@MainActor
final class PortablePlaylistsTests: XCTestCase {
    func testDesktopExportPreservesOrderOnlineMetadataAndUnresolvedLocalFiles() throws {
        let data = Data(#"{"app":"Riff","playlists":[{"name":"Road trip","description":"Desktop collection","tracks":[{"id":"abcdefghijk","title":"Online song","artist":"Artist","album":"Album","platform":"ytmusic","duration":123,"cover":"https://example.com/cover.jpg"},{"id":"local_song","url":"C:\\Music\\local.wav","title":"Local song","artist":"Local artist","platform":"local","duration":45}]}]}"#.utf8)
        let imported = try PortablePlaylists.read(data)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported[0].description, "Desktop collection")
        XCTAssertEqual(imported[0].entries.count, 2)
        guard case .online(let online) = imported[0].entries[0].source,
              case .file(let local) = imported[0].entries[1].source else { return XCTFail("Both song sources must survive import") }
        XCTAssertEqual(online.webpageURL, "https://music.youtube.com/watch?v=abcdefghijk")
        XCTAssertEqual(online.album, "Album")
        XCTAssertEqual(online.artworkURL, "https://example.com/cover.jpg")
        XCTAssertEqual(local.filename, "local.wav")
        XCTAssertEqual(local.title, "Local song")
        XCTAssertEqual(local.duration, 45)
    }

    func testImportIsAtomicAndPortableRoundTripRetainsLocalReferences() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistStore(root: root)
        let valid = Data(#"{"name":"Files","tracks":[{"title":"Local song","artist":"Riff","url":"../private/song.wav","platform":"local"}]}"#.utf8)
        XCTAssertEqual(try store.importFile(valid), 1)
        let previous = try Data(contentsOf: root.appending(path: "playlists.json"))
        let invalid = Data(#"{"playlists":[{"name":"Valid","tracks":[]},{"name":"Invalid","tracks":[{"title":"Bad scheme","url":"javascript:alert(1)"}]}]}"#.utf8)
        XCTAssertThrowsError(try store.importFile(invalid))
        XCTAssertEqual(store.playlists.count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "playlists.json")), previous)
        let exported = try PortablePlaylists.write(store.playlists, library: AudioLibrary(root: root.appending(path: "audio")))
        let decoded = try PortablePlaylists.read(exported)
        guard case .file(let reference) = decoded[0].entries[0].source else { return XCTFail("Local reference was discarded") }
        XCTAssertEqual(reference.filename, "song.wav")
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("../private"))
        XCTAssertEqual(PlaylistStore(root: root).playlists[0].entries.count, 1)
    }

    func testImportedFileReferenceMatchesUniqueLibraryAudioAfterImport() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = AudioLibrary(root: root)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ui-tone", withExtension: "wav"))
        let reference = LocalFileReference(filename: "desktop.wav", title: "ui-tone", artist: "", album: nil, duration: nil)
        XCTAssertNil(library.matchingLocalFile(reference))
        await library.importFiles([fixture])
        XCTAssertEqual(library.matchingLocalFile(reference)?.id, library.tracks.first?.id)
        let second = root.appending(path: "other.wav")
        try FileManager.default.copyItem(at: fixture, to: second)
        await library.importFiles([second])
        let duplicate = try XCTUnwrap(library.tracks.last)
        try library.updateMetadata(duplicate.id, title: "ui-tone", artist: "", album: "")
        XCTAssertNil(library.matchingLocalFile(reference), "An ambiguous local match must not play the wrong recording")
    }
}
