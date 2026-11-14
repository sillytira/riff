import Foundation
import XCTest
@testable import Riff

final class CookieFileTests: XCTestCase {
    private func row(_ domain: String, _ name: String, _ value: String = "test-session", expiry: String = "4102444800") -> String {
        "\(domain)\tTRUE\t/\tTRUE\t\(expiry)\t\(name)\t\(value)"
    }
    func testOnlyYouTubeLoginCookiesEstablishASession() {
        XCTAssertTrue(CookieFile.hasYouTubeLogin(Data(row("#HttpOnly_.youtube.com", "LOGIN_INFO").utf8)))
        XCTAssertFalse(CookieFile.hasYouTubeLogin(Data(row(".google.com", "LOGIN_INFO").utf8)))
        XCTAssertFalse(CookieFile.hasYouTubeLogin(Data(row(".youtube.com.evil.example", "LOGIN_INFO").utf8)))
        XCTAssertFalse(CookieFile.hasYouTubeLogin(Data(row(".youtube.com", "PREF").utf8)))
    }
    func testExpiredAndNonFiniteExpiryAreRejected() {
        XCTAssertFalse(CookieFile.hasYouTubeLogin(Data(row(".youtube.com", "LOGIN_INFO", expiry: "1").utf8)))
        XCTAssertFalse(CookieFile.hasYouTubeLogin(Data(row(".youtube.com", "LOGIN_INFO", expiry: "inf").utf8)))
        XCTAssertTrue(CookieFile.hasYouTubeLogin(Data(row(".youtube.com", "LOGIN_INFO", expiry: "0").utf8)))
    }
    func testImportStripsOtherServicesAndPreservesHTTPOnly() throws {
        let contents = row("#HttpOnly_.youtube.com", "LOGIN_INFO") + "\n" + row(".other.example", "auth", "unrelated-private-session")
        let filtered = try CookieFile.filtered(Data(contents.utf8))
        let text = String(decoding: filtered, as: UTF8.self)
        XCTAssertTrue(text.contains("#HttpOnly_.youtube.com"))
        XCTAssertFalse(text.contains("unrelated-private-session"))
        XCTAssertThrowsError(try CookieFile.filtered(Data("not a cookie file".utf8)))
    }
}
