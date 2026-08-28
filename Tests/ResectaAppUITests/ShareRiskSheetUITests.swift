import XCTest

/// UI test for the share-risk confirm sheet's completion path.
///
/// `SlideToShareControl` (DocumentEditorView.swift) is the
/// slide-to-confirm control on the share-risk sheet. Its VoiceOver /
/// XCUITest completion path is a hidden-but-accessible `Button`
/// overlaid on the visible track, carrying the family's stable
/// accessibility identifier (`shareAnywayConfirm` / `shareSkippedConfirm`
/// / `shareIncompleteWarnConfirm`). Measured on the frozen 1.1.0 build: a
/// 1×1-pt hidden target answered a coordinate `.tap()` on a freshly
/// presented sheet but not on a RE-presented one. The fix widened the
/// target to `ResectaTokens.TouchTarget.minimum`, moved into dead space
/// below the footer's "Go back" row.
///
/// This test drives the SKIPPED family end to end, twice, on the real
/// device tree (no `@testable import` — this is a black-box XCUITest):
/// once on a freshly presented sheet, once on the sheet re-presented
/// after backing out of the system share sheet without completing the
/// share (the exact re-arm path the former 1×1 target failed on).
///
/// Route to SKIPPED: flip "Verify Before Export" off in Settings so a
/// redact-without-verify run lands on `.skipped`, which routes Share
/// through `shareSkippedConfirm` (`shareNeedsSkippedConfirm`, pinned by
/// `SkippedShareGateTests`). The toggle is restored to ON in `tearDown`
/// so the simulator is left as found regardless of where the test stops.
///
/// nonisolated for the same reason as `DetectionTriageDismissUITests`:
/// an XCUITest drives a separate process and touches no @MainActor app
/// state; under the SE-0466 MainActor-default flip the lifecycle
/// overrides would otherwise mismatch XCTestCase's nonisolated ObjC
/// lifecycle methods.
nonisolated final class ShareRiskSheetUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        // Leave the simulator as found no matter where the test stopped —
        // this is idempotent (setVerifyBeforeExport only taps the toggle
        // when its current value doesn't already match the target).
        setVerifyBeforeExport(on: true)
        app = nil
        super.tearDown()
    }

    // MARK: - Test

    func testShareSkippedConfirm_hiddenButtonWorksOnFreshAndRepresentedSheet() {
        setVerifyBeforeExport(on: false)

        app.terminate()
        app.launchArguments = ["--uitesting", "--seedTriage"]
        app.launch()

        awaitSeededReviewAndApplyAll()
        runRedactFromOverflowMenu()

        XCTAssertTrue(
            app.staticTexts["Verification Skipped"].waitForExistence(timeout: 30),
            "Verification results screen never reached Verification Skipped."
        )

        let shareCard = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Share Document'"))
            .firstMatch
        XCTAssertTrue(shareCard.waitForExistence(timeout: 10), "Share card not found.")
        shareCard.tap()

        assertShareRiskSheetPresented()
        attachScreenshot(named: "share-risk-sheet-presented")
        logMeasuredGeometry()

        // First activation, on the freshly presented sheet.
        app.buttons["shareSkippedConfirm"].tap()
        attachScreenshot(named: "after-first-hidden-button-tap")
        assertSystemShareSheetPresented()

        dismissSystemShareSheetWithSwipeDown()

        XCTAssertTrue(
            app.staticTexts["Verification Skipped"].waitForExistence(timeout: 10),
            "Did not return to Verification Skipped after backing out of the share sheet."
        )
        XCTAssertFalse(
            app.staticTexts["Shared."].exists,
            "\"Shared.\" must not appear after backing out without completing the share."
        )

        // Re-arm: Share again presents the confirm sheet fresh.
        shareCard.tap()
        assertShareRiskSheetPresented()

        // Second activation, on the RE-PRESENTED sheet — the case the
        // former 1×1 hidden target failed on.
        app.buttons["shareSkippedConfirm"].tap()
        assertSystemShareSheetPresented()

        let copyCell = app.cells["Copy"]
        let copyTarget = copyCell.waitForExistence(timeout: 10) ? copyCell : app.buttons["Copy"]
        XCTAssertTrue(
            copyTarget.waitForExistence(timeout: 10),
            "Copy action never appeared in the system share sheet."
        )
        copyTarget.tap()

        XCTAssertTrue(
            app.staticTexts["Shared."].waitForExistence(timeout: 5),
            "\"Shared.\" acknowledgment never appeared after completing the share."
        )
        attachScreenshot(named: "after-shared-toast")
    }

    // MARK: - Settings: Verify Before Export

    /// Idempotent: only taps the toggle when its current value doesn't
    /// already match `on`, so this is safe to call unconditionally from
    /// `tearDown` regardless of where the test stopped.
    private func setVerifyBeforeExport(on: Bool) {
        app.terminate()
        app.launchArguments = ["--uitesting", "--openSettings", "--settingsScrollToWorkflow"]
        app.launch()

        let toggle = verifyBeforeExportInnerSwitch()
        XCTAssertTrue(
            toggle.waitForExistence(timeout: 15),
            "Verify Before Export toggle never appeared in Settings."
        )
        // `--settingsScrollToWorkflow` scrolls to this section on a 600ms
        // delay (SettingsView.swift), so the row is still animating into
        // its resting position right after `waitForExistence` succeeds —
        // existence in the accessibility tree isn't the same as being
        // settled for a tap. Give the scroll a moment to land before
        // interacting (mirrors `SearchDetentLayoutUITests`'s settle wait
        // after a comparable position change).
        sleep(1)

        let desired = on ? "1" : "0"
        if (toggle.value as? String) != desired {
            toggle.tap()
        }
        XCTAssertEqual(
            verifyBeforeExportInnerSwitch().value as? String, desired,
            "Verify Before Export toggle did not land on \(desired)."
        )
    }

    /// The outer `Toggle`'s merged accessibility element reports as a
    /// switch whose label starts with "Verify Before Export" (the label
    /// also carries the toggle's two footnote lines); tapping THAT
    /// element is unreliable — the inner switch resolved one level down
    /// is the element that actually answers `.tap()`.
    private func verifyBeforeExportInnerSwitch() -> XCUIElement {
        app.switches
            .matching(NSPredicate(format: "label BEGINSWITH 'Verify Before Export'"))
            .firstMatch
            .switches
            .firstMatch
    }

    // MARK: - Seeded review → Redact

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
    }

    /// The editor's trailing toolbar overflows on this device/width after
    /// the seeded-review round trip — Redact resolves through the
    /// system overflow menu rather than directly on the bar.
    private func runRedactFromOverflowMenu() {
        let overflow = app.buttons["OverflowBarButtonItem"]
        XCTAssertTrue(
            overflow.waitForExistence(timeout: 10),
            "Toolbar overflow button never appeared."
        )
        overflow.tap()

        let redact = app.buttons["Redact"]
        XCTAssertTrue(
            redact.waitForExistence(timeout: 10),
            "Redact menu item never appeared in the overflow menu."
        )
        redact.tap()
    }

    // MARK: - Share-risk sheet

    private func assertShareRiskSheetPresented() {
        XCTAssertTrue(
            app.staticTexts["Share with reported issues?"].waitForExistence(timeout: 10),
            "Share-risk confirm sheet title never appeared."
        )
        XCTAssertTrue(
            app.buttons["shareSkippedConfirm"].waitForExistence(timeout: 10),
            "shareSkippedConfirm hidden completion Button never appeared."
        )
    }

    private func assertSystemShareSheetPresented() {
        let activityList = app.otherElements["ActivityListView"]
        let copyCell = app.cells["Copy"]
        XCTAssertTrue(
            activityList.waitForExistence(timeout: 10) || copyCell.waitForExistence(timeout: 10),
            "System share sheet never presented."
        )
    }

    private func dismissSystemShareSheetWithSwipeDown() {
        // No Close button on this sheet — drag it down and off, matching
        // `SearchDetentLayoutUITests`'s coordinate-drag idiom.
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    // MARK: - Placement measurement (logged once, not asserted)

    /// Prints the hidden Button's frame, the "Go back" row's frame, and
    /// the window frame — the geometry is measured rather than
    /// hardcoded, since the sheet's own render scale is device/OS
    /// dependent.
    private func logMeasuredGeometry() {
        let confirmFrame = app.buttons["shareSkippedConfirm"].frame
        let goBackFrame = app.buttons["shareRiskConfirmGoBack"].frame
        let windowFrame = app.windows.firstMatch.frame
        print("[measured geometry] shareSkippedConfirm.frame = \(confirmFrame)")
        print("[measured geometry] shareRiskConfirmGoBack.frame = \(goBackFrame)")
        print("[measured geometry] window.frame = \(windowFrame)")
    }

    // MARK: - Screenshots

    private func attachScreenshot(named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
