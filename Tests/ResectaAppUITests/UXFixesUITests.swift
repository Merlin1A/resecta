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

    // MARK: - A rejected draw says why

    /// A one-line box — wide enough to clear the 8-pt start gate, 6 pt
    /// tall, under the commit floor — is rejected, and the rejection is
    /// shown on screen, not only spoken to VoiceOver.
    func testTooSmallDrawShowsTheZoomInNotice() {
        launchSampleInEditor()
        enterDrawMode()
        let before = currentRegionCount()

        drag(fromNormalized: CGVector(dx: 0.15, dy: 0.30), byPoints: 120, 6)

        let notice = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Region too small. Zoom in to draw a smaller region."))
            .firstMatch
        XCTAssertTrue(
            notice.waitForExistence(timeout: 10),
            "A rejected draw must say why on screen: no 'Region too small. Zoom in to draw a smaller region.' notice appeared."
        )
        XCTAssertEqual(currentRegionCount(), before, "The too-small box must not commit.")
        attachScreenshot(named: "ux-too-small-notice")
    }

}

// MARK: - Editor driving

/// The editor drive the canvas legs share: the sample opened from Home,
/// the Rectangle tool, window-normalized drags and the page bar's region
/// count (canvas regions are not in the accessibility tree; the page bar's
/// "N region(s)" text is the served hook). Members are `nonisolated` like
/// the class: an XCUITest drives a separate process.
private extension UXFixesUITests {

    nonisolated var window: XCUIElement { app.windows.firstMatch }

    /// Home → "Try the Sample" → the editor on page 1 of the 3-page sample,
    /// once the text-layer toast has cleared so no drag lands on it.
    nonisolated func launchSampleInEditor() {
        app.launchArguments = ["--uitesting"]
        app.launch()
        let sampleCard = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Try the Sample'"))
            .firstMatch
        XCTAssertTrue(sampleCard.waitForExistence(timeout: 30), "HomeView's sample card never appeared.")
        sampleCard.tap()
        XCTAssertTrue(app.buttons["drawTool"].waitForExistence(timeout: 30), "The editor never appeared.")
        let toast = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH 'Text layer detected'"))
            .firstMatch
        if toast.waitForExistence(timeout: 5) {
            XCTAssertTrue(toast.waitForNonExistence(timeout: 20), "The text-layer toast never cleared.")
        }
        sleep(1)
    }

    /// Tap the Rectangle tool until it reports drawing mode (a dropped or
    /// late tap is corrected by the next round).
    nonisolated func enterDrawMode() {
        let tool = app.buttons["drawTool"]
        XCTAssertTrue(tool.waitForExistence(timeout: 10), "Rectangle tool not present.")
        for _ in 0..<3 {
            tool.tap()
            if waitForToolValue("Drawing mode active", timeout: 6) { return }
        }
        XCTFail("The Rectangle tool did not report drawing mode after three taps.")
    }

    nonisolated func waitForToolValue(_ expected: String, timeout: TimeInterval) -> Bool {
        let tool = app.buttons["drawTool"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (tool.value as? String) == expected { return true }
            usleep(250_000)
        }
        return (tool.value as? String) == expected
    }

    /// A slow drag by a screen-point delta that rests before lifting, so a
    /// loaded host cannot lift it short of a threshold.
    nonisolated func drag(fromNormalized start: CGVector, byPoints dx: CGFloat, _ dy: CGFloat) {
        let size = window.frame.size
        let end = CGVector(dx: start.dx + dx / size.width, dy: start.dy + dy / size.height)
        window.coordinate(withNormalizedOffset: start).press(
            forDuration: 0.05,
            thenDragTo: window.coordinate(withNormalizedOffset: end),
            withVelocity: .slow,
            thenHoldForDuration: 0.2
        )
    }

    /// The page bar's region count for the current page — 0 when it shows none.
    nonisolated func currentRegionCount() -> Int {
        let label = app.staticTexts
            .matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+ regions?$"))
            .firstMatch
        guard label.exists,
              let head = label.label.split(separator: " ").first,
              let count = Int(head)
        else { return 0 }
        return count
    }
}
