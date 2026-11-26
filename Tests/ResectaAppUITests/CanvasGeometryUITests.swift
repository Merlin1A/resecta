import XCTest

/// The canvas's geometry on the 23-page fixture: which region a touch picks
/// on applied one-line regions, what a touch does at 2x, and how a box is
/// drawn. The "Amount" search applied on the 23-page fixture puts a stack
/// of one-line boxes on page 1, a few points apart at the fit zoom; a tap
/// or a hold at a box's centre must pick that box, not the one below it.
/// Boxes are read from the screen (`CanvasPixelProbe`): every box is the
/// veil inside a page-teal line, whatever placed it.
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
        let before = try stack.rows(in: probe(), tint: .teal)
        XCTAssertEqual(before.count, Stack.rowCount, "the applied stack is on the page")
        tap(stack.centre(row))
        sleep(1)
        // The selected box's handles cover its one-line strip, so the
        // selection is read by deleting it: the box that goes is the one
        // the tap selected.
        let overflow = app.editorOverflowButton
        XCTAssertTrue(overflow.waitForExistence(timeout: 10))
        overflow.tap()
        let delete = app.buttons["Delete Region"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the tap selected one region")
        delete.tap()
        XCTAssertTrue(waitForRegionCount(Stack.rowCount - 1))
        sleep(1)
        let after = try stack.rows(in: probe(), tint: .teal)
        XCTAssertEqual(Set(before).subtracting(after), [row], "a tap at row \(row)'s centre selects row \(row)")
    }

    func testHoldAtARowCentreDeletesThatRow() throws {
        let stack = try applyAmountStack()
        let row = 10
        let before = try stack.rows(in: probe(), tint: .teal)
        XCTAssertEqual(before.count, Stack.rowCount, "the applied stack is on the page")
        let count = currentRegionCount()
        point(stack.centre(row)).press(forDuration: 0.8)
        let delete = app.buttons["Delete Region"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the hold opens the region's menu")
        delete.tap()
        XCTAssertTrue(waitForRegionCount(count - 1), "one region is deleted")
        sleep(1)
        let after = try stack.rows(in: probe(), tint: .teal)
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
        // Both lines are teal: A is read in the left half of the canvas, B in
        // the right, clear of the bars' teal glyphs.
        let canvas = canvasArea()
        let left = CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width / 2, height: canvas.height)
        let right = CGRect(x: canvas.midX, y: canvas.minY, width: canvas.width / 2, height: canvas.height)
        let before = try probe()
        let a0 = try XCTUnwrap(before.tintBounds(.teal, in: left), "A at zoom")
        let b0 = try XCTUnwrap(before.tintBounds(.teal, in: right), "B at zoom")
        point(CGPoint(x: a0.midX, y: a0.midY)).press(forDuration: 0.05, thenDragTo: point(CGPoint(x: a0.midX, y: a0.midY - 60)))
        sleep(2)
        let after = try probe()
        let a1 = try XCTUnwrap(after.tintBounds(.teal, in: left))
        let b1 = try XCTUnwrap(after.tintBounds(.teal, in: right))
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
        let b = try XCTUnwrap(zoomed.tintBounds(.teal, in: canvasArea()), "the selected box at zoom")
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

    // MARK: - The tag

    /// A Search box's tag shows outside the box, above its leading corner,
    /// only once its line is tall enough on screen: none on the stack at the
    /// fit zoom, where a row is about 6 points tall; at zoom, an ink tag
    /// with white words; gone while its box is selected, back at rest.
    func testTheTagShowsOutsideTheBoxOnlyWhenItsLineIsTallEnough() throws {
        let stack = try applyAmountStack()
        let fit = try probe()
        let corner = CGPoint(x: stack.page.minX + 180 * stack.scale, y: stack.centre(10).y - 4 * stack.scale)
        let above = CGRect(x: corner.x - 2, y: corner.y - 20, width: 24, height: 20)
        keepScreenshot("fit")
        XCTAssertNil(fit.tintBounds(.tagFill, in: above), "no tag above row 10 at fit")
        XCTAssertNil(fit.tintBounds(.tagFill, in: canvasArea()), "no tag anywhere at fit")

        var tag: CGRect?
        let canvas = app.scrollViews.allElementsBoundByIndex.max { $0.frame.height < $1.frame.height } ?? app.scrollViews.firstMatch
        // The pinch zooms about the window's middle, which moves the amount
        // column off the left edge; each step brings it back to the middle,
        // then has the overlay redraw at the new zoom.
        for _ in 1...3 where tag == nil {
            canvas.pinch(withScale: 2.0, velocity: 1.0)
            sleep(3)
            try centreTheBoxes()
            try redrawAtThisZoom()
            tag = try probe().tintBounds(.tagFill, in: canvasArea().insetBy(dx: 4, dy: 4))
        }
        let zoomed = try probe()
        keepScreenshot("zoomed")
        // Each row has its tag; the first whole one from the top is read.
        let all = try XCTUnwrap(tag, "a tag at zoom")
        var shown: CGRect?
        var top = all.minY
        while shown == nil, top < all.maxY,
              let b = zoomed.tintBounds(.tagFill, in: CGRect(x: all.minX - 1, y: top, width: all.width + 2, height: 16)) {
            if b.height >= 12 { shown = b } else { top = b.maxY + 1 }
        }
        let one = try XCTUnwrap(shown, "one whole tag at zoom")
        print("tag at \(one), rgb at its middle \(zoomed.rgb(one.midX, one.midY))")
        XCTAssertGreaterThanOrEqual(one.height, 12, "the tag is about 15 points tall")
        var white = 0
        var y = one.minY
        while y < one.maxY {
            var x = one.minX
            while x < one.maxX {
                let (r, g, b) = zoomed.rgb(x, y)
                if r >= 235 && g >= 235 && b >= 235 { white += 1 }
                x += 1
            }
            y += 1
        }
        XCTAssertGreaterThanOrEqual(white, 6, "white words inside the tag")
        let lineBelow = CGRect(x: one.minX, y: one.maxY - 1, width: min(one.width, 20), height: 8)
        XCTAssertNotNil(zoomed.tintBounds(.teal, in: lineBelow), "the box's teal line just below the tag")

        tap(CGPoint(x: one.minX + 8, y: one.maxY + 8))
        sleep(1)
        let selected = try probe()
        keepScreenshot("selected")
        XCTAssertNil(selected.tintBounds(.tagFill, in: one), "no tag while its box is selected")
        tap(CGPoint(x: window.frame.width - 16, y: one.midY))
        sleep(1)
        XCTAssertNotNil(try probe().tintBounds(.tagFill, in: one.insetBy(dx: -2, dy: -2)), "the tag is back at rest")
    }

    // MARK: - Handles and corner dots

    /// A hand-drawn box at rest on white: the veil inside a teal line no
    /// thicker than 1.8 points on its edge, and neither handles nor dots.
    func testAHandDrawnBoxIsAVeilWithATealLine() throws {
        launchMultipage()
        let page = try fitPage()
        let before = try probe()
        let white = try XCTUnwrap(Self.whiteArea(in: before, page: page, size: CGSize(width: 140, height: 50)),
                                  "no white 140 x 50 area on the fit page above its lowest fifth")
        drawBoxes([white.insetBy(dx: 10, dy: 10)])
        tap(CGPoint(x: page.midX, y: page.minY + page.height * 0.9))
        sleep(1)
        let shot = try probe()
        let reach = try XCTUnwrap(shot.differenceBounds(from: before, in: white.insetBy(dx: -6, dy: -6)), "the box drew")
        let box = reach.insetBy(dx: 0.7, dy: 0.7)  // the 1.4-point line is centred on the box's edge
        let inner = box.insetBy(dx: 2, dy: 2)
        var inside = 0, veiled = 0
        for y in stride(from: inner.minY, to: inner.maxY, by: 1) {
            for x in stride(from: inner.minX, to: inner.maxX, by: 1) {
                inside += 1
                let (r, g, b) = shot.rgb(x, y)
                if CanvasPixelProbe.Tint.veil.matches(r, g, b) { veiled += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(Double(veiled), 0.8 * Double(inside), "the veil inside the box: \(veiled) of \(inside) points")
        XCTAssertGreaterThanOrEqual(shot.edgeCoverage(of: box, .teal), 0.8, "a teal line on the box's edge (box \(box))")
        let run = shot.thickness(of: .teal, across: CGPoint(x: box.midX, y: box.minY), vertical: true)
        XCTAssertGreaterThan(run, 0, "the top edge's middle is teal")
        XCTAssertLessThanOrEqual(run, 1.8, "the resting line is \(run) points thick")
        for c in Self.corners(of: box) {
            let (r, g, b) = shot.rgb(c.x, c.y)
            XCTAssertFalse(r >= 235 && g >= 235 && b >= 235, "no white handle disc at the corner \(c)")
        }
        for p in Self.outsideCorners(of: box) {
            XCTAssertEqual(Self.grid(around: p).filter { Self.isTeal(shot, $0) }.count, 0, "no corner dot at \(p)")
        }
    }

    /// A box 120 x 12 on screen: at rest a teal line no thicker than 1.8
    /// points; selected, a heavier one, four corner handles stepped 5
    /// points clear of it and a handle at the middle of the top and the
    /// bottom; none at the middle of the 12-point sides. A handle is a white
    /// disc with a teal ring of radius 4.5.
    func testASelectedBoxShowsAHeavierTealLineAndHandlesClearOfIt() throws {
        launchMultipage()
        let page = try fitPage()
        let drawn = CGRect(x: page.minX + page.width * 0.2, y: page.minY + page.height * 0.42, width: 120, height: 12)
        drawBoxes([drawn])
        tap(CGPoint(x: page.midX, y: page.minY + page.height * 0.8))
        sleep(1)
        let search = drawn.insetBy(dx: -20, dy: -20)
        let rest = try probe()
        let line = try XCTUnwrap(rest.tintPixelBounds(.teal, in: search), "the box at rest")
        let box = line.insetBy(dx: 0.7, dy: 0.7)  // the 1.4-point line is centred on the box's edge
        // A quarter along the top: clear of the corner and middle handles.
        let along = CGPoint(x: box.minX + box.width / 4, y: box.minY)
        let restRun = rest.thickness(of: .teal, across: along, vertical: true)
        XCTAssertGreaterThan(restRun, 0, "the top edge is teal at rest")
        XCTAssertLessThanOrEqual(restRun, 1.8, "the resting line is \(restRun) points thick")
        tap(CGPoint(x: box.midX, y: box.midY))
        sleep(1)
        let shot = try probe()
        let run = shot.thickness(of: .teal, across: along, vertical: true)
        // Measured on an iOS 26.4.1 simulator at 3x: 4 teal pixels at rest and
        // 6 selected; a 1.4- and a 2.4-point line lose their blended edge
        // pixels. Half a pixel of slack keeps a whole-pixel 2.0 from failing on
        // rounding.
        XCTAssertGreaterThanOrEqual(run, 2.0 - shot.pixel / 2, "the selected line is heavier: \(run) points, at rest \(restRun)")
        XCTAssertGreaterThan(run, restRun + shot.pixel / 2, "the selected line is heavier than the resting one")
        XCTAssertGreaterThanOrEqual(shot.edgeCoverage(of: box, .teal), 0.8, "a teal line on the selected box's edge")
        let out: CGFloat = (22 - box.height) / 2
        let handles = [CGPoint(x: box.minX, y: box.minY - out), CGPoint(x: box.maxX, y: box.minY - out),
                       CGPoint(x: box.minX, y: box.maxY + out), CGPoint(x: box.maxX, y: box.maxY + out),
                       CGPoint(x: box.midX, y: box.minY - out), CGPoint(x: box.midX, y: box.maxY + out)]
        for c in handles {
            let (r, g, b) = shot.rgb(c.x, c.y)
            XCTAssertTrue(r >= 235 && g >= 235 && b >= 235, "a white handle disc at \(c) (box \(box)): \((r, g, b))")
            XCTAssertEqual(Self.ring(around: c).filter { Self.isTeal(shot, $0) }.count, 4, "a teal ring round the handle at \(c)")
        }
        // Across the side only: the ring's points above and below a side's
        // middle lie on the box's own teal line.
        for c in [CGPoint(x: box.minX, y: box.midY), CGPoint(x: box.maxX, y: box.midY)] {
            let across = [CGPoint(x: c.x - 4.5, y: c.y), CGPoint(x: c.x + 4.5, y: c.y)]
            XCTAssertEqual(across.filter { Self.isTeal(shot, $0) }.count, 0, "no handle at the short side's middle \(c)")
        }
    }

    /// Two boxes selected with Add to Selection on show no handles: each
    /// carries a teal dot at every corner, read 1.5 points diagonally outside
    /// the corner, where at rest there is no teal.
    func testASelectionWithoutHandlesCarriesCornerDots() throws {
        launchMultipage()
        let page = try fitPage()
        let boxA = CGRect(x: page.minX + page.width * 0.12, y: page.minY + page.height * 0.42, width: page.width * 0.3, height: 30)
        let boxB = CGRect(x: page.minX + page.width * 0.58, y: boxA.minY, width: page.width * 0.3, height: 30)
        drawBoxes([boxA, boxB])
        tap(CGPoint(x: page.midX, y: page.minY + page.height * 0.8))
        sleep(1)
        let rest = try probe()
        let boxes = try [boxA, boxB].map { drawn in
            try XCTUnwrap(rest.tintPixelBounds(.teal, in: drawn.insetBy(dx: -20, dy: -20)), "box at rest near \(drawn)").insetBy(dx: 0.7, dy: 0.7)
        }
        // Every line is teal, so each dot is read outside the line:
        // `outsideCorners` reads 1.5 points diagonally past each corner,
        // beyond the selected line's reach of 1.2 points and inside the
        // dot's teal (about 2.35 points from its centre).
        func outside(_ box: CGRect) -> [CGPoint] { Self.outsideCorners(of: box) }
        for box in boxes {
            for p in outside(box) {
                XCTAssertEqual(Self.grid(around: p).filter { Self.isTeal(rest, $0) }.count, 0, "no teal at \(p) at rest")
            }
        }
        setAddToSelection(on: true)
        for box in boxes { tap(CGPoint(x: box.midX, y: box.midY)); usleep(600_000) }
        sleep(1)
        let selected = try probe()
        for box in boxes {
            for p in outside(box) {
                XCTAssertGreaterThanOrEqual(Self.grid(around: p).filter { Self.isTeal(selected, $0) }.count, 5, "a teal dot at \(p)")
            }
            for c in [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY)] {
                let (r, g, b) = selected.rgb(c.x, c.y)
                XCTAssertFalse(r >= 235 && g >= 235 && b >= 235, "no white handle disc at the corner \(c)")
            }
        }
        XCTAssertEqual(deleteRow(), "Delete 2 Regions", "both boxes are selected")
    }

    /// On a dark page the white keyline rims the box: just outside the line,
    /// at rest and selected, the keyline stands 3 : 1 against the page 6
    /// points further out.
    func testOnADarkPageTheKeylineRimsTheBox() throws {
        app.launchArguments = ["--uitesting", "--loadTestImage=uitest_image_dark"]
        app.launch()
        XCTAssertTrue(app.buttons["drawTool"].waitForExistence(timeout: 60), "the editor never appeared")
        sleep(2)
        let before = try probe()
        // The page's dark ground, not the canvas's black background.
        let dark = try XCTUnwrap(Self.area(in: before, within: canvasArea().insetBy(dx: 10, dy: 10), size: CGSize(width: 160, height: 110)) {
            [$0, $1, $2].allSatisfy { (16...40).contains($0) }
        }, "no dark ground of 160 x 110 on the page")
        let drawn = CGRect(x: dark.minX + 20, y: dark.minY + 20, width: 120, height: 30)
        drawBoxes([drawn])
        tap(CGPoint(x: dark.midX, y: dark.maxY - 12))
        sleep(1)
        let rest = try probe()
        XCTAssertNotNil(rest.differenceBounds(from: before, in: dark), "the box drew")
        // The box's edge is the middle of its teal line, read pixel by pixel
        // (the resting line is 1.4 points). Measured on an iOS 26.4.1 simulator
        // at 3x: teal at 319.33-320.67 round an edge at 320.0, the keyline
        // brightest at 321.0-321.33 and faded by 322.0, nearer the line than
        // the model's middle at 321.5, since a 0.8-point line is drawn on whole
        // pixels.
        let box = try XCTUnwrap(rest.tintPixelBounds(.teal, in: dark), "the box's line").insetBy(dx: 0.7, dy: 0.7)
        func rims(_ shot: CanvasPixelProbe, lineWidth: CGFloat, _ state: String) {
            // The keyline lies between the line's outer edge and its own
            // outer edge (half the line, the 0.4 gap and its 0.8 width, a
            // pixel either side): the brightest pixel in that band, read
            // outward, against the page 6 points further out.
            let near = lineWidth / 2 + 0.4 - 0.4, far = lineWidth / 2 + 0.4 + 0.8 + 0.4
            let points: [(CGPoint, CGVector)] = [1, 2].flatMap { (k: CGFloat) -> [(CGPoint, CGVector)] in
                let x = box.minX + box.width * k / 3, y = box.minY + box.height * k / 3
                return [(CGPoint(x: x, y: box.minY), CGVector(dx: 0, dy: -1)), (CGPoint(x: x, y: box.maxY), CGVector(dx: 0, dy: 1)),
                        (CGPoint(x: box.minX, y: y), CGVector(dx: -1, dy: 0)), (CGPoint(x: box.maxX, y: y), CGVector(dx: 1, dy: 0))]
            }
            for (edge, away) in points {
                let q = CGPoint(x: edge.x + away.dx * (far + 6), y: edge.y + away.dy * (far + 6))
                var d = near, best = 0.0, at = edge
                while d <= far {
                    let p = CGPoint(x: edge.x + away.dx * d, y: edge.y + away.dy * d)
                    let c = shot.contrast(p, q)
                    if c > best { best = c; at = p }
                    d += shot.pixel
                }
                XCTAssertGreaterThanOrEqual(best, 3.0, "\(state): the keyline near \(at) against the page at \(q)")
            }
        }
        rims(rest, lineWidth: 1.4, "at rest")
        tap(CGPoint(x: box.midX, y: box.midY))
        sleep(1)
        rims(try probe(), lineWidth: 2.4, "selected")
    }
}

// MARK: - Helpers

private extension CanvasGeometryUITests {

    /// The "Amount" boxes on page 1 of the fixture: one per ledger row,
    /// "Amount" set at x 180–212.4 of the 612-point page on baselines
    /// 472 − 13·row (Scripts/generate_uitest_multipage.py). Rows are placed
    /// from that geometry and read by the teal line at each box's left
    /// edge.
    nonisolated struct Stack {
        static let rowCount = 28
        let page: CGRect
        var scale: CGFloat { page.width / 612 }
        func centre(_ row: Int) -> CGPoint {
            CGPoint(x: page.minX + 196.2 * scale, y: page.minY + (792 - (472 - 13 * CGFloat(row) + 2.5)) * scale)
        }
        /// The rows whose box shows `tint` on its left line, at the word's
        /// left edge (x 180). Measured on an iOS 26.4.1 simulator at 3x:
        /// each box's left line is 4 pixels of page teal there, continuous
        /// down the row; inside it, the veil over the row's first glyph
        /// leaves no clear strip, so the line is read and not the veil.
        func rows(in probe: CanvasPixelProbe, tint: CanvasPixelProbe.Tint) -> [Int] {
            (0..<Self.rowCount).filter { row in
                let y = centre(row).y, x = page.minX + 180 * scale
                let hits = [-1.5, -0.75, 0, 0.75, 1.5].filter { dy in
                    let (r, g, b) = probe.rgb(x, y + dy)
                    return tint.matches(r, g, b)
                }
                return hits.count >= 3
            }
        }
    }

    nonisolated var window: XCUIElement { app.windows.firstMatch }

    /// Four points at radius 4.5 (a handle's ring) round `c`.
    nonisolated static func ring(around c: CGPoint) -> [CGPoint] {
        [CGPoint(x: c.x, y: c.y - 4.5), CGPoint(x: c.x, y: c.y + 4.5), CGPoint(x: c.x - 4.5, y: c.y), CGPoint(x: c.x + 4.5, y: c.y)]
    }

    /// Nine points a third of a point apart round `p`, so a read one pixel
    /// off still lands.
    nonisolated static func grid(around p: CGPoint) -> [CGPoint] {
        [-1, 0, 1].flatMap { dy in [-1, 0, 1].map { dx in CGPoint(x: p.x + CGFloat(dx) / 3, y: p.y + CGFloat(dy) / 3) } }
    }

    /// The four corners of `box`.
    nonisolated static func corners(of box: CGRect) -> [CGPoint] {
        [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
         CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)]
    }

    /// The points 1.5 points diagonally outside each corner of `box`.
    nonisolated static func outsideCorners(of box: CGRect) -> [CGPoint] {
        [CGPoint(x: box.minX - 1.5, y: box.minY - 1.5), CGPoint(x: box.maxX + 1.5, y: box.minY - 1.5),
         CGPoint(x: box.minX - 1.5, y: box.maxY + 1.5), CGPoint(x: box.maxX + 1.5, y: box.maxY + 1.5)]
    }

    /// The first area of `size`, in 10-point steps, every point of which
    /// shows `ground` in `probe`, inside `within`.
    nonisolated static func area(in probe: CanvasPixelProbe, within: CGRect, size: CGSize,
                                 _ ground: (Int, Int, Int) -> Bool) -> CGRect? {
        for y in stride(from: within.minY, through: within.maxY - size.height, by: 10) {
            for x in stride(from: within.minX, through: within.maxX - size.width, by: 10) {
                let area = CGRect(origin: CGPoint(x: x, y: y), size: size)
                let every = stride(from: area.minY, to: area.maxY, by: 1).allSatisfy { py in
                    stride(from: area.minX, to: area.maxX, by: 1).allSatisfy { px in
                        let (r, g, b) = probe.rgb(px, py)
                        return ground(r, g, b)
                    }
                }
                if every { return area }
            }
        }
        return nil
    }

    /// A white area of the fit page (every point at least 250), above its
    /// lowest fifth, where the tap that clears a selection lands.
    nonisolated static func whiteArea(in probe: CanvasPixelProbe, page: CGRect, size: CGSize) -> CGRect? {
        let within = CGRect(x: page.minX + 10, y: page.minY + 20, width: page.width - 20, height: page.height * 0.8 - 20)
        return area(in: probe, within: within, size: size) { $0 >= 250 && $1 >= 250 && $2 >= 250 }
    }

    /// The canvas a box is read on: the page's scroll view, short of the
    /// navigation bar, the page bar, the selection bar and the toolbar,
    /// whose glyphs can be teal too.
    nonisolated func canvasArea() -> CGRect {
        let scroll = app.scrollViews.allElementsBoundByIndex.max { $0.frame.height < $1.frame.height }?.frame ?? window.frame
        var area = scroll.intersection(window.frame)
        let bar = app.navigationBars.firstMatch
        if bar.exists, bar.frame.maxY > area.minY {
            area = CGRect(x: area.minX, y: bar.frame.maxY + 2, width: area.width, height: max(0, area.maxY - bar.frame.maxY - 2))
        }
        for id in ["drawTool", "pageNavCounter", "selectionBarCount", "selectionBarDuplicate", "selectionBarDelete"] {
            let e = app.descendants(matching: .any).matching(identifier: id).firstMatch
            guard e.exists else { continue }
            let f = e.frame.insetBy(dx: 0, dy: -8)
            guard f.intersects(area) else { continue }
            if f.midY > area.midY {
                area = CGRect(x: area.minX, y: area.minY, width: area.width, height: max(0, f.minY - area.minY))
            } else {
                area = CGRect(x: area.minX, y: f.maxY, width: area.width, height: max(0, area.maxY - f.maxY))
            }
        }
        return area
    }

    nonisolated static func isTeal(_ probe: CanvasPixelProbe, _ p: CGPoint) -> Bool {
        let (r, g, b) = probe.rgb(p.x, p.y)
        return CanvasPixelProbe.Tint.teal.matches(r, g, b)
    }


    /// Keeps a screenshot with the run, so a reading can be checked by eye.
    nonisolated func keepScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

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
                if tool.drawToolReads(value) { return }
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
    /// Pans the canvas so the boxes, read by their teal lines in the
    /// window's middle half, sit at its middle across. The drag starts 30
    /// points beside them, clear of any box's touch area, so it pans and
    /// neither moves nor selects one; it ends
    /// slowly so the canvas does not glide on.
    nonisolated func centreTheBoxes() throws {
        let band = CGRect(x: 0, y: window.frame.height * 0.25, width: window.frame.width, height: window.frame.height * 0.5)
            .intersection(canvasArea())
        guard let boxes = try probe().tintBounds(.teal, in: band) else { return }
        let shift = window.frame.midX - boxes.midX
        guard abs(shift) > 20 else { return }
        let start = CGPoint(x: shift > 0 ? boxes.maxX + 30 : boxes.minX - 30, y: band.midY)
        point(start).press(forDuration: 0.05, thenDragTo: point(CGPoint(x: start.x + shift, y: start.y)),
                           withVelocity: .slow, thenHoldForDuration: 0.2)
        sleep(2)
    }

    /// Has the overlay redraw at the zoom on screen, with the trigger it has
    /// today: a tap inside a box selects it, a tap on the page at the
    /// window's trailing edge clears it. A change of zoom alone does not ask
    /// for a redraw yet. The box is read down the middle of the boxes in the
    /// window's middle half: a gap over 12 points between two runs of teal
    /// is a box's inside (between boxes it is about 8 at this zoom). Does
    /// nothing while the boxes are shorter than that.
    nonisolated func redrawAtThisZoom() throws {
        let band = CGRect(x: 0, y: window.frame.height * 0.25, width: window.frame.width, height: window.frame.height * 0.5)
            .intersection(canvasArea())
        let shot = try probe()
        guard let boxes = shot.tintBounds(.teal, in: band) else { return }
        var starts: [CGFloat] = []
        var inRun = false
        var y = band.minY
        while y < band.maxY {
            let (r, g, b) = shot.rgb(boxes.midX, y)
            let teal = CanvasPixelProbe.Tint.teal.matches(r, g, b)
            if teal, !inRun { starts.append(y) }
            inRun = teal
            y += 1
        }
        guard let i = starts.indices.dropLast().first(where: { starts[$0 + 1] - starts[$0] > 12 }) else { return }
        let inside = CGPoint(x: boxes.midX, y: (starts[i] + starts[i + 1]) / 2)
        tap(inside)
        sleep(1)
        tap(CGPoint(x: window.frame.width - 16, y: inside.y))
        sleep(1)
    }

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
        let overflow = app.editorOverflowButton
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
        let row = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH 'Delete' AND identifier != 'selectionBarDelete'")).firstMatch
        let label = row.waitForExistence(timeout: 2) ? row.label : nil
        dismissMenus()
        return label
    }
}
