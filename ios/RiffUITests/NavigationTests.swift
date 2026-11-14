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

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
