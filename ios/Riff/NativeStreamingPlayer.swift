import AVFoundation

@MainActor
final class NativeStreamingPlayer {
    private struct Session: Sendable {
        let handle: StreamDecoderHandle
        let decoder: StreamDecoder
        let gate = StreamBufferGate()
        init() throws {
            let handle = try StreamDecoderHandle()
            self.handle = handle
            decoder = StreamDecoder(handle: handle)
        }
        func cancel() { handle.cancel(); Task { await gate.cancel() } }
    }
    private let format: AVAudioFormat
    private let graph: AudioGraph
    private var session: Session?
    private var producer: Task<Void, Never>?
    private var ready: CheckedContinuation<Void, Error>?
    private var token = UUID()
    private var sourceURL: URL?
    private var headers: [String: String] = [:]
    private var queued = 0
    private var readingComplete = false
    private var desiredPlaying = false
    private var buffering = false
    private var sourceStart = 0.0
    private var heldTime = 0.0
    private var lastScheduledEnd: Double?
    private var pausedAt: Date?
    private(set) var hasFailed = false
    private(set) var hasEnded = false
    private(set) var duration: Double
    var onFinish: (@MainActor () -> Void)?
    var onError: (@MainActor (Error) -> Void)?
    var onBuffering: (@MainActor (Bool) -> Void)?
    var settings: AudioEffectSettings { didSet { graph.apply(settings) } }
    var isPlaying: Bool { desiredPlaying }
    var needsRefresh: Bool { hasFailed || pausedAt.map { Date.now.timeIntervalSince($0) > 60 } == true }
    var elapsed: Double {
        let value: Double
        if graph.player.isPlaying, let render = graph.player.lastRenderTime, let time = graph.player.playerTime(forNodeTime: render) {
            value = sourceStart + Double(time.sampleTime) / 48000
        } else { value = heldTime }
        return min(duration > 0 ? duration : .greatestFiniteMagnitude, max(0, value.isFinite ? value : 0))
    }

    init(duration: Double?, settings: AudioEffectSettings) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) else { throw ExtractionError(message: "The audio output is unavailable.") }
        self.format = format
        graph = AudioGraph(format: format, settings: settings)
        self.settings = settings
        self.duration = duration.map { $0.isFinite ? max(0, $0) : 0 } ?? 0
    }

    func prepare(url: URL, headers: [String: String], position: Double = 0) async throws {
        try Task.checkCancellation()
        self.sourceURL = url
        self.headers = headers
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                launch(at: position, playing: true)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }
    func pause() {
        heldTime = elapsed
        desiredPlaying = false
        pausedAt = .now
        graph.player.pause()
        graph.engine.pause()
        setBuffering(false)
    }
    func resume() throws {
        desiredPlaying = true
        pausedAt = nil
        if hasEnded { launch(at: 0, playing: true); return }
        do { try ensurePlayback() }
        catch { desiredPlaying = false; throw error }
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let position = min(duration > 0 ? duration : .greatestFiniteMagnitude, max(0, seconds))
        launch(at: position, playing: desiredPlaying)
    }
    func stop() {
        heldTime = elapsed
        desiredPlaying = false
        shutdown(preservingWaiter: false)
        setBuffering(false)
    }

    private func launch(at seconds: Double, playing: Bool) {
        shutdown(preservingWaiter: true)
        let id = token
        queued = 0
        readingComplete = false
        hasFailed = false
        hasEnded = false
        desiredPlaying = playing
        pausedAt = playing ? nil : .now
        sourceStart = max(0, seconds)
        heldTime = sourceStart
        lastScheduledEnd = nil
        setBuffering(playing)
        guard let sourceURL else { fail(ExtractionError(message: "The audio output is unavailable."), id: id); return }
        do {
            let session = try Session()
            self.session = session
            let headers = self.headers
            producer = Task { @MainActor [weak self] in
                guard let self else { session.cancel(); return }
                do {
                    let duration = try await session.decoder.open(url: sourceURL, headers: headers, position: seconds)
                    guard self.token == id else { return }
                    if duration > 0 { self.duration = duration }
                    while !Task.isCancelled, await session.gate.acquire() {
                        try Task.checkCancellation()
                        let chunk = try await session.decoder.read()
                        guard self.token == id else { return }
                        guard let chunk else {
                            await session.gate.release()
                            self.readingComplete = true
                            if self.queued == 0 {
                                if self.lastScheduledEnd == nil { throw ExtractionError(message: "The stream contains no playable audio.") }
                                self.finish(id: id)
                            } else { try self.ensurePlayback() }
                            break
                        }
                        try self.enqueue(chunk, id: id, gate: session.gate)
                    }
                } catch { if self.token == id { self.fail(error, id: id) } }
                if self.token == id { self.producer = nil }
            }
        } catch { fail(error, id: id) }
    }
    private func enqueue(_ chunk: StreamChunk, id: UUID, gate: StreamBufferGate) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count)), let channels = buffer.floatChannelData else {
            throw ExtractionError(message: "Could not allocate the playback buffer.")
        }
        chunk.left.withUnsafeBufferPointer { if let base = $0.baseAddress { channels[0].update(from: base, count: chunk.count) } }
        chunk.right.withUnsafeBufferPointer { if let base = $0.baseAddress { channels[1].update(from: base, count: chunk.count) } }
        buffer.frameLength = AVAudioFrameCount(chunk.count)
        if lastScheduledEnd == nil { sourceStart = chunk.position; heldTime = sourceStart }
        lastScheduledEnd = chunk.position + Double(chunk.count) / 48000
        queued += 1
        graph.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor in self?.played(id: id, gate: gate) }
        }
        try ensurePlayback()
    }
    private func played(id: UUID, gate: StreamBufferGate) {
        guard token == id else { return }
        queued = max(0, queued - 1)
        Task { await gate.release() }
        if queued == 0 {
            if readingComplete { finish(id: id) }
            else if desiredPlaying {
                heldTime = elapsed
                graph.player.pause()
                setBuffering(true)
            }
        }
    }
    private func ensurePlayback() throws {
        guard desiredPlaying else { return }
        guard queued >= 2 || (readingComplete && queued > 0) else { setBuffering(true); return }
        if !graph.engine.isRunning { try graph.engine.start() }
        if !graph.player.isPlaying { graph.player.play() }
        setBuffering(false)
        ready?.resume()
        ready = nil
    }
    private func finish(id: UUID) {
        guard token == id else { return }
        heldTime = duration > 0 ? duration : (lastScheduledEnd ?? elapsed)
        desiredPlaying = false
        hasEnded = true
        pausedAt = .now
        shutdown(preservingWaiter: true)
        setBuffering(false)
        onFinish?()
    }
    private func fail(_ error: Error, id: UUID) {
        guard token == id else { return }
        heldTime = elapsed
        desiredPlaying = false
        hasFailed = true
        pausedAt = .now
        shutdown(preservingWaiter: true)
        setBuffering(false)
        if let ready { self.ready = nil; ready.resume(throwing: error) }
        else { onError?(error) }
    }
    private func shutdown(preservingWaiter: Bool) {
        token = UUID()
        session?.cancel()
        session = nil
        producer?.cancel()
        producer = nil
        graph.player.stop()
        graph.engine.stop()
        if !preservingWaiter, let ready { self.ready = nil; ready.resume(throwing: CancellationError()) }
    }
    private func setBuffering(_ value: Bool) {
        guard value != buffering else { return }
        buffering = value
        onBuffering?(value)
    }
}
