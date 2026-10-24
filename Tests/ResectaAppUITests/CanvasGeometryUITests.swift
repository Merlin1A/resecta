import XCTest

/// The canvas's geometry on the 23-page fixture: which region a touch picks
/// on applied one-line regions, and what a touch does at 2x. The "Amount"
/// search applied on the 23-page fixture puts a stack of one-line boxes on
/// page 1, a few points apart at the fit zoom; a tap or a hold at a box's
/// centre must pick that box, not the one below it. Boxes are read by tint
/// (`CanvasPixelProbe`): applied boxes are green.
///
/// nonisolated: an XCUITest drives a separate process and touches no
/// @MainActor state.
nonisolated final class CanvasGeometryUITests: XCTestCase {

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

    // MARK: - Applied one-line regions

    func testTapAtARowCentreSelectsThatRow() throws {
        let stack = try applyAmountStack()
        let row = 10
        let before = try stack.rows(in: probe(), tint: .green)
        XCTAssertEqual(before.count, Stack.rowCount, "the applied stack is on the page")
        tap(stack.centre(row))
        sleep(1)
        // The selected box's handles cover its one-line strip, so the
        // selection is read by deleting it: the box that goes is the one
        // the tap selected.
        let overflow = app.buttons["OverflowBarButtonItem"]
        XCTAssertTrue(overflow.waitForExistence(timeout: 10))
        overflow.tap()
        let delete = app.buttons["Delete Region"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the tap selected one region")
        delete.tap()
        XCTAssertTrue(waitForRegionCount(Stack.rowCount - 1))
        sleep(1)
        let after = try stack.rows(in: probe(), tint: .green)
        XCTAssertEqual(Set(before).subtracting(after), [row], "a tap at row \(row)'s centre selects row \(row)")
    }

    func testHoldAtARowCentreDeletesThatRow() throws {
        let stack = try applyAmountStack()
        let row = 10
        let before = try stack.rows(in: probe(), tint: .green)
        XCTAssertEqual(before.count, Stack.rowCount, "the applied stack is on the page")
        let count = currentRegionCount()
        point(stack.centre(row)).press(forDuration: 0.8)
        let delete = app.buttons["Delete Region"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the hold opens the region's menu")
        delete.tap()
        XCTAssertTrue(waitForRegionCount(count - 1), "one region is deleted")
        sleep(1)
        let after = try stack.rows(in: probe(), tint: .green)
        XCTAssertEqual(Set(before).subtracting(after), [row], "the hold at row \(row)'s centre deletes row \(row)")
    }

    // MARK: - At 2x

    func testAtZoomADragOnASelectedBoxMovesItAndAMarqueeSelects() throws {
        launchMultipage()
        let page = try fitPage()
        let boxA = CGRect(x: page.minX + page.width * 0.15, y: page.minY + page.height * 0.42, width: page.width * 0.25, height: 30)
        let boxB = CGRect(x: page.minX + page.width * 0.6, y: boxA.minY, width: page.width * 0.25, height: 30)
        drawBoxes([boxA, boxB])
        tap(CGPoint(x: boxA.midX, y: boxA.midY))
        sleep(1)
        XCTAssertTrue(try pinchToZoom(above: page), "the pinch zooms the page")
        let before = try probe()
        let a0 = try XCTUnwrap(before.tintBounds(.blue, in: CGRect(x: 0, y: 0, width: window.frame.width / 2, height: window.frame.height)), "A is selected")
        let b0 = try XCTUnwrap(before.tintBounds(.red, in: CGRect(x: window.frame.width / 2, y: 0, width: window.frame.width / 2, height: window.frame.height)))
        point(CGPoint(x: a0.midX, y: a0.midY)).press(forDuration: 0.05, thenDragTo: point(CGPoint(x: a0.midX, y: a0.midY - 60)))
        sleep(2)
        let after = try probe()
        let a1 = try XCTUnwrap(after.tintBounds(.blue, in: CGRect(x: 0, y: 0, width: window.frame.width / 2, height: window.frame.height)))
        let b1 = try XCTUnwrap(after.tintBounds(.red, in: CGRect(x: window.frame.width / 2, y: 0, width: window.frame.width / 2, height: window.frame.height)))
        XCTAssertLessThan(a1.midY, a0.midY - 40, "the selected box moved up with the finger")
        XCTAssertEqual(b1.midY, b0.midY, accuracy: 2, "its neighbour stayed: the page did not scroll")

        setAddToSelection(on: true)
        point(CGPoint(x: window.frame.width - 12, y: b1.minY - 30)).press(forDuration: 0.05,
            thenDragTo: point(CGPoint(x: b1.minX - 10, y: b1.maxY + 30)))
        sleep(1)
        XCTAssertEqual(deleteRow(), "Delete 2 Regions", "the marquee at zoom adds the neighbour")
    }

    func testAtZoomADoubleTapOnABoxKeepsTheZoom() throws {
        launchMultipage()
        let page = try fitPage()
        let box = CGRect(x: page.minX + page.width * 0.3, y: page.minY + page.height * 0.42, width: page.width * 0.3, height: 40)
        drawBoxes([box])
        tap(CGPoint(x: box.midX, y: box.midY))
        sleep(1)
        XCTAssertTrue(try pinchToZoom(above: page), "the pinch zooms the page")
        let zoomed = try probe()
        let b = try XCTUnwrap(zoomed.tintBounds(.blue, in: CGRect(origin: .zero, size: window.frame.size)), "the selected box at zoom")
        point(CGPoint(x: b.midX, y: b.midY)).doubleTap()
        sleep(2)
        XCTAssertFalse(try probe().isBackground(CGPoint(x: page.midX, y: page.minY - 8)), "a double tap on a box keeps the zoom")
    }

    func testTheZoomSurvivesTheSearchSheetsMoves() throws {
        launchMultipage(extra: ["--searchQuery=Amount"])
        let page = try fitPage()
        let above = CGPoint(x: page.midX, y: page.minY - 8)
        XCTAssertTrue(try pinchToZoom(above: page), "the pinch zooms the page")
        app.buttons["searchRedact"].tap()
        let dismiss = app.buttons["searchDismissButton"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 15), "the search sheet opened")
        sleep(2)
        let list = app.descendants(matching: .any).matching(identifier: "searchResultsList").firstMatch
        let strip = app.descendants(matching: .any).matching(identifier: "compactFloatStrip").firstMatch
        if list.waitForExistence(timeout: 10) {
            for _ in 0..<3 where !strip.exists {
                list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                    .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
                _ = strip.waitForExistence(timeout: 3)
            }
        }
        XCTAssertTrue(strip.exists, "the sheet parked")
        sleep(1)
        XCTAssertFalse(try probe().isBackground(above), "parked: still zoomed")
        point(CGPoint(x: window.frame.width / 2, y: window.frame.height * 0.95))
            .press(forDuration: 0.1, thenDragTo: point(CGPoint(x: window.frame.width / 2, y: window.frame.height * 0.45)))
        sleep(2)
        XCTAssertFalse(try probe().isBackground(above), "raised: still zoomed")
        if dismiss.waitForExistence(timeout: 5) { dismiss.tap() }
        _ = dismiss.waitForNonExistence(timeout: 10)
        sleep(2)
        XCTAssertFalse(try probe().isBackground(above), "dismissed: still zoomed")
    }
}

// MARK: - Helpers

private extension CanvasGeometryUITests {

    /// The "Amount" boxes on page 1 of the fixture: one per ledger row,
    /// "Amount" set at x 180–212.4 of the 612-point page on baselines
    /// 472 − 13·row (Scripts/generate_uitest_multipage.py). Rows are placed
    /// from that geometry and read by tint at each box's left strip, clear of
    /// the search badge at its top right.
    nonisolated struct Stack {
        static let rowCount = 28
        let page: CGRect
        var scale: CGFloat { page.width / 612 }
        func centre(_ row: Int) -> CGPoint {
            CGPoint(x: page.minX + 196.2 * scale, y: page.minY + (792 - (472 - 13 * CGFloat(row) + 2.5)) * scale)
        }
        /// The rows whose box shows `tint` at its left strip.
        func rows(in probe: CanvasPixelProbe, tint: CanvasPixelProbe.Tint) -> [Int] {
            (0..<Self.rowCount).filter { row in
                let y = centre(row).y, x = page.minX + 182.5 * scale
                let hits = [-1.5, -0.75, 0, 0.75, 1.5].filter { dy in
                    let (r, g, b) = probe.rgb(x, y + dy)
                    return tint.matches(r, g, b)
                }
                return hits.count >= 3
            }
        }
    }

    nonisolated var window: XCUIElement { app.windows.firstMatch }

    nonisolated func probe() throws -> CanvasPixelProbe {
        try XCTUnwrap(CanvasPixelProbe(XCUIScreen.main.screenshot(), windowSize: window.frame.size))
    }

    nonisolated func point(_ p: CGPoint) -> XCUICoordinate {
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x, dy: p.y))
    }

    nonisolated func tap(_ p: CGPoint) { point(p).tap() }

    nonisolated var counter: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "pageNavCounter").firstMatch
    }

    nonisolated func currentRegionCount() -> Int {
        guard counter.waitForExistence(timeout: 5) else { return -1 }
        let label = counter.label
        guard let match = label.range(of: #"(\d+) regions?"#, options: .regularExpression) else { return 0 }
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

    /// Search "Amount", Select All, Apply, Dismiss; then read the page at
    /// fit and the stack of applied boxes down the "Amount" column
    /// (x = 196.2 of the 612-point page, generate_uitest_multipage.py).
    nonisolated func applyAmountStack() throws -> Stack {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc",
                               "--openSearchSheet", "--searchQuery=Amount", "--searchDetent=medium"]
        app.launch()
        let selectAll = app.buttons["footerSelectAllButton"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 40), "the seeded search never listed its results")
        selectAll.tap()
        let apply = app.buttons["searchApplyButton"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10))
        let enabled = NSPredicate(format: "isEnabled == true")
        _ = XCTWaiter.wait(for: [expectation(for: enabled, evaluatedWith: apply)], timeout: 10)
        apply.tap()
        let dismiss = app.buttons["searchDismissButton"]
        if dismiss.waitForExistence(timeout: 10) { dismiss.tap() }
        _ = dismiss.waitForNonExistence(timeout: 10)
        let toast = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Text layer detected'")).firstMatch
        if toast.waitForExistence(timeout: 4) { _ = toast.waitForNonExistence(timeout: 20) }
        sleep(2)
        let page = try XCTUnwrap(try probe().fitPage(), "the page at fit is measurable")
        return Stack(page: page)
    }

    nonisolated func launchMultipage(extra: [String] = []) {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["drawTool"].waitForExistence(timeout: 60), "the editor never appeared")
        let toast = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Text layer detected'")).firstMatch
        if toast.waitForExistence(timeout: 4) { _ = toast.waitForNonExistence(timeout: 20) }
        sleep(1)
    }

    nonisolated func fitPage() throws -> CGRect {
        try XCTUnwrap(try probe().fitPage(), "the page at fit is measurable")
    }

    nonisolated func setDrawTool(_ value: String) {
        let tool = app.buttons["drawTool"]
        for _ in 0..<3 {
            tool.tap()
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                if (tool.value as? String) == value { return }
                usleep(250_000)
            }
        }
        XCTFail("The Rectangle tool never read \(value).")
    }

    nonisolated func drawBoxes(_ boxes: [CGRect]) {
        let count = currentRegionCount()
        setDrawTool("Drawing mode active")
        for box in boxes {
            point(CGPoint(x: box.minX, y: box.minY)).press(forDuration: 0.05,
                thenDragTo: point(CGPoint(x: box.maxX, y: box.maxY)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        setDrawTool("Tap to enter drawing mode")
        XCTAssertTrue(waitForRegionCount(count + boxes.count), "the boxes drew")
    }

    /// Pinch PDFKit's scroll view (the tallest) 2x, proven by the canvas
    /// background just above the fit page turning page-white.
    nonisolated func pinchToZoom(above page: CGRect) throws -> Bool {
        let probePoint = CGPoint(x: page.midX, y: page.minY - 8)
        let canvas = app.scrollViews.allElementsBoundByIndex.max { $0.frame.height < $1.frame.height } ?? app.scrollViews.firstMatch
        for _ in 1...2 {
            canvas.pinch(withScale: 2.0, velocity: 1.0)
            sleep(3)
            if try !probe().isBackground(probePoint) { return true }
        }
        return false
    }

    nonisolated func openOverflow() {
        let overflow = app.buttons["OverflowBarButtonItem"]
        XCTAssertTrue(overflow.waitForExistence(timeout: 10))
        overflow.tap()
        _ = app.buttons["Add to Selection"].waitForExistence(timeout: 5)
    }

    nonisolated func dismissMenus() {
        counter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        usleep(500_000)
    }

    nonisolated func setAddToSelection(on: Bool) {
        openOverflow()
        let row = app.buttons["Add to Selection"]
        let isOn = (row.value as? String).map { $0.hasPrefix("On") || $0 == "1" } ?? row.isSelected
        if isOn != on { row.tap() } else { dismissMenus() }
        usleep(500_000)
    }

    /// The overflow menu's delete row's label, or nil when it offers none.
    nonisolated func deleteRow() -> String? {
        openOverflow()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete'")).firstMatch
        let label = row.waitForExistence(timeout: 2) ? row.label : nil
        dismissMenus()
        return label
    }
}
