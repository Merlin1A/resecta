import XCTest

/// The canvas's regions in the accessibility tree. The overlay builds one
/// element per region ("Redaction region N", with a hint to select or
/// delete it), but the page view PDFKit hosts the overlay in served none of
/// them, so VoiceOver could not reach a region, the whole-page cover or its
/// Delete. With a whole-page region and a drawn box on the page, both must
/// be in the tree, on the page.
///
/// nonisolated: an XCUITest drives a separate process and touches no
/// @MainActor state.
nonisolated final class CanvasRegionAccessibilityUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"]
        app.launch()
        XCTAssertTrue(app.buttons["drawTool"].waitForExistence(timeout: 60), "the editor never appeared")
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    func testRegionsAreInTheAccessibilityTree() {
        let mark = app.buttons["pageNavMarkWholePage"]
        XCTAssertTrue(mark.waitForExistence(timeout: 10))
        mark.tap()
        XCTAssertTrue(waitForRegionCount(1), "Mark Whole Page added a region")

        let tool = app.buttons["drawTool"]
        tool.tap()
        XCTAssertTrue(waitForValue(tool, "Drawing mode active"))
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.40))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.47)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
        tool.tap()
        XCTAssertTrue(waitForValue(tool, "Tap to enter drawing mode"))
        XCTAssertTrue(waitForRegionCount(2), "the box drew")

        let regions = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Redaction region'"))
        XCTAssertTrue(regions.firstMatch.waitForExistence(timeout: 10), "the regions are in the accessibility tree")
        XCTAssertEqual(regions.count, 2, "one element per region")
        let page = window.frame
        for element in regions.allElementsBoundByIndex {
            XCTAssertTrue(page.intersects(element.frame), "\(element.label) lies on screen: \(element.frame)")
        }
    }

    /// A box drawn while the Search sheet is parked, then the sheet raised
    /// and closed: the canvas grows, the page settles lower and the box with
    /// it, and the box's element must follow it there. Before, each element's
    /// frame was fixed in screen coordinates when the list was built, and
    /// nothing rebuilt the list when the page moved without the overlay being
    /// laid out again, so the frame stayed where the box had been.
    func testABoxsElementStaysOnTheBoxWhenTheSearchSheetCloses() throws {
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--multipageDoc",
            "--openSearchSheet", "--searchDetent=compact",
        ]
        app.launch()
        XCTAssertTrue(compactFloatStrip.waitForExistence(timeout: 30), "The sheet never parked at the compact float.")
        XCTAssertTrue(app.buttons["drawTool"].waitForExistence(timeout: 30), "the editor never appeared")
        sleep(1)

        drawBox(CGRect(x: 60, y: 300, width: 140, height: 40))
        let box = regionElement
        XCTAssertTrue(box.waitForExistence(timeout: 10), "the box is in the accessibility tree")

        // The canvas is not dimmed while the sheet is parked.
        let before = try XCTUnwrap(try settledDrawnBounds(), "the box's red line is on the parked canvas")
        attachScreenshot(named: "box-element-sheet-parked")
        assertOnTheBox(box.frame, before, "with the sheet parked")

        // No colour read while the sheet is up: the canvas is dimmed under it.
        expandCompactStripToMedium()
        let dismiss = app.buttons["searchDismissButton"].firstMatch
        dismiss.tap()
        XCTAssertTrue(dismiss.waitForNonExistence(timeout: 10), "the Search sheet did not close")
        XCTAssertTrue(compactFloatStrip.waitForNonExistence(timeout: 10), "the parked strip is still up")

        let after = try XCTUnwrap(try settledDrawnBounds(), "the box's red line settled once the sheet closed")
        attachScreenshot(named: "box-element-sheet-closed")
        XCTAssertGreaterThan(
            abs(after.minY - before.minY), 20,
            "the page moved when the sheet closed (drawn at \(before), then \(after))"
        )
        assertOnTheBox(regionElement.frame, after, "after the sheet closed")
    }

    /// A box on a fit page, then the page pinched larger: the box's element
    /// must be on the box at its new size and place.
    func testABoxsElementStaysOnTheBoxAfterAPinch() throws {
        let toast = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Text layer detected'")).firstMatch
        if toast.waitForExistence(timeout: 4) { _ = toast.waitForNonExistence(timeout: 20) }
        sleep(1)
        let page = try XCTUnwrap(try probe().fitPage(), "the page at fit is measurable")

        // Centred across the page, so the zoomed box stays on screen.
        drawBox(CGRect(x: page.midX - 70, y: 300, width: 140, height: 40))
        let box = regionElement
        XCTAssertTrue(box.waitForExistence(timeout: 10), "the box is in the accessibility tree")
        let before = try XCTUnwrap(try settledDrawnBounds(), "the box's red line is on the fit page")
        attachScreenshot(named: "box-element-fit-page")
        assertOnTheBox(box.frame, before, "on the fit page")

        XCTAssertTrue(try pinchToZoom(above: page), "the pinch zoomed the page")
        let after = try XCTUnwrap(try settledDrawnBounds(), "the box's red line settled after the pinch")
        attachScreenshot(named: "box-element-after-pinch")
        XCTAssertGreaterThanOrEqual(
            after.width, before.width * 1.2,
            "the pinch made the box larger (drawn at \(before), then \(after))"
        )
        let screen = window.frame
        XCTAssertTrue(
            after.minX > screen.minX + 1 && after.maxX < screen.maxX - 1,
            "the zoomed box is whole on screen, so its drawn bounds are its own: \(after)"
        )
        // The line is drawn with the page: 2 pt wide at fit, so 1 pt outside
        // the box there, and zoom times that once the page is zoomed. The
        // probe reads whole points, which adds up to 1 pt more. At fit this
        // is the 2 pt of the other reads. Measured on iOS 26.4.1 after a 2x
        // pinch: a zoom of about 1.78 (drawn width 142 pt, then 253 pt); read
        // from the pixels, the box's drawn edge lay 1.81 to 1.89 pt outside
        // the element's frame on all four sides, so the element was centred
        // on the box; the probe's whole-point read put the far sides at
        // 2.2 and 2.55 pt, over a flat 2 pt. The unfixed frame stayed at its
        // fit place, about 56 pt off.
        let zoom = after.width / before.width
        assertOnTheBox(regionElement.frame, after, "after the pinch", tolerance: zoom + 1)
    }
}

private extension CanvasRegionAccessibilityUITests {

    nonisolated func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.drawToolReads(value) { return true }
            usleep(250_000)
        }
        return false
    }

    nonisolated func waitForRegionCount(_ n: Int, timeout: TimeInterval = 8) -> Bool {
        let counter = app.descendants(matching: .any).matching(identifier: "pageNavCounter").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if counter.exists, let match = counter.label.range(of: #"(\d+) regions?"#, options: .regularExpression),
               Int(counter.label[match].split(separator: " ").first ?? "") == n { return true }
            usleep(250_000)
        }
        return false
    }
}

/// The reads the frame tests share: the box's element, the box's drawn
/// bounds from the screen's pixels, and the moves that shift the page.
private extension CanvasRegionAccessibilityUITests {

    nonisolated var window: XCUIElement { app.windows.firstMatch }

    nonisolated var compactFloatStrip: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "compactFloatStrip").firstMatch
    }

    nonisolated var regionElement: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Redaction region'")).firstMatch
    }

    nonisolated func probe() throws -> CanvasPixelProbe {
        try XCTUnwrap(CanvasPixelProbe(XCUIScreen.main.screenshot(), windowSize: window.frame.size))
    }

    nonisolated func point(_ p: CGPoint) -> XCUICoordinate {
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x, dy: p.y))
    }

    /// One box drawn with the Rectangle tool, the tool left off after.
    nonisolated func drawBox(_ box: CGRect) {
        let tool = app.buttons["drawTool"]
        tool.tap()
        XCTAssertTrue(waitForValue(tool, "Drawing mode active"))
        point(CGPoint(x: box.minX, y: box.minY)).press(forDuration: 0.05,
            thenDragTo: point(CGPoint(x: box.maxX, y: box.maxY)), withVelocity: .slow, thenHoldForDuration: 0.2)
        tool.tap()
        XCTAssertTrue(waitForValue(tool, "Tap to enter drawing mode"))
        XCTAssertTrue(waitForRegionCount(1), "the box drew")
    }

    /// The bounds of the box's red line once two screenshots 0.3 s apart
    /// show it in the same place; nil if it never settles or is not found.
    /// The line is 2 pt wide, so the drawn bounds are 1 pt outside the box.
    nonisolated func settledDrawnBounds(timeout: TimeInterval = 10) throws -> CGRect? {
        let size = window.frame.size
        let band = CGRect(x: 0, y: 60, width: size.width, height: size.height * 0.75 - 60)
        let deadline = Date().addingTimeInterval(timeout)
        var last = try probe().tintBounds(.red, in: band)
        while Date() < deadline {
            usleep(300_000)
            let next = try probe().tintBounds(.red, in: band)
            if let a = last, let b = next,
               abs(a.minX - b.minX) < 0.5, abs(a.minY - b.minY) < 0.5,
               abs(a.width - b.width) < 0.5, abs(a.height - b.height) < 0.5 {
                return b
            }
            last = next
        }
        return nil
    }

    /// The element's frame within `tolerance` (2 pt at fit) of the box's
    /// drawn bounds on each side.
    nonisolated func assertOnTheBox(_ frame: CGRect, _ drawn: CGRect, _ step: String, tolerance: CGFloat = 2,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let gaps = [frame.minX - drawn.minX, frame.minY - drawn.minY, frame.maxX - drawn.maxX, frame.maxY - drawn.maxY]
        XCTAssertTrue(
            gaps.allSatisfy { abs($0) <= tolerance },
            "\(step): the box's element is at \(frame), the box is drawn at \(drawn) (within \(tolerance) pt)",
            file: file, line: line
        )
    }

    /// Raise the parked sheet by its strip, as the detent tests do: a press
    /// and drag from the foot of the window to its middle, once more if the
    /// strip is still up, until the full sheet's Dismiss shows.
    nonisolated func expandCompactStripToMedium() {
        for _ in 0..<2 {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            start.press(forDuration: 0.1, thenDragTo: end)
            sleep(2)
            if !compactFloatStrip.exists { break }
        }
        XCTAssertTrue(
            app.buttons["searchDismissButton"].firstMatch.waitForExistence(timeout: 5),
            "the parked sheet never rose to show its Dismiss button"
        )
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
}
