import XCTest

/// UI tests for the editor's chrome: the page bar's whole-page control as a
/// per-page toggle that keeps its place, the page bar on a one-page
/// document, and the page bar back once a parked match walk ends.
///
/// Launch arguments only; every assertion reads identifiers and labels.
/// nonisolated for the same reason as `SearchDetentLayoutUITests`: an
/// XCUITest drives a separate process and touches no @MainActor state.
nonisolated final class EditorChromeUITests: XCTestCase {

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

    /// Wait until `element`'s label equals `label`.
    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 8) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: - Mark ↔ Unmark

    func testWholePageControl_marksThenUnmarksInPlace() {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"]
        app.launch()

        let control = app.buttons["pageNavMarkWholePage"]
        XCTAssertTrue(control.waitForExistence(timeout: 30), "The page bar's whole-page control never appeared.")
        let counter = element("pageNavCounter")
        XCTAssertTrue(waitForLabel(counter, "Page 1 of 23, 0 regions"),
                      "An empty page's counter must speak its zero count; it read '\(counter.label)'.")
        XCTAssertEqual(control.label, "Mark Whole Page")
        let xBefore = control.frame.midX

        control.tap()
        XCTAssertTrue(waitForLabel(counter, "Page 1 of 23, 1 region"),
                      "Mark Whole Page must add one region; the counter read '\(counter.label)'.")
        XCTAssertTrue(waitForLabel(control, "Unmark Whole Page"), "A marked page's control must read Unmark Whole Page.")
        XCTAssertTrue(control.isSelected, "A marked page's control must report itself selected.")
        XCTAssertEqual(control.frame.midX, xBefore, accuracy: 0.5,
                       "The control must keep its place when the count appears.")
        attachScreenshot(named: "chrome-page-bar-marked")

        control.tap()
        XCTAssertTrue(waitForLabel(counter, "Page 1 of 23, 0 regions"),
                      "Unmark Whole Page must remove the region; the counter read '\(counter.label)'.")
        XCTAssertTrue(waitForLabel(control, "Mark Whole Page"))
        XCTAssertFalse(control.isSelected)
        XCTAssertEqual(control.frame.midX, xBefore, accuracy: 0.5)
    }

    // MARK: - The control at large text sizes

    /// The largest text size, and Accessibility 1, the first size above the
    /// symbol's ceiling. A wrong name is ignored and the app runs at the
    /// default size, so each launch checks that its size took.
    private static let largestTextSize = "UICTContentSizeCategoryAccessibilityXXXL"
    private static let accessibilityOne = "UICTContentSizeCategoryAccessibilityM"

    /// Launch the multi-page document at `textSize` (nil: the default) and
    /// return the whole-page control.
    private func launchWholePageControl(atTextSize textSize: String?) -> XCUIElement {
        var arguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"]
        if let textSize { arguments += ["-UIPreferredContentSizeCategoryName", textSize] }
        app.launchArguments = arguments
        app.launch()
        let control = app.buttons["pageNavMarkWholePage"]
        XCTAssertTrue(control.waitForExistence(timeout: 30), "The page bar's whole-page control never appeared.")
        if textSize != nil {
            // At an accessibility size the counter stacks its two lines.
            let counter = element("pageNavCounter")
            XCTAssertTrue(counter.waitForExistence(timeout: 10))
            XCTAssertGreaterThan(counter.frame.height, 40,
                                 "The text size did not take: the counter is \(counter.frame.height) pt tall.")
        }
        return control
    }

    private func screenshotProbe() throws -> CanvasPixelProbe {
        try XCTUnwrap(CanvasPixelProbe(XCUIScreen.main.screenshot(), windowSize: app.windows.firstMatch.frame.size))
    }

    /// Mark the page, then: at 8 points on a circle of radius 19 pt round
    /// the control's centre the disc shows teal, and the symbol's middle is
    /// white.
    private func markAndCheckTheDisc(_ control: XCUIElement, screenshot name: String) throws {
        control.tap()
        XCTAssertTrue(waitForLabel(control, "Unmark Whole Page"), "A marked page's control must read Unmark Whole Page.")
        let probe = try screenshotProbe()
        attachScreenshot(named: name)
        let centre = CGPoint(x: control.frame.midX, y: control.frame.midY)
        for step in 0..<8 {
            let angle = CGFloat(step) * .pi / 4
            let (r, g, b) = probe.rgb(centre.x + 19 * cos(angle), centre.y + 19 * sin(angle))
            XCTAssertTrue(CanvasPixelProbe.Tint.teal.matches(r, g, b),
                          "The disc must show teal \(step * 45)° round the symbol; it read (\(r), \(g), \(b)).")
        }
        let (r, g, b) = probe.rgb(centre.x, centre.y)
        XCTAssertTrue(r >= 235 && g >= 235 && b >= 235,
                      "The marked symbol's middle must be white; it read (\(r), \(g), \(b)).")
    }

    func testWholePageControl_atTheLargestTextSize_symbolStaysInsideItsDisc() throws {
        let control = launchWholePageControl(atTextSize: Self.largestTextSize)
        XCTAssertTrue(waitForLabel(control, "Mark Whole Page"))
        let unmarked = try screenshotProbe()
        attachScreenshot(named: "chrome-whole-page-largest-unmarked")
        let symbol = try XCTUnwrap(unmarked.tintBounds(.teal, in: control.frame), "No teal symbol inside the control.")
        XCTAssertLessThanOrEqual(symbol.width, 30, "The unmarked symbol must stop growing at its ceiling; it is \(symbol.width) pt wide.")
        XCTAssertLessThanOrEqual(symbol.height, 24, "The unmarked symbol must stop growing at its ceiling; it is \(symbol.height) pt tall.")
        try markAndCheckTheDisc(control, screenshot: "chrome-whole-page-largest-marked")
    }

    func testWholePageControl_atAccessibilityOne_symbolStaysInsideItsDisc() throws {
        let control = launchWholePageControl(atTextSize: Self.accessibilityOne)
        XCTAssertTrue(waitForLabel(control, "Mark Whole Page"))
        try markAndCheckTheDisc(control, screenshot: "chrome-whole-page-accessibility-one-marked")
    }

    func testWholePageControl_atTheDefaultSize_discIsUnchanged() throws {
        let control = launchWholePageControl(atTextSize: nil)
        XCTAssertTrue(waitForLabel(control, "Mark Whole Page"))
        try markAndCheckTheDisc(control, screenshot: "chrome-whole-page-default-marked")
        let disc = try XCTUnwrap(try screenshotProbe().tintBounds(.teal, in: control.frame), "No teal disc inside the control.")
        XCTAssertEqual(disc.width, 44, accuracy: 1, "The default size's disc must stay 44 pt wide.")
        XCTAssertEqual(disc.height, 44, accuracy: 1, "The default size's disc must stay 44 pt tall.")
    }

    // MARK: - The bar's order

    /// The bar's four pieces, left to right: the whole-page control,
    /// Previous, the counter, Next. Each ends before the next begins, and
    /// the control is one stack gap (16 pt) from Previous: the hairline
    /// between them adds no width.
    private func checkTheBarLeadsWithTheControl(_ control: XCUIElement) -> [XCUIElement] {
        let previous = app.buttons["pageNavPrevious"]
        let counter = element("pageNavCounter")
        let next = app.buttons["pageNavNext"]
        XCTAssertTrue(previous.waitForExistence(timeout: 10))
        XCTAssertTrue(counter.waitForExistence(timeout: 10))
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        let pieces = [control, previous, counter, next]
        let names = ["the whole-page control", "Previous", "the counter", "Next"]
        for i in 0..<(pieces.count - 1) {
            XCTAssertLessThanOrEqual(pieces[i].frame.maxX, pieces[i + 1].frame.minX + 0.5,
                                     "\(names[i]) must end before \(names[i + 1]) begins: \(pieces[i].frame) then \(pieces[i + 1].frame).")
        }
        XCTAssertEqual(previous.frame.minX - control.frame.maxX, 16, accuracy: 0.5,
                       "The control must sit one stack gap from Previous: \(control.frame) then \(previous.frame).")
        return pieces
    }

    func testPageBar_wholePageControlLeadsTheBar() {
        let control = launchWholePageControl(atTextSize: nil)
        _ = checkTheBarLeadsWithTheControl(control)
        let bar = element("pageNav")
        XCTAssertTrue(bar.exists)
        print("page bar width at the default size: \(bar.frame.width) pt")
        attachScreenshot(named: "chrome-page-bar-default-control-first")
    }

    func testPageBarCount_isNotOrangeOnAPageWithABox() throws {
        let control = launchWholePageControl(atTextSize: nil)
        let counter = element("pageNavCounter")
        XCTAssertTrue(counter.waitForExistence(timeout: 10))
        control.tap()
        XCTAssertTrue(waitForLabel(counter, "Page 1 of 23, 1 region"),
                      "Mark Whole Page must add one region; the counter read '\(counter.label)'.")
        let probe = try screenshotProbe()
        attachScreenshot(named: "chrome-page-bar-count-with-a-box")
        XCTAssertNil(probe.tintBounds(.red, in: counter.frame),
                     "The count on a page with a box must be the support grey, not orange.")
    }

    func testPageBar_atTheLargestTextSize_controlLeadsAndNothingIsCut() {
        let control = launchWholePageControl(atTextSize: Self.largestTextSize)
        let pieces = checkTheBarLeadsWithTheControl(control)
        let window = app.windows.firstMatch.frame
        let bar = element("pageNav")
        XCTAssertTrue(bar.exists)
        for piece in pieces + [bar] {
            XCTAssertTrue(window.contains(piece.frame),
                          "Every piece of the bar must lie inside the window \(window) at the largest text size: \(piece.frame).")
        }
        print("page bar width at the largest text size: \(bar.frame.width) pt")
        attachScreenshot(named: "chrome-page-bar-largest-control-first")
    }

    // MARK: - The one-page bar

    func testOnePageDocument_showsTheCountWithoutArrowsOrControl() {
        app.launchArguments = ["--uitesting", "--loadTestDocument"]
        app.launch()

        let counter = element("pageNavCounter")
        XCTAssertTrue(counter.waitForExistence(timeout: 30), "A one-page document must show the page bar's counter.")
        XCTAssertTrue(waitForLabel(counter, "Page 1 of 1, 0 regions"),
                      "The one-page counter read '\(counter.label)'.")
        XCTAssertTrue(app.staticTexts["1 of 1"].exists, "The drawn counter must read '1 of 1'.")
        XCTAssertFalse(app.buttons["pageNavPrevious"].exists, "No page arrows on a one-page document.")
        XCTAssertFalse(app.buttons["pageNavNext"].exists, "No page arrows on a one-page document.")
        XCTAssertFalse(app.buttons["pageNavMarkWholePage"].exists,
                       "No whole-page control on a one-page document; the … menu keeps the action.")
        attachScreenshot(named: "chrome-page-bar-one-page")
    }

    // MARK: - The page bar comes back when the walk ends

    /// The bar steps aside while the walk is parked and is back, usable,
    /// once the sheet is dismissed and the walk ends.
    func testWalkEnds_pageBarReturns() {
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--multipageDoc",
            "--openSearchSheet", "--searchQuery=Amount", "--searchDetent=medium",
        ]
        app.launch()
        let next = app.buttons["resultNavNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 30), "The seeded query returned nothing or the sheet never presented.")
        next.tap()
        XCTAssertTrue(element("compactFloatStrip").waitForExistence(timeout: 10), "The first chevron tap did not park the sheet.")
        let pageBar = element("pageNav")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: pageBar)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "The page bar must step aside while the walk is parked.")

        let dismiss = raiseSheetToDismiss()
        XCTAssertNotNil(dismiss, "The sheet's Dismiss never appeared after the raise.")
        dismiss?.tap()
        let pageNext = app.buttons["pageNavNext"]
        XCTAssertTrue(pageNext.waitForExistence(timeout: 10), "The page bar must be back once the walk ends.")
        XCTAssertTrue(pageNext.isHittable, "The page bar's next control must be usable once the walk ends.")
        let counter = element("pageNavCounter")
        let before = counter.label
        pageNext.tap()
        let paged = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", before), object: counter)
        XCTAssertEqual(XCTWaiter().wait(for: [paged], timeout: 8), .completed, "The returned page bar must page.")
        attachScreenshot(named: "chrome-walk-ended-page-bar-back")
    }

    /// Grabber drag from the parked strip up until the sheet's Dismiss
    /// shows (`ResultWalkUITests`' idiom); the Dismiss, or nil.
    private func raiseSheetToDismiss() -> XCUIElement? {
        let window = app.windows.firstMatch
        let dismiss = app.buttons["searchDismissButton"].firstMatch
        for _ in 0..<3 {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            start.press(forDuration: 0.1, thenDragTo: end)
            if dismiss.waitForExistence(timeout: 3), dismiss.isHittable { return dismiss }
        }
        return nil
    }
}
