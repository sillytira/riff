import AVFoundation
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

    func testVorbisImportArtworkPlaybackAndRelaunchNeedNoDecodedCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "tagged", withExtension: "ogg"))
        let library = AudioLibrary(root: root)
        await library.importFiles([input])
        XCTAssertNil(library.error)
        for _ in 0..<100 {
            if library.tracks.first?.artworkURL != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let track = try XCTUnwrap(library.tracks.first)
        XCTAssertEqual(track.name, "Local Decoder Song")
        XCTAssertEqual(track.artist, "Riff")
        XCTAssertNotNil(track.artworkURL)
        XCTAssertNil(track.playbackFilename)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix("-decoded.wav") })
        let restored = AudioLibrary(root: root)
        restored.repeatMode = .off
        restored.effects.pitch = 2
        restored.play(track, startingAt: 0.7)
        defer { restored.stop() }
        for _ in 0..<100 {
            if restored.isPlaying || restored.error != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNil(restored.error)
        XCTAssertTrue(restored.isPlaying)
        XCTAssertGreaterThanOrEqual(restored.elapsed, 0.7)
        XCTAssertEqual(restored.current?.id, track.id)
        restored.togglePlayback()
        XCTAssertFalse(restored.isPlaying)
        restored.togglePlayback()
        XCTAssertTrue(restored.isPlaying)
    }

    func testVorbisEditorUsesDisposableAudioAndExportsPlayableOpusWithoutProxy() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "tagged", withExtension: "ogg"))
        let originalBytes = try Data(contentsOf: input)
        let source = try await EditorAudioSource.shared.prepare(input)
        defer { source.removeTemporaryFiles() }
        let output = root.appending(path: "trim.wav"), encoded = root.appending(path: "trim.opus")
        try await AudioProcessor.shared.exportWAV(input: source.url, output: output, start: 0.3, end: 1.5, settings: AudioEffectSettings())
        let wav = try AVAudioFile(forReading: output)
        XCTAssertEqual(Double(wav.length) / wav.processingFormat.sampleRate, 1.2, accuracy: 0.05)
        try await CodecService.shared.convert(input: output, output: encoded, format: .opus)
        let library = AudioLibrary(root: root.appending(path: "library"))
        let original = LocalTrack(id: UUID(), name: "Song", filename: "original.ogg")
        try await library.importEditedFile(encoded, original: original)
        let track = try XCTUnwrap(library.tracks.first)
        XCTAssertNil(track.playbackFilename)
        XCTAssertTrue(track.filename.hasSuffix(".opus"))
        XCTAssertEqual(try Data(contentsOf: input), originalBytes)
        source.removeTemporaryFiles()
        if let temporary = source.temporaryDirectory { XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path)) }
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
