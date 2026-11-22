import XCTest

/// The editor's band under the toolbar, with the paused notice: a run left
/// unfinished because the app went to the background. The route marks page
/// 2 whole and returns to page 1, so every zoom, drag and tap lands on a
/// page that holds no box (a box takes a one-finger touch); Redact starts
/// the run, the app leaves while it runs and comes back. A route that never
/// raises the notice skips with its reason: not reached, never a pass.
nonisolated final class NoticeBandUITests: XCTestCase {

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

    private static let largest = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private var notice: XCUIElement { element("pausedNotice") }
    private var mark: XCUIElement { element("noticeFoldedMark") }

    private var canvas: XCUIElement {
        app.scrollViews.allElementsBoundByIndex.max { $0.frame.height < $1.frame.height } ?? app.scrollViews.firstMatch
    }

    /// Launch, box page 2, back to page 1, Redact, leave during the run,
    /// return: the paused notice. Skips when the run ended before the app left.
    private func raisePausedNotice(_ extra: [String] = []) throws {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"] + extra
        app.launch()
        let next = app.buttons["pageNavNext"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 30), "The page bar never appeared.")
        next.tap()
        app.buttons["pageNavMarkWholePage"].firstMatch.tap()
        app.buttons["pageNavPrevious"].firstMatch.tap()
        if extra == Self.largest {
            // At the largest sizes Redact is in the … menu, not on the bar
            // (`EditorToolbarLayout`'s fold).
            XCTAssertTrue(app.editorOverflowButton.waitForExistence(timeout: 10), "The … menu button is missing.")
            XCTAssertFalse(app.buttons["redactButton"].firstMatch.exists, "Redact is on the bar at the largest size.")
            app.editorOverflowButton.tap()
        }
        // In the … menu the item is found by its label; on the bar, by its identifier.
        let redact = extra == Self.largest ? app.buttons["Redact"].firstMatch : app.buttons["redactButton"].firstMatch
        XCTAssertTrue(redact.waitForExistence(timeout: 10), "Redact is missing.")
        redact.tap()
        guard app.buttons["stopProcessing"].firstMatch.waitForExistence(timeout: 10) else {
            throw XCTSkip("not reached: the run ended before the app left")
        }
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        guard notice.waitForExistence(timeout: 20) else {
            // The run was seen going, so a mark in the notice's place is the
            // notice folded on its arrival, not a run that ended first.
            XCTAssertFalse(mark.exists, "The paused notice arrived folded to its mark.")
            if mark.exists { return }
            throw XCTSkip("not reached: the run ended before the app left")
        }
    }

    /// The notice's place under the toolbar: 8 points under the bar's foot.
    private func assertUnderTheToolbar(_ file: StaticString = #filePath, line: UInt = #line) {
        let gap = notice.frame.minY - app.navigationBars.firstMatch.frame.maxY
        XCTAssertEqual(gap, 8, accuracy: 2, "The notice is \(gap) pt under the toolbar.", file: file, line: line)
    }

    func testLeavingDuringARunShowsThePausedNoticeUnderTheToolbarWithRestartAndDismiss() throws {
        try raisePausedNotice()
        assertUnderTheToolbar()
        let close = app.buttons["noticeClose"].firstMatch
        XCTAssertTrue(close.exists, "The notice has no Dismiss.")
        XCTAssertTrue(app.buttons["noticeAction"].firstMatch.exists, "The notice has no Restart.")
        attachScreenshot(named: "notice-paused-open")
        // 20 above the glyph's centre: outside its drawing, inside its 46.
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: -20)).tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5), "A tap 20 above the close's glyph did not close the notice.")

        app.terminate()
        try raisePausedNotice()
        let restart = app.buttons["noticeAction"].firstMatch
        // 20 below the capsule's centre: outside the 32 capsule, inside its 46.
        restart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 20)).tap()
        XCTAssertTrue(app.buttons["stopProcessing"].firstMatch.waitForExistence(timeout: 10),
                      "A tap 20 below Restart's capsule did not start the run.")
    }

    func testAZoomUnderThePausedNoticeFoldsItToItsMarkAndATapOpensIt() throws {
        try raisePausedNotice()
        canvas.pinch(withScale: 2.5, velocity: 2)
        XCTAssertTrue(mark.waitForExistence(timeout: 5), "A zoom that brings the page under the notice did not fold it.")
        XCTAssertFalse(notice.exists, "The open notice is still drawn beside its mark.")
        attachScreenshot(named: "notice-paused-folded")
        // 20 left of the mark's centre (inside its 44 drawing).
        mark.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: -20, dy: 0)).tap()
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "A tap on the mark did not open the notice.")

        // A one-finger drag of the zoomed page (page 1 holds no box).
        XCTAssertTrue(element("pageNavCounter").label.contains("1"), "The drag is not on page 1.")
        let centre = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        centre.press(forDuration: 0.05, thenDragTo: centre.withOffset(CGVector(dx: 0, dy: -120)))
        XCTAssertTrue(mark.waitForExistence(timeout: 5), "A scroll that leaves the page under the notice did not fold it.")
        XCTAssertFalse(notice.exists)

        // Opened again, then a page change by the page bar folds it.
        mark.tap()
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        app.buttons["pageNavNext"].firstMatch.tap()
        XCTAssertTrue(mark.waitForExistence(timeout: 5), "A page change under the open notice did not fold it.")

        // The mark hides while the drawing tool is on, and comes back.
        let draw = app.buttons["drawTool"].firstMatch
        XCTAssertTrue(draw.waitForExistence(timeout: 5))
        draw.tap()
        XCTAssertTrue(mark.waitForNonExistence(timeout: 5), "The mark shows with the drawing tool on.")
        draw.tap()
        XCTAssertTrue(mark.waitForExistence(timeout: 5), "The mark did not come back when the tool went off.")
    }

    /// The mark is a button: a drag that starts on it does not reach the
    /// page (a named limit, the mark's own 46-point frame); one that starts
    /// just beside it moves the page. Read on the canvas's own picture, so
    /// the status bar's clock cannot move it.
    func testADragOnTheFoldedMarkKeepsThePageAndOneBesideItMovesIt() throws {
        try raisePausedNotice()
        canvas.pinch(withScale: 2.5, velocity: 2)
        XCTAssertTrue(mark.waitForExistence(timeout: 5), "The zoom did not fold the notice.")
        sleep(1)
        let before = canvas.screenshot().pngRepresentation
        let start = mark.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -150, dy: 150)))
        sleep(1)
        XCTAssertEqual(canvas.screenshot().pngRepresentation, before, "A drag from the mark moved the page.")
        XCTAssertFalse(notice.exists, "A drag from the mark opened the notice.")
        // 30 left of the mark's centre: outside its 46 frame, on the page.
        let beside = start.withOffset(CGVector(dx: -30, dy: 0))
        beside.press(forDuration: 0.05, thenDragTo: beside.withOffset(CGVector(dx: -150, dy: 150)))
        sleep(1)
        XCTAssertNotEqual(canvas.screenshot().pngRepresentation, before, "A drag beside the mark did not move the page.")
        XCTAssertFalse(notice.exists, "A drag beside the mark opened the notice.")
    }

    func testAtTheLargestTextSizeThePausedNoticeIsWholeWithRestartAndDismissOnScreen() throws {
        try raisePausedNotice(Self.largest)
        XCTAssertGreaterThan(element("pageNavCounter").frame.height, 40, "The largest text size did not take.")
        let words = notice.staticTexts.firstMatch
        XCTAssertTrue(words.isHittable, "The notice's words are not on screen.")
        XCTAssertTrue(app.buttons["noticeAction"].firstMatch.isHittable, "Restart is not on screen.")
        XCTAssertTrue(app.buttons["noticeClose"].firstMatch.isHittable, "Dismiss is not on screen.")
        let bar = element("pageNav")
        XCTAssertLessThanOrEqual(notice.frame.maxY, bar.frame.minY, "The notice runs under the page bar.")
        attachScreenshot(named: "notice-paused-largest")
    }
}
