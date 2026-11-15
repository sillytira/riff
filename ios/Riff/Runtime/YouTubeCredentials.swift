import Foundation
import Security

/// Keychain holds the durable session. Extractor requests get disposable sandbox files.
enum YouTubeCredentials {
    private static let lock = NSLock()
    private static let service = "io.github.rootscripts.riff.youtube"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session"]
    }
    static func read() throws -> Data? { try lock.withLock { try readUnlocked() } }
    static func save(_ data: Data) throws { try lock.withLock { try saveUnlocked(data) } }
    static func refresh(_ updated: Data, replacing original: Data) throws {
        try lock.withLock {
            guard try readUnlocked() == original else { return }
            try saveUnlocked(updated)
        }
    }
    private static func readUnlocked() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ExtractionError(message: "Saved YouTube sign-in could not be accessed. Try signing in again.") }
        return item as? Data
    }
    private static func saveUnlocked(_ data: Data) throws {
        guard CookieFile.hasYouTubeLogin(data) else { throw ExtractionError(message: "Finish signing in to YouTube before saving the session.") }
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ExtractionError(message: "YouTube sign-in could not be saved securely.") }
    }
    static func delete() throws {
        try lock.withLock {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw ExtractionError(message: "Saved YouTube sign-in could not be removed.") }
        }
    }
}

enum CookieFile {
    static func isYouTubeDomain(_ raw: String) -> Bool {
        let domain = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domain == "youtube.com" || domain.hasSuffix(".youtube.com")
    }
    static func isAccountDomain(_ raw: String) -> Bool {
        let domain = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return isYouTubeDomain(domain) || domain == "google.com" || domain.hasSuffix(".google.com")
    }
    static func filtered(_ data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else { throw ExtractionError(message: "Choose a UTF-8 Netscape cookies.txt file.") }
        let rows = text.components(separatedBy: .newlines).filter { line in
            let row = line.hasPrefix("#HttpOnly_") ? String(line.dropFirst(10)) : line
            guard !row.hasPrefix("#") else { return false }
            let fields = row.components(separatedBy: "\t")
            return fields.count == 7 && isAccountDomain(fields[0])
        }
        let result = Data((["# Netscape HTTP Cookie File"] + rows).joined(separator: "\n").appending("\n").utf8)
        guard hasYouTubeLogin(result) else { throw ExtractionError(message: "This file does not contain a current YouTube sign-in.") }
        return result
    }
    static func hasYouTubeLogin(_ data: Data, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        var names: Set<String> = []
        for line in text.components(separatedBy: .newlines) {
            let row = line.hasPrefix("#HttpOnly_") ? String(line.dropFirst(10)) : line
            guard !row.hasPrefix("#") else { continue }
            let fields = row.components(separatedBy: "\t")
            guard fields.count == 7, isYouTubeDomain(fields[0]), !fields[6].isEmpty,
                  let expiry = Double(fields[4]), expiry.isFinite, expiry <= 0 || expiry > now else { continue }
            names.insert(fields[5])
        }
        return names.contains("LOGIN_INFO") || (names.contains("SAPISID") && names.contains("SID"))
    }
    static func fromBrowser(_ cookies: [HTTPCookie]) throws -> Data {
        var rows = ["# Netscape HTTP Cookie File"]
        for cookie in cookies where isAccountDomain(cookie.domain) {
            let domain = (cookie.isHTTPOnly ? "#HttpOnly_" : "") + cookie.domain
            rows.append([domain, cookie.domain.hasPrefix(".") ? "TRUE" : "FALSE", cookie.path,
                         cookie.isSecure ? "TRUE" : "FALSE", String(Int(cookie.expiresDate?.timeIntervalSince1970 ?? 0)), cookie.name, cookie.value].joined(separator: "\t"))
        }
        return try filtered(Data(rows.joined(separator: "\n").appending("\n").utf8))
    }
}
