import XCTest

/// The one end-to-end leg for the Search Re-check (verification's last
/// layer): a typed text search applied from the Search sheet, redacted
/// through the editor's overflow Redact, and read back on the results
/// screen as a passing row with the check's own name.
///
/// Route: `--openSearchSheet` over the bundled single-page fixture
/// ("Sample Document Page 1") → type "Sample" → Select All → Apply →
/// dismiss the sheet → overflow → Redact (default Secure Rasterization,
/// Verify Before Export on by default) → "Checks Passed" → the headline
/// (`verificationMasthead`) states the counts → the sixth row
/// (`layerResult_5`) is the Search Re-check and reads "Passed."; the seventh
/// (`layerResult_6`) is the Detection Sweep. The row's accessibility label
/// is the title + status phrase + the row's own line, so the black-box
/// assertion needs no `@testable` import.
///
/// Runs in the simulator suite census, not the pull-request gate (no
/// XCUI there). Cost class: one Redact of a one-page fixture.
///
/// nonisolated for the same reason as `SearchMarkForRedactionUITests`:
/// an XCUITest drives a separate process and touches no @MainActor app
/// state; under the SE-0466 MainActor-default flip the lifecycle
/// overrides would otherwise mismatch XCTestCase's nonisolated ObjC
/// lifecycle methods.
nonisolated final class SearchRecheckUITests: XCTestCase {

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

    func testSearchRecheck_appliedTextSearch_rowReadsCheckPassed() {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--openSearchSheet"]
        app.launch()

        // Text search against the fixture's known content.
        let field = app.textFields["Search text"]
        XCTAssertTrue(
            field.waitForExistence(timeout: 30),
            "Search sheet never presented — check the --openSearchSheet launch hook."
        )
        field.tap()
        field.typeText("Sample")
        XCTAssertTrue(
            app.staticTexts["Page 1"].waitForExistence(timeout: 15),
            "Text search returned no results for the bundled fixture."
        )

        // Select All → Apply (direct apply; the toast confirms the commit).
        let selectAll = app.buttons["footerSelectAllButton"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 10), "Select All button not found.")
        selectAll.tap()
        let apply = app.buttons["searchApplyButton"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10), "Apply button not found.")
        XCTAssertTrue(apply.isEnabled, "Apply stayed disabled — Select All did not select any results.")
        apply.tap()
        let toast = app.staticTexts.matching(
            NSPredicate(format: #"label BEGINSWITH "Marked""#)
        ).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 10), "Apply toast never appeared.")

        // Dismiss the sheet, then Redact from the toolbar overflow.
        let dismiss = app.buttons["searchDismissButton"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 10), "Dismiss button not found after Apply.")
        dismiss.tap()

        let overflow = app.buttons["OverflowBarButtonItem"]
        XCTAssertTrue(overflow.waitForExistence(timeout: 10), "Toolbar overflow button never appeared.")
        overflow.tap()
        let redact = app.buttons["Redact"]
        XCTAssertTrue(redact.waitForExistence(timeout: 10), "Redact menu item never appeared.")
        redact.tap()

        // Redaction + verification of a one-page fixture: seconds, with
        // headroom for a cold simulator.
        XCTAssertTrue(
            app.staticTexts["Checks Passed"].waitForExistence(timeout: 90),
            "Verification did not reach 'Checks Passed'."
        )
        // A search-only run carries no line about automated detection on
        // the run-facts strip: the verification ledger states what the
        // detectors observed on the output instead of a disclaimer.
        let detectionLine = app.staticTexts.matching(
            NSPredicate(format: #"label CONTAINS "Automated detection did not run""#)
        ).firstMatch
        XCTAssertFalse(detectionLine.exists, "The detection-disclosure line must not render.")
        attachScreenshot(named: "search-recheck-01-checks-passed")

        // The headline states the counts (label = "{Title}. {P} of {T}
        // checks passed. … {sentence}"). Every check passed, so the rows
        // render as one `Checks` list below the fold — scroll for them;
        // elements outside the scroll view's visible region are not
        // reliably served to XCUITest.
        let results = app.scrollViews["verificationResults"]
        XCTAssertTrue(results.waitForExistence(timeout: 10), "Results scroll view not found.")
        let masthead = app.descendants(matching: .any)["verificationMasthead"]
        XCTAssertTrue(masthead.waitForExistence(timeout: 10), "The results headline not found.")
        XCTAssertTrue(masthead.label.hasPrefix("Checks Passed. 7 of 7 checks passed."),
                      "Secure Rasterization runs a 7-layer check, every one passing: \(masthead.label)")
        results.swipeUp()

        // The sixth row (zero-indexed identifier) is the Search Re-check in
        // Secure Rasterization. Collapsed, the row is one combined element
        // whose label is "Search Re-check, Passed. …".
        let row = app.descendants(matching: .any)
            .matching(identifier: "layerResult_5")
            .firstMatch
        var scrolls = 0
        while !row.exists && scrolls < 4 {
            results.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The sixth verification row never appeared.")
        let label = row.label
        XCTAssertTrue(label.contains("Search Re-check"),
                      "Row 6 is not the Search Re-check: \(label)")
        XCTAssertTrue(label.contains("Passed."),
                      "The Search Re-check did not read as passed: \(label)")
        attachScreenshot(named: "search-recheck-02-details-row")
    }

    // MARK: - Detection Sweep row

    /// One drawn box over the bundled one-page fixture → Redact. The run
    /// carries no typed search, so the Search Re-check reads as an
    /// informational note and the seventh row — the Detection Sweep —
    /// reports what the detectors observed on the output. The run-facts
    /// strip carries no line about detection having or not having run:
    /// the row measures it.
    func testDetectionSweep_drawnBox_rowPresentAndNoDetectionLine() {
        app.launchArguments = ["--uitesting", "--loadTestDocument"]
        app.launch()

        let drawTool = app.buttons["drawTool"]
        XCTAssertTrue(drawTool.waitForExistence(timeout: 30),
                      "The editor's Rectangle tool never appeared — check the --loadTestDocument launch hook.")
        drawTool.tap()
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.55))
            .press(forDuration: 0.05,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.62)))
        drawTool.tap()

        let overflow = app.buttons["OverflowBarButtonItem"]
        XCTAssertTrue(overflow.waitForExistence(timeout: 10), "Toolbar overflow button never appeared.")
        overflow.tap()
        let redact = app.buttons["Redact"]
        XCTAssertTrue(redact.waitForExistence(timeout: 10), "Redact menu item never appeared.")
        redact.tap()

        XCTAssertTrue(app.staticTexts["Checks Passed"].waitForExistence(timeout: 90),
                      "Verification did not reach 'Checks Passed'.")
        // No line about automated detection on the strip — the ledger row
        // states what the detectors observed instead.
        let detectionLine = app.staticTexts.matching(
            NSPredicate(format: #"label CONTAINS "Automated detection did not run""#)
        ).firstMatch
        XCTAssertFalse(detectionLine.exists, "The detection-disclosure line must not render.")
        attachScreenshot(named: "detection-sweep-01-checks-passed")

        let results = app.scrollViews["verificationResults"]
        XCTAssertTrue(results.waitForExistence(timeout: 10), "Results scroll view not found.")
        let masthead = app.descendants(matching: .any)["verificationMasthead"]
        XCTAssertTrue(masthead.waitForExistence(timeout: 10), "The results headline not found.")
        XCTAssertTrue(masthead.label.contains("5 of 7 checks passed. 2\u{00A0}had nothing to check."),
                      "No typed search and no captured term: the re-check and the term check had nothing to check: \(masthead.label)")
        results.swipeUp()
        // The idle re-check sits above the pass cluster, so the cluster
        // starts collapsed: open it to reach the sweep's row.
        let cluster = app.buttons["passedChecksCluster"]
        XCTAssertTrue(cluster.waitForExistence(timeout: 10), "The pass cluster never appeared.")
        cluster.tap()

        let row = app.descendants(matching: .any).matching(identifier: "layerResult_6").firstMatch
        var scrolls = 0
        while !row.exists && scrolls < 4 {
            results.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The seventh verification row never appeared.")
        XCTAssertTrue(row.label.contains("Detection Sweep"), "Row 7 is not the Detection Sweep: \(row.label)")
        // The collapsed row and its spoken label carry the gate the sweep
        // applies, not only the expanded detail.
        XCTAssertTrue(row.label.contains("Names and addresses are not swept."),
                      "The Detection Sweep row must state its gate when collapsed: \(row.label)")
        attachScreenshot(named: "detection-sweep-02-details-row")
    }

    // MARK: - Evidence

}
