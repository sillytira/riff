import AVFoundation

struct AudioEffectSettings: Codable, Sendable, Equatable {
    var rate: Float = 1
    var pitch: Float = 0
    var reverb: Float = 0
    var distortion: Float = 0
    var gains: [Float] = Array(repeating: 0, count: 10)
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
}

/// A graph is used on one owning executor. AVFoundation renders its nodes internally.
final class AudioGraph {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let equalizer = AVAudioUnitEQ(numberOfBands: 10)
    let timePitch = AVAudioUnitTimePitch()
    let reverb = AVAudioUnitReverb()
    let distortion = AVAudioUnitDistortion()
    private let sampleRate: Double

    init(format: AVAudioFormat, settings: AudioEffectSettings) {
        sampleRate = format.sampleRate
        let nodes: [AVAudioNode] = [player, equalizer, timePitch, reverb, distortion]
        nodes.forEach(engine.attach)
        engine.connect(player, to: equalizer, format: format)
        engine.connect(equalizer, to: timePitch, format: format)
        engine.connect(timePitch, to: reverb, format: format)
        engine.connect(reverb, to: distortion, format: format)
        engine.connect(distortion, to: engine.mainMixerNode, format: format)
        reverb.loadFactoryPreset(.mediumHall)
        distortion.loadFactoryPreset(.multiBrokenSpeaker)
        apply(settings)
    }

    func apply(_ settings: AudioEffectSettings) {
        timePitch.rate = min(4, max(0.25, settings.rate))
        timePitch.pitch = min(24, max(-24, settings.pitch)) * 100
        timePitch.bypass = settings.rate == 1 && settings.pitch == 0
        reverb.wetDryMix = min(100, max(0, settings.reverb))
        reverb.bypass = settings.reverb == 0
        distortion.wetDryMix = min(100, max(0, settings.distortion))
        distortion.bypass = settings.distortion == 0
        for (index, band) in equalizer.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = min(AudioEffectSettings.frequencies[index], Float(sampleRate * 0.45))
            band.bandwidth = 1
            band.gain = settings.gains.indices.contains(index) ? min(12, max(-12, settings.gains[index])) : 0
            band.bypass = band.gain == 0
        }
        equalizer.bypass = settings.gains.allSatisfy { $0 == 0 }
    }
}

@MainActor
final class NativeAudioPlayer {
    private let file: AVAudioFile
    private let graph: AudioGraph
    private var startingFrame: AVAudioFramePosition = 0
    private var heldTime = 0.0
    private var needsSchedule = false
    private var token = UUID()
    var onFinish: (@MainActor () -> Void)?
    var settings = AudioEffectSettings() { didSet { graph.apply(settings) } }
    var duration: Double { Double(file.length) / file.processingFormat.sampleRate }
    var isPlaying: Bool { graph.player.isPlaying }
    var currentTime: Double {
        get {
            let offset: AVAudioFramePosition
            if graph.player.isPlaying, let render = graph.player.lastRenderTime, let time = graph.player.playerTime(forNodeTime: render) { offset = time.sampleTime }
            else { return heldTime }
            return min(duration, Double(startingFrame + offset) / file.processingFormat.sampleRate)
        }
        set {
            let playing = isPlaying
            schedule(from: min(duration, max(0, newValue)))
            if playing {
                if startingFrame >= file.length { onFinish?() }
                else { _ = play() }
            }
        }
    }

    init(contentsOf url: URL) throws {
        let audioFile = try AVAudioFile(forReading: url)
        guard audioFile.length > 0 else { throw ExtractionError(message: "This audio file has no playable samples.") }
        file = audioFile
        graph = AudioGraph(format: audioFile.processingFormat, settings: AudioEffectSettings())
        schedule(from: 0)
    }

    func prepareToPlay() -> Bool { graph.engine.prepare(); return true }
    func play() -> Bool {
        do {
            if !graph.engine.isRunning { try graph.engine.start() }
            if needsSchedule || startingFrame >= file.length { schedule(from: 0) }
            graph.player.play()
            return true
        } catch { return false }
    }
    func pause() { heldTime = currentTime; graph.player.pause() }
    func stop() {
        heldTime = currentTime
        needsSchedule = true
        token = UUID()
        graph.player.stop()
        graph.engine.stop()
    }

    private func schedule(from seconds: Double) {
        let id = UUID()
        token = id
        graph.player.stop()
        startingFrame = min(file.length, AVAudioFramePosition(seconds * file.processingFormat.sampleRate))
        heldTime = Double(startingFrame) / file.processingFormat.sampleRate
        needsSchedule = false
        let count = file.length - startingFrame
        guard count > 0 else { return }
        graph.player.scheduleSegment(file, startingFrame: startingFrame, frameCount: AVAudioFrameCount(min(count, AVAudioFramePosition(UInt32.max))), at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.token == id else { return }
                self.startingFrame = self.file.length
                self.heldTime = self.duration
                self.needsSchedule = true
                self.graph.player.stop()
                self.onFinish?()
            }
        }
    }
}

/// Offline rendering uses the same signal chain as local playback, never edits the input.
actor AudioProcessor {
    static let shared = AudioProcessor()

    func exportWAV(input: URL, output: URL, start: Double, end: Double, settings: AudioEffectSettings) throws {
        let file = try AVAudioFile(forReading: input)
        let format = file.processingFormat
        let duration = Double(file.length) / format.sampleRate
        guard start.isFinite, end.isFinite, start >= 0, end > start, end <= duration + 0.001,
              settings.rate.isFinite, settings.rate >= 0.25, settings.rate <= 4 else {
            throw ExtractionError(message: "Choose valid start and end points inside the track.")
        }
        guard input.standardizedFileURL != output.standardizedFileURL else {
            throw ExtractionError(message: "An export must use a new file so the original stays intact.")
        }
        let first = AVAudioFramePosition(start * format.sampleRate)
        let count = min(file.length - first, AVAudioFramePosition((end - start) * format.sampleRate))
        guard count > 0, count <= AVAudioFramePosition(UInt32.max) else { throw ExtractionError(message: "This selection is too long to render in one operation.") }
        let graph = AudioGraph(format: format, settings: settings)
        try graph.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        defer { graph.player.stop(); graph.engine.stop() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw ExtractionError(message: "Could not allocate the audio rendering buffer.")
        }
        graph.player.scheduleSegment(file, startingFrame: first, frameCount: AVAudioFrameCount(count), at: nil)
        try graph.engine.start()
        graph.player.play()
        do {
            let destination = try AVAudioFile(forWriting: output, settings: format.settings)
            var remaining = AVAudioFramePosition(Double(count) / Double(settings.rate))
            var stalled = 0
            while remaining > 0 {
                try Task.checkCancellation()
                let frames = AVAudioFrameCount(min(remaining, 4096))
                let status = try graph.engine.renderOffline(frames, to: buffer)
                switch status {
                case .success:
                    guard buffer.frameLength > 0 else { throw ExtractionError(message: "The audio renderer produced no samples.") }
                    try destination.write(from: buffer)
                    remaining -= AVAudioFramePosition(buffer.frameLength)
                    stalled = 0
                case .cannotDoInCurrentContext, .insufficientDataFromInputNode:
                    stalled += 1
                    if stalled > 100 { throw ExtractionError(message: "The audio renderer could not complete this selection.") }
                case .error:
                    throw ExtractionError(message: "Audio rendering failed.")
                @unknown default:
                    throw ExtractionError(message: "The device returned an unsupported audio rendering state.")
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}
