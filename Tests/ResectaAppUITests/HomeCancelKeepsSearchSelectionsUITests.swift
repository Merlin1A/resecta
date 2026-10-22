import XCTest

/// Home over a search sheet holding ticked matches, then Cancel on the
/// close dialog: the parked session comes back with its ticks. The apply
/// button's count is the oracle ("Apply N" before and after).
// nonisolated: XCUITest driving a separate process, no @MainActor app state.
nonisolated final class HomeCancelKeepsSearchSelectionsUITests: XCTestCase {

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

    private var compactStrip: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "compactFloatStrip").firstMatch
    }

    func testHomeThenCancelKeepsTheTickedMatches() {
        let field = app.textFields["Search text"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "Search sheet never presented under --openSearchSheet.")
        field.tap()
        field.typeText("Sample")
        XCTAssertTrue(app.staticTexts["Page 1"].waitForExistence(timeout: 15), "no results for the fixture's text")

        let selectAll = app.buttons["footerSelectAllButton"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 10), "the footer's Select All never appeared")
        selectAll.tap()
        let apply = app.buttons["searchApplyButton"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        let ticked = apply.label
        XCTAssertNotEqual(ticked, "Apply 0", "Select All ticked nothing")

        // Drop the sheet to the compact float so the editor's overflow is reachable.
        let window = app.windows.firstMatch
        let dismissKeyboard = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        _ = dismissKeyboard
        for _ in 0..<2 where !compactStrip.exists {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97))
            start.press(forDuration: 0.1, thenDragTo: end)
            sleep(2)
        }
        XCTAssertTrue(compactStrip.waitForExistence(timeout: 10), "the sheet did not drop to the compact float")

        openOverflowAndTapHome()
        let title = app.staticTexts["Close this document?"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Home with ticked matches must present the close dialog.")
        backOutOfCloseDialog(title: title)

        // The parked session comes back: at the compact float or in full chrome.
        let dismiss = app.buttons["searchDismissButton"].firstMatch
        let deadline = Date().addingTimeInterval(10)
        while !dismiss.exists && !compactStrip.exists && Date() < deadline { usleep(200_000) }
        XCTAssertTrue(dismiss.exists || compactStrip.exists, "the parked search did not come back after Cancel")
        if !dismiss.exists {
            for _ in 0..<2 where !dismiss.exists {
                let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
                let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
                start.press(forDuration: 0.1, thenDragTo: end)
                sleep(2)
            }
        }
        XCTAssertTrue(apply.waitForExistence(timeout: 10), "the restored sheet shows no Apply button")
        XCTAssertEqual(apply.label, ticked, "Cancel dropped the ticked matches")
    }

    private func openOverflowAndTapHome() {
        let overflow = app.buttons["OverflowBarButtonItem"]
        XCTAssertTrue(overflow.waitForExistence(timeout: 10), "Toolbar overflow button never appeared.")
        overflow.tap()
        let byLabel = app.buttons["Home"].firstMatch
        if byLabel.waitForExistence(timeout: 5) { byLabel.tap(); return }
        let byIdentifier = app.buttons["editorHomeButton"].firstMatch
        XCTAssertTrue(byIdentifier.waitForExistence(timeout: 5), "Home never appeared in the overflow menu.")
        byIdentifier.tap()
    }

    private func backOutOfCloseDialog(title: XCUIElement) {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 2) {
            cancel.tap()
        } else {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        }
        XCTAssertTrue(title.waitForNonExistence(timeout: 5), "Backing out must dismiss the close dialog.")
    }
}
