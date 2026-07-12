import XCTest

/// UI test for the Detection Triage "Dismiss" flow.
///
/// This exercises the triage → Dismiss path on the **Simulator**, which
/// on-device detection cannot reach there (the Auto-Detect page-0
/// Vision/Core-Graphics rasterize is not serviceable on the sim). The app's
/// DEBUG `--seedTriage` launch hook (`ResectaApp` → `RedactionState.seedDebugTriage()`)
/// presents the "Review Detections" sheet with mock detections, so the Dismiss
/// button is reachable without running detection.
///
/// Two paths converge on `DetectionTriageSheet.performDismiss()`:
///  - **Direct (Hypothesis B):** a fresh seed leaves `hasModifiedSelections == false`,
///    so tapping Dismiss calls `performDismiss()` with no confirmation dialog.
///  - **Dialog (Hypothesis A):** after toggling a row (which flips
///    `hasModifiedSelections`), Dismiss routes through the GATE-5
///    `confirmationDialog` before `performDismiss()`.
///
/// Each path is run twice — once over the (non-loading) single sample and once
/// with `--multipageDoc`, which loads a bundled 23-page document behind the
/// sheet. The multipage variants probe whether a real paginated document
/// changes the Dismiss behavior.
///
/// Root cause (fixed): `performDismiss()` enqueues a toast whose `@Observable`
/// mutation synchronously flushes a SwiftUI graph transaction *during* the
/// button-tap update cycle. `ToastView` read its queue manager via
/// `@Environment(ToastQueueManager.self)`; that re-entrant flush re-evaluated
/// the toast body and the observable-object environment lookup could not
/// resolve mid-transaction, tripping the strict-Observation "state during
/// update" assertion (`EXC_BREAKPOINT`).
///
/// Shipped fix (PR #148): inject the manager into `ToastView` as a plain `let`
/// constant from `ContentView`, sidestepping the environment read. Deferring
/// the toast out of the synchronous update cycle was tried FIRST and explicitly
/// REJECTED — it did not fix the crash. The structural invariant (ToastView
/// holds the manager as a `let`, never an `@Environment` read) is pinned by
/// `ToastManagerLetInjectionTests`; these UI tests are the crash-PATH guard.
///
/// Each test asserts the app is still in the foreground afterward; a crash in
/// `performDismiss()` aborts the process and fails that assertion (the bare
/// "sheet gone" check alone would false-pass on a crash, since a dead app also
/// has no Dismiss button).
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

    /// Hypothesis B — direct dismiss, no confirmation dialog, single sample.
    func testDismissUntouchedTriageSheet() {
        launchSeededTriage(multipage: false)
        performDirectDismiss()
    }

    /// Hypothesis B with a real 23-page document loaded behind the sheet.
    func testDismissUntouchedTriageSheet_multipageDocument() {
        launchSeededTriage(multipage: true)
        performDirectDismiss()
    }

    /// Hypothesis A — dismiss routed through the GATE-5 confirmation dialog.
    func testDismissAfterModifyingSelections() {
        launchSeededTriage(multipage: false)
        performDialogDismiss()
    }

    /// Hypothesis A with a real 23-page document loaded behind the sheet.
    func testDismissAfterModifyingSelections_multipageDocument() {
        launchSeededTriage(multipage: true)
        performDialogDismiss()
    }

    // MARK: - Launch

    /// Launch into the seeded "Review Detections" triage sheet.
    ///
    /// `--seedTriage` implies the test-document load; `multipage: true` adds
    /// `--multipageDoc`, which swaps the single-page sample for the bundled
    /// 23-page fixture so the Dismiss path runs with a real paginated document
    /// behind the sheet. The seeded triage stays page-0 in both cases, so the
    /// only variable between variants is the document's page count.
    private func launchSeededTriage(multipage: Bool) {
        var arguments = ["--uitesting", "--loadTestDocument", "--seedTriage"]
        if multipage {
            arguments.append("--multipageDoc")
        }
        app.launchArguments = arguments
        app.launch()
    }

    // MARK: - Dismiss paths

    /// Tap Dismiss on an untouched sheet (direct `performDismiss()`).
    private func performDirectDismiss() {
        let dismissButton = app.buttons["detectionTriageDismissButton"]
        XCTAssertTrue(
            dismissButton.waitForExistence(timeout: 30),
            "Seeded 'Review Detections' sheet never presented — check the --seedTriage launch hook."
        )

        dismissButton.tap()

        assertSurvivedDismiss(dismissButton)
    }

    /// Modify a selection, tap Dismiss, confirm the destructive dialog.
    private func performDialogDismiss() {
        let dismissButton = app.buttons["detectionTriageDismissButton"]
        XCTAssertTrue(
            dismissButton.waitForExistence(timeout: 30),
            "Seeded 'Review Detections' sheet never presented — check the --seedTriage launch hook."
        )

        // Flip `hasModifiedSelections` so the Dismiss tap routes through the
        // GATE-5 confirmation dialog. Toggling the first row's acceptance
        // checkmark sets the flag. The row uses
        // `.accessibilityElement(children: .combine)`, so the inner toggle
        // Button isn't a separately addressable AX element — tap its leading
        // checkmark region by coordinate (touch hit-testing is independent of
        // the accessibility merge). This is deterministic, unlike the
        // batch-actions SwiftUI Menu, which is flaky to open from XCUITest.
        let firstRow = app.cells.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5), "No triage rows present to modify.")
        firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()

        dismissButton.tap()

        // GATE-5 confirmation dialog — confirm the destructive Dismiss.
        // SwiftUI's confirmationDialog surfaces the destructive button twice in
        // the AX tree (a legacy computed Button nested under a modern
        // PopUpButton), so the bare identifier query is ambiguous — disambiguate
        // with .firstMatch.
        let confirm = app.buttons["detectionTriageDismissConfirm"].firstMatch
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 5),
            "Confirmation dialog did not appear after Dismiss with modified selections."
        )
        confirm.tap()

        assertSurvivedDismiss(dismissButton)
    }

    // MARK: - Assertion

    /// Shared post-dismiss assertion: the sheet closed AND the app process is
    /// still alive. A state-during-update trap inside `performDismiss()` aborts
    /// the process, which the `.runningForeground` check detects (the bare
    /// "sheet gone" check alone would false-pass on a crash, since a dead app
    /// also has no Dismiss button).
    private func assertSurvivedDismiss(_ dismissButton: XCUIElement) {
        XCTAssertTrue(
            dismissButton.waitForNonExistence(timeout: 5),
            "Triage sheet did not dismiss."
        )
        XCTAssertEqual(
            app.state, .runningForeground,
            "App left the foreground after Dismiss — likely a crash in performDismiss()."
        )
        // Editor chrome should be back and interactive.
        XCTAssertTrue(
            app.buttons["autoDetect"].waitForExistence(timeout: 5),
            "Editor toolbar did not return after dismissing the triage sheet."
        )
    }
}
