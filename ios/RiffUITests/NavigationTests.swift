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

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
