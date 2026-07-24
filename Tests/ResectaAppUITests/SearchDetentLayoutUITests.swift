import XCTest

/// UI tests for the Search & Redact sheet's detent-dependent layout
/// (q18 / UXF-05, +UXF-17 cross-ref).
///
/// Three demonstrated defect classes, all driven end-to-end here:
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
/// - D-67 → D-70/SA-2: below the top detent, detent arbitration
///   swallowed every pan starting on list content (D-67). The D-68
///   `.scrolls` pin bought list scrolling by retiring scroll↔detent
///   cooperation; SA-2 removed the two composition poisons
///   (NavigationStack wrapper, chip H-ScrollViews — 18-SCROLL-ARCH
///   §3) and retired that pin, so `.automatic` cooperates natively.
///   The cooperative pins drive real in-list drags and assert the
///   Maps-idiom contract: an in-list drag at medium EXPANDS the
///   sheet (the D-68-era headerY-HELD assertion is deliberately
///   INVERTED), content scrolls under drag at the top detent, a
///   content-at-top down-drag steps the sheet back down — through
///   medium to the compact strip — and the grabber path still
///   resizes both directions.
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

    private var reviewList: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "scanReviewList").firstMatch
    }

    /// Finger drag inside the review list body. Offsets are
    /// normalized against the list frame; start on the row area,
    /// clear of the pinned footer.
    private func dragInReviewList(from: CGFloat, to: CGFloat) {
        dragInList(reviewList, from: from, to: to)
    }

    private var searchResultsList: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "searchResultsList").firstMatch
    }

    /// Finger drag inside an arbitrary list body — shared by the
    /// review-list and results-list cooperative legs.
    private func dragInList(_ list: XCUIElement, from: CGFloat, to: CGFloat) {
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
        let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    /// Normalize the seeded review to the medium detent (seeded
    /// arrival is medium by design, but a cold first launch can
    /// arrive expanded — the O-1 presentation-settle class) via the
    /// grabber path, and return the settled header Y.
    private func normalizeSeededReviewToMedium(
        window: XCUIElement, dismiss: XCUIElement
    ) -> CGFloat {
        if dismiss.frame.minY < window.frame.height * 0.35 {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.10))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.50))
            start.press(forDuration: 0.1, thenDragTo: end)
            sleep(1)
        }
        let headerY = dismiss.frame.minY
        XCTAssertTrue(
            headerY > window.frame.height * 0.35
                && headerY < window.frame.height * 0.65,
            "Sheet not at the medium detent (header at \(headerY)) — the cooperative legs would exercise nothing."
        )
        return headerY
    }

    private func attachScreenshot(named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
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

    // MARK: - Cooperative arbitration (D-70/SA-2)

    // Reshaped from the D-68-era
    // `testMediumDetent_seededReviewDragScrollsListGrabberStillExpands`:
    // under `.scrolls` an in-list drag at medium scrolled content
    // while the header HELD. With the poisons removed and the pin
    // retired, `.automatic` cooperation makes the same stroke EXPAND
    // the sheet (probe R6: headerY 447→95 on this sim class) — the
    // held-header assertion is deliberately INVERTED. The grabber
    // path must keep resizing in BOTH directions (it did in every
    // COOP probe run).
    func testMediumDetent_seededReviewInListDragCooperativelyExpands() {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--seedTriage"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["6 found — none selected yet"].waitForExistence(timeout: 30),
            "Seeded review never presented — check the --seedTriage launch hook."
        )
        XCTAssertTrue(
            reviewList.waitForExistence(timeout: 10),
            "scanReviewList not found on the seeded review."
        )

        let window = app.windows.firstMatch
        let dismiss = app.buttons["searchDismissButton"].firstMatch
        XCTAssertTrue(
            dismiss.waitForExistence(timeout: 5),
            "Dismiss button not found on the seeded review."
        )
        let headerYAtMedium = normalizeSeededReviewToMedium(window: window, dismiss: dismiss)
        attachScreenshot(named: "sa2-arrival-medium")

        // The D-67 stroke — a slow drag up inside the list body. Dead
        // under the defect, scroll-in-place under `.scrolls`,
        // cooperative EXPAND now. R7 transient guard: the FIRST pan
        // after presentation can be swallowed while custom-detent
        // resolution settles (probe R7 expanded on drag-2; O-1
        // class) — retry once ONLY if the header genuinely did not
        // move. A true dead regime fails the assertion on the retry;
        // a `.scrolls`-class regime scrolls content with the header
        // held on BOTH strokes, so the negative control stays red.
        dragInReviewList(from: 0.6, to: 0.15)
        sleep(2)
        if abs(dismiss.frame.minY - headerYAtMedium) < 10 {
            dragInReviewList(from: 0.6, to: 0.15)
            sleep(2)
        }

        XCTAssertLessThan(
            dismiss.frame.minY, window.frame.height * 0.2,
            "In-list drag did not expand the sheet — cooperation lost (dead or scroll-in-place arbitration regime)."
        )
        attachScreenshot(named: "sa2-inlist-drag-expanded")

        // Grabber path down: a top-strip drag returns the sheet to
        // medium (resize-down still rides the grabber).
        let downStart = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.10))
        let downEnd = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.50))
        downStart.press(forDuration: 0.1, thenDragTo: downEnd)
        sleep(1)
        let headerYAfterGrabberDown = dismiss.frame.minY
        XCTAssertTrue(
            headerYAfterGrabberDown > window.frame.height * 0.35
                && headerYAfterGrabberDown < window.frame.height * 0.65,
            "Grabber down-drag did not return the sheet to medium (header at \(headerYAfterGrabberDown))."
        )

        // Grabber path up: the house expand drag still lands the top
        // detent.
        dragSheetToExpanded()
        assertSheetExpanded()
        attachScreenshot(named: "sa2-grabber-expanded")
    }

    // Cooperative collapse: at the top detent with content at its
    // top edge (the six seeded rows fit entirely at large — nothing
    // to scroll), an in-list down-drag steps the sheet DOWN instead
    // of dying (probe R6 "content-drag down at large collapses").
    func testTopDetent_seededReviewContentAtTopDownDragCooperativelyCollapses() {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--seedTriage"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["6 found — none selected yet"].waitForExistence(timeout: 30),
            "Seeded review never presented — check the --seedTriage launch hook."
        )
        XCTAssertTrue(
            reviewList.waitForExistence(timeout: 10),
            "scanReviewList not found on the seeded review."
        )
        let window = app.windows.firstMatch
        let dismiss = app.buttons["searchDismissButton"].firstMatch
        XCTAssertTrue(
            dismiss.waitForExistence(timeout: 5),
            "Dismiss button not found on the seeded review."
        )
        let headerYAtMedium = normalizeSeededReviewToMedium(window: window, dismiss: dismiss)

        // Reach the top detent through the cooperative in-list path
        // (R7 first-pan transient guard — see the expand pin).
        dragInReviewList(from: 0.6, to: 0.15)
        sleep(2)
        if abs(dismiss.frame.minY - headerYAtMedium) < 10 {
            dragInReviewList(from: 0.6, to: 0.15)
            sleep(2)
        }
        XCTAssertLessThan(
            dismiss.frame.minY, window.frame.height * 0.2,
            "Precondition failed: in-list drag did not expand the sheet."
        )

        // Content sits at its top edge; a down-drag inside the list
        // must collapse the sheet a detent step (large → medium).
        dragInReviewList(from: 0.2, to: 0.7)
        sleep(2)
        XCTAssertTrue(
            dismiss.exists,
            "Sheet vanished on the cooperative collapse — the down-drag dismissed instead of stepping detents."
        )
        let headerYAfterCollapse = dismiss.frame.minY
        XCTAssertTrue(
            headerYAfterCollapse > window.frame.height * 0.35,
            "Content-at-top down-drag did not collapse the sheet (header still at \(headerYAfterCollapse))."
        )
        attachScreenshot(named: "sa2-cooperative-collapsed")
    }

    // The down-chain's last step: from medium with content at top, a
    // further in-list down-drag reaches the compact float, where the
    // BH-B-01 strip composition replaces the full chrome (probe R7:
    // full chain large → medium → compact strip).
    func testMediumDetent_seededReviewDownDragChainReachesCompactStrip() {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--seedTriage"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["6 found — none selected yet"].waitForExistence(timeout: 30),
            "Seeded review never presented — check the --seedTriage launch hook."
        )
        XCTAssertTrue(
            reviewList.waitForExistence(timeout: 10),
            "scanReviewList not found on the seeded review."
        )
        let window = app.windows.firstMatch
        let dismiss = app.buttons["searchDismissButton"].firstMatch
        XCTAssertTrue(
            dismiss.waitForExistence(timeout: 5),
            "Dismiss button not found on the seeded review."
        )
        _ = normalizeSeededReviewToMedium(window: window, dismiss: dismiss)

        // Content is at its top edge on arrival — the in-list
        // down-drag steps medium → compact. R7 first-pan transient
        // guard: retry once if the first stroke was swallowed (the
        // review list is still on screen exactly when the step has
        // not happened yet).
        dragInReviewList(from: 0.2, to: 0.7)
        sleep(2)
        let strip = app.descendants(matching: .any)
            .matching(identifier: "compactFloatStrip").firstMatch
        if !strip.exists, reviewList.exists {
            dragInReviewList(from: 0.2, to: 0.7)
            sleep(2)
        }
        XCTAssertTrue(
            strip.waitForExistence(timeout: 10),
            "Compact strip never appeared — the down-chain stalled above the compact float."
        )
        // The full chrome yields to the strip at compact (BH-B-01
        // composition branch), and the review origin's one-line
        // summary reuses the footer's exact label.
        XCTAssertFalse(
            reviewList.exists,
            "Review list still present at the compact float — the strip did not replace the full chrome."
        )
        XCTAssertTrue(
            app.staticTexts["6 found — none selected yet"].waitForExistence(timeout: 5),
            "Compact review summary line missing at the compact float."
        )
        attachScreenshot(named: "sa2-compact-chain-strip")
    }

    // SA-3 rider (B-3): review-row canvas-navigation parity — a
    // row-BODY tap drops the sheet to the compact float (the shipped
    // search-row idiom; ST-105 keeps the canvas interactive behind
    // it). The strip's summary line doubles as the no-selection
    // proof: a body tap must NAVIGATE, never toggle — the selection
    // circle keeps its own hit region.
    func testMediumDetent_seededReviewRowBodyTapDropsToCompact() {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--seedTriage"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["6 found — none selected yet"].waitForExistence(timeout: 30),
            "Seeded review never presented — check the --seedTriage launch hook."
        )
        XCTAssertTrue(
            reviewList.waitForExistence(timeout: 10),
            "scanReviewList not found on the seeded review."
        )
        let window = app.windows.firstMatch
        let dismiss = app.buttons["searchDismissButton"].firstMatch
        XCTAssertTrue(
            dismiss.waitForExistence(timeout: 5),
            "Dismiss button not found on the seeded review."
        )
        _ = normalizeSeededReviewToMedium(window: window, dismiss: dismiss)

        // Tap the SSN row's matched-text area — row BODY, clear of
        // the leading selection circle and the trailing W9 button.
        let ssnRow = app.staticTexts["123-45-6789"].firstMatch
        XCTAssertTrue(ssnRow.waitForExistence(timeout: 10), "SSN row not found.")
        ssnRow.tap()

        let strip = app.descendants(matching: .any)
            .matching(identifier: "compactFloatStrip").firstMatch
        XCTAssertTrue(
            strip.waitForExistence(timeout: 10),
            "Row-body tap did not drop the sheet to the compact float — B-3 navigation parity missing."
        )
        XCTAssertFalse(
            reviewList.exists,
            "Review list still present after the row-tap compact drop."
        )
        XCTAssertTrue(
            app.staticTexts["6 found — none selected yet"].waitForExistence(timeout: 5),
            "Row-body tap changed the selection count — the tap must navigate, not toggle selection."
        )
        attachScreenshot(named: "sa2-review-rowtap-compact")
    }

    // The Search-results leg — cooperation re-proven on the list
    // that carries the SA-1-cleaned gesture stack (the D-70 probe
    // proved the REVIEW list only; the caveat on record requires
    // this list's own proof). The 23-page fixture's "account" query
    // lands one match per page — 23 rows across 23 page sections
    // overflow the large detent, and the DISTINCT pinned section
    // headers ("Page N") anchor the displacement checks (row labels
    // are all identical, and a pinned header never moves — the
    // anchors must be LATER sections becoming hittable).
    func testTopDetent_searchResultsContentScrollsThenCooperativelyCollapses() {
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--multipageDoc",
            "--openSearchSheet",
        ]
        app.launch()

        let field = app.textFields["Search text"]
        XCTAssertTrue(
            field.waitForExistence(timeout: 30),
            "Search sheet never presented — check the --openSearchSheet launch hook."
        )
        field.tap()
        field.typeText("account\n")

        XCTAssertTrue(
            app.staticTexts["23 found — none selected yet"].waitForExistence(timeout: 20),
            "The multipage fixture's 'account' query did not land its 23 per-page matches."
        )

        let window = app.windows.firstMatch
        let dismiss = app.buttons["searchDismissButton"].firstMatch
        XCTAssertTrue(
            dismiss.waitForExistence(timeout: 5),
            "Dismiss button not found with results on board."
        )
        // Results arrival raises medium → large (the blessed nudge);
        // top up via the grabber if the raise was pre-empted.
        if dismiss.frame.minY > window.frame.height * 0.2 {
            dragSheetToExpanded()
        }
        assertSheetExpanded()
        let headerYAtTop = dismiss.frame.minY

        XCTAssertTrue(
            searchResultsList.waitForExistence(timeout: 10),
            "searchResultsList not found with results on board."
        )
        // Top-anchored arrival: the early sections are on screen, the
        // deep ones are past the fold. (`isHittable`, not `exists` —
        // the virtualized List pre-mounts offscreen rows.)
        let deepHeader = app.staticTexts["Page 9"].firstMatch
        XCTAssertFalse(
            deepHeader.exists && deepHeader.isHittable,
            "Section 'Page 9' visible at arrival — the fixture no longer overflows the large detent."
        )

        // Content scrolls under in-list drags at the top detent —
        // deep sections arrive from below the fold while the sheet
        // header holds. Up to three strokes (R7 first-pan guard +
        // per-stroke travel).
        var deepArrived = false
        for _ in 0..<3 {
            dragInList(searchResultsList, from: 0.6, to: 0.15)
            sleep(2)
            if deepHeader.exists && deepHeader.isHittable {
                deepArrived = true
                break
            }
        }
        XCTAssertTrue(
            deepArrived,
            "In-list drags at the top detent never scrolled 'Page 9' on screen — the results list did not scroll."
        )
        XCTAssertEqual(
            dismiss.frame.minY, headerYAtTop, accuracy: 10,
            "Content drags at the top detent moved the sheet header — the drags resized instead of scrolling."
        )
        attachScreenshot(named: "sa2-results-scrolled-at-top")

        // Down-drags with content off-top: cooperation gives the
        // gesture to content until its edge — the return strokes must
        // HOLD the top detent (asserted per stroke), and only at the
        // content edge does a stroke step the sheet down.
        var collapsed = false
        for _ in 0..<8 {
            dragInList(searchResultsList, from: 0.2, to: 0.7)
            sleep(2)
            if dismiss.exists, dismiss.frame.minY > window.frame.height * 0.35 {
                collapsed = true
                break
            }
            // Not collapsed yet ⇒ this stroke was the content-return
            // phase — the sheet must not have moved.
            XCTAssertEqual(
                dismiss.frame.minY, headerYAtTop, accuracy: 10,
                "A down-drag neither collapsed the sheet nor held the top detent — cooperation lost mid-chain."
            )
        }
        XCTAssertTrue(
            collapsed,
            "Content-at-top down-drags never collapsed the sheet from the top detent."
        )
        // One detent step: full chrome still up at medium — the
        // collapse must not sail through to the compact strip.
        XCTAssertTrue(
            searchResultsList.exists,
            "The collapse sailed past medium — the results list should still be presented after one detent step."
        )
        attachScreenshot(named: "sa2-results-cooperative-collapsed")
    }
}
