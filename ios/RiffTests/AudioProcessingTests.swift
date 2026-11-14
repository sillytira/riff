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

    func testNativePlayerAdvancesPausesSeeksAndResumes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try tone(in: root)
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        let player = try NativeAudioPlayer(contentsOf: source)
        defer { player.stop() }
        XCTAssertTrue(player.prepareToPlay())
        XCTAssertTrue(player.play())
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(player.currentTime, 0.05)
        player.pause()
        let paused = player.currentTime
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(player.currentTime, paused, accuracy: 0.03)
        player.currentTime = 0.5
        XCTAssertEqual(player.currentTime, 0.5, accuracy: 0.001)
        XCTAssertTrue(player.play())
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(player.currentTime, 0.55)
    }

    func testRateChangesExportLengthAndPitchDoesNot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try tone(in: root)
        var fast = AudioEffectSettings()
        fast.rate = 2
        let fastOutput = root.appending(path: "fast.wav")
        try await AudioProcessor.shared.exportWAV(input: source, output: fastOutput, start: 0, end: 1, settings: fast)
        XCTAssertEqual(try AVAudioFile(forReading: fastOutput).length, 22050)
        var pitched = AudioEffectSettings()
        pitched.pitch = 12
        let pitchOutput = root.appending(path: "pitch.wav")
        try await AudioProcessor.shared.exportWAV(input: source, output: pitchOutput, start: 0, end: 1, settings: pitched)
        let file = try AVAudioFile(forReading: pitchOutput)
        XCTAssertEqual(file.length, 44100)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44100)!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        var risingCrossings = 0
        for frame in 10001..<30000 {
            if samples[frame - 1] <= 0 && samples[frame] > 0 { risingCrossings += 1 }
        }
        let frequency = Double(risingCrossings) * 44100 / 19999
        XCTAssertGreaterThan(frequency, 1800)
        XCTAssertLessThan(frequency, 2200)
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
