import XCTest
@testable import Riff

@MainActor
final class DownloadRecoveryTests: XCTestCase {
    func testOSBackgroundSessionCompletesAndImportsAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = AudioLibrary(root: root.appending(path: "library"))
        let service = try BackgroundTransfers(root: root.appending(path: "downloads"), identifier: "io.github.rootscripts.riff.test." + UUID().uuidString)
        defer { service.invalidate() }
        let manager = DownloadManager(library: library, root: root.appending(path: "downloads"), transfers: service)
        await manager.reconnect()
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["RIFF_FIXTURE_SERVER"])
        let url = try XCTUnwrap(URL(string: base + "/ui-session.m4a"))
        let identity = TransferIdentity(job: UUID(), attempt: UUID())
        _ = service.startDirect(URLRequest(url: url), identity: identity)
        for _ in 0..<600 {
            if manager.jobs.first?.state == .saved || manager.jobs.first?.state == .failed { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(manager.jobs.first?.state, .saved, manager.jobs.first?.status ?? "Background session did not complete")
        XCTAssertEqual(library.tracks.count, 1)
        XCTAssertEqual(library.tracks.first?.downloadJobID, identity.job)
    }

    func testPausedJobRestoresAndCompletesWithoutDuplicateLibraryEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appending(path: "library"), downloads = root.appending(path: "downloads")
        let service = try BackgroundTransfers(root: downloads, identifier: UUID().uuidString, background: false)
        defer { service.invalidate() }
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["RIFF_FIXTURE_SERVER"])
        let track = OnlineTrack(id: "recovery", title: "Recovery song", artist: "Riff", webpageURL: base + "/slow/ui-session.m4a", artworkURL: nil, duration: 180, provider: "Generic")
        let firstLibrary = AudioLibrary(root: storage)
        var first: DownloadManager? = DownloadManager(library: firstLibrary, root: downloads, transfers: service)
        first?.download(track, into: firstLibrary)
        for _ in 0..<600 {
            if first?.jobs.first?.state == .downloading { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let id = try XCTUnwrap(first?.jobs.first?.id)
        XCTAssertEqual(first?.jobs.first?.state, .downloading)
        first?.pause(id)
        XCTAssertEqual(first?.jobs.first?.state, .paused)
        first = nil
        let library = AudioLibrary(root: storage)
        let restored = DownloadManager(library: library, root: downloads, transfers: service)
        await restored.reconnect()
        XCTAssertEqual(restored.jobs.first?.state, .paused)
        restored.resume(id)
        for _ in 0..<600 {
            if restored.jobs.first?.state == .saved || restored.jobs.first?.state == .failed { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(restored.jobs.first?.state, .saved, restored.jobs.first?.status ?? "No restored job")
        XCTAssertEqual(library.tracks.count, 1)
        XCTAssertEqual(library.tracks.first?.downloadJobID, id)
        let again = DownloadManager(library: library, root: downloads, transfers: service)
        await again.reconnect()
        XCTAssertEqual(library.tracks.count, 1)
        again.download(track, into: library)
        XCTAssertEqual(again.jobs.count, 1)
    }

    func testCompletedFileCheckpointReimportsExactlyOnceAfterRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appending(path: "library"), downloads = root.appending(path: "downloads")
        let service = try BackgroundTransfers(root: downloads, identifier: UUID().uuidString, background: false)
        defer { service.invalidate() }
        let input = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ui-tone", withExtension: "wav"))
        let online = OnlineTrack(id: "checkpoint", title: "Checkpoint song", artist: "Riff", webpageURL: "https://example.com/song", artworkURL: nil, duration: 2, provider: "Generic")
        let identity = TransferIdentity(job: UUID(), attempt: UUID())
        var job = DownloadJob(id: identity.job, track: online)
        job.attempt = identity.attempt; job.ext = "wav"; job.state = .downloading
        try protectedDownloadWrite(JSONEncoder().encode([job]), to: downloads.appending(path: "jobs.json"))
        let filename = identity.job.uuidString + "-" + identity.attempt.uuidString + ".download"
        try FileManager.default.copyItem(at: input, to: downloads.appending(path: "Staging/" + filename))
        // Emulate termination after the library commit but before job completion.
        let library = AudioLibrary(root: storage)
        let media = ResolvedMedia(track: online, streamURL: "", headers: [:], ext: "wav", protocol: "https")
        try library.importDownload(input, media: media, downloadJobID: identity.job)
        let originalID = library.tracks.first?.id
        let restoredLibrary = AudioLibrary(root: storage)
        let restored = DownloadManager(library: restoredLibrary, root: downloads, transfers: service)
        await restored.reconnect()
        for _ in 0..<100 {
            if restored.jobs.first?.state == .saved { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(restored.jobs.first?.state, .saved)
        XCTAssertEqual(restoredLibrary.tracks.count, 1)
        XCTAssertEqual(restoredLibrary.tracks.first?.id, originalID)
        XCTAssertTrue(service.receipts().isEmpty)
    }

    func testCorruptDownloadJournalIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appending(path: "downloads")
        let service = try BackgroundTransfers(root: downloads, identifier: UUID().uuidString, background: false)
        defer { service.invalidate() }
        let bytes = Data("corrupt download journal".utf8)
        let file = downloads.appending(path: "jobs.json")
        try bytes.write(to: file)
        let library = AudioLibrary(root: root.appending(path: "library"))
        let manager = DownloadManager(library: library, root: downloads, transfers: service)
        manager.clearCompleted()
        XCTAssertNotNil(manager.error)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
}
