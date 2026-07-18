import XCTest

/// UI test for the unified review surface's Dismiss flow (conditional dismiss).
///
/// This exercises the review → Dismiss path on the **Simulator**, which
/// on-device detection cannot reach there (the page-0 Vision/Core-Graphics
/// rasterize is not serviceable on the sim). The app's DEBUG `--seedTriage`
/// launch hook (`ResectaApp` → `RedactionState.seedDebugTriage()`) stages
/// mock findings; the editor's presentation bridge opens the search sheet
/// pre-switched to the Scan interface with the review list, so Dismiss is
/// reachable without running detection.
///
/// Premise change (sanctioned): the standalone "Review Detections" triage
/// sheet this suite originally drove was absorbed into the search sheet's
/// Scan interface, and its confirm-if-selections-touched Dismiss rule
/// generalized to the whole sheet. The two converging paths carry over
/// with inverted arrival polarity (findings now arrive DESELECTED):
///  - **Direct:** a fresh seed leaves `userModifiedSelections == false`,
///    so tapping Dismiss closes in one tap with no dialog.
///  - **Dialog:** after selecting a row (which flips the tracker),
///    Dismiss routes through the confirmation dialog.
///
/// Each path runs twice — once over the (non-loading) single sample and
/// once with `--multipageDoc`, which loads a bundled 23-page document
/// behind the sheet, probing whether a real paginated document changes
/// the Dismiss behavior.
///
/// The crash class this suite guards (PR #148: a toast enqueue's
/// synchronous graph flush during the dismiss transaction tripping the
/// strict-Observation assertion) is unchanged by the absorption — the
/// dismiss path still enqueues through the let-injected ToastView
/// contract pinned by `ToastManagerLetInjectionTests`. Each test asserts
/// the app is still in the foreground afterward; a crash aborts the
/// process and fails that assertion (the bare "sheet gone" check alone
/// would false-pass on a crash).
// nonisolated: this is an XCUITest that drives the app through `XCUIApplication`
// (a separate process) and does NOT `@testable import` app internals, so it touches
// no @MainActor app state and was nonisolated pre-flip (ran 4/4 green). Under the
// s04 SE-0466 MainActor-default flip it would default to MainActor, whose
// setUp/tearDown/init overrides then mismatch XCTestCase's nonisolated ObjC lifecycle
// methods ("different actor isolation from nonisolated overridden declaration"). Pin
// it nonisolated to restore the pre-flip isolation. (The ResectaAppTests unit classes
// are @MainActor instead because they DO touch @MainActor app types via @testable.)
nonisolated final class DetectionTriageDismissUITests: XCTestCase {

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

    // MARK: - Tests

    /// Direct dismiss — untouched review, no confirmation dialog, single sample.
    func testDismissUntouchedReviewSheet() {
        launchSeededReview(multipage: false)
        performDirectDismiss()
    }

    /// Direct dismiss with a real 23-page document loaded behind the sheet.
    func testDismissUntouchedReviewSheet_multipageDocument() {
        launchSeededReview(multipage: true)
        performDirectDismiss()
    }

    /// Dialog dismiss — routed through the conditional confirmation dialog.
    func testDismissAfterModifyingSelections() {
        launchSeededReview(multipage: false)
        performDialogDismiss()
    }

    /// Dialog dismiss with a real 23-page document loaded behind the sheet.
    func testDismissAfterModifyingSelections_multipageDocument() {
        launchSeededReview(multipage: true)
        performDialogDismiss()
    }

    // MARK: - Launch

    /// Launch into the seeded review (search sheet, Scan interface).
    ///
    /// `--seedTriage` implies the test-document load; `multipage: true` adds
    /// `--multipageDoc`, which swaps the single-page sample for the bundled
    /// 23-page fixture. The seeded findings stay page-0 in both cases, so the
    /// only variable between variants is the document's page count.
    private func launchSeededReview(multipage: Bool) {
        var arguments = ["--uitesting", "--loadTestDocument", "--seedTriage"]
        if multipage {
            arguments.append("--multipageDoc")
        }
        app.launchArguments = arguments
        app.launch()
    }

    /// Wait for the seeded review to present: the sheet's Dismiss button
    /// plus the review list itself (the Scan interface's absorbed
    /// findings view).
    private func awaitSeededReview() -> XCUIElement {
        let dismissButton = app.buttons["searchDismissButton"]
        XCTAssertTrue(
            dismissButton.waitForExistence(timeout: 30),
            "Seeded review sheet never presented — check the --seedTriage launch hook + presentation bridge."
        )
        XCTAssertTrue(
            app.otherElements["scanReviewList"].waitForExistence(timeout: 10)
                || app.collectionViews["scanReviewList"].waitForExistence(timeout: 5),
            "Review list did not render inside the Scan interface."
        )
        return dismissButton
    }

    // MARK: - Dismiss paths

    /// Tap Dismiss on an untouched review (direct one-tap close).
    private func performDirectDismiss() {
        let dismissButton = awaitSeededReview()

        dismissButton.tap()

        assertSurvivedDismiss(dismissButton)
    }

    /// Select a review row, tap Dismiss, confirm the destructive dialog.
    private func performDialogDismiss() {
        let dismissButton = awaitSeededReview()

        // Flip the touched tracker so the Dismiss tap routes through the
        // conditional confirmation dialog. Selecting the first review row's
        // circle does it — the row uses
        // `.accessibilityElement(children: .ignore)`, so the inner
        // selection Button isn't a separately addressable AX element —
        // tap its leading circle region by coordinate (touch hit-testing
        // is independent of the accessibility merge). Findings arrive
        // DESELECTED (review-first arrival), so this tap SELECTS — same tracker flip,
        // inverted polarity vs the retired preselected triage sheet.
        let firstRow = app.cells.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5), "No review rows present to modify.")
        firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()

        dismissButton.tap()

        // conditional confirmation dialog — confirm the destructive Dismiss.
        // SwiftUI's confirmationDialog surfaces the destructive button twice in
        // the AX tree (a legacy computed Button nested under a modern
        // PopUpButton), so the bare identifier query is ambiguous — disambiguate
        // with .firstMatch.
        let confirm = app.buttons["searchDismissConfirmButton"].firstMatch
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 5),
            "Confirmation dialog did not appear after Dismiss with modified selections."
        )
        confirm.tap()

        assertSurvivedDismiss(dismissButton)
    }

    // MARK: - Assertion

    /// Shared post-dismiss assertion: the sheet closed AND the app process is
    /// still alive. A state-during-update trap inside the dismiss path aborts
    /// the process, which the `.runningForeground` check detects (the bare
    /// "sheet gone" check alone would false-pass on a crash, since a dead app
    /// also has no Dismiss button).
    private func assertSurvivedDismiss(_ dismissButton: XCUIElement) {
        XCTAssertTrue(
            dismissButton.waitForNonExistence(timeout: 5),
            "Review sheet did not dismiss."
        )
        XCTAssertEqual(
            app.state, .runningForeground,
            "App left the foreground after Dismiss — likely a crash in the dismiss path."
        )
        // Editor chrome should be back and interactive.
        XCTAssertTrue(
            app.buttons["autoDetect"].waitForExistence(timeout: 5),
            "Editor toolbar did not return after dismissing the review sheet."
        )
    }
}
