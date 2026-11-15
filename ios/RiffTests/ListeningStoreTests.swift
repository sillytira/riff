import XCTest
@testable import Riff

@MainActor
final class ListeningStoreTests: XCTestCase {
    func testMixedFavoritesAndHistoryPersistWithoutDuplicateEntries() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = PlaylistSource.local(UUID())
        let online = PlaylistSource.online(OnlineTrack(id: "song", title: "Song", artist: "Artist", webpageURL: "https://example.com/song", artworkURL: nil, duration: 200, provider: "Generic"))
        let store = ListeningStore(root: root)
        store.toggleFavorite(local)
        store.toggleFavorite(online)
        store.record(local, at: Date(timeIntervalSince1970: 1))
        store.record(online, at: Date(timeIntervalSince1970: 2))
        store.record(local, at: Date(timeIntervalSince1970: 3))
        let restored = ListeningStore(root: root)
        XCTAssertTrue(restored.isFavorite(local))
        XCTAssertTrue(restored.isFavorite(online))
        XCTAssertEqual(restored.history.count, 2)
        XCTAssertEqual(restored.history.first?.id, ListeningEntry.key(for: local))
        XCTAssertEqual(restored.history.first?.playedAt, Date(timeIntervalSince1970: 3))
        restored.toggleFavorite(local)
        restored.clearHistory()
        let cleared = ListeningStore(root: root)
        XCTAssertFalse(cleared.isFavorite(local))
        XCTAssertTrue(cleared.isFavorite(online))
        XCTAssertTrue(cleared.history.isEmpty)
    }

    func testCorruptListeningDataIsPreservedOnMutation() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "listening.json")
        let original = Data("corrupt".utf8)
        try original.write(to: file)
        let store = ListeningStore(root: root)
        store.record(.local(UUID()))
        store.toggleFavorite(.local(UUID()))
        XCTAssertNotNil(store.error)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
