import XCTest

/// 1.1.0 Home swap (UXC-41) — the iPhone editor's overflow ("…") menu offers Home
/// in place of the former file-import entry: Home closes the open
/// document through the verification-screen Done teardown and the
/// editor's `.empty` auto-return brings HomeView back. The shared
/// "Close this document?" dialog gates sessions that carry work
/// (drawn/applied regions or a staged Scan review); an idle session
/// closes in one tap.
///
/// Two legs, driven end to end on the real device tree (black-box
/// XCUITest, no `@testable import`):
///  - T1 idle: `--loadTestDocument` → overflow → Home → HomeView, no
///    dialog, editor chrome gone.
///  - T2 with work: `--seedTriage` → Select All → Apply (regions exist)
///    → overflow → Home → dialog → back out (Cancel row, or a tap
///    outside the iOS 26 popover) keeps the editor → overflow → Home →
///    Close → HomeView.
///
/// Home is resolved by LABEL first (identifiers do not reliably
/// propagate into the system overflow menu — `ShareRiskSheetUITests`
/// taps Redact by label for the same reason), the `editorHomeButton`
/// identifier second; which one resolved is recorded as an activity.
///
/// nonisolated for the same reason as the sibling suites: an XCUITest
/// drives a separate process and touches no @MainActor app state.
nonisolated final class EditorHomeUITests: XCTestCase {

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

    /// T1 — idle session: Home closes directly and HomeView returns.
    func testHomeOnIdleSessionReturnsHomeWithoutDialog() {
        app.launchArguments = ["--uitesting", "--loadTestDocument"]
        app.launch()
        awaitEditor()

        openOverflowAndTapHome()

        assertHomeViewPresent()
        XCTAssertFalse(
            app.staticTexts["Close this document?"].exists,
            "An idle session must close without the confirm dialog."
        )
        XCTAssertTrue(
            app.buttons["OverflowBarButtonItem"].waitForNonExistence(timeout: 5),
            "The editor's overflow chrome must be gone once HomeView is back."
        )
    }

    /// T2 — session with applied regions: Home routes through the shared
    /// close dialog; backing out keeps the editor, Close returns home.
    func testHomeWithRegionsConfirmsThroughSharedCloseDialog() {
        app.launchArguments = ["--uitesting", "--seedTriage"]
        app.launch()
        awaitSeededReviewAndApplyAll()

        openOverflowAndTapHome()
        let title = app.staticTexts["Close this document?"]
        XCTAssertTrue(
            title.waitForExistence(timeout: 10),
            "Home on a session with regions must present the shared close dialog."
        )

        backOutOfCloseDialog(title: title)
        XCTAssertTrue(
            app.buttons["OverflowBarButtonItem"].waitForExistence(timeout: 10),
            "Backing out must leave the editor in place."
        )

        openOverflowAndTapHome()
        XCTAssertTrue(
            title.waitForExistence(timeout: 10),
            "The close dialog must present again on the second Home tap."
        )
        tapDialogClose()

        assertHomeViewPresent()
    }

    // MARK: - Helpers

    private func awaitEditor() {
        XCTAssertTrue(
            app.buttons["OverflowBarButtonItem"].waitForExistence(timeout: 30),
            "Editor toolbar overflow never appeared — check the --loadTestDocument launch hook."
        )
    }

    /// Open the "…" menu and tap Home — label first, identifier second.
    private func openOverflowAndTapHome() {
        let overflow = app.buttons["OverflowBarButtonItem"]
        XCTAssertTrue(
            overflow.waitForExistence(timeout: 10),
            "Toolbar overflow button never appeared."
        )
        overflow.tap()

        let byLabel = app.buttons["Home"].firstMatch
        if byLabel.waitForExistence(timeout: 5) {
            XCTContext.runActivity(named: "Home resolved by label") { _ in
                byLabel.tap()
            }
            return
        }
        let byIdentifier = app.buttons["editorHomeButton"].firstMatch
        XCTAssertTrue(
            byIdentifier.waitForExistence(timeout: 5),
            "Home never appeared in the overflow menu (neither the label nor editorHomeButton resolved)."
        )
        XCTContext.runActivity(named: "Home resolved by identifier editorHomeButton") { _ in
            byIdentifier.tap()
        }
    }

    /// Back out of the close dialog without closing. On iOS 26 the
    /// `.confirmationDialog` presents as a popover anchored to the
    /// overflow button with NO Cancel row (dismissal is a tap outside the
    /// sheet — observed on the iPhone 17 / iOS 26.4 sim); other
    /// presentations render an explicit Cancel. Try the row first, then
    /// tap the canvas well below the sheet.
    private func backOutOfCloseDialog(title: XCUIElement) {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 2) {
            XCTContext.runActivity(named: "Back out via the Cancel row") { _ in
                cancel.tap()
            }
        } else {
            // Resolved outside the activity closure: the closure is
            // main-actor-isolated and must not capture this nonisolated
            // test case (Swift 6 strict concurrency).
            let outside = app.windows.firstMatch
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            XCTContext.runActivity(named: "Back out via a tap outside the popover") { _ in
                outside.tap()
            }
        }
        XCTAssertTrue(
            title.waitForNonExistence(timeout: 5),
            "Backing out must dismiss the close dialog."
        )
    }

    /// Confirm the destructive Close — identifier first (SwiftUI's
    /// confirmationDialog surfaces the destructive button twice in the AX
    /// tree, so `.firstMatch` disambiguates — see
    /// `DetectionTriageDismissUITests`), label second.
    private func tapDialogClose() {
        let byIdentifier = app.buttons["verificationActionBarDoneConfirm"].firstMatch
        if byIdentifier.waitForExistence(timeout: 5) {
            XCTContext.runActivity(named: "Close resolved by identifier verificationActionBarDoneConfirm") { _ in
                byIdentifier.tap()
            }
            return
        }
        let byLabel = app.buttons["Close"].firstMatch
        XCTAssertTrue(
            byLabel.waitForExistence(timeout: 5),
            "Close never appeared on the dialog (neither the identifier nor the label resolved)."
        )
        XCTContext.runActivity(named: "Close resolved by label") { _ in
            byLabel.tap()
        }
    }

    /// HomeView is back when its primary choice card is on screen. The
    /// card is a `Button` whose merged accessibility label starts with
    /// its title ("Open a Document" — `HomeChoiceCard`).
    private func assertHomeViewPresent() {
        let openCard = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Open a Document'"))
            .firstMatch
        XCTAssertTrue(
            openCard.waitForExistence(timeout: 10),
            "HomeView never returned after Home."
        )
    }

    /// Seeded review → Select All → Apply → dismiss, leaving applied
    /// regions on the document (pattern from `ShareRiskSheetUITests`).
    private func awaitSeededReviewAndApplyAll() {
        let dismissButton = app.buttons["searchDismissButton"]
        XCTAssertTrue(
            dismissButton.waitForExistence(timeout: 30),
            "Seeded review sheet never presented — check the --seedTriage launch hook."
        )

        let selectAll = app.buttons["footerSelectAllButton"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 10), "Select All button not found.")
        selectAll.tap()

        let apply = app.buttons["searchApplyButton"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10), "Apply button not found.")
        apply.tap()

        XCTAssertTrue(
            dismissButton.waitForExistence(timeout: 10),
            "Dismiss button not found after Apply."
        )
        dismissButton.tap()
        XCTAssertTrue(
            dismissButton.waitForNonExistence(timeout: 10),
            "Review sheet did not dismiss after Apply."
        )
    }
}
