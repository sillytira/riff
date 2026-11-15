import Foundation

struct StreamChunk: Sendable {
    let left: [Float]
    let right: [Float]
    let position: Double
    var count: Int { left.count }
}

final class StreamDecoderHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init() throws {
        guard let pointer = riff_decoder_create() else { throw ExtractionError(message: "Could not allocate an audio stream.") }
        self.pointer = pointer
    }
    func cancel() { riff_decoder_cancel(pointer) }
    deinit { riff_decoder_destroy(pointer) }
}

actor StreamDecoder {
    private let handle: StreamDecoderHandle
    init(handle: StreamDecoderHandle) { self.handle = handle }

    func open(url: URL, headers: [String: String], position: Double) throws -> Double {
        try Task.checkCancellation()
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw URLError(.unsupportedURL) }
        for (key, value) in headers {
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  !value.contains("\r"), !value.contains("\n"), !value.contains("\0") else {
                throw ExtractionError(message: "The provider returned invalid playback headers.")
            }
        }
        var forwarded = headers.filter { !["range", "accept-encoding"].contains($0.key.lowercased()) }
        forwarded["Accept-Encoding"] = "identity"
        let headerText = forwarded.sorted { $0.key < $1.key }.map { $0.key + ": " + $0.value + "\r\n" }.joined()
        var duration = 0.0
        let capacity = 512
        var message = [CChar](repeating: 0, count: capacity)
        let raw = url.absoluteString
        let address = url.scheme!.lowercased() + raw.dropFirst(url.scheme!.count)
        let result = riff_decoder_open(handle.pointer, address, headerText, position, &duration, &message, capacity)
        try Task.checkCancellation()
        guard result >= 0 else { throw failure(message, fallback: "Could not open the audio stream.") }
        return duration.isFinite ? max(0, duration) : 0
    }

    func read() throws -> StreamChunk? {
        try Task.checkCancellation()
        let capacity = 4096, errorCapacity = 512
        var left = [Float](repeating: 0, count: capacity), right = left
        var position = 0.0
        var message = [CChar](repeating: 0, count: errorCapacity)
        let count = riff_decoder_read(handle.pointer, &left, &right, Int32(capacity), &position, &message, errorCapacity)
        try Task.checkCancellation()
        guard count >= 0 else { throw failure(message, fallback: "The audio stream stopped receiving data.") }
        guard count > 0 else { return nil }
        return StreamChunk(left: Array(left.prefix(Int(count))), right: Array(right.prefix(Int(count))), position: position)
    }
    private func failure(_ buffer: [CChar], fallback: String) -> ExtractionError {
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return ExtractionError(message: text.isEmpty ? fallback : text)
    }
}

actor StreamBufferGate {
    private var available = 12
    private var closed = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    func acquire() async -> Bool {
        guard !closed else { return false }
        if available > 0 { available -= 1; return true }
        return await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        guard !closed else { return }
        if !waiters.isEmpty { waiters.removeFirst().resume(returning: true) }
        else { available = min(12, available + 1) }
    }
    func cancel() {
        closed = true
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume(returning: false) }
    }
}
