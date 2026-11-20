import XCTest

/// The Detection Sweep's needs-review result offers Review in Scan, as its
/// note does. The seeded report `searchableSweepReview` reads Needs Review
/// from the sweep alone, the thirteenth check of a Searchable run; on the
/// results screen it is the Findings row `finding_otherNeedsReview-12`
/// (its check numbered from zero in the engine's order). Opened, the row
/// shows the button; a tap leaves the results for the editor.
/// The debug hook loads the sample document before it seeds the report, so
/// the tap has a document to return to.
///
/// Black-box (no `@testable import`). nonisolated because an XCUITest
/// drives a separate process and touches no @MainActor app state (see
/// `ShareRiskSheetUITests`).
nonisolated final class ReviewInScanUITests: XCTestCase {

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

    func testNeedsReviewSweepRowShowsReviewInScan() {
        app.launchArguments = ["--uitesting", "--seedVerifiedReport=searchableSweepReview"]
        app.launch()

        let results = app.scrollViews["verificationResults"]
        XCTAssertTrue(results.waitForExistence(timeout: 30), "The seeded results never appeared.")

        let row = app.descendants(matching: .any).matching(identifier: "finding_otherNeedsReview-12").firstMatch
        var scrolls = 0
        while !row.isHittable && scrolls < 6 {
            results.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The sweep's Findings row never appeared.")
        row.tap()

        let button = app.buttons["reviewInScanButton"]
        scrolls = 0
        while !button.isHittable && scrolls < 4 {
            results.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(button.waitForExistence(timeout: 10), "The opened needs-review row has no Review in Scan button.")
        XCTAssertTrue(button.isHittable, "Review in Scan cannot be tapped.")
        button.tap()

        let gone = NSPredicate(format: "exists == false")
        let resultsGone = expectation(for: gone, evaluatedWith: results)
        wait(for: [resultsGone], timeout: 10)
    }
}
