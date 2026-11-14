import XCTest
@testable import Riff

@MainActor
final class MediaExtractorTests: XCTestCase {
    func testEmbeddedInterpreterTLSAndJavaScriptCoreAreAvailable() async throws {
        let health = try await MediaExtractor.shared.health()
        XCTAssertTrue(health.python.hasPrefix("3.13"))
        XCTAssertEqual(health.extractor, "2026.10.26")
        XCTAssertTrue(health.tls.contains("OpenSSL"))
        XCTAssertTrue(health.javascript)
        let data = Data(try XCTUnwrap(health.javascriptResult).utf8)
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Int]
        XCTAssertEqual(result?["answer"], 42)
    }

    func testHTTPAudioResolutionDownloadAndOfflinePersistence() async throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["RIFF_FIXTURE_SERVER"])
        let media = try await MediaExtractor.shared.resolve(base + "/silence.wav")
        XCTAssertEqual(media.ext, "wav")
        let url = try XCTUnwrap(URL(string: media.streamURL))
        let (file, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = AudioLibrary(root: root)
        try library.importDownload(file, media: media)
        XCTAssertEqual(library.tracks.count, 1)
        let restored = AudioLibrary(root: root)
        XCTAssertEqual(restored.tracks.first?.webpageURL, media.track.webpageURL)
        XCTAssertEqual(restored.tracks.first?.id, library.tracks.first?.id)
    }

    func testEmptySearchReturnsWithoutNetwork() async throws {
        let tracks = try await MediaExtractor.shared.search("  ", provider: "youtube")
        XCTAssertTrue(tracks.isEmpty)
    }

    func testLocalFileAndNonHTTPURLsAreRejected() async throws {
        do {
            _ = try await MediaExtractor.shared.resolve("file:///etc/passwd")
            XCTFail("A file URL must not be passed into the network extractor")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP"))
        }
    }
}
