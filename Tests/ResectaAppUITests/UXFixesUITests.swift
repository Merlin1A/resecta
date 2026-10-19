import XCTest

/// UI tests for the search sheet's exits and the parked chrome: a
/// persisted Source = OCR filter on a document whose pages read as
/// text offers Show All from the empty state, and a parked result walk
/// keeps the page bar so a page with no hits stays reachable.
///
/// Every launch passes `--uitesting` (its filter clear runs first); the
/// seeded-filter case writes the filter after that clear.
///
/// nonisolated for the same reason as `SearchDetentLayoutUITests`: an
/// XCUITest drives a separate process and touches no @MainActor state.
nonisolated final class UXFixesUITests: XCTestCase {

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

    // MARK: - The parked walk keeps the page bar

    func testParkedWalk_keepsPageBarAndReachesAPageWithNoHits() {
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--multipageDoc",
            "--openSearchSheet", "--searchQuery=Amount", "--searchDetent=medium",
        ]
        app.launch()
        let next = app.buttons["resultNavNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 30), "The seeded query returned nothing or the sheet never presented.")
        next.tap()
        let strip = app.descendants(matching: .any).matching(identifier: "compactFloatStrip").firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 10), "The first chevron tap did not park the sheet at the compact float.")

        let pageBar = app.descendants(matching: .any).matching(identifier: "pageNav").firstMatch
        XCTAssertTrue(pageBar.waitForExistence(timeout: 10), "The page bar must stay while the walk is parked.")
        let pageNext = app.buttons["pageNavNext"]
        XCTAssertTrue(pageNext.waitForExistence(timeout: 5) && pageNext.isHittable, "The page bar's next control must be reachable above the parked strip.")
        let position = pageBar.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+ of [0-9]+$")).firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 5), "The page bar's position label is missing.")
        let parts = position.label.components(separatedBy: " of ")
        guard parts.count == 2, let current = Int(parts[0]) else {
            XCTFail("Unreadable page position '\(position.label)'.")
            return
        }
        pageNext.tap()
        let nextPosition = pageBar.staticTexts["\(current + 1) of \(parts[1])"]
        XCTAssertTrue(nextPosition.waitForExistence(timeout: 10), "The page bar's next control did not move the page while parked.")
        XCTAssertTrue(strip.exists, "Paging from the bar must keep the sheet parked.")
        attachScreenshot(named: "ux-parked-walk-page-bar")
    }

    // MARK: - Show All from a persisted OCR filter (the seeded leg runs last)

    func testZZ_persistedOCRFilter_offersShowAllFromTheEmptyState() {
        app.launchArguments = [
            "--uitesting", "--searchSourceFilter=ocr", "--loadTestDocument", "--multipageDoc",
            "--openSearchSheet", "--searchQuery=Amount", "--searchDetent=medium",
        ]
        app.launch()
        let showAll = app.buttons["Show All"]
        XCTAssertTrue(showAll.waitForExistence(timeout: 30), "A text-layer document filtered to OCR rows must offer Show All.")
        attachScreenshot(named: "ux-show-all-offered")
        showAll.tap()
        XCTAssertTrue(app.buttons["resultNavNext"].waitForExistence(timeout: 10), "Show All must bring the text-layer results back.")
        XCTAssertFalse(showAll.exists)
    }

}
