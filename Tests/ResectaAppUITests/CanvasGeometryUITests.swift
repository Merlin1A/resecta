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
        let before = try stack.rows(in: probe(), tint: .veil)
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
        let after = try stack.rows(in: probe(), tint: .veil)
        XCTAssertEqual(Set(before).subtracting(after), [row], "a tap at row \(row)'s centre selects row \(row)")
    }

    func testHoldAtARowCentreDeletesThatRow() throws {
        let stack = try applyAmountStack()
        let row = 10
        let before = try stack.rows(in: probe(), tint: .veil)
        XCTAssertEqual(before.count, Stack.rowCount, "the applied stack is on the page")
        let count = currentRegionCount()
        point(stack.centre(row)).press(forDuration: 0.8)
        let delete = app.buttons["Delete Region"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the hold opens the region's menu")
        delete.tap()
        XCTAssertTrue(waitForRegionCount(count - 1), "one region is deleted")
        sleep(1)
        let after = try stack.rows(in: probe(), tint: .veil)
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
        let line = try XCTUnwrap(rest.tintBounds(.teal, in: search), "the box at rest")
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
        XCTAssertGreaterThanOrEqual(run, 2.0, "the selected line is heavier: \(run) points, at rest \(restRun)")
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
        for c in [CGPoint(x: box.minX, y: box.midY), CGPoint(x: box.maxX, y: box.midY)] {
            XCTAssertEqual(Self.ring(around: c).filter { Self.isTeal(shot, $0) }.count, 0, "no handle at the short side's middle \(c)")
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
            try XCTUnwrap(rest.tintBounds(.teal, in: drawn.insetBy(dx: -20, dy: -20)), "box at rest near \(drawn)").insetBy(dx: 0.7, dy: 0.7)
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
        // The keyline's outer edge is 1.5 points outside the box at rest.
        let reach = try XCTUnwrap(rest.differenceBounds(from: before, in: dark), "the box drew")
        let box = reach.insetBy(dx: 1.5, dy: 1.5)
        func rims(_ shot: CanvasPixelProbe, lineWidth: CGFloat, _ state: String) {
            // The keyline's middle: half the line plus 0.4 outside the box.
            let out = lineWidth / 2 + 0.4
            let ring = box.insetBy(dx: -out, dy: -out)
            let points: [(CGPoint, CGVector)] = [1, 2].flatMap { (k: CGFloat) -> [(CGPoint, CGVector)] in
                let x = ring.minX + ring.width * k / 3, y = ring.minY + ring.height * k / 3
                return [(CGPoint(x: x, y: ring.minY), CGVector(dx: 0, dy: -6)), (CGPoint(x: x, y: ring.maxY), CGVector(dx: 0, dy: 6)),
                        (CGPoint(x: ring.minX, y: y), CGVector(dx: -6, dy: 0)), (CGPoint(x: ring.maxX, y: y), CGVector(dx: 6, dy: 0))]
            }
            for (p, away) in points {
                let q = CGPoint(x: p.x + away.dx, y: p.y + away.dy)
                XCTAssertGreaterThanOrEqual(shot.contrast(p, q), 3.0, "\(state): the keyline at \(p) against the page at \(q)")
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
    /// from that geometry and read by the veil at each box's left strip,
    /// clear of the search badge at its top right.
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
