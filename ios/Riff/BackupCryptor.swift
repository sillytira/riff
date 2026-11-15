import CryptoKit
import Foundation
import Security

enum BackupError: LocalizedError {
    case invalid, tooLarge, password, unlock, crypto
    var errorDescription: String? {
        switch self {
        case .invalid: "This is not a supported Riff backup file."
        case .tooLarge: "This backup exceeds the 16 MB data limit."
        case .password: "Use a backup password with at least eight characters."
        case .unlock: "The backup could not be unlocked. Check its password and that the file is complete."
        case .crypto: "A backup encryption key could not be created."
        }
    }
}

/// Version 1: RIFB, version byte, PBKDF2 rounds (BE32), salt (16), then the
/// CryptoKit AES-GCM combined representation (nonce, ciphertext, tag).
/// The entire 25-byte header is authenticated as associated data.
actor BackupCryptor {
    static let shared = BackupCryptor()
    static let maximumData = 16 * 1024 * 1024
    private let rounds: UInt32 = 300_000

    func encrypt(_ plaintext: Data, password: String) throws -> Data {
        guard plaintext.count <= Self.maximumData else { throw BackupError.tooLarge }
        guard password.count >= 8 else { throw BackupError.password }
        try Task.checkCancellation()
        let salt = try randomData(count: 16)
        var header = Data("RIFB".utf8)
        header.append(1)
        for shift in [24, 16, 8, 0] { header.append(UInt8(truncatingIfNeeded: rounds >> shift)) }
        header.append(salt)
        let key = try derive(password, salt: salt, rounds: rounds)
        guard let compressed = RiffArchiveTransform(plaintext, false) else { throw BackupError.tooLarge }
        let box = try AES.GCM.seal(compressed, using: key, authenticating: header)
        guard let combined = box.combined else { throw BackupError.crypto }
        try Task.checkCancellation()
        return header + combined
    }

    func decrypt(_ data: Data, password: String) throws -> Data {
        guard data.count <= Self.maximumData + 1024 * 1024 else { throw BackupError.tooLarge }
        guard data.count >= 53, data.prefix(4) == Data("RIFB".utf8), data[4] == 1 else { throw BackupError.invalid }
        let rounds = data[5..<9].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard (100_000...1_000_000).contains(rounds) else { throw BackupError.invalid }
        try Task.checkCancellation()
        let header = data.prefix(25)
        let key = try derive(password, salt: Data(data[9..<25]), rounds: rounds)
        let compressed: Data
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(25))
            compressed = try AES.GCM.open(box, using: key, authenticating: header)
        } catch { throw BackupError.unlock }
        guard let plaintext = RiffArchiveTransform(compressed, true) else { throw BackupError.invalid }
        try Task.checkCancellation()
        return plaintext
    }

    /// Original desktop .rfacc uses an application-wide key. Read it for
    /// migration; new iPhone backups always use the user's password and a salt.
    func decryptDesktopAccount(_ data: Data) throws -> Data {
        guard data.count <= Self.maximumData + 1024 * 1024 else { throw BackupError.tooLarge }
        guard data.count >= 32, data.prefix(4) == Data("RFAC".utf8) else { throw BackupError.invalid }
        try Task.checkCancellation()
        let key = SymmetricKey(data: SHA256.hash(data: Data("riff-account-key-v1".utf8)))
        let compressed: Data
        do {
            let nonce = try AES.GCM.Nonce(data: data[4..<16])
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: data.dropFirst(32), tag: data[16..<32])
            compressed = try AES.GCM.open(box, using: key)
        } catch { throw BackupError.unlock }
        guard let plaintext = RiffArchiveTransform(compressed, true) else { throw BackupError.invalid }
        return plaintext
    }

    private func derive(_ password: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        guard let key = RiffBackupKey(Data(password.utf8), salt, rounds) else { throw BackupError.crypto }
        return SymmetricKey(data: key)
    }
    private func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw BackupError.crypto }
        return data
    }
}
