import XCTest

/// UI tests for the result walk's chrome on the parked Search sheet:
/// the page bar steps aside while a walk is live at the compact float
/// and is back after expand; each step centres the current match's ring
/// in the visible canvas (pixel-measured — the ring is not served
/// through AX); and the parked strip's controls meet the 44-pt
/// effective floor inside the attached sheet. All three drive the
/// multipage fixture with the seeded "Amount" query at the medium
/// detent (an arrival raise may lift it to large — either is a valid
/// start for the first chevron tap).
///
/// nonisolated for the same reason as `SearchDetentLayoutUITests`: an
/// XCUITest drives a separate process and touches no @MainActor state.
nonisolated final class ResultWalkUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--multipageDoc",
            "--openSearchSheet", "--searchQuery=Amount", "--searchDetent=medium",
        ]
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    // MARK: - The page bar steps aside

    func testWalkStep_pageBarStepsAsideAtCompactAndReturnsOnExpand() {
        app.launch()
        let next = app.buttons["resultNavNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 30), "The seeded query returned nothing or the sheet never presented.")
        let pageBar = app.descendants(matching: .any).matching(identifier: "pageNav").firstMatch
        XCTAssertTrue(pageBar.waitForExistence(timeout: 10), "The page bar must be mounted on the multipage fixture before the walk parks the sheet.")

        next.tap()
        XCTAssertTrue(compactStrip.waitForExistence(timeout: 10), "The first chevron tap did not park the sheet at the compact float.")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: pageBar)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed,
                       "The page bar must step aside while the walk is live at the compact float.")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Result 1 of ")).firstMatch.exists,
            "The walk did not land on result 1."
        )
        attachScreenshot(named: "rw-page-bar-parked")

        expandCompactStripToMedium()
        XCTAssertTrue(
            pageBar.waitForExistence(timeout: 10),
            "The page bar must be back once the sheet leaves the compact float."
        )
        attachScreenshot(named: "rw-page-bar-expanded")
    }

    // MARK: - The match is centred

    /// Three steps including a page crossing (▲ from result 1 wraps to
    /// the last result on the last page): the ring's centre sits within
    /// 12 pt of the visible canvas's centre every time. The ring is
    /// pixel-measured on a screenshot: the brand-teal stroke is the only
    /// teal inside the canvas band (black-on-white fixture text).
    func testWalkStep_centresTheRingInTheVisibleCanvas() throws {
        app.launch()
        let next = app.buttons["resultNavNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 30), "The seeded query returned nothing or the sheet never presented.")
        next.tap()
        XCTAssertTrue(compactStrip.waitForExistence(timeout: 10), "The first chevron tap did not park the sheet.")
        let prev = app.buttons["resultNavPrevious"]
        let compactNext = app.buttons["resultNavNext"]
        XCTAssertTrue(prev.waitForExistence(timeout: 5) && compactNext.exists, "The parked strip's chevrons are missing.")

        try assertRingCentred(step: "1 (result 1, page 1)")
        compactNext.tap()
        try assertRingCentred(step: "2 (result 2, page 1)")
        prev.tap()
        prev.tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Result 644 of ")).firstMatch.waitForExistence(timeout: 10),
            "The second ▲ did not wrap the walk to the last result."
        )
        try assertRingCentred(step: "3 (result 644, page 23 — a page crossing)")
        attachScreenshot(named: "rw-centred-page-crossing")
    }

    // MARK: - The effective floor

    /// The parked strip's controls are measured in screen points, so
    /// the sheet's render scale is already applied.
    func testCompactStrip_controlsMeetTheEffectiveFloor() {
        app.launch()
        let next = app.buttons["resultNavNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 30), "The seeded query returned nothing or the sheet never presented.")
        next.tap()
        XCTAssertTrue(compactStrip.waitForExistence(timeout: 10), "The first chevron tap did not park the sheet.")
        let apply = app.buttons["applyCurrentResultButton"]
        let prev = app.buttons["resultNavPrevious"]
        let compactNext = app.buttons["resultNavNext"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5) && prev.exists && compactNext.exists, "The parked strip's controls are missing.")
        for (name, element) in [("Apply", apply), ("previous chevron", prev), ("next chevron", compactNext)] {
            XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(name) height \(element.frame.height) is under the 44-pt effective floor.")
            XCTAssertGreaterThanOrEqual(element.frame.width, 44, "\(name) width \(element.frame.width) is under the 44-pt effective floor.")
        }
        attachScreenshot(named: "rw-strip-floor")
    }

    // MARK: - Helpers

    private var compactStrip: XCUIElement { RingCentre.compactStrip(app) }

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
                if headerY > window.frame.height * 0.3 && headerY < window.frame.height * 0.7 { return }
                if headerY <= window.frame.height * 0.3 { return }
            }
        }
        XCTFail("The grabber drag did not leave the compact float.")
    }
}

extension ResultWalkUITests {
    /// The ring's centre within 12 pt of the visible canvas's centre
    /// (the multipage fixture's matches sit clear of the page's edges).
    nonisolated fileprivate func assertRingCentred(step: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try RingCentre.assertRingCentred(app, step: step, expected: RingCentre.bandCentre, file: file, line: line)
    }
}
