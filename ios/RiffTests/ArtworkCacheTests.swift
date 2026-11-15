import Foundation
import MediaPlayer
import ImageIO
import XCTest
@testable import Riff

private final class OfflineArtworkProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() { }
}

@MainActor
final class ArtworkCacheTests: XCTestCase {
    func testEmbeddedArtworkSurvivesCacheRecreationAndIsDecodable() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "cover", withExtension: "png"))
        let cache = ArtworkCache(root: root)
        let identifier = try await cache.storeEmbedded(Data(contentsOf: source), identity: "track")
        let restored = ArtworkCache(root: root)
        let data = try await restored.imageData(for: identifier, pixelSize: 100)
        let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any])
        XCTAssertLessThanOrEqual(properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0, 100)
    }

    func testLocalImportIndexesTagsAndPersistsEmbeddedCover() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "tagged", withExtension: "m4a"))
        let library = AudioLibrary(root: root)
        library.importFiles([source])
        for _ in 0..<100 {
            if library.tracks.first?.metadataIndexed == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let track = try XCTUnwrap(library.tracks.first)
        XCTAssertEqual(track.name, "Metadata Test Song")
        XCTAssertEqual(track.artist, "Riff Test Artist")
        XCTAssertEqual(track.album, "Metadata Test Album")
        let artwork = try XCTUnwrap(track.artworkURL)
        XCTAssertTrue(artwork.hasPrefix("riff-artwork://"))
        let data = try await ArtworkCache.shared.imageData(for: artwork, pixelSize: 100)
        XCTAssertNotNil(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(AudioLibrary(root: root).tracks.first?.artworkURL, artwork)
        library.play(track)
        defer { if library.isPlaying { library.togglePlayback() } }
        for _ in 0..<50 {
            if MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] is MPMediaItemArtwork { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] is MPMediaItemArtwork)
    }

    func testYouTubeFallbackRejectsUnrelatedHostsAndHandlesSupportedLinks() {
        XCTAssertEqual(ArtworkLocator.youtubeThumbnail(for: "https://youtu.be/abcdefghijk"), "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg")
        XCTAssertNotNil(ArtworkLocator.youtubeThumbnail(for: "https://www.youtube.com/shorts/abcdefghijk"))
        XCTAssertNil(ArtworkLocator.youtubeThumbnail(for: "https://youtube.com.evil.example/watch?v=abcdefghijk"))
        XCTAssertNil(ArtworkLocator.youtubeThumbnail(for: "file://youtube.com/watch?v=abcdefghijk"))
    }

    func testRemoteArtworkRemainsAvailableWithNetworkDisabled() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["RIFF_FIXTURE_SERVER"])
        let url = base + "/cover.png"
        let cache = ArtworkCache(root: root)
        let first = try await cache.imageData(for: url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineArtworkProtocol.self]
        let offline = ArtworkCache(root: root, session: URLSession(configuration: configuration))
        let restored = try await offline.imageData(for: url)
        XCTAssertEqual(first, restored)
    }
}
