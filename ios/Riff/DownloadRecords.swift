import Foundation

enum DownloadState: String, Codable, Sendable {
    case queued, resolving, downloading, paused, importing, saved, cancelled, failed
}
struct DownloadJob: Codable, Identifiable, Sendable {
    let id: UUID
    var track: OnlineTrack
    var state: DownloadState = .queued
    var attempt: UUID?
    var ext: String? = nil
    var isHLS = false
    var received: Int64 = 0
    var expected: Int64 = 0
    var hlsProgress: Double? = nil
    var hasResumeData = false
    var message: String? = nil
    var isActive: Bool { [.queued, .resolving, .downloading, .importing].contains(state) }
    var progress: Double? {
        if let hlsProgress { return max(0, min(1, hlsProgress)) }
        return expected > 0 ? max(0, min(1, Double(received) / Double(expected))) : nil
    }
    var status: String {
        switch state {
        case .queued: "Queued"
        case .resolving: "Resolving audio…"
        case .downloading: isHLS ? "Saving HLS audio offline…" : "Downloading…"
        case .paused: "Paused"
        case .importing: "Saving to library…"
        case .saved: "Saved offline"
        case .cancelled: "Cancelled"
        case .failed: message ?? "Download failed"
        }
    }
}

struct TransferIdentity: Sendable {
    let job: UUID
    let attempt: UUID
    var text: String { job.uuidString + "/" + attempt.uuidString }
    init(job: UUID, attempt: UUID) { self.job = job; self.attempt = attempt }
    init?(_ text: String?) {
        guard let text else { return nil }
        let values = text.split(separator: "/")
        guard let first = values.first, let job = UUID(uuidString: String(first)) else { return nil }
        self.job = job
        if values.count == 1 { attempt = job }
        else if values.count == 2, let attempt = UUID(uuidString: String(values[1])) { self.attempt = attempt }
        else { return nil }
    }
}

struct DownloadReceipt: Codable, Sendable {
    let job: UUID
    let attempt: UUID
    let isHLS: Bool
    let location: String
}

func downloadSourceKey(_ source: String) -> String {
    if let thumbnail = ArtworkLocator.youtubeThumbnail(for: source) { return thumbnail }
    return source
}

func protectedDownloadWrite(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
}
