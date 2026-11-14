import AVFoundation
import XCTest
@testable import Riff

@MainActor
final class AudioProcessingTests: XCTestCase {
    private func tone(in root: URL) throws -> URL {
        let url = root.appending(path: "tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        buffer.frameLength = 44100
        for frame in 0..<44100 { buffer.floatChannelData![0][frame] = 0.05 * sin(2 * .pi * 1000 * Float(frame) / 44100) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
    private func rms(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        var sum = 0.0
        for frame in 0..<Int(buffer.frameLength) { sum += Double(samples[frame] * samples[frame]) }
        return sqrt(sum / Double(buffer.frameLength))
    }

    func testTrimProducesExactSampleCountWithoutChangingOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try tone(in: root)
        let original = try Data(contentsOf: source)
        let output = root.appending(path: "trim.wav")
        try await AudioProcessor.shared.exportWAV(input: source, output: output, start: 0.25, end: 0.75, settings: AudioEffectSettings())
        XCTAssertEqual(try AVAudioFile(forReading: output).length, 22050)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertGreaterThan(try rms(output), 0.02)
    }

    func testEqualizerChangesActualRenderedAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try tone(in: root)
        let output = root.appending(path: "boosted.wav")
        var settings = AudioEffectSettings()
        settings.gains[5] = 12
        try await AudioProcessor.shared.exportWAV(input: source, output: output, start: 0, end: 1, settings: settings)
        XCTAssertGreaterThan(try rms(output), try rms(source) * 2)
    }
}
