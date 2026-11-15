import XCTest
@testable import Riff

@MainActor
final class PlaylistsTests: XCTestCase {
    func testPlaylistEditsPersistWithoutChangingTrackIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistStore(root: root)
        let a = PlaylistEntry(source: .local(UUID()))
        let b = PlaylistEntry(source: .local(UUID()))
        let c = PlaylistEntry(source: .local(UUID()))
        let id = try XCTUnwrap(store.create(name: "Road trip", entries: [a, b, c]))
        store.move(in: id, from: IndexSet(integer: 0), to: 3)
        store.rename(id, to: "Driving")
        let restored = PlaylistStore(root: root)
        XCTAssertEqual(restored.playlists[0].name, "Driving")
        XCTAssertEqual(restored.playlists[0].entries.map(\.id), [b.id, c.id, a.id])
        store.remove(from: id, offsets: IndexSet(integer: 1))
        XCTAssertEqual(store.playlists[0].entries.map(\.id), [b.id, a.id])
    }

    func testCorruptPlaylistIndexIsNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = Data("corrupt".utf8)
        let file = root.appending(path: "playlists.json")
        try data.write(to: file)
        let store = PlaylistStore(root: root)
        XCTAssertNil(store.create(name: "New"))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testMixedQueueOrderAndRepeatOneApplyOnlyToAutomaticAdvance() {
        let local = PlaylistEntry(source: .local(UUID()))
        let remote = PlaylistEntry(source: .online(OnlineTrack(id: "remote", title: "Online", artist: "Artist", webpageURL: "https://example.com/track", artworkURL: nil, duration: 10, provider: "test")))
        var queue = PlaybackQueue(entries: [local, remote], currentID: local.id)
        XCTAssertEqual(queue.advance(automatic: true, shuffle: false, repeatMode: "one")?.id, local.id)
        XCTAssertEqual(queue.advance(automatic: false, shuffle: false, repeatMode: "one")?.id, remote.id)
        XCTAssertNil(queue.advance(automatic: true, shuffle: false, repeatMode: "off"))
        XCTAssertEqual(queue.advance(automatic: true, shuffle: false, repeatMode: "all")?.id, local.id)
    }
}
