import AVFoundation
import XCTest
@testable import Riff

@MainActor
final class CodecTests: XCTestCase {
    func testCodecLicenseTextsAreBundledWithTheApp() throws {
        for name in ["FFmpeg-LGPL-2.1", "LAME-LGPL", "Opus-BSD"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Licenses"))
            XCTAssertGreaterThan(try Data(contentsOf: url).count, 300)
        }
    }

    func testEncodedFormatsDecodeToAudibleAudioOnIPhone() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ui-tone", withExtension: "wav"))
        let original = try Data(contentsOf: input)
        for format in [AudioExportFormat.mp3, .flac, .m4a, .opus] {
            let output = root.appending(path: "encoded." + format.rawValue)
            try await CodecService.shared.convert(input: input, output: output, format: format, title: "Native Codec Song", artist: "Riff")
            let playable: URL
            if format == .opus {
                playable = root.appending(path: "decoded.wav")
                try await CodecService.shared.convert(input: output, output: playable, format: .wav)
            } else { playable = output }
            let file = try AVAudioFile(forReading: playable)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            XCTAssertEqual(duration, 2, accuracy: 0.2, format.rawValue)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192))
            try file.read(into: buffer)
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            let energy = (0..<Int(buffer.frameLength)).reduce(0.0) { $0 + Double(channel[$1] * channel[$1]) }
            XCTAssertGreaterThan(energy / Double(buffer.frameLength), 0.0001, format.rawValue)
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testOpusEditPreservesEncodedFileAndPlayableCopyAcrossRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ui-tone", withExtension: "wav"))
        let encoded = root.appending(path: "export.opus"), decoded = root.appending(path: "decoded.wav")
        try await CodecService.shared.convert(input: input, output: encoded, format: .opus)
        try await CodecService.shared.convert(input: encoded, output: decoded, format: .wav)
        let encodedBytes = try Data(contentsOf: encoded)
        let storage = root.appending(path: "library")
        let library = AudioLibrary(root: storage)
        let original = LocalTrack(id: UUID(), name: "Song", filename: "original.wav", artist: "Artist")
        try await library.importEditedFile(encoded, original: original, playableCopy: decoded)
        try FileManager.default.removeItem(at: encoded)
        try FileManager.default.removeItem(at: decoded)
        let restored = AudioLibrary(root: storage)
        let track = try XCTUnwrap(restored.tracks.first)
        XCTAssertTrue(track.filename.hasSuffix(".opus"))
        XCTAssertNotNil(track.playbackFilename)
        XCTAssertEqual(try Data(contentsOf: storage.appending(path: track.filename)), encodedBytes)
        let playback = try XCTUnwrap(restored.editableURL(for: track))
        XCTAssertGreaterThan(try AVAudioFile(forReading: playback).length, 0)
        restored.play(track)
        defer { if restored.isPlaying { restored.togglePlayback() } }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(restored.isPlaying)
        XCTAssertGreaterThan(restored.elapsed, 0.05)
    }

    func testCancelledConversionDoesNotLeaveAnOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ui-tone", withExtension: "wav"))
        let output = root.appending(path: "cancelled.mp3")
        let conversion = Task { try await CodecService.shared.convert(input: input, output: output, format: .mp3) }
        conversion.cancel()
        do { try await conversion.value; XCTFail("A cancelled conversion must not complete") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
