import XCTest

/// The search sheet's Dismiss while a toast fires: the crash class of
/// PR #148 (a toast enqueue's synchronous graph flush during the dismiss
/// transaction tripping the strict-Observation assertion). The direct
/// route over unapplied matches enqueues "Search closed — N unapplied
/// matches cleared." as the sheet goes; the confirmed route over ticked
/// matches goes through the Discard dialog. Each test asserts the app is
/// still in the foreground afterward — a crash aborts the process, and
/// the bare "sheet gone" check alone would false-pass on one. The
/// structural half (the let-injected toast manager) is pinned by
/// `ToastManagerLetInjectionTests`.
// nonisolated: XCUITest driving a separate process, no @MainActor app state.
nonisolated final class SearchDismissToastUITests: XCTestCase {

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

    /// Untouched matches: Dismiss closes in one tap and the cleared-matches
    /// toast fires during the dismiss.
    func testDirectDismissWithUnappliedMatchesSurvivesTheToast() {
        let dismiss = searchForFixtureText()

        dismiss.tap()

        assertSurvivedDismiss(dismiss)
        let toast = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Search closed"))
            .firstMatch
        XCTAssertTrue(
            toast.waitForExistence(timeout: 5),
            "Dismiss over unapplied matches must name what it cleared."
        )
    }

    /// Ticked matches: Dismiss routes through the Discard dialog.
    func testConfirmedDismissWithTickedMatchesSurvives() {
        let dismiss = searchForFixtureText()
        let selectAll = app.buttons["footerSelectAllButton"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 10), "the footer's Select All never appeared")
        selectAll.tap()

        dismiss.tap()

        // The destructive button surfaces twice in the AX tree (a legacy
        // Button under a PopUpButton); `.firstMatch` disambiguates.
        let confirm = app.buttons["searchDismissConfirmButton"].firstMatch
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 5),
            "Dismiss with ticked matches must ask before discarding them."
        )
        confirm.tap()

        assertSurvivedDismiss(dismiss)
    }

    // MARK: - Helpers

    /// Type the fixture's own text ("Sample Document Page 1") and wait for
    /// its page-grouped results; returns the sheet's Dismiss button.
    private func searchForFixtureText() -> XCUIElement {
        let field = app.textFields["Search text"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "Search sheet never presented under --openSearchSheet.")
        field.tap()
        field.typeText("Sample")
        XCTAssertTrue(app.staticTexts["Page 1"].waitForExistence(timeout: 15), "no results for the fixture's text")
        let dismiss = app.buttons["searchDismissButton"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "the sheet shows no Dismiss button")
        return dismiss
    }

    private func assertSurvivedDismiss(_ dismiss: XCUIElement) {
        XCTAssertTrue(dismiss.waitForNonExistence(timeout: 5), "The search sheet did not dismiss.")
        XCTAssertEqual(
            app.state, .runningForeground,
            "App left the foreground after Dismiss — likely a crash in the dismiss path."
        )
        XCTAssertTrue(
            app.buttons["autoDetect"].waitForExistence(timeout: 5),
            "Editor toolbar did not return after dismissing the search sheet."
        )
    }
}
