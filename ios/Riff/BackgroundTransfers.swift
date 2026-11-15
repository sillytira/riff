import AVFoundation
import UIKit

@MainActor
final class BackgroundSessionEvents {
    static let shared = BackgroundSessionEvents()
    private var handlers: [String: [() -> Void]] = [:]
    private var drained: Set<String> = []
    func started(_ identifier: String) { drained.remove(identifier) }
    func register(_ identifier: String, completion: @escaping () -> Void) {
        if drained.remove(identifier) != nil { completion() }
        else { handlers[identifier, default: []].append(completion) }
    }
    func finish(_ identifier: String) {
        let pending = handlers.removeValue(forKey: identifier) ?? []
        if pending.isEmpty { drained.insert(identifier) }
        pending.forEach { $0() }
    }
}

final class BackgroundTransfers: NSObject, URLSessionDownloadDelegate, AVAssetDownloadDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case progress(TransferIdentity, Int64, Int64, Double?)
        case finished(DownloadReceipt)
        case failed(TransferIdentity, String, Bool)
        case drained(String)
    }
    @MainActor private static var instance: BackgroundTransfers?
    @MainActor static func shared() throws -> BackgroundTransfers {
        if let instance { return instance }
        let root = URL.applicationSupportDirectory.appending(path: "Riff/Downloads")
        let service = try BackgroundTransfers(root: root, identifier: (Bundle.main.bundleIdentifier ?? "Riff") + ".downloads", legacyHLSIdentifier: "io.github.rootscripts.riff.hls")
        instance = service
        return service
    }
    let root: URL
    private let handlerLock = NSLock()
    private var handler: (@Sendable (Event) -> Void)?
    private(set) var direct: URLSession!
    private(set) var hls: AVAssetDownloadURLSession?

    init(root: URL, identifier: String, legacyHLSIdentifier: String? = nil, background: Bool = true) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root.appending(path: "Staging"), withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try FileManager.default.createDirectory(at: root.appending(path: "Receipts"), withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var excluded = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let config = background ? URLSessionConfiguration.background(withIdentifier: identifier) : .default
        config.waitsForConnectivity = true
        config.isDiscretionary = false
        config.timeoutIntervalForResource = 7 * 86400
        direct = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        if background {
            let config = URLSessionConfiguration.background(withIdentifier: legacyHLSIdentifier ?? identifier + ".hls")
            config.waitsForConnectivity = true
            config.isDiscretionary = false
            hls = AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: self, delegateQueue: queue)
        }
    }
    func bind(_ action: @escaping @Sendable (Event) -> Void) {
        handlerLock.lock(); handler = action; handlerLock.unlock()
    }
    private func emit(_ event: Event) {
        handlerLock.lock(); let action = handler; handlerLock.unlock()
        action?(event)
    }
    func invalidate() { direct.invalidateAndCancel(); hls?.invalidateAndCancel() }
    func allTasks() async -> [URLSessionTask] {
        let tasks = await direct.allTasks
        if let hls { return tasks + (await hls.allTasks) }
        return tasks
    }
    func startDirect(_ request: URLRequest, identity: TransferIdentity) -> URLSessionDownloadTask {
        let task = direct.downloadTask(with: request)
        start(task, identity: identity)
        return task
    }
    func resumeDirect(_ data: Data, identity: TransferIdentity) -> URLSessionDownloadTask {
        let task = direct.downloadTask(withResumeData: data)
        start(task, identity: identity)
        return task
    }
    private func start(_ task: URLSessionTask, identity: TransferIdentity) {
        task.taskDescription = identity.text
        if let identifier = direct.configuration.identifier {
            Task { @MainActor in BackgroundSessionEvents.shared.started(identifier) }
        }
        task.resume()
    }
    func startHLS(_ asset: AVURLAsset, title: String, identity: TransferIdentity) throws -> AVAssetDownloadTask {
        guard let hls else { throw ExtractionError(message: "HLS downloads are unavailable in this session.") }
        let configuration = AVAssetDownloadConfiguration(asset: asset, title: title)
        let task = hls.makeAssetDownloadTask(downloadConfiguration: configuration)
        task.taskDescription = identity.text
        if let identifier = hls.configuration.identifier { Task { @MainActor in BackgroundSessionEvents.shared.started(identifier) } }
        task.resume()
        return task
    }
    func receiptURL(_ identity: TransferIdentity) -> URL {
        root.appending(path: "Receipts/" + identity.job.uuidString + "-" + identity.attempt.uuidString + ".json")
    }
    func receipts() -> [DownloadReceipt] {
        let files = (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "Receipts"), includingPropertiesForKeys: nil)) ?? []
        var results = files.compactMap { try? JSONDecoder().decode(DownloadReceipt.self, from: Data(contentsOf: $0)) }
        let staged = (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "Staging"), includingPropertiesForKeys: nil)) ?? []
        for file in staged where file.pathExtension == "download" {
            let name = file.deletingPathExtension().lastPathComponent
            guard name.count == 73, let job = UUID(uuidString: String(name.prefix(36))),
                  let attempt = UUID(uuidString: String(name.suffix(36))), !results.contains(where: { $0.job == job && $0.attempt == attempt }) else { continue }
            results.append(DownloadReceipt(job: job, attempt: attempt, isHLS: false, location: file.lastPathComponent))
        }
        return results
    }
    func location(_ receipt: DownloadReceipt) throws -> URL {
        if receipt.isHLS {
            let home = URL(filePath: NSHomeDirectory()).resolvingSymlinksInPath()
            let url = home.appending(path: receipt.location).standardizedFileURL.resolvingSymlinksInPath()
            guard !receipt.location.hasPrefix("/"), !receipt.location.split(separator: "/").contains(".."), url.path.hasPrefix(home.path + "/"), url.pathExtension == "movpkg" else { throw URLError(.badURL) }
            return url
        }
        let filename = receipt.job.uuidString + "-" + receipt.attempt.uuidString + ".download"
        guard receipt.location == filename else { throw URLError(.badURL) }
        return root.appending(path: "Staging/" + filename)
    }
    func forget(_ receipt: DownloadReceipt, removeAsset: Bool) {
        if removeAsset, let url = try? location(receipt) { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: receiptURL(TransferIdentity(job: receipt.job, attempt: receipt.attempt)))
    }
    private func checkpoint(_ identity: TransferIdentity, location: URL, hls: Bool) throws {
        let stored: String
        if hls {
            let home = URL(filePath: NSHomeDirectory()).resolvingSymlinksInPath().path + "/"
            let canonical = location.resolvingSymlinksInPath()
            guard canonical.path.hasPrefix(home), canonical.pathExtension == "movpkg" else { throw URLError(.badURL) }
            stored = String(canonical.path.dropFirst(home.count))
        } else {
            stored = identity.job.uuidString + "-" + identity.attempt.uuidString + ".download"
            let destination = root.appending(path: "Staging/" + stored)
            if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.moveItem(at: location, to: destination) }
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        }
        let receipt = DownloadReceipt(job: identity.job, attempt: identity.attempt, isHLS: hls, location: stored)
        try protectedDownloadWrite(JSONEncoder().encode(receipt), to: receiptURL(identity))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let identity = TransferIdentity(downloadTask.taskDescription) else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw ExtractionError(message: "The provider refused the audio download. Retry to obtain a fresh link.") }
            try checkpoint(identity, location: location, hls: false)
        } catch { emit(.failed(identity, error.localizedDescription, false)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let identity = TransferIdentity(downloadTask.taskDescription) else { return }
        emit(.progress(identity, totalBytesWritten, totalBytesExpectedToWrite, nil))
    }
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let identity = TransferIdentity(assetDownloadTask.taskDescription) else { return }
        do { try checkpoint(identity, location: location, hls: true) }
        catch { emit(.failed(identity, error.localizedDescription, false)) }
    }
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        guard let identity = TransferIdentity(assetDownloadTask.taskDescription) else { return }
        let total = timeRangeExpectedToLoad.duration.seconds
        let loaded = totalTimeRangesLoaded.reduce(0.0) { $0 + max(0, $1.timeRangeValue.duration.seconds) }
        emit(.progress(identity, 0, 0, total.isFinite && total > 0 && loaded.isFinite ? min(1, loaded / total) : nil))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let identity = TransferIdentity(task.taskDescription) else { return }
        if let error { emit(.failed(identity, error.localizedDescription, (error as? URLError)?.code == .cancelled)); return }
        do {
            let receipt = try JSONDecoder().decode(DownloadReceipt.self, from: Data(contentsOf: receiptURL(identity)))
            emit(.finished(receipt))
        } catch { emit(.failed(identity, "The download completed without a recoverable audio file.", false)) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        if let id = session.configuration.identifier { emit(.drained(id)) }
    }
}
