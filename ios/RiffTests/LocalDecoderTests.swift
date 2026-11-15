import XCTest
@testable import Riff

@MainActor
final class LocalDecoderTests: XCTestCase {
    func testVorbisAndOpusDecodeSeekAndRetainEmbeddedMetadata() async throws {
        for ext in ["ogg", "opus"] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "tagged", withExtension: ext))
            let handle = try StreamDecoderHandle()
            defer { handle.cancel() }
            let decoder = StreamDecoder(handle: handle)
            let duration = try await decoder.open(url: url, headers: [:], position: 0.7)
            XCTAssertEqual(duration, 2, accuracy: 0.1)
            let decoded = try await decoder.read()
            let chunk = try XCTUnwrap(decoded)
            XCTAssertEqual(chunk.position, 0.7, accuracy: 0.05)
            XCTAssertGreaterThan(chunk.left.reduce(0) { $0 + Double($1 * $1) } / Double(chunk.count), 0.0001)
            let metadata = await decoder.metadata()
            XCTAssertEqual(metadata.title, "Local Decoder Song")
            XCTAssertEqual(metadata.artist, "Riff")
            XCTAssertEqual(metadata.album, "Codec Tests")
            XCTAssertEqual(metadata.artwork?.prefix(4), Data([0x89, 0x50, 0x4e, 0x47]))
            let indexed = try await LocalMetadataReader.shared.read(url)
            XCTAssertEqual(indexed.title, metadata.title)
            XCTAssertEqual(indexed.artwork, metadata.artwork)
        }
    }

    func testLocalDecoderRejectsDirectoriesAndNetworkPlaylists() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let playlist = root.appending(path: "remote.m3u8")
        try Data("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nhttps://example.invalid/private.ts\n#EXT-X-ENDLIST\n".utf8).write(to: playlist)
        for input in [root, playlist] {
            let handle = try StreamDecoderHandle()
            defer { handle.cancel() }
            let decoder = StreamDecoder(handle: handle)
            do {
                _ = try await decoder.open(url: input, headers: [:], position: 0)
                XCTFail("Local audio must not open directories or network playlists")
            } catch { }
        }
    }
}
