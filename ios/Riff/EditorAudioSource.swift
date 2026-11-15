import AVFoundation

struct PreparedEditorAudio: Sendable {
    let url: URL
    let temporaryDirectory: URL?
    func removeTemporaryFiles() {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }
}

actor EditorAudioSource {
    static let shared = EditorAudioSource()
    func prepare(_ original: URL) async throws -> PreparedEditorAudio {
        try Task.checkCancellation()
        if let file = try? AVAudioFile(forReading: original), file.length > 0 {
            return PreparedEditorAudio(url: original, temporaryDirectory: nil)
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "RiffEditor/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let output = folder.appending(path: "source.wav")
            try await CodecService.shared.convert(input: original, output: output, format: .wav)
            try Task.checkCancellation()
            return PreparedEditorAudio(url: output, temporaryDirectory: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
