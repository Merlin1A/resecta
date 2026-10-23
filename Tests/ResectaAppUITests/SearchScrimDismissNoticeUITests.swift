import XCTest

/// A search sheet with unapplied, unticked matches closed by a tap on the
/// dimmed scrim above it: the system dismissal skips the sheet's own
/// Dismiss, and the editor still names what the close dropped.
// nonisolated: XCUITest driving a separate process, no @MainActor app state.
nonisolated final class SearchScrimDismissNoticeUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--openSearchSheet"]
        app.launch()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    func testScrimTapNamesTheClearedMatches() {
        let field = app.textFields["Search text"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "Search sheet never presented under --openSearchSheet.")
        field.tap()
        field.typeText("Sample")
        XCTAssertTrue(app.staticTexts["Page 1"].waitForExistence(timeout: 15), "no results for the fixture's text")

        // Close the keyboard with the return key, then tap the scrim above
        // the sheet. Nothing is ticked, so the sheet may close this way.
        field.typeText("\n")
        let dismissButton = app.buttons["searchDismissButton"].firstMatch
        let window = app.windows.firstMatch
        for dy in [0.06, 0.12, 0.2] where dismissButton.exists {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy)).tap()
            _ = dismissButton.waitForNonExistence(timeout: 3)
        }
        XCTAssertFalse(dismissButton.exists, "a scrim tap did not close the untouched sheet")

        let notice = app.staticTexts.matching(
            NSPredicate(format: #"label BEGINSWITH "Search closed" AND label CONTAINS "unapplied match""#)
        ).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10),
                      "the scrim close dropped the unapplied matches without a notice")
    }
}
