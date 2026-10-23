import XCTest

/// A search sheet with unapplied, unticked matches closed by the system (a
/// tap on the dimmed scrim, or a drag down): the system dismissal skips the
/// sheet's own Dismiss, and the editor still names what the close dropped.
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

    func testSystemCloseNamesTheClearedMatches() {
        let field = app.textFields["Search text"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "Search sheet never presented under --openSearchSheet.")
        field.tap()
        field.typeText("Sample")
        XCTAssertTrue(app.staticTexts["Page 1"].waitForExistence(timeout: 15), "no results for the fixture's text")

        // Close the sheet the system's way, never through its Dismiss: a tap
        // on the dimmed scrim above it, then a drag down off the screen.
        // Nothing is ticked, so the sheet may close either way.
        let dismissButton = app.buttons["searchDismissButton"].firstMatch
        let compactStrip = app.descendants(matching: .any)
            .matching(identifier: "compactFloatStrip").firstMatch
        let window = app.windows.firstMatch
        var sheetUp: Bool { dismissButton.exists || compactStrip.exists }
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).tap()
        sleep(1)
        for _ in 0..<4 where sheetUp {
            let top = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: compactStrip.exists ? 0.86 : 0.11))
            top.press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995)))
            sleep(1)
        }
        XCTAssertFalse(sheetUp, "neither the scrim nor a drag closed the untouched sheet")

        let notice = app.staticTexts.matching(
            NSPredicate(format: #"label BEGINSWITH "Search closed" AND label CONTAINS "unapplied match""#)
        ).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10),
                      "the system close dropped the unapplied matches without a notice")
    }
}
