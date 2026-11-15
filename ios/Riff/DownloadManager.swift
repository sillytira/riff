import Foundation
import AVFoundation
import Observation

@MainActor @Observable
final class DownloadManager {
    private(set) var jobs: [DownloadJob] = []
    var error: String?
    @ObservationIgnored private weak var library: AudioLibrary?
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let manifest: URL
    @ObservationIgnored private var transfers: BackgroundTransfers?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var imports: Set<UUID> = []
    @ObservationIgnored private var live: [UUID: URLSessionTask] = [:]
    @ObservationIgnored private var readable = true
    @ObservationIgnored private var reconnecting = false
    @ObservationIgnored private var lastProgressSave = Date.distantPast

    init(library: AudioLibrary, root: URL = URL.applicationSupportDirectory.appending(path: "Riff/Downloads"), transfers: BackgroundTransfers? = nil) {
        self.library = library
        self.root = root
        manifest = root.appending(path: "jobs.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: manifest.path) {
                jobs = try JSONDecoder().decode([DownloadJob].self, from: Data(contentsOf: manifest))
            }
        } catch { readable = false; self.error = "Download history could not be read. Its data was preserved." }
        do {
            self.transfers = try transfers ?? BackgroundTransfers.shared()
            self.transfers?.bind { [weak self] event in Task { @MainActor in self?.receive(event) } }
        } catch { self.error = error.localizedDescription }
        Task { [weak self] in await self?.reconnect() }
    }
    func download(_ track: OnlineTrack, into library: AudioLibrary) {
        self.library = library
        guard readable, transfers != nil else { error = "Download storage is unavailable. Existing data has been preserved."; return }
        if let existing = jobs.first(where: { downloadSourceKey($0.track.webpageURL) == downloadSourceKey(track.webpageURL) && ($0.isActive || $0.state == .paused) }) {
            if existing.state == .paused { resume(existing.id) }
            return
        }
        if library.hasOfflineSource(track.webpageURL) { return }
        let job = DownloadJob(id: UUID(), track: track)
        jobs.insert(job, at: 0)
        guard save() else { return }
        resolve(job.id)
    }
    private func resolve(_ id: UUID) {
        guard let index = index(id), transfers != nil else { return }
        tasks[id]?.cancel()
        let attempt = UUID()
        jobs[index].attempt = attempt
        jobs[index].state = .resolving
        jobs[index].message = nil
        jobs[index].received = 0
        jobs[index].expected = 0
        jobs[index].hlsProgress = nil
        guard save() else { return }
        let track = jobs[index].track
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { if self.jobs.first(where: { $0.id == id })?.attempt == attempt { self.tasks[id] = nil } }
            do {
                var media = try await MediaExtractor.shared.resolve(track.webpageURL)
                try Task.checkCancellation()
                guard let index = self.index(id), self.jobs[index].attempt == attempt, self.jobs[index].state == .resolving,
                      let transfers = self.transfers else { return }
                guard let url = URL(string: media.streamURL), url.host != nil, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw ExtractionError(message: "The provider returned an invalid audio URL.") }
                media.track = track.enriched(with: media.track)
                self.jobs[index].track = media.track
                self.jobs[index].ext = media.ext
                self.jobs[index].isHLS = media.protocol?.contains("m3u8") ?? false
                self.jobs[index].state = .downloading
                guard self.save() else { return }
                let identity = TransferIdentity(job: id, attempt: attempt)
                if self.jobs[index].isHLS {
                    let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": media.headers])
                    self.live[id] = try transfers.startHLS(asset, title: track.title, identity: identity)
                } else {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 120
                    for (key, value) in media.headers { request.setValue(value, forHTTPHeaderField: key) }
                    self.live[id] = transfers.startDirect(request, identity: identity)
                }
                if let cover = media.track.artworkURL { Task { _ = try? await ArtworkCache.shared.imageData(for: cover) } }
            } catch {
                guard let index = self.index(id), self.jobs[index].attempt == attempt, self.jobs[index].state != .paused, self.jobs[index].state != .cancelled else { return }
                self.jobs[index].state = error is CancellationError ? .cancelled : .failed
                self.jobs[index].message = error.localizedDescription
                _ = self.save()
            }
        }
    }
    func pause(_ id: UUID) {
        guard let index = index(id), [.queued, .resolving, .downloading].contains(jobs[index].state) else { return }
        jobs[index].state = .paused
        tasks[id]?.cancel()
        tasks[id] = nil
        let attempt = jobs[index].attempt
        if let task = live[id] as? URLSessionDownloadTask {
            task.cancel { [weak self] data in
                Task { @MainActor in
                    guard let self, let index = self.index(id), self.jobs[index].attempt == attempt, self.jobs[index].state == .paused else { return }
                    if let data {
                        do { try protectedDownloadWrite(data, to: self.resumeURL(id)); self.jobs[index].hasResumeData = true }
                        catch { self.error = error.localizedDescription }
                    }
                    _ = self.save()
                }
            }
            live[id] = nil
        } else { live[id]?.suspend() }
        _ = save()
    }
    func resume(_ id: UUID) {
        guard let index = index(id), [.paused, .failed, .cancelled].contains(jobs[index].state) else { return }
        if jobs[index].state == .failed, let receipt = transfers?.receipts().first(where: { $0.job == id && $0.attempt == jobs[index].attempt }) {
            importReceipt(receipt)
            return
        }
        if let task = live[id], task.state == .suspended {
            jobs[index].state = .downloading
            _ = save()
            task.resume()
            return
        }
        if jobs[index].hasResumeData, let transfers,
           let data = try? Data(contentsOf: resumeURL(id)), data.count <= 2 * 1024 * 1024 {
            let identity = TransferIdentity(job: id, attempt: UUID())
            jobs[index].attempt = identity.attempt
            jobs[index].state = .downloading
            jobs[index].hasResumeData = false
            guard save() else { return }
            live[id] = transfers.resumeDirect(data, identity: identity)
            try? FileManager.default.removeItem(at: resumeURL(id))
        } else { resolve(id) }
    }
    func cancel(_ id: UUID) {
        guard let index = index(id), jobs[index].state != .importing, jobs[index].state != .saved else { return }
        jobs[index].state = .cancelled
        tasks[id]?.cancel(); tasks[id] = nil
        live.removeValue(forKey: id)?.cancel()
        jobs[index].hasResumeData = false
        try? FileManager.default.removeItem(at: resumeURL(id))
        if let transfers {
            for receipt in transfers.receipts() where receipt.job == id { transfers.forget(receipt, removeAsset: true) }
        }
        _ = save()
    }
    func clearCompleted() {
        if let transfers {
            let terminal = Set(jobs.filter { [.saved, .cancelled, .failed].contains($0.state) }.map(\.id))
            for receipt in transfers.receipts() where terminal.contains(receipt.job) {
                let retained = library?.tracks.contains { $0.downloadJobID == receipt.job } ?? false
                transfers.forget(receipt, removeAsset: !receipt.isHLS || !retained)
            }
        }
        jobs.removeAll { [.saved, .cancelled, .failed].contains($0.state) }
        _ = save()
    }
    func reconnect() async {
        guard !reconnecting, readable, let transfers else { return }
        reconnecting = true
        defer { reconnecting = false }
        let existing = await transfers.allTasks()
        for task in existing {
            guard let identity = TransferIdentity(task.taskDescription) else { continue }
            ensureRecovered(identity, hls: task is AVAssetDownloadTask)
            guard let index = index(identity.job) else { continue }
            if jobs[index].attempt != identity.attempt || [.saved, .cancelled, .failed].contains(jobs[index].state) { task.cancel(); continue }
            live[identity.job] = task
            if jobs[index].state == .paused { task.suspend() }
            else { jobs[index].state = .downloading; task.resume() }
        }
        let receipts = transfers.receipts()
        for receipt in receipts { receive(.finished(receipt)) }
        for job in jobs where job.isActive && live[job.id] == nil && tasks[job.id] == nil && !imports.contains(job.id) {
            if !receipts.contains(where: { $0.job == job.id && $0.attempt == job.attempt }) { resolve(job.id) }
        }
        _ = save()
    }
    private func receive(_ event: BackgroundTransfers.Event) {
        if case .drained(let identifier) = event { BackgroundSessionEvents.shared.finish(identifier); return }
        guard readable else { return }
        switch event {
        case .progress(let identity, let received, let expected, let fraction):
            guard let index = index(identity.job), jobs[index].attempt == identity.attempt, jobs[index].state == .downloading else { return }
            jobs[index].received = max(jobs[index].received, received)
            jobs[index].expected = expected
            jobs[index].hlsProgress = fraction
            if Date.now.timeIntervalSince(lastProgressSave) > 1 { lastProgressSave = .now; _ = save() }
        case .failed(let identity, let message, let cancelled):
            guard let index = index(identity.job), jobs[index].attempt == identity.attempt,
                  ![.saved, .paused, .cancelled, .failed, .importing].contains(jobs[index].state) else { return }
            live[identity.job] = nil
            jobs[index].state = cancelled ? .cancelled : .failed
            jobs[index].message = message
            _ = save()
        case .finished(let receipt):
            ensureRecovered(TransferIdentity(job: receipt.job, attempt: receipt.attempt), hls: receipt.isHLS)
            guard let index = index(receipt.job), let transfers, jobs[index].attempt == receipt.attempt else { return }
            if jobs[index].state == .saved { transfers.forget(receipt, removeAsset: !receipt.isHLS); return }
            if jobs[index].state == .cancelled { transfers.forget(receipt, removeAsset: true); return }
            importReceipt(receipt)
        case .drained(let identifier): BackgroundSessionEvents.shared.finish(identifier)
        }
    }
    private func importReceipt(_ receipt: DownloadReceipt) {
        guard let index = index(receipt.job), let transfers, let library, imports.insert(receipt.job).inserted else { return }
        jobs[index].state = .importing
        guard save() else { imports.remove(receipt.job); return }
        let job = jobs[index]
        Task { [weak self] in
            guard let self else { return }
            defer { self.imports.remove(receipt.job); self.live[receipt.job] = nil }
            do {
                if let cover = job.track.artworkURL { _ = try? await ArtworkCache.shared.imageData(for: cover) }
                let location = try transfers.location(receipt)
                let media = ResolvedMedia(track: job.track, streamURL: "", headers: [:], ext: job.ext, protocol: job.isHLS ? "m3u8" : "https")
                if receipt.isHLS { try await library.importHLSDownload(location, media: media, downloadJobID: job.id) }
                else { try library.importDownload(location, media: media, downloadJobID: job.id) }
                guard let index = self.index(job.id) else { return }
                self.jobs[index].state = .saved
                self.jobs[index].hlsProgress = 1
                self.jobs[index].hasResumeData = false
                guard self.save() else { return }
                transfers.forget(receipt, removeAsset: !receipt.isHLS)
            } catch {
                if let index = self.index(job.id) {
                    self.jobs[index].state = .failed
                    self.jobs[index].message = error.localizedDescription
                    _ = self.save()
                }
            }
        }
    }
    private func ensureRecovered(_ identity: TransferIdentity, hls: Bool) {
        guard index(identity.job) == nil else { return }
        let track = OnlineTrack(id: identity.job.uuidString, title: "Recovered download", artist: "", webpageURL: "", artworkURL: nil, duration: nil, provider: "Recovered")
        var job = DownloadJob(id: identity.job, track: track)
        job.attempt = identity.attempt; job.state = .downloading; job.isHLS = hls; job.ext = "m4a"
        jobs.insert(job, at: 0)
    }
    private func index(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }
    private func resumeURL(_ id: UUID) -> URL { root.appending(path: id.uuidString + ".resume") }
    @discardableResult private func save() -> Bool {
        guard readable else { return false }
        do { try protectedDownloadWrite(JSONEncoder().encode(jobs), to: manifest); return true }
        catch { error = "Could not save download progress: " + error.localizedDescription; return false }
    }
}
