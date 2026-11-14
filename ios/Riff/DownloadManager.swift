import Foundation
import Observation

struct DownloadJob: Identifiable {
    let id: UUID
    let track: OnlineTrack
    var status: String
    var isActive: Bool
}

@MainActor @Observable
final class DownloadManager {
    private(set) var jobs: [DownloadJob] = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    func download(_ track: OnlineTrack, into library: AudioLibrary) {
        guard !jobs.contains(where: { $0.isActive && $0.track.webpageURL == track.webpageURL }) else { return }
        let id = UUID()
        jobs.insert(DownloadJob(id: id, track: track, status: "Resolving audio…", isActive: true), at: 0)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let media = try await MediaExtractor.shared.resolve(track.webpageURL)
                try Task.checkCancellation()
                guard let url = URL(string: media.streamURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                    throw ExtractionError(message: "The provider returned an invalid audio URL.")
                }
                guard !(media.protocol?.contains("m3u8") ?? false) else {
                    throw ExtractionError(message: "This provider returned segmented audio. A direct downloadable format is required.")
                }
                self.update(id, "Downloading…")
                var request = URLRequest(url: url)
                request.timeoutInterval = 120
                for (key, value) in media.headers { request.setValue(value, forHTTPHeaderField: key) }
                let (file, response) = try await URLSession.shared.download(for: request)
                defer { try? FileManager.default.removeItem(at: file) }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw ExtractionError(message: "The provider refused the audio download. Try resolving it again.")
                }
                try Task.checkCancellation()
                try library.importDownload(file, media: media)
                self.update(id, "Saved offline", active: false)
            } catch is CancellationError {
                self.update(id, "Cancelled", active: false)
            } catch {
                self.update(id, error.localizedDescription, active: false)
            }
            self.tasks[id] = nil
        }
    }

    func cancel(_ id: UUID) { tasks[id]?.cancel() }

    private func update(_ id: UUID, _ status: String, active: Bool = true) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = status
        jobs[index].isActive = active
    }
}
