import XCTest

/// Which region a touch picks on applied one-line regions. The "Amount"
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
}
