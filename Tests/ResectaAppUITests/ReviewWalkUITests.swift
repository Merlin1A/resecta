import XCTest

/// UI test for the review-origin walk on the parked Scan sheet: the
/// staged detection review steps its rows from the compact strip's
/// ‹ › pair, the match line names the current row, the strip's Select
/// toggles the row's selection (the footer count moves), and the page
/// bar steps aside beneath the parked strip while the walk is live —
/// on the 23-page fixture with the DEBUG-seeded review (six staged
/// detections on page 1, none selected on arrival).
///
/// nonisolated for the same reason as `SearchDetentLayoutUITests`: an
/// XCUITest drives a separate process and touches no @MainActor state.
nonisolated final class ReviewWalkUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc", "--seedTriage"]
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    func testSeededReview_walkStepsAndSelectsCurrentFinding() {
        app.launch()
        XCTAssertTrue(
            app.staticTexts["0 of 6 selected"].waitForExistence(timeout: 30),
            "Seeded review never presented — check the --seedTriage launch hook."
        )
        XCTAssertTrue(reviewList.waitForExistence(timeout: 10), "scanReviewList not found on the seeded review.")
        let pageBar = app.descendants(matching: .any).matching(identifier: "pageNav").firstMatch
        XCTAssertTrue(
            pageBar.waitForExistence(timeout: 10),
            "The page bar must be mounted on the multipage fixture behind the review before the walk parks the sheet."
        )

        // Park the review with a row-BODY tap on the SSN row (the shipped
        // navigation idiom): that row becomes the walk's current.
        let ssnRow = app.staticTexts["123-45-6789"].firstMatch
        XCTAssertTrue(ssnRow.waitForExistence(timeout: 10), "SSN row not found on the seeded review.")
        ssnRow.tap()
        XCTAssertTrue(compactStrip.waitForExistence(timeout: 10), "The row-body tap did not park the review at the compact float.")
        XCTAssertTrue(
            pageBar.waitForNonExistence(timeout: 10),
            "The page bar must step aside while the review walk is live at the compact float."
        )
        let line = app.descendants(matching: .any).matching(identifier: "walkMatchLine").firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5), "The match line is missing from the parked review strip.")
        XCTAssertTrue(
            line.label.contains("SSN") && line.label.contains("123-45-6789"),
            "The match line does not name the tapped row: \(line.label)"
        )
        XCTAssertTrue(counter("Result 1 of 6").waitForExistence(timeout: 5), "The counter did not read 1 of 6 for the tapped row.")
        attachScreenshot(named: "rw-review-parked-row1")

        // ▼ twice: Email, then Phone — the line and the counter follow.
        let next = app.buttons["resultNavNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 5), "The parked review strip is missing its ▼ chevron.")
        next.tap()
        XCTAssertTrue(counter("Result 2 of 6").waitForExistence(timeout: 5), "▼ did not step the review walk to row 2.")
        XCTAssertTrue(
            line.label.contains("Email") && line.label.contains("j.doe@example.com"),
            "The match line does not name row 2: \(line.label)"
        )
        next.tap()
        XCTAssertTrue(counter("Result 3 of 6").waitForExistence(timeout: 5), "▼ did not step the review walk to row 3.")
        XCTAssertTrue(line.label.contains("Phone"), "The match line does not name row 3: \(line.label)")

        // Select the current row from the strip: the button reads
        // selected and the walk stays put.
        let select = app.buttons["applyCurrentResultButton"]
        XCTAssertTrue(select.waitForExistence(timeout: 5), "The strip's Select is missing on the review origin.")
        XCTAssertEqual(select.label, "Select", "The strip's per-item button must read Select on the review origin.")
        XCTAssertTrue(select.isEnabled, "Select must be enabled with a current row.")
        XCTAssertFalse(select.isSelected, "A row arriving unselected must not read selected.")
        select.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { select.isSelected }, "The strip's Select did not mark the current row selected.")
        XCTAssertTrue(counter("Result 3 of 6").exists, "Select moved the walk — select-and-stay-put means the current row must not change.")
        attachScreenshot(named: "rw-review-selected")

        // The footer count moves: read it with the sheet expanded; the
        // page bar returns once the sheet leaves the compact float.
        expandCompactStripToMedium()
        XCTAssertTrue(
            app.staticTexts["1 of 6 selected"].waitForExistence(timeout: 10),
            "The footer count did not move to 1 of 6 after the strip's Select."
        )
        XCTAssertTrue(pageBar.waitForExistence(timeout: 10), "The page bar must return once the sheet leaves the compact float.")

        // Park again on the selected row: the strip reads Selected; a
        // second tap deselects and the footer follows.
        let phoneRow = app.staticTexts["(555) 010-2934"].firstMatch
        XCTAssertTrue(phoneRow.waitForExistence(timeout: 10), "Phone row not found on the re-expanded review.")
        phoneRow.tap()
        XCTAssertTrue(compactStrip.waitForExistence(timeout: 10), "The second row-body tap did not park the review.")
        XCTAssertTrue(waitUntil(timeout: 5) { select.isSelected }, "The strip must read Selected for a selected current row.")
        select.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !select.isSelected }, "A second tap must deselect the current row.")
        expandCompactStripToMedium()
        XCTAssertTrue(
            app.staticTexts["0 of 6 selected"].waitForExistence(timeout: 10),
            "The footer did not return to 0 of 6 after the deselect."
        )
        attachScreenshot(named: "rw-review-deselected-footer")
    }

    // MARK: - Helpers

    private var compactStrip: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "compactFloatStrip").firstMatch
    }

    private var reviewList: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "scanReviewList").firstMatch
    }

    private func counter(_ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Grabber drag from the parked strip up to the medium detent —
    /// `SearchDetentLayoutUITests`' idiom.
    private func expandCompactStripToMedium() {
        let window = app.windows.firstMatch
        for _ in 0..<3 {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            start.press(forDuration: 0.1, thenDragTo: end)
            let dismiss = app.buttons["searchDismissButton"].firstMatch
            if dismiss.waitForExistence(timeout: 3) {
                let headerY = dismiss.frame.minY
                if headerY < window.frame.height * 0.7 { return }
            }
        }
        XCTFail("The grabber drag did not leave the compact float.")
    }

    /// Poll a condition for up to `timeout` seconds — AX state such as
    /// `isSelected` has no `waitForExistence` analogue.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(250_000)
        }
        return condition()
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
