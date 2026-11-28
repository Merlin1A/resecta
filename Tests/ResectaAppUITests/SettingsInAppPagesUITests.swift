import XCTest

/// Settings opens its two in-app pages, each in a sheet from its own row:
/// What Boxes Can Show from the Redaction Boxes section, Acknowledgements
/// from the Privacy section. Both read from the app bundle.
// nonisolated: XCUITest driving a separate process, no @MainActor app state.
nonisolated final class SettingsInAppPagesUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--openSettings"]
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)["settingsView"].waitForExistence(timeout: 30),
            "Settings never presented under --openSettings."
        )
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    func testWhatBoxesCanShowOpensFromRedactionBoxes() {
        let row = scrolledTo("settingsWhatBoxesCanShow")
        XCTAssertEqual(row.label, "What Boxes Can Show")
        row.tap()
        assertPageOpen(title: "What Boxes Can Show", showing: "What a box can still show")
    }

    func testAcknowledgementsOpenFromPrivacy() {
        scrolledTo("settingsAcknowledgements").tap()
        assertPageOpen(title: "Acknowledgements", showing: nil)
    }

    /// The row, scrolled into view.
    private func scrolledTo(_ identifier: String) -> XCUIElement {
        let row = app.descendants(matching: .any)[identifier]
        var swipes = 0
        while !(row.exists && row.isHittable) && swipes < 10 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(identifier) is missing from Settings")
        return row
    }

    /// The page's sheet is up with its title (and, given one, a heading of
    /// the page), and Done closes it back to Settings.
    private func assertPageOpen(title: String, showing heading: String?) {
        XCTAssertTrue(app.descendants(matching: .any)["legalDocumentView"].waitForExistence(timeout: 10),
                      "the row opened no page")
        XCTAssertTrue(app.navigationBars[title].exists, "the page is not titled \(title)")
        if let heading {
            XCTAssertTrue(app.staticTexts[heading].exists, "the page does not show \(heading)")
        }
        app.buttons["legalDocumentDone"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["settingsView"].waitForExistence(timeout: 10),
                      "Done did not return to Settings")
    }
}
