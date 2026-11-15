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
    func testMashupUsesTitleArtistAndDoesNotInventSynchronizedTiming() {
        let identities = LyricsIdentity.candidates(title: "Lord Verity - Encore (I Miss The Quiet Mashup)", artist: "Rubyyy")
        let base = identities.first { $0.title == "Encore" && $0.artist == "Lord Verity" }
        XCTAssertNotNil(base)
        XCTAssertTrue(base?.alternateRecording ?? false)
        let wrongArtist = LyricsMatch(id: 1, trackName: "Encore", artistName: "Another Artist", albumName: nil, duration: 485, syncedLyrics: "[00:01]Hello", plainLyrics: "Hello")
        XCTAssertFalse(LyricsMatching.isStrongMatch(wrongArtist, identity: base!))
        let matchingArtist = LyricsMatch(id: 2, trackName: "Encore", artistName: "Lord Verity", albumName: nil, duration: 200, syncedLyrics: "[00:01]Hello", plainLyrics: "Hello")
        XCTAssertTrue(LyricsMatching.isStrongMatch(matchingArtist, identity: base!))
        let document = LyricsMatching.document(matchingArtist, duration: 485, forcePlain: true)
        XCTAssertTrue(document.lines.isEmpty)
        XCTAssertFalse(document.timingMatches)
        XCTAssertEqual(document.plainText, "Hello")
    }

    func testExactRecordingRetainsSynchronizedLyrics() {
        let match = LyricsMatch(id: 1, trackName: "Song", artistName: "Artist", albumName: nil, duration: 200, syncedLyrics: "[00:01]Hello", plainLyrics: "Hello")
        let document = LyricsMatching.document(match, duration: 200)
        XCTAssertEqual(document.lines.first?.time, 1)
        XCTAssertTrue(document.timingMatches)
    }

    func testPlainTextAndMetadataAreNotTimestamps() {
        XCTAssertTrue(LyricsDocument.parse("Hello\n[ar:Artist]\n[00:99]Invalid").lines.isEmpty)
    }
}
