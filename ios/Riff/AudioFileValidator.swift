import AVFoundation

struct ValidatedAudio: Sendable {
    let usesCodecs: Bool
    let duration: Double
}

/// Validation and codec probing run off the UI executor before a manifest commit.
actor AudioFileValidator {
    static let shared = AudioFileValidator()
    func validate(_ url: URL) async throws -> ValidatedAudio {
        try Task.checkCancellation()
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0 else { throw ExtractionError(message: "This audio file has no playable samples.") }
            return ValidatedAudio(usesCodecs: false, duration: Double(file.length) / file.processingFormat.sampleRate)
        } catch {
            let handle = try StreamDecoderHandle()
            let decoder = StreamDecoder(handle: handle)
            return try await withTaskCancellationHandler {
                let duration = try await decoder.open(url: url, headers: [:], position: 0)
                guard let chunk = try await decoder.read(), chunk.count > 0 else { throw ExtractionError(message: "This audio file has no playable samples.") }
                return ValidatedAudio(usesCodecs: true, duration: duration)
            } onCancel: { handle.cancel() }
        }
    }
}
