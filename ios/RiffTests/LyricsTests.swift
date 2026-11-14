import XCTest
@testable import Riff

final class LyricsTests: XCTestCase {
    func testMultipleTimestampsFractionsOffsetAndUnicode() {
        let document = LyricsDocument.parse("[offset:-500]\n[00:01.50][00:03.250]مرحبا\n[00:02.7]Hello")
        XCTAssertEqual(document.lines.map(\.time), [1, 2.2, 2.75])
        XCTAssertEqual(document.lines.map(\.text), ["مرحبا", "Hello", "مرحبا"])
        XCTAssertNil(document.activeLine(at: 0.5))
        XCTAssertEqual(document.activeLine(at: 2.3), 1)
    }
    func testPlainTextAndMetadataAreNotTimestamps() {
        XCTAssertTrue(LyricsDocument.parse("Hello\n[ar:Artist]\n[00:99]Invalid").lines.isEmpty)
    }
}
