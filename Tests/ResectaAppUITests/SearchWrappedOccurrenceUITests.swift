import XCTest

/// A search match that runs onto a second line is one result row. The
/// 23-page fixture prints, on every page, a line ending "…exercise
/// multipage" and the next beginning "rendering, …": the phrase
/// "multipage rendering" wraps once per page, so the search returns 46
/// line pieces for 23 matches. The sheet counts the matches — "23 found",
/// "0 of 23 selected" — and Select All then Apply marks 23.
///
/// nonisolated for the same reason as `ShareRiskSheetUITests`: an
/// XCUITest drives a separate process and touches no @MainActor app state.
nonisolated final class SearchWrappedOccurrenceUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    func testWrappedMatch_isOneRow_andCountsOnce() {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc", "--openSearchSheet",
                               "--searchQuery=multipage rendering", "--searchDetent=large"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["23 found"].waitForExistence(timeout: 60),
            "The toolbar never read 23 found — one per wrapped match, not one per line."
        )
        XCTAssertTrue(app.staticTexts["0 of 23 selected"].waitForExistence(timeout: 10), "Footer count")

        let selectAll = app.buttons["Select All"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 10), "Footer 'Select All' button not found.")
        selectAll.tap()
        XCTAssertTrue(app.staticTexts["23 of 23 selected"].waitForExistence(timeout: 10), "Select All counts matches")

        let apply = app.buttons["searchApplyButton"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5) && apply.isEnabled, "Apply stayed disabled.")
        apply.tap()
        let toast = app.staticTexts.matching(
            NSPredicate(format: #"label BEGINSWITH "Marked 23 for redaction""#)
        ).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 15), "The Marked notice did not count 23 matches.")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
