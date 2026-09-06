import XCTest

/// The one end-to-end leg for the Search Re-check (verification's last
/// layer): a typed text search applied from the Search sheet, redacted
/// through the editor's overflow Redact, and read back on the results
/// screen as a passing row with the check's own name.
///
/// Route: `--openSearchSheet` over the bundled single-page fixture
/// ("Sample Document Page 1") → type "Sample" → Select All → Apply →
/// dismiss the sheet → overflow → Redact (default Secure Rasterization,
/// Verify Before Export on by default) → "Checks Passed" → expand
/// Verification Details → the sixth row (`layerResult_5`) is the Search
/// Re-check and reads "Check passed." The row's accessibility label is
/// the ordinal + name + status phrase + the layer's own line, so the
/// black-box assertion needs no `@testable` import.
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
        attachScreenshot(named: "search-recheck-01-checks-passed")

        // Expand Verification Details (label = "Verification Details, <summary>").
        // The toggle sits at the foot of the results scroll view on this
        // device class and the rows render beneath it, below the fold, so
        // scroll it up before the tap and scroll again for the rows —
        // elements outside the scroll view's visible region are not
        // reliably served to XCUITest.
        let results = app.scrollViews["verificationResults"]
        XCTAssertTrue(results.waitForExistence(timeout: 10), "Results scroll view not found.")
        results.swipeUp()
        let details = app.buttons.matching(
            NSPredicate(format: #"label BEGINSWITH "Verification Details""#)
        ).firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 10), "Verification Details toggle not found.")
        XCTAssertTrue(details.label.contains("6 of 6 checks passed"),
                      "Secure Rasterization runs a 6-layer check: \(details.label)")
        details.tap()

        // The sixth row (zero-indexed identifier) is the Search Re-check in
        // Secure Rasterization. Collapsed, the row is one combined element
        // whose label is "Layer 6, Search Re-check, Check passed. …".
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
        XCTAssertTrue(label.contains("Check passed."),
                      "The Search Re-check did not read as passed: \(label)")
        attachScreenshot(named: "search-recheck-02-details-row")
    }

    // MARK: - Evidence

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
