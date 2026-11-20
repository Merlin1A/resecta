import XCTest

// The selection bar never covers the selection: a box selected at the foot
// of the canvas, where the bar's bottom place would lie over it or its
// handles, sends the bar to the top of the canvas, 8 pt under its top; the
// page does not move. A box clear of the bottom place leaves the bar there.
nonisolated final class SelectionBarClearanceUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Half the app's 46-pt touch target: how far a handle's touch area
    /// reaches past its box.
    private static let reach: CGFloat = 23
    /// The space the bar keeps from the selection and from the canvas's top
    /// (`ResectaTokens.Spacing.sm`).
    private static let gap: CGFloat = 8

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    // MARK: - Lookups

    nonisolated var window: XCUIElement { app.windows.firstMatch }

    nonisolated func probe() throws -> CanvasPixelProbe {
        try XCTUnwrap(CanvasPixelProbe(XCUIScreen.main.screenshot(), windowSize: window.frame.size))
    }

    nonisolated func point(_ p: CGPoint) -> XCUICoordinate {
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x, dy: p.y))
    }

    nonisolated var counter: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "pageNavCounter").firstMatch
    }

    nonisolated var bar: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "selectionBar").firstMatch
    }

    nonisolated var box: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label MATCHES 'Redaction (region|box) [0-9]+'")).firstMatch
    }

    /// PDFKit's scroll view: the tallest.
    nonisolated var canvas: CGRect {
        (app.scrollViews.allElementsBoundByIndex.max { $0.frame.height < $1.frame.height } ?? app.scrollViews.firstMatch).frame
    }

    nonisolated func currentRegionCount() -> Int {
        guard counter.waitForExistence(timeout: 5) else { return -1 }
        let label = counter.label
        guard let match = label.range(of: #"(\d+) (regions?|box(es)?)"#, options: .regularExpression) else { return 0 }
        return Int(label[match].split(separator: " ").first ?? "") ?? -1
    }

    nonisolated func waitForRegionCount(_ n: Int, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if currentRegionCount() == n { return true }
            usleep(250_000)
        }
        return currentRegionCount() == n
    }

    /// The element's frame once two reads 0.3 s apart agree, at most 3 s.
    nonisolated func settledFrame(_ element: XCUIElement) -> CGRect {
        var last = element.frame
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            usleep(300_000)
            let now = element.frame
            if now == last { return now }
            last = now
        }
        return last
    }

    nonisolated func setDrawTool(_ value: String) {
        let tool = app.buttons["drawTool"]
        for _ in 0..<3 {
            tool.tap()
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                if tool.drawToolReads(value) { return }
                usleep(250_000)
            }
        }
        XCTFail("The Rectangle tool never read \(value).")
    }

    nonisolated func drawBox(from a: CGPoint, to b: CGPoint) {
        let count = currentRegionCount()
        setDrawTool("Drawing mode active")
        point(a).press(forDuration: 0.05, thenDragTo: point(b), withVelocity: .slow, thenHoldForDuration: 0.2)
        setDrawTool("Tap to enter drawing mode")
        XCTAssertTrue(waitForRegionCount(count + 1), "the box drew; the counter read \(currentRegionCount())")
    }

    /// Pinch PDFKit's scroll view 2x, proven by the canvas background just
    /// above the fit page turning page-white.
    nonisolated func pinchToZoom(above page: CGRect) throws -> Bool {
        let probePoint = CGPoint(x: page.midX, y: page.minY - 8)
        let scroll = app.scrollViews.allElementsBoundByIndex.max { $0.frame.height < $1.frame.height } ?? app.scrollViews.firstMatch
        for _ in 1...2 {
            scroll.pinch(withScale: 2.0, velocity: 1.0)
            sleep(3)
            if try !probe().isBackground(probePoint) { return true }
        }
        return false
    }

    nonisolated func launch(_ arguments: [String]) {
        app.launchArguments = ["--uitesting", "--loadTestDocument"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["drawTool"].waitForExistence(timeout: 60), "the editor never appeared")
        let toast = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Text layer detected'")).firstMatch
        if toast.waitForExistence(timeout: 4) { _ = toast.waitForNonExistence(timeout: 20) }
        sleep(1)
    }

    /// The selection, with its handles' reach, and the bar grown by the gap
    /// share no point.
    nonisolated func clear(_ box: CGRect, of bar: CGRect) -> Bool {
        !box.insetBy(dx: -Self.reach, dy: -Self.reach).intersects(bar.insetBy(dx: -Self.gap, dy: -Self.gap))
    }

    /// Selects the drawn box by its centre; returns its frame before and
    /// after, and the bar's.
    nonisolated func select() -> (b0: CGRect, b1: CGRect, bar: CGRect) {
        XCTAssertTrue(box.waitForExistence(timeout: 5), "the box is on the canvas")
        let b0 = settledFrame(box)
        point(CGPoint(x: b0.midX, y: b0.midY)).tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "selecting the box shows the selection bar")
        let barFrame = settledFrame(bar)
        return (b0, settledFrame(box), barFrame)
    }

    /// The bar in its top place, the selection clear of it, the page unmoved.
    nonisolated func assertTopPlace(b0: CGRect, b1: CGRect, bar barFrame: CGRect, canvas c: CGRect,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(barFrame.minY - c.minY, Self.gap, accuracy: 1,
                       "the bar's top is 8 pt under the canvas's top (bar \(barFrame), canvas \(c))", file: file, line: line)
        XCTAssertTrue(clear(b1, of: barFrame), "the box and its handles are clear of the bar (box \(b1), bar \(barFrame))",
                      file: file, line: line)
        XCTAssertEqual(b1.minX, b0.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(b1.minY, b0.minY, accuracy: 1, "the page did not move", file: file, line: line)
        XCTAssertEqual(b1.width, b0.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(b1.height, b0.height, accuracy: 1, "the zoom did not change", file: file, line: line)
    }

    // MARK: - Cases

    func testOnALegalPageABoxAtTheFootSendsTheBarToTheTop() throws {
        launch(["--legalDoc"])
        // The document took: two pages, and a page taller than Letter.
        XCTAssertTrue(counter.label.hasPrefix("Page 1 of 2,"), "the Legal document loaded (counter \(counter.label))")
        let c = canvas
        // The Legal page's sides are read 45 pt under its top, between its
        // second and third text lines (Scripts/generate_uitest_legal.py).
        let page = try XCTUnwrap(try probe().fitPage(aspect: 1008.0 / 612.0, sideRow: 45), "the Legal page at fit is measurable")
        let shot = try probe()
        XCTAssertTrue(shot.isBackground(CGPoint(x: page.minX + 6, y: page.maxY + 4)), "below the page's foot is canvas")
        XCTAssertFalse(shot.isBackground(CGPoint(x: page.minX + 6, y: page.maxY - 4)), "above the page's foot is page")
        XCTAssertGreaterThan(page.maxY, c.maxY - 60, "the page ends near the canvas's foot, as a Legal page at fit does")

        drawBox(from: CGPoint(x: page.minX + 0.30 * page.width, y: page.maxY - 53),
                to: CGPoint(x: page.minX + 0.60 * page.width, y: page.maxY - 25))
        let (b0, b1, barFrame) = select()
        XCTContext.runActivity(named: "the bar's tree frame: \(barFrame)") { _ in }
        XCTAssertEqual(barFrame.height, 44, accuracy: 1, "the bar's frame is its glass")
        assertTopPlace(b0: b0, b1: b1, bar: barFrame, canvas: c)
        attachScreenshot(named: "legal-foot-bar-at-top")

        // Its bottom handle drags the box down; the bar stays clear of it.
        point(CGPoint(x: b1.midX, y: b1.maxY + 4)).press(forDuration: 0.2,
            thenDragTo: point(CGPoint(x: b1.midX, y: b1.maxY + 20)), withVelocity: .slow, thenHoldForDuration: 0.2)
        let b2 = settledFrame(box)
        let bar2 = settledFrame(bar)
        XCTAssertEqual(b2.height, b1.height + 16, accuracy: 4, "the bottom handle resized the box")
        XCTAssertTrue(clear(b2, of: bar2), "after the resize the box is clear of the bar (box \(b2), bar \(bar2))")
        XCTAssertEqual(bar2.minY - c.minY, Self.gap, accuracy: 1, "the bar is still at the top")
        attachScreenshot(named: "legal-foot-resized")

        // Delete, then Undo: the box comes back selected, the bar at the top again, nothing moved.
        app.descendants(matching: .any).matching(identifier: "selectionBarDelete").firstMatch.tap()
        XCTAssertTrue(waitForRegionCount(0), "Delete removed the box")
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5), "with nothing selected the bar leaves")
        app.buttons["undoButton"].tap()
        XCTAssertTrue(waitForRegionCount(1), "Undo brought the box back")
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "the box came back selected, with the bar")
        sleep(1)
        let b3 = settledFrame(box)
        let bar3 = settledFrame(bar)
        XCTAssertEqual(b3.minY, b2.minY, accuracy: 1, "nothing scrolled back")
        XCTAssertEqual(bar3.minY - c.minY, Self.gap, accuracy: 1, "the bar is at the top again")
        XCTAssertTrue(clear(b3, of: bar3))
    }

    func testAtTheLargestTextSizeABoxAtTheFootOfALetterPageSendsTheBarToTheTop() throws {
        launch(["--multipageDoc", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        // The size took: the page counter stacks at every accessibility size.
        XCTAssertGreaterThan(counter.frame.height, 40, "the largest text size is in effect")
        let c = canvas
        let page = try XCTUnwrap(try probe().fitPage(), "the Letter page at fit is measurable")
        XCTAssertGreaterThan(page.maxY, c.maxY - 68, "at this size the bar's bottom place lies over the page's foot")
        drawBox(from: CGPoint(x: page.minX + 0.30 * page.width, y: page.maxY - 50),
                to: CGPoint(x: page.minX + 0.60 * page.width, y: page.maxY - 26))
        let (b0, b1, barFrame) = select()
        assertTopPlace(b0: b0, b1: b1, bar: barFrame, canvas: c)
        attachScreenshot(named: "largest-letter-foot-bar-at-top")
    }

    func testZoomedInABoxAtTheCanvasFootSendsTheBarToTheTop() throws {
        launch(["--multipageDoc"])
        let c = canvas
        let page = try XCTUnwrap(try probe().fitPage(), "the Letter page at fit is measurable")
        drawBox(from: CGPoint(x: page.minX + 0.30 * page.width, y: page.maxY - 50),
                to: CGPoint(x: page.minX + 0.60 * page.width, y: page.maxY - 26))
        XCTAssertTrue(try pinchToZoom(above: page), "the page zoomed in")
        for _ in 0..<4 {
            point(CGPoint(x: 14, y: c.maxY - 100)).press(forDuration: 0.01,
                thenDragTo: point(CGPoint(x: 14, y: c.minY + 60)), withVelocity: .fast, thenHoldForDuration: 0)
        }
        sleep(2)
        let before = settledFrame(box)
        XCTAssertGreaterThan(before.maxY, c.maxY - 80, "the box is at the canvas's foot (box \(before), canvas \(c))")
        let (b0, b1, barFrame) = select()
        assertTopPlace(b0: b0, b1: b1, bar: barFrame, canvas: c)
    }

    func testOnALetterPageAtFitABoxAtTheFootLeavesTheBarAtTheBottom() throws {
        launch(["--multipageDoc"])
        let c = canvas
        let page = try XCTUnwrap(try probe().fitPage(), "the Letter page at fit is measurable")
        drawBox(from: CGPoint(x: page.minX + 0.30 * page.width, y: page.maxY - 22),
                to: CGPoint(x: page.minX + 0.60 * page.width, y: page.maxY - 4))
        let (b0, b1, barFrame) = select()
        XCTAssertEqual(b1.minY, b0.minY, accuracy: 1, "nothing moved")
        XCTAssertEqual(b1.height, b0.height, accuracy: 1)
        XCTAssertGreaterThan(barFrame.minY, c.midY, "the bar is at its bottom place (bar \(barFrame))")
        let after = try XCTUnwrap(try probe().fitPage())
        XCTAssertEqual(after.minY, page.minY, accuracy: 1, "the page did not move")
        let reached = b1.insetBy(dx: -Self.reach, dy: -Self.reach).intersection(page)
        XCTAssertFalse(reached.intersects(barFrame.insetBy(dx: -Self.gap, dy: -Self.gap)),
                       "the box and its handles, cut to the page, are clear of the bar")
    }

    func testWhileTheFitNoticeHoldsTheBandABoxAtTheFootLeavesTheBarAtTheBottom() throws {
        // Page 1's Search result is marked as drawn wider than its word
        // (--uitestWidenPage=0) and applied, so the fit notice holds the
        // editor's band. Its box sits on the page's last line, where the bar's
        // bottom place lies over it at fit: with no notice the bar would go to
        // the top. A notice in the band keeps it at the bottom (settled point 7).
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--legalDoc", "--openSearchSheet",
                               "--searchQuery=strip", "--searchDetent=medium", "--uitestWidenPage=0"]
        app.launch()
        let banner = app.descendants(matching: .any).matching(identifier: "widenedBoxBanner").firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 60), "the Search sheet names the page with widened boxes")
        let selectAll = app.buttons["footerSelectAllButton"].firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 10), "the Search sheet shows Select All")
        selectAll.tap()
        let apply = app.buttons["searchApplyButton"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: apply)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 10), .completed)
        apply.tap()
        let dismiss = app.buttons["searchDismissButton"]
        if dismiss.waitForExistence(timeout: 10) { dismiss.tap() }
        XCTAssertTrue(dismiss.waitForNonExistence(timeout: 10), "the Search sheet closed")
        XCTAssertTrue(app.buttons["drawTool"].waitForExistence(timeout: 30), "the editor is back")
        // The apply's own notice leaves the band first; then the fit notice
        // is the only notice there.
        let marked = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Marked'")).firstMatch
        XCTAssertTrue(marked.waitForNonExistence(timeout: 30), "the apply's notice left the band")
        XCTAssertTrue(counter.label.hasPrefix("Page 1 of 2,"), "page 1 is in view (counter \(counter.label))")
        let open = app.descendants(matching: .any).matching(identifier: "fitNotice").firstMatch
        let folded = app.descendants(matching: .any).matching(identifier: "noticeFoldedMark")
            .matching(NSPredicate(format: "label CONTAINS 'than their words'")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10) || folded.exists, "the fit notice holds the band")

        let c = canvas
        let shown = app.buttons.matching(NSPredicate(format: "label MATCHES 'Redaction (region|box) [0-9]+'"))
            .allElementsBoundByIndex.filter { c.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        XCTAssertEqual(shown.count, 1, "page 1 shows one box, on its last line")
        let foot = try XCTUnwrap(shown.first)
        let b0 = settledFrame(foot)
        XCTAssertGreaterThan(b0.maxY, c.maxY - 80, "the box is at the canvas's foot (box \(b0), canvas \(c))")
        point(CGPoint(x: b0.midX, y: b0.midY)).tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "selecting the box shows the selection bar")
        let barFrame = settledFrame(bar)
        XCTAssertFalse(clear(settledFrame(foot), of: barFrame),
                       "the box meets the bar's bottom place (box \(b0), bar \(barFrame))")
        XCTAssertGreaterThan(barFrame.minY, c.midY,
                             "with the fit notice in the band the bar stays at the bottom (bar \(barFrame))")
        attachScreenshot(named: "fit-notice-bar-at-bottom")
    }
}
