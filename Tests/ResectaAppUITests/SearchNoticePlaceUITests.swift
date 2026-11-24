import XCTest

/// The notice place above the results as a user meets it: one notice,
/// whole or folded to its first sentence by the room it has, an arrow to
/// the details when a second notice holds, a page chip there that parks the
/// sheet on its page, the notice held in place while a new search runs, and
/// the parked strip's caution mark. `--uitestNoticeSeed=` (a DEBUG launch
/// hook) adds the facts once a run has ended; `--uitestWidenPage=` marks a
/// page's results widened.
///
/// nonisolated for the same reason as `SearchDetentLayoutUITests`: an
/// XCUITest drives a separate process and touches no @MainActor state.
nonisolated final class SearchNoticePlaceUITests: XCTestCase {

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

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func launch(_ extra: [String], query: String = "Amount") {
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--multipageDoc", "--openSearchSheet", "--searchQuery=\(query)",
        ] + extra
        app.launch()
    }

    private static let tooLarge7 = "Page 7 was too large to scan for text \u{2014} image content there was not searched."

    /// Some simulators never bring the software keyboard on screen; there
    /// the keyboard tests skip and say why (a skip is not a pass).
    private func requireKeyboard() throws {
        let keyboard = app.keyboards.firstMatch
        _ = keyboard.waitForExistence(timeout: 8)
        let onScreen = keyboard.exists && keyboard.frame.minY < app.windows.firstMatch.frame.maxY - 100
        #if targetEnvironment(simulator)
        try XCTSkipUnless(onScreen, "No software keyboard on this simulator, so the notice cannot be judged with the keyboard up.")
        #else
        XCTAssertTrue(onScreen, "Software keyboard is not on screen.")
        #endif
    }

    func testOneNotice_showsWholeAboveTheResults() {
        launch(["--searchDetent=large", "--uitestNoticeSeed=tooLarge:6"])
        let notice = element("ocrSkipBanner")
        XCTAssertTrue(notice.waitForExistence(timeout: 30), "The notice never came up.")
        XCTAssertEqual(notice.label, Self.tooLarge7)
        let firstRow = app.cells.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        XCTAssertLessThan(notice.frame.minY, firstRow.frame.minY, "The notice stands above the results.")
        attachScreenshot(named: "notice-one")
    }

    func testTwoNotices_theArrowOpensTheList_andAPageChipParksOnThatPage() {
        launch(["--searchDetent=large", "--uitestNoticeSeed=tooLarge:6", "--uitestWidenPage=0"])
        let notice = element("ocrSkipBanner")
        XCTAssertTrue(notice.waitForExistence(timeout: 30))
        XCTAssertEqual(notice.elementType, .button, "With a second notice the first opens the details.")
        XCTAssertFalse(element("widenedBoxBanner").exists, "A second notice never stacks.")
        notice.tap()
        let details = element("noticeDetailsSheet")
        XCTAssertTrue(details.waitForExistence(timeout: 10), "The details never opened.")
        XCTAssertTrue(app.staticTexts["Not Searched"].exists)
        XCTAssertTrue(app.staticTexts[Self.tooLarge7].exists || element(Self.tooLarge7).exists
                      || app.descendants(matching: .any)
                        .matching(NSPredicate(format: "label CONTAINS 'too large to scan'")).firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'drawn wider than their words'")).firstMatch.exists)
        attachScreenshot(named: "notice-details")
        app.buttons["Go to page 7"].firstMatch.tap()
        XCTAssertTrue(details.waitForNonExistence(timeout: 10), "The chip did not close the details.")
        XCTAssertTrue(element("compactFloatStrip").waitForExistence(timeout: 10), "The chip did not park the sheet.")
        let onPage7 = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH 'Page 7 of'"), object: element("pageNavCounter"))
        XCTAssertEqual(XCTWaiter().wait(for: [onPage7], timeout: 10), .completed, "Page 7 is not the page shown.")
    }

    func testKeyboardUp_theLimitShowsItsFirstSentence() throws {
        launch(["--searchDetent=large", "--uitestNoticeSeed=limit:20/23"])
        let notice = element("resultLimitNotice")
        XCTAssertTrue(notice.waitForExistence(timeout: 30))
        XCTAssertTrue(notice.label.hasPrefix("Showing first 1,000 results. Search stopped at page 20 of 23"),
                      "The notice reads \"\(notice.label)\".")
        let restHeight = notice.frame.height
        let field = app.textFields["Search text"]
        field.tap()
        try requireKeyboard()
        XCTAssertLessThanOrEqual(notice.frame.height, restHeight - 20, "With the keyboard up the notice takes one line.")
        XCTAssertEqual(notice.elementType, .button, "A cut notice opens the details.")
        attachScreenshot(named: "notice-limit-keyboard")
        app.keyboards.buttons["Return"].firstMatch.tap()
        let back = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "frame.size.height >= %f", restHeight - 1), object: notice)
        XCTAssertEqual(XCTWaiter().wait(for: [back], timeout: 10), .completed, "The notice is whole again.")
    }

    func testNothingFound_theNoticeStaysAboveTheEmptyState() {
        launch(["--searchDetent=large", "--uitestNoticeSeed=tooLarge:6"], query: "Zqx")
        let notice = element("ocrSkipBanner")
        XCTAssertTrue(notice.waitForExistence(timeout: 30))
        let empty = app.staticTexts["No matches"]
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertLessThan(notice.frame.minY, empty.frame.minY)
    }

    func testANewRun_keepsTheNoticeInPlace() {
        launch(["--searchDetent=large", "--uitestNoticeSeed=tooLarge:6"])
        let notice = element("ocrSkipBanner")
        XCTAssertTrue(notice.waitForExistence(timeout: 30))
        let top = notice.frame.minY
        let field = app.textFields["Search text"]
        field.tap()
        field.typeText("s")
        for _ in 0..<40 {
            XCTAssertTrue(notice.exists, "The notice left while the new search ran.")
            XCTAssertEqual(notice.frame.minY, top, accuracy: 1, "The notice moved while the new search ran.")
            usleep(50_000)
        }
    }

    func testParkedStrip_carriesTheMark_besideTheArrows() {
        launch(["--searchDetent=compact", "--uitestNoticeSeed=tooLarge:6"])
        let mark = element("parkedStripNoticeMark")
        XCTAssertTrue(mark.waitForExistence(timeout: 30), "The parked strip has no mark.")
        XCTAssertEqual(mark.label, Self.tooLarge7)
        let previous = app.buttons["resultNavPrevious"]
        XCTAssertTrue(previous.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(mark.frame.maxX, previous.frame.minX + 1, "The mark stands before the arrows.")
        for other in app.buttons.allElementsBoundByIndex where other.identifier != "parkedStripNoticeMark" && other.isHittable {
            XCTAssertFalse(mark.frame.insetBy(dx: 1, dy: 1).intersects(other.frame) && other.frame.width < 200,
                           "The mark meets \(other.identifier).")
        }
        attachScreenshot(named: "notice-strip-mark")
        mark.tap()
        XCTAssertTrue(app.buttons["searchDismissButton"].waitForExistence(timeout: 10), "The mark did not raise the sheet.")
        XCTAssertTrue(element("ocrSkipBanner").waitForExistence(timeout: 10))
    }

    func testParkedStrip_carriesTheMark_whenNothingWasFound() {
        launch(["--searchDetent=compact", "--uitestNoticeSeed=tooLarge:6"], query: "Zqx")
        let mark = element("parkedStripNoticeMark")
        XCTAssertTrue(mark.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["resultNavNext"].exists)
        let title = app.staticTexts["Search"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let withMark = title.frame
        app.terminate()
        launch(["--searchDetent=compact"], query: "Zqx")
        let plain = app.staticTexts["Search"].firstMatch
        XCTAssertTrue(plain.waitForExistence(timeout: 30))
        XCTAssertFalse(element("parkedStripNoticeMark").exists)
        XCTAssertEqual(plain.frame.minX, withMark.minX, accuracy: 1, "The mark moved the title.")
        XCTAssertEqual(plain.frame.minY, withMark.minY, accuracy: 1, "The mark moved the title.")
    }

    func testScan_theDegradedNoticeStandsAboveTheList() {
        launch(["--searchMode=piiScan", "--searchDetent=large", "--uitestNoticeSeed=degraded"])
        let notice = element("degradedDetectionBanner")
        XCTAssertTrue(notice.waitForExistence(timeout: 30), "The degraded-detection notice never came up in Scan.")
        XCTAssertTrue(notice.label.contains("is degraded for this session"), "It reads \"\(notice.label)\".")
        attachScreenshot(named: "notice-scan-degraded")
    }

    func testWithANotice_oneSwipeStillScrollsAndResizes() {
        launch(["--searchDetent=medium", "--uitestNoticeSeed=tooLarge:6"])
        XCTAssertTrue(element("ocrSkipBanner").waitForExistence(timeout: 30))
        let window = app.windows.firstMatch
        let dismiss = app.buttons["searchDismissButton"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 10))
        let before = dismiss.frame.minY
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        let raised = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "frame.origin.y < %f", before - 100), object: dismiss)
        XCTAssertEqual(XCTWaiter().wait(for: [raised], timeout: 10), .completed, "One swipe did not raise the sheet.")
    }

    func testTyping_withANotice_keepsTheFieldFocused() throws {
        launch(["--searchDetent=large", "--uitestNoticeSeed=tooLarge:6"])
        XCTAssertTrue(element("ocrSkipBanner").waitForExistence(timeout: 30))
        let field = app.textFields["Search text"]
        field.tap()
        try requireKeyboard()
        field.typeText("ss")
        sleep(2)
        XCTAssertTrue((field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false, "The field lost focus.")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "The keyboard closed.")
    }
}
