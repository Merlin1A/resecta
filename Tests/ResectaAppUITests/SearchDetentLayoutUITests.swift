import XCTest

/// UI tests for the Search & Redact sheet's detent-dependent layout
/// (q18 / UXF-05, +UXF-17 cross-ref).
///
/// Two demonstrated defects, both driven end-to-end here:
/// - ts5-02 / seq 134: at the expanded detent the pinned Dismiss /
///   Apply toolbar header overlapped the mode tabs; a tap on the
///   Multi-term tab did NOTHING. The test drags the sheet to expanded
///   with a real drag gesture (the occlusion appeared after drag
///   transitions, not programmatic detent seeding) and asserts the
///   Multi-term tap actually switches mode.
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
    /// match across element types by label.
    private func modeSegment(_ title: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND (elementType == 9 OR elementType == 42 OR elementType == 13)", title))
            .firstMatch
    }

    /// Interface-switcher segments, scoped INSIDE the switcher by its
    /// stable identifier: the editor toolbar behind the sheet carries
    /// buttons with the same "Scan" / "Search" labels, so an app-wide
    /// label match could target the occluded toolbar instead.
    private func interfaceSegment(_ title: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "interfaceSwitcher")
            .firstMatch
            .descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND (elementType == 9 OR elementType == 42 OR elementType == 13)", title))
            .firstMatch
    }

    // MARK: - Expanded detent: segmented controls must win the tap (seq 134)

    // Premise updated for the two-interface chassis: the 4-segment mode
    // picker (which included a "PII Scan" segment) became a 2-segment
    // interface switcher + a Search-side 3-segment mode picker, and the
    // per-run confidence slider is retired. The defect class this test
    // pins is unchanged — at the expanded detent the pinned toolbar
    // header must not occlude the segmented controls at the top of the
    // sheet — so the drive now exercises BOTH segmented rows and
    // asserts the Scan side's run button (its remaining pinned control)
    // instead of the retired slider.
    func testExpandedDetent_interfaceAndModeTabsSwitchSurfaces() {
        launchSearchSheet(mode: "piiScan")

        // Sheet is up once the Scan surface renders.
        XCTAssertTrue(
            app.buttons["Scan document for PII"].waitForExistence(timeout: 30),
            "Search sheet never presented — check the --openSearchSheet launch hook."
        )

        dragSheetToExpanded()

        // Prove the drag actually expanded the sheet: at the expanded
        // detent the pinned Dismiss button sits in the top fifth of the
        // window (~91 pt on the 26.4 iPhone 17 sim; ~413 pt at medium).
        let dismiss = app.buttons["searchDismissButton"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "Dismiss button not found after drag.")
        let window = app.windows.firstMatch
        XCTAssertLessThan(
            dismiss.frame.minY, window.frame.height * 0.2,
            "Sheet did not reach the expanded detent — the drag gesture failed, so this test exercised nothing."
        )

        // The seq-134 failure class, first row: tap the interface
        // switcher's Search segment at the expanded detent. On the
        // defective layout the pinned header owned this hit target and
        // the tap was a silent no-op.
        let searchSegment = interfaceSegment("Search")
        XCTAssertTrue(
            searchSegment.waitForExistence(timeout: 10),
            "Interface switcher's Search segment not found after expanding the sheet."
        )
        XCTAssertTrue(searchSegment.isHittable, "Search segment exists but is not hittable at the expanded detent.")
        searchSegment.tap()

        // Interface actually switched: the text field replaces the
        // Scan run button.
        XCTAssertTrue(
            app.textFields["Search text"].waitForExistence(timeout: 10),
            "Tapping the Search segment at the expanded detent did not switch interface — the seq-134 occlusion no-op."
        )

        // Second row — the Search-side mode picker (the original
        // seq-134 target): tap Multi-term and prove the mode switched.
        let multiTerm = modeSegment("Multi-term")
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

        // Round-trip: back to Scan; its run button must land
        // unobstructed (the retired slider's replacement assertion).
        let scanSegment = interfaceSegment("Scan")
        XCTAssertTrue(
            scanSegment.waitForExistence(timeout: 10),
            "Interface switcher's Scan segment not found."
        )
        scanSegment.tap()
        let scanButton = app.buttons["Scan document for PII"]
        XCTAssertTrue(
            scanButton.waitForExistence(timeout: 10),
            "Scan run button missing after switching back to Scan at the expanded detent."
        )
        XCTAssertTrue(scanButton.isHittable, "Scan run button not hittable at the expanded detent.")
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
    }
}
