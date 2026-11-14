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
