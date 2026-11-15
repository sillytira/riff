import Foundation

actor FileImportReader {
    static let shared = FileImportReader()
    func copy(_ source: URL, to destination: URL) throws {
        try Task.checkCancellation()
        guard source.isFileURL, destination.isFileURL else { throw URLError(.unsupportedURL) }
        if let error = RiffCoordinatedFileCopy(source, destination) { throw error }
        try Task.checkCancellation()
    }
}

struct AudioImportFailure: Identifiable, Sendable {
    let id = UUID()
    let message: String
}
