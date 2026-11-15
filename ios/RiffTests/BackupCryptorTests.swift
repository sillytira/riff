import XCTest
@testable import Riff

@MainActor
final class BackupCryptorTests: XCTestCase {
    func testPasswordBackupsRoundTripUnicodeAndUseIndependentRandomness() async throws {
        let input = Data(String(repeating: "Riff song 🎧\n", count: 8000).utf8)
        let password = "backup password 🎵"
        let first = try await BackupCryptor.shared.encrypt(input, password: password)
        let second = try await BackupCryptor.shared.encrypt(input, password: password)
        XCTAssertNotEqual(first, second)
        XCTAssertLessThan(first.count, input.count)
        let restored = try await BackupCryptor.shared.decrypt(first, password: password)
        XCTAssertEqual(restored, input)
    }
    func testWrongPasswordAndAuthenticatedHeaderOrCiphertextChangesAreRejected() async throws {
        let archive = try await BackupCryptor.shared.encrypt(Data("Private library data".utf8), password: "correct password")
        for index in [9, archive.count - 1] {
            var changed = archive
            changed[index] ^= 1
            do { _ = try await BackupCryptor.shared.decrypt(changed, password: "correct password"); XCTFail("Changed backup data must not decrypt") }
            catch { }
        }
        do { _ = try await BackupCryptor.shared.decrypt(archive, password: "wrong password"); XCTFail("An incorrect password must not decrypt") }
        catch { }
    }
    func testDesktopAccountCompatibilityUsesOriginalNodeCryptoAndRawDeflateFormat() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "desktop-account", withExtension: "rfacc"))
        let restored = try await BackupCryptor.shared.decryptDesktopAccount(Data(contentsOf: url))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: restored) as? [String: Any])
        XCTAssertEqual(object["app"] as? String, "Riff")
        let storage = try XCTUnwrap(object["localStorage"] as? [String: String])
        let playlists = try XCTUnwrap(storage["devsize_playlists"])
        let imported = try PortablePlaylists.read(Data(playlists.utf8))
        XCTAssertEqual(imported.first?.name, "Desktop playlist")
        XCTAssertEqual(imported.first?.entries.count, 1)
    }
    func testPBKDF2MatchesPublishedSHA256VectorAndOversizedDecompressionIsRejected() async throws {
        let key = try XCTUnwrap(RiffBackupKey(Data("password".utf8), Data("salt".utf8), 1))
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "oversized-account", withExtension: "rfacc"))
        do { _ = try await BackupCryptor.shared.decryptDesktopAccount(Data(contentsOf: url)); XCTFail("Decompressed data must stay within the limit") }
        catch { }
    }
}
