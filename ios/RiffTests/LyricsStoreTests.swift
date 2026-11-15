import XCTest
@testable import Riff

final class LyricsStoreTests: XCTestCase {
    func testLyricsAndOffsetsPersistIndependentlyPerTrack() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LyricsStore(root: root)
        try await store.save(.parse("[00:01]First song"), key: "track-a")
        try await store.save(.parse("[00:02]Second song"), key: "track-b")
        try await store.setOffset(1.5, key: "track-a")
        let restored = LyricsStore(root: root)
        let first = try await restored.read("track-a")
        let second = try await restored.read("track-b")
        XCTAssertEqual(first?.offset, 1.5)
        XCTAssertEqual(second?.offset, 0)
        XCTAssertEqual(first?.document.lines.first?.text, "First song")
        XCTAssertEqual(second?.document.lines.first?.time, 2)
    }
}
