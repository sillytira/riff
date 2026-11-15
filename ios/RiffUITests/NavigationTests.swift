import XCTest

@MainActor
final class NavigationTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testArtworkFromDownloadedMetadataIsVisibleInLibraryAndPlayer() {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Discover"].tap()
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("http://127.0.0.1:8765/tagged.m4a\n")
        XCTAssertTrue(app.staticTexts["tagged"].firstMatch.waitForExistence(timeout: 30))
        app.buttons["Download"].firstMatch.tap()
        app.tabBars.buttons["Downloads"].tap()
        XCTAssertTrue(app.staticTexts["Saved offline"].waitForExistence(timeout: 30))
        app.tabBars.buttons["Library"].tap()
        let track = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "local-track-", "Metadata Test Song")).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 15))
        attach(app, name: "Library with embedded cover")
        track.tap()
        app.buttons["now-playing-open"].tap()
        XCTAssertTrue(app.navigationBars["Now Playing"].waitForExistence(timeout: 10))
        attach(app, name: "Now Playing with embedded cover")
        app.buttons["Add to Favorites"].tap()
        app.buttons["Close"].tap()
        app.buttons["Favorites"].tap()
        XCTAssertTrue(app.navigationBars["Favorites"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Metadata Test Song"].firstMatch.exists)
        app.terminate()
        app.launch()
        app.buttons["Favorites"].tap()
        XCTAssertTrue(app.staticTexts["Metadata Test Song"].firstMatch.waitForExistence(timeout: 5))
    }

    func testLibraryDiscoverAndDownloadsAreReachable() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Riff"].waitForExistence(timeout: 15))
        attach(app, name: "Library")
        app.tabBars.buttons["Discover"].tap()
        XCTAssertTrue(app.navigationBars["Discover"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls.buttons["YouTube"].exists)
        XCTAssertTrue(app.segmentedControls.buttons["SoundCloud"].exists)
        attach(app, name: "Discover")
        app.tabBars.buttons["Downloads"].tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 5))
        attach(app, name: "Downloads")
    }

    func testPlaylistCreationRenameAndRelaunchPersistence() {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Playlists"].tap()
        app.buttons["Add playlist"].tap()
        app.buttons["New playlist"].tap()
        let title = "Road trip " + String(UUID().uuidString.prefix(6))
        let alert = app.alerts["New playlist"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText(title)
        alert.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        app.staticTexts[title].tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
        app.buttons["Playlist actions"].tap()
        app.buttons["Rename"].tap()
        let rename = app.alerts["Rename playlist"]
        let field = rename.textFields.firstMatch
        field.tap()
        let renamed = title + " favorites"
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: title.count) + renamed)
        rename.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars[renamed].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        app.tabBars.buttons["Playlists"].tap()
        XCTAssertTrue(app.staticTexts[renamed].waitForExistence(timeout: 5))
    }

    func testSettingsAccountControlsAreReachable() {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Library"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Sign in to YouTube"].exists)
        XCTAssertTrue(app.buttons["Import browser cookies"].exists)
        attach(app, name: "Settings")
    }

    func testStreamingDownloadAndEditingThroughTheInterface() {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Discover"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("http://127.0.0.1:8765/ui-session.m4a\n")
        let result = app.staticTexts["ui-session"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        result.tap()
        XCTAssertTrue(app.buttons["now-playing-open"].waitForExistence(timeout: 30))
        app.buttons["Download"].firstMatch.tap()
        app.tabBars.buttons["Downloads"].tap()
        let downloadRow = app.cells.containing(.staticText, identifier: "ui-session").firstMatch
        XCTAssertTrue(downloadRow.staticTexts["Saved offline"].waitForExistence(timeout: 30))
        app.tabBars.buttons["Library"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "local-track-", "ui-session")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        saved.tap()
        app.buttons["Pause"].tap()
        app.buttons["now-playing-open"].tap()
        XCTAssertTrue(app.navigationBars["Now Playing"].waitForExistence(timeout: 10))
        attach(app, name: "Now Playing")
        for _ in 0..<3 {
            if app.buttons["Audio Editor"].isHittable { break }
            app.swipeUp()
        }
        app.buttons["Audio Editor"].tap()
        XCTAssertTrue(app.navigationBars["Audio Editor"].waitForExistence(timeout: 10))
        app.buttons["Save selection as WAV"].tap()
        let shared = app.buttons["Share exported audio"]
        let wavReady = shared.waitForExistence(timeout: 30)
        if !wavReady { attach(app, name: "WAV export unavailable") }
        XCTAssertTrue(wavReady)
        let format = app.buttons["export-format"]
        for _ in 0..<3 {
            if format.isHittable { break }
            app.swipeUp()
        }
        format.tap()
        app.buttons["MP3"].tap()
        app.buttons["Save selection as MP3"].tap()
        let mp3Ready = shared.waitForExistence(timeout: 30)
        if !mp3Ready { attach(app, name: "MP3 export unavailable") }
        XCTAssertTrue(mp3Ready)
        attach(app, name: "Audio Editor")
        app.terminate()
        app.launch()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "local-track-", "ui-session (edit)")).firstMatch.waitForExistence(timeout: 10))
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
