import XCTest

@MainActor
final class NavigationTests: XCTestCase {
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
        search.typeText("http://127.0.0.1:8765/ui-tone.wav\n")
        let result = app.staticTexts["ui-tone"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        result.tap()
        XCTAssertTrue(app.buttons["now-playing-open"].waitForExistence(timeout: 30))
        app.buttons["Download"].firstMatch.tap()
        app.tabBars.buttons["Downloads"].tap()
        XCTAssertTrue(app.staticTexts["Saved offline"].waitForExistence(timeout: 30))
        app.tabBars.buttons["Library"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "local-track-")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        saved.tap()
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
        XCTAssertTrue(app.buttons["Share exported audio"].waitForExistence(timeout: 30))
        attach(app, name: "Audio Editor")
        app.terminate()
        app.launch()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["ui-tone (edit)"].waitForExistence(timeout: 10))
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
