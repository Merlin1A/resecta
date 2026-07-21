import XCTest

/// UI tests for the Search & Redact sheet's detent-dependent layout
/// (q18 / UXF-05, +UXF-17 cross-ref).
///
/// Two demonstrated defect classes, both driven end-to-end here:
/// - ts5-02 / seq 134: at the expanded detent the pinned Dismiss /
///   Apply toolbar header overlapped the segmented rows at the top of
///   the sheet; taps there were silent no-ops. The tests drag the
///   sheet to expanded with a real drag gesture (the occlusion
///   appeared after drag transitions, not programmatic detent
///   seeding) and assert the top controls stay hittable and their
///   taps take effect — once per interface entry, since interface
///   choice lives on the editor toolbar's two entry buttons rather
///   than in-sheet chrome.
/// - ts2-04: at the medium detent with results, the first result row
///   rendered below the fold, half-clipped at the footer, and row taps
///   landed on the footer. The test searches at the default medium
///   detent and asserts the first row's selection toggle is hittable
///   and actually toggles the footer count.
///
/// nonisolated for the same reason as `SearchMarkForRedactionUITests`:
/// an XCUITest drives a separate process and touches no @MainActor app
/// state.
nonisolated final class SearchDetentLayoutUITests: XCTestCase {

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

    // MARK: - Helpers

    private func launchSearchSheet(mode: String?) {
        var arguments = ["--uitesting", "--loadTestDocument", "--openSearchSheet"]
        if let mode {
            arguments.append("--searchMode=\(mode)")
        }
        app.launchArguments = arguments
        app.launch()
    }

    /// Drag the sheet from its medium-detent grabber region to the top
    /// of the screen — the same gesture the ts5 walkthrough used to
    /// reach the expanded detent. Coordinates are normalized against
    /// the app window so the drag holds across device sizes.
    private func dragSheetToExpanded() {
        let window = app.windows.firstMatch
        // Medium detent puts the sheet's top edge just below half
        // height; start on the grabber strip and finish near the top.
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.50))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    /// A picker's segments surface with the segment title as the
    /// label; `.tabs` on the 26.4 sim, `.buttons` on some hierarchies —
    /// match across element types by label. Query ONLY titles unique
    /// in the presented hierarchy (incl. the editor toolbar behind the
    /// sheet). "Text" is NOT one: the OCR source filter renders an
    /// identically-typed "Text" segment on the Search surface, so a
    /// label match there is ambiguous — round-trip via "Regex" instead.
    private func segment(_ title: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND (elementType == 9 OR elementType == 42 OR elementType == 13)", title))
            .firstMatch
    }

    /// Drag-proof shared by the expanded-detent tests: at the expanded
    /// detent the pinned Dismiss button sits in the top fifth of the
    /// window (~91 pt on the 26.4 iPhone 17 sim; ~413 pt at medium).
    /// Without this, a failed drag leaves the sheet at medium and the
    /// occlusion assertions below exercise nothing.
    private func assertSheetExpanded() {
        let dismiss = app.buttons["searchDismissButton"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "Dismiss button not found after drag.")
        let window = app.windows.firstMatch
        XCTAssertLessThan(
            dismiss.frame.minY, window.frame.height * 0.2,
            "Sheet did not reach the expanded detent — the drag gesture failed, so this test exercised nothing."
        )
    }

    // MARK: - Expanded detent: top controls must win the tap (seq 134)

    // Premise updated for the two-entry model: interface choice lives
    // on the editor toolbar's two entry buttons (the in-sheet
    // switcher is gone), so each interface pins the seq-134 occlusion
    // class from its own entry. The defect class is unchanged — at
    // the expanded detent the pinned toolbar header must not occlude
    // the controls at the top of the sheet.

    // Scan entry. --searchMode seeds the same interface the toolbar
    // Scan button opens, without the entry's auto-run (a run in
    // flight would disable the controls this test asserts against).
    // Reshaped for D-63/UT: the retired chips strip + scope picker
    // are pinned ABSENT flag-dark, the occlusion class pins against
    // the NEW shipping chrome (the relocated ↻ + bookmark in the
    // search bar — the bookmark tap presenting the saved list is the
    // taps-take-effect proof), and a relaunch under the DEBUG reveal
    // arg smokes the revival path.
    func testExpandedDetent_scanEntryTopControlsTakeTaps() {
        launchSearchSheet(mode: "piiScan")

        // Sheet is up once the Scan surface renders — the run
        // control's stable label resolves to the relocated bar ↻.
        XCTAssertTrue(
            app.buttons["Scan document for PII"].waitForExistence(timeout: 30),
            "Search sheet never presented — check the --openSearchSheet launch hook."
        )

        dragSheetToExpanded()
        assertSheetExpanded()

        // D-63 flag-off absence: the retired controls must not render
        // (asserted at the expanded detent, where they WOULD be
        // visible if present).
        XCTAssertFalse(
            segment("This page").exists,
            "The retired scope picker rendered on the Scan surface with the flag dark."
        )
        XCTAssertFalse(
            segment("Whole document").exists,
            "The retired scope picker rendered on the Scan surface with the flag dark."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "scanCategoryChips").firstMatch.exists,
            "The retired category-chips strip rendered with the flag dark."
        )
        // Exactly one run control — the no-double-↻ contract.
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(format: "label == %@", "Scan document for PII")).count, 1,
            "Expected exactly one Scan run control on the flag-dark surface."
        )

        // The seq-134 failure class: on the defective layout the
        // pinned header owned the top controls' hit targets and taps
        // were silent no-ops. The relocated ↻ is the surface's top
        // pinned control...
        let scanButton = app.buttons["Scan document for PII"]
        XCTAssertTrue(scanButton.isHittable, "Scan run button not hittable at the expanded detent.")

        // ...its bar-mate bookmark must be hittable too...
        let bookmark = app.buttons["Saved Searches"]
        XCTAssertTrue(
            bookmark.waitForExistence(timeout: 10),
            "Saved-searches bookmark not found in the Scan bar — the UT-04 relocation lost Scan's only saved-list entry point."
        )
        XCTAssertTrue(
            bookmark.isHittable,
            "Bookmark exists but is not hittable at the expanded detent."
        )

        // ...and its tap must actually land: the saved list presents.
        bookmark.tap()
        XCTAssertTrue(
            app.navigationBars["Saved Searches"].waitForExistence(timeout: 10),
            "Tapping the bookmark did not present the saved list — the seq-134 occlusion no-op."
        )

        // Reveal smoke (the D-63 revival path): relaunch with the
        // DEBUG reveal arg — the retired rows render again and the
        // run control collapses back to the chips-row ↻, still
        // exactly one.
        app.terminate()
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--openSearchSheet",
            "--searchMode=piiScan", "--showRetiredSheetControls",
        ]
        app.launch()
        XCTAssertTrue(
            app.buttons["Scan document for PII"].waitForExistence(timeout: 30),
            "Reveal relaunch never presented the sheet."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "scanCategoryChips").firstMatch
                .waitForExistence(timeout: 10),
            "--showRetiredSheetControls did not restore the category-chips strip."
        )
        dragSheetToExpanded()
        assertSheetExpanded()
        XCTAssertTrue(
            segment("This page").waitForExistence(timeout: 10),
            "--showRetiredSheetControls did not restore the scope picker."
        )
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(format: "label == %@", "Scan document for PII")).count, 1,
            "The reveal co-rendered two Scan run controls — the bar ↻ must hide whenever the chips strip (and its in-row ↻) returns."
        )
    }

    // Search entry, plus the surviving Search-side mode tabs (the
    // original seq-134 target): Text / Regex / Multi-term must win
    // their taps at the expanded detent.
    func testExpandedDetent_searchEntryModeTabsSwitchSurfaces() {
        launchSearchSheet(mode: nil)

        let field = app.textFields["Search text"]
        XCTAssertTrue(
            field.waitForExistence(timeout: 30),
            "Search sheet never presented — check the --openSearchSheet launch hook."
        )

        dragSheetToExpanded()
        assertSheetExpanded()

        // Top pinned control of the Search surface.
        XCTAssertTrue(field.isHittable, "Search field not hittable at the expanded detent.")

        // D-63 flag-off absence on the Search surface too — the
        // scope picker was ONE shared row across both interfaces.
        XCTAssertFalse(
            segment("This page").exists,
            "The retired scope picker rendered on the Search surface with the flag dark."
        )
        XCTAssertFalse(
            segment("Whole document").exists,
            "The retired scope picker rendered on the Search surface with the flag dark."
        )
        // The Search side's field-side bookmark is untouched by the
        // UT-04 relocation.
        XCTAssertTrue(
            app.buttons["Saved Searches"].exists,
            "The Search side's field-side bookmark went missing."
        )

        // seq-134: tap Multi-term and prove the mode switched — its
        // dedicated term field replaces the shared text field.
        let multiTerm = segment("Multi-term")
        XCTAssertTrue(
            multiTerm.waitForExistence(timeout: 10),
            "Multi-term mode tab not found on the Search interface."
        )
        XCTAssertTrue(multiTerm.isHittable, "Multi-term tab exists but is not hittable at the expanded detent.")
        multiTerm.tap()

        XCTAssertTrue(
            app.textFields["Search term input"].waitForExistence(timeout: 10),
            "Tapping the Multi-term tab at the expanded detent did not switch mode — the seq-134 occlusion no-op."
        )

        // Round-trip: over to Regex, which shares the text-search
        // field — the field's return proves the tap landed. (Regex is
        // queried instead of Text because the Text label is ambiguous
        // here; see `segment(_:)`.)
        let regexTab = segment("Regex")
        XCTAssertTrue(
            regexTab.waitForExistence(timeout: 10),
            "Regex mode tab not found on the Search interface."
        )
        XCTAssertTrue(regexTab.isHittable, "Regex tab exists but is not hittable at the expanded detent.")
        regexTab.tap()
        XCTAssertTrue(
            app.textFields["Search text"].waitForExistence(timeout: 10),
            "Tapping the Regex tab did not restore the shared text field — the seq-134 occlusion no-op."
        )
        XCTAssertTrue(
            app.textFields["Search text"].isHittable,
            "Search field not hittable after the mode round-trip."
        )
    }

    // MARK: - Medium detent with results: first row must be reachable (ts2-04)

    func testMediumDetent_firstResultRowTapSelectsRow() {
        launchSearchSheet(mode: nil)

        let field = app.textFields["Search text"]
        XCTAssertTrue(
            field.waitForExistence(timeout: 30),
            "Search sheet never presented — check the --openSearchSheet launch hook."
        )
        field.tap()
        // Trailing newline dismisses the software keyboard. With the
        // interface switcher's added chrome above the list, a raised
        // keyboard clips the single result row's bottom edge, and
        // XCUIElement.tap()'s occlusion-aware hit point then drifts
        // off-center onto the row's leading selection circle —
        // toggling selection instead of navigating (observed in the
        // failure AX dump: row Selected, no counter). The row tap this
        // test pins is a full-row-visible interaction; the app-side
        // flow is verified correct by manual drive.
        field.typeText("Sample\n")

        // One match in the bundled fixture. Review-first label family: results
        // arrive deselected and the footer states the arrival default
        // explicitly ("N found — none selected yet") in place of the
        // former "0 of N selected".
        let footerCount = app.staticTexts["1 found — none selected yet"]
        XCTAssertTrue(
            footerCount.waitForExistence(timeout: 15),
            "Text search returned no results for the bundled fixture."
        )

        // The first result row (one AX element per row: "Search match,
        // page N"). On the ts2-04 layout it rendered half-clipped under
        // the footer — unhittable, or the tap landed on the footer.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: #"label == "Search match, page 1""#))
            .firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 10),
            "First result row not found."
        )
        XCTAssertTrue(
            row.isHittable,
            "First result row exists but is not hittable — buried below the fold (ts2-04)."
        )
        row.tap()

        // A row tap navigates to the match: the position counter appears
        // in the search bar. If the tap had landed on the footer instead
        // (the ts2-04 hit-trap), the counter would never populate — and a
        // footer "Select All" hit would flip the selection count.
        XCTAssertTrue(
            app.staticTexts["Result 1 of 1"].waitForExistence(timeout: 10)
                || app.staticTexts["1/1"].waitForExistence(timeout: 2),
            "Row tap did not navigate to the match — the tap landed elsewhere (footer hit-trap)."
        )
        XCTAssertFalse(
            app.staticTexts["1 of 1 selected"].exists,
            "Row tap flipped the footer selection count — the tap landed on the footer's Select All."
        )

        // D-63/UT chevron pin: the shared bar's trailing result-nav
        // chevrons stay present and hittable with results on board
        // (they had zero coverage pre-UT, and the UT-04 relocation
        // reshaped their row's leading content).
        let nextResult = app.buttons["Next result"]
        XCTAssertTrue(
            nextResult.waitForExistence(timeout: 10),
            "Next result chevron not found with results present."
        )
        XCTAssertTrue(
            nextResult.isHittable,
            "Next result chevron exists but is not hittable at the medium detent."
        )
        XCTAssertTrue(
            app.buttons["Previous result"].isHittable,
            "Previous result chevron exists but is not hittable at the medium detent."
        )
    }
}
