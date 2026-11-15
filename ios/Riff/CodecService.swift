import Foundation

enum AudioExportFormat: String, CaseIterable, Sendable {
    case wav, mp3, flac, m4a, opus
    var title: String { rawValue.uppercased() }
}

/// The C context owns only atomics and run-local buffers. Only cancellation and
/// progress may be accessed concurrently; conversion is serialized by the actor.
private final class CodecJob: @unchecked Sendable {
    let pointer: OpaquePointer
    init() throws {
        guard let pointer = riff_conversion_create() else { throw ExtractionError(message: "Could not allocate an audio conversion.") }
        self.pointer = pointer
    }
    func cancel() { riff_conversion_cancel(pointer) }
    deinit { riff_conversion_destroy(pointer) }
}

actor CodecService {
    static let shared = CodecService()

    func convert(input: URL, output: URL, format: AudioExportFormat, bitrate: Int = 192000,
                 title: String = "", artist: String = "", album: String = "") async throws {
        guard input.isFileURL, output.isFileURL,
              input.resolvingSymlinksInPath() != output.resolvingSymlinksInPath() else {
            throw ExtractionError(message: "Conversion needs a new local audio file.")
        }
        let job = try CodecJob()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let capacity = 512
            var message = [CChar](repeating: 0, count: capacity)
            let result = riff_conversion_run(job.pointer, input.path, output.path, format.rawValue, Int32(clamping: bitrate), title, artist, album, &message, capacity)
            if result < 0 {
                try Task.checkCancellation()
                let detail = String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                throw ExtractionError(message: detail.isEmpty ? "Audio conversion failed." : detail)
            }
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: output)
                throw CancellationError()
            }
        } onCancel: { job.cancel() }
    }
}
