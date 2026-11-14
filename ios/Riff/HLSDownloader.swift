import AVFoundation

/// AVFoundation owns HLS segment persistence and encryption handling.
@MainActor
final class HLSDownloader: NSObject, AVAssetDownloadDelegate {
    static let shared = HLSDownloader()
    private var session: AVAssetDownloadURLSession!
    private struct Pending {
        let continuation: CheckedContinuation<URL, Error>
        let task: AVAssetDownloadTask
        var location: URL?
    }
    private var pending: [UUID: Pending] = [:]

    override private init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: "io.github.rootscripts.riff.hls")
        configuration.waitsForConnectivity = true
        session = AVAssetDownloadURLSession(configuration: configuration, assetDownloadDelegate: self, delegateQueue: .main)
    }

    func download(_ asset: AVURLAsset, title: String) async throws -> URL {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard let task = session.makeAssetDownloadTask(asset: asset, assetTitle: title, assetArtworkData: nil, options: nil) else {
                    continuation.resume(throwing: ExtractionError(message: "This HLS audio cannot be downloaded on this device."))
                    return
                }
                task.taskDescription = id.uuidString
                pending[id] = Pending(continuation: continuation, task: task)
                task.resume()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.pending[id]?.task.cancel() }
        }
    }

    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        let identifier = assetDownloadTask.taskDescription
        Task { @MainActor [weak self] in
            guard let identifier, let id = UUID(uuidString: identifier) else { return }
            self?.pending[id]?.location = location
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let identifier = task.taskDescription
        let message = error?.localizedDescription
        let cancelled = (error as? URLError)?.code == .cancelled
        Task { @MainActor [weak self] in
            guard let identifier, let id = UUID(uuidString: identifier), let job = self?.pending.removeValue(forKey: id) else { return }
            if cancelled { job.continuation.resume(throwing: CancellationError()) }
            else if let message { job.continuation.resume(throwing: ExtractionError(message: message)) }
            else if let location = job.location { job.continuation.resume(returning: location) }
            else { job.continuation.resume(throwing: ExtractionError(message: "The HLS download completed without an offline asset.")) }
        }
    }
}
