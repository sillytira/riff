import AVFoundation
import XCTest
@testable import Riff

@MainActor
final class StreamingTests: XCTestCase {
    private func base() throws -> URL {
        try XCTUnwrap(URL(string: try XCTUnwrap(ProcessInfo.processInfo.environment["RIFF_FIXTURE_SERVER"])))
    }
    func testHTTPAndHLSDecodeToAudiblePCMAndHTTPSeekUsesSourceTime() async throws {
        let root = try base()
        for path in ["ui-tone.wav", "hls/index.m3u8"] {
            let handle = try StreamDecoderHandle()
            defer { handle.cancel() }
            let decoder = StreamDecoder(handle: handle)
            _ = try await decoder.open(url: root.appending(path: path), headers: [:], position: 0)
            let decoded = try await decoder.read()
            let chunk = try XCTUnwrap(decoded)
            XCTAssertEqual(chunk.count, 4096)
            XCTAssertGreaterThan(chunk.left.reduce(0) { $0 + Double($1 * $1) } / Double(chunk.count), 0.0001)
        }
        for path in ["ui-tone.wav", "tagged.ogg", "tagged.opus"] {
            let handle = try StreamDecoderHandle()
            defer { handle.cancel() }
            let decoder = StreamDecoder(handle: handle)
            _ = try await decoder.open(url: root.appending(path: path), headers: [:], position: 0.7)
            let decoded = try await decoder.read()
            let chunk = try XCTUnwrap(decoded)
            XCTAssertEqual(chunk.position, 0.7, accuracy: 0.03)
        }
    }

    func testTLSVerificationRejectsUntrustedRootAndHLSChild() async throws {
        let urls = [URL(string: "https://127.0.0.1:8766/ui-tone.wav")!, try base().appending(path: "hls/untrusted-child.m3u8")]
        for url in urls {
            let handle = try StreamDecoderHandle()
            defer { handle.cancel() }
            let decoder = StreamDecoder(handle: handle)
            do {
                _ = try await decoder.open(url: url, headers: [:], position: 0)
                _ = try await decoder.read()
                XCTFail("An untrusted certificate must not produce playable audio")
            } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }

    func testCredentialsAreNotForwardedToOtherOriginsByRedirectOrPlaylist() async throws {
        for path in ["redirect-cross-host", "hls/cross-origin.m3u8"] {
            let handle = try StreamDecoderHandle()
            defer { handle.cancel() }
            let decoder = StreamDecoder(handle: handle)
            _ = try await decoder.open(url: try base().appending(path: path), headers: ["Authorization": "Bearer fixture-only", "Cookie": "fixture=only"], position: 0)
            let decoded = try await decoder.read()
            XCTAssertNotNil(decoded)
        }
    }

    func testNetworkPlayerAdvancesPausesSeeksAndResumesWithEffects() async throws {
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        var settings = AudioEffectSettings()
        settings.rate = 1.5
        settings.pitch = 3
        settings.gains[3] = 4
        settings.reverb = 10
        let player = try NativeStreamingPlayer(duration: 180, settings: settings)
        defer { player.stop() }
        try await player.prepare(url: try base().appending(path: "ui-session.m4a"), headers: [:])
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertGreaterThan(player.elapsed, 0.2)
        player.pause()
        let held = player.elapsed
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(player.elapsed, held, accuracy: 0.02)
        player.seek(to: 20)
        XCTAssertEqual(player.elapsed, 20, accuracy: 0.03)
        try player.resume()
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertTrue(player.isPlaying)
        XCTAssertFalse(player.hasFailed)
        XCTAssertGreaterThan(player.elapsed, 20.2)
    }
}
