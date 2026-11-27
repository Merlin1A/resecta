import XCTest

/// `WitnessMeasure` on synthetic bitmaps and plain numbers: the three scans,
/// why the window is cut, the inside check, the comparison where the line
/// hides an edge, the page's ink, the correction for a page whose size in
/// pixels is not whole, and the read-out's check against the page's white.
///
/// nonisolated: plain functions of bitmaps and numbers; it touches no @MainActor state.
nonisolated final class WitnessMeasureTests: XCTestCase {
    typealias Measure = WitnessMeasure
    let paper = SyntheticBitmap.paper

    func box(_ x: ClosedRange<Int>, _ y: ClosedRange<Int>) -> (Int, Int) -> SyntheticBitmap.RGB {
        { px, py in x.contains(px) && y.contains(py) ? SyntheticBitmap.black : SyntheticBitmap.paper }
    }

    func testThreeScansOfACleanRectangleAgree() {
        let shot = SyntheticBitmap.make(width: 100, height: 80, box(30...69, 20...59))
        let expected = CGRect(x: 30, y: 20, width: 40, height: 40)
        let scans = Measure.threeScans(of: shot, window: expected.insetBy(dx: -10, dy: -10), expected: expected,
                                       columns: [0.25, 0.5, 0.75], classed: false, paper: paper, step: 64)
        XCTAssertEqual(scans.count, 3)
        XCTAssertTrue(Measure.agree(scans, within: 1))
        XCTAssertEqual(scans[1].fill, CanvasPixelProbe.Edges(left: 30, right: 69, top: 20, bottom: 59))
    }

    func testThreeScansOfAnLShapedFillDisagree() {
        let shot = SyntheticBitmap.make(width: 100, height: 80) { x, y in
            let inBox = (30...69).contains(x) && (20...59).contains(y)
            let cut = x >= 50 && y < 40
            return inBox && !cut ? SyntheticBitmap.black : SyntheticBitmap.paper
        }
        let expected = CGRect(x: 30, y: 20, width: 40, height: 40)
        let scans = Measure.threeScans(of: shot, window: expected.insetBy(dx: -10, dy: -10), expected: expected,
                                       columns: [0.25, 0.5, 0.75], classed: false, paper: paper, step: 64)
        XCTAssertFalse(Measure.agree(scans, within: 1), "one row and one column cannot tell a rectangle from an L")
    }

    func testAWindowThatHoldsASecondMarkReadsTheOuterOne() {
        let shot = SyntheticBitmap.make(width: 100, height: 80) { x, y in
            ((30...59).contains(x) || (80...85).contains(x)) && (20...49).contains(y)
                ? SyntheticBitmap.black : SyntheticBitmap.paper
        }
        let expected = CGRect(x: 30, y: 20, width: 30, height: 30)
        let cut = Measure.threeScans(of: shot, window: expected.insetBy(dx: -10, dy: -10), expected: expected,
                                     columns: [0.25, 0.5, 0.75], classed: false, paper: paper, step: 64)
        XCTAssertEqual(cut[1].fill?.right, 59, "the cut window holds the box alone")
        let whole = Measure.threeScans(of: shot, window: CGRect(x: 0, y: 0, width: 100, height: 80),
                                       expected: expected, columns: [0.25, 0.5, 0.75], classed: false,
                                       paper: paper, step: 64)
        XCTAssertEqual(whole[1].fill?.right, 85, "an uncut window reads the second mark's edge: why it is cut")
    }

    func testCoveredIsFalseOverLettersWithPaperBetweenThem() {
        let letters = SyntheticBitmap.make(width: 60, height: 10) { x, _ in
            x % 6 < 3 ? SyntheticBitmap.black : SyntheticBitmap.paper
        }
        XCTAssertFalse(Measure.covered(in: letters, row: 5, from: 0, to: 59, paper: paper, step: 64))
        let solid = SyntheticBitmap.make(width: 60, height: 10, box(0...59, 0...9))
        XCTAssertTrue(Measure.covered(in: solid, row: 5, from: 0, to: 59, paper: paper, step: 64))
    }

    func testInsideCoveredIsFalseOverAnOutlineAndOverAWordWithNoVeil() {
        let expected = CGRect(x: 10, y: 7, width: 20, height: 16)
        let outline = SyntheticBitmap.make(width: 40, height: 30) { x, y in
            SyntheticBitmap.onRing(x, y) ? SyntheticBitmap.teal : SyntheticBitmap.paper
        }
        XCTAssertFalse(Measure.insideCovered(in: outline, expected: expected, inset: 4, row: 15, column: 20,
                                             paper: paper, step: 20), "an outline with paper within")
        let word = SyntheticBitmap.make(width: 40, height: 30) { x, y in
            (10...29).contains(x) && (7...22).contains(y) && x % 4 < 2 ? SyntheticBitmap.black : SyntheticBitmap.paper
        }
        XCTAssertFalse(Measure.insideCovered(in: word, expected: expected, inset: 4, row: 15, column: 20,
                                             paper: paper, step: 20), "a word with no veil shows paper between letters")
        let veiled = SyntheticBitmap.make(width: 40, height: 30) { x, y in
            guard (10...29).contains(x) && (7...22).contains(y) else { return SyntheticBitmap.paper }
            return x % 4 < 2 ? SyntheticBitmap.black : SyntheticBitmap.veil
        }
        XCTAssertTrue(Measure.insideCovered(in: veiled, expected: expected, inset: 4, row: 15, column: 20,
                                            paper: paper, step: 20), "the veil covers between the letters")
    }

    func testWhereTheLineHidesAnEdgeTheComparisonTakesTheLinesBand() {
        // Right side (outward +1): the line's outer end at 100.8 lies past the fill read at 100.
        XCTAssertTrue(Measure.sideAgrees(editorFill: 100, editorLineOuter: 100.8, preview: 100.6,
                                         outward: 1, tolerance: 0.52))
        XCTAssertFalse(Measure.sideAgrees(editorFill: 100, editorLineOuter: 100.8, preview: 101.5,
                                          outward: 1, tolerance: 0.52))
        XCTAssertFalse(Measure.sideAgrees(editorFill: 100, editorLineOuter: 100.8, preview: 99.4,
                                          outward: 1, tolerance: 0.52))
        // The fill met first: no band, the tolerance alone.
        XCTAssertFalse(Measure.sideAgrees(editorFill: 100, editorLineOuter: nil, preview: 100.6,
                                          outward: 1, tolerance: 0.52))
        XCTAssertFalse(Measure.sideAgrees(editorFill: 100, editorLineOuter: 99.5, preview: 100.6,
                                          outward: 1, tolerance: 0.52))
        XCTAssertTrue(Measure.sideAgrees(editorFill: 100, editorLineOuter: nil, preview: 100.4,
                                         outward: 1, tolerance: 0.52))
        // Left side (outward -1).
        XCTAssertTrue(Measure.sideAgrees(editorFill: 50, editorLineOuter: 49.2, preview: 49.4,
                                         outward: -1, tolerance: 0.52))
        XCTAssertFalse(Measure.sideAgrees(editorFill: 50, editorLineOuter: 49.2, preview: 48.5,
                                          outward: -1, tolerance: 0.52))
    }

    func testInkOutOfPlacePassesInkInItsPlacesAndPointsToALineMovedByThreePoints() {
        // At 3 device pixels a point, a line moved by 3 pt is 9 pixels off its recorded box.
        let lineBox = CGRect(x: 10, y: 10, width: 30, height: 6)
        let fillBox = CGRect(x: 50, y: 30, width: 20, height: 12)
        let page = CGRect(x: 2, y: 2, width: 96, height: 76)
        let inPlace = SyntheticBitmap.make(width: 100, height: 80) { x, y in
            (12...37).contains(x) && (11...14).contains(y) || (50...69).contains(x) && (30...41).contains(y)
                ? SyntheticBitmap.black : SyntheticBitmap.paper
        }
        XCTAssertNil(Measure.inkOutOfPlace(in: inPlace, page: page, allowed: [lineBox, fillBox], paper: paper, step: 64))
        let moved = SyntheticBitmap.make(width: 100, height: 80) { x, y in
            (21...46).contains(x) && (11...14).contains(y) || (50...69).contains(x) && (30...41).contains(y)
                ? SyntheticBitmap.black : SyntheticBitmap.paper
        }
        XCTAssertEqual(Measure.inkOutOfPlace(in: moved, page: page, allowed: [lineBox, fillBox], paper: paper, step: 64),
                       CGPoint(x: 40, y: 11))
    }

    func testCorrectedOnAnA4WidthAt150AndALetterWidth() {
        XCTAssertEqual(Measure.corrected(535.796, side: 595.2756, picture: 1241, quality: 150), 536.160, accuracy: 0.0005)
        XCTAssertEqual(Measure.corrected(400, side: 612, picture: 1275, quality: 150), 400, accuracy: 1e-9)
    }

    func testTheReadOutIsCheckedAgainstThePagesWhite() {
        // A grey canvas, a white page at window points (10, 5) of 20 x 16 at 3 pixels a point.
        let shot = SyntheticBitmap.make(width: 120, height: 90) { x, y in
            (30..<90).contains(x) && (15..<63).contains(y) ? SyntheticBitmap.paper : (242, 242, 247)
        }
        XCTAssertTrue(Measure.readOutOnThePage(shot, origin: CGPoint(x: 10, y: 5), shown: CGSize(width: 20, height: 16),
                                               screenScale: 3))
        XCTAssertFalse(Measure.readOutOnThePage(shot, origin: CGPoint(x: 11, y: 5), shown: CGSize(width: 20, height: 16),
                                                screenScale: 3), "a corner one point off the page's white")
    }

    func testToPageTurnsAWindowPointWithTheYFlip() {
        let point = Measure.toPage(CGPoint(x: 110, y: 60), origin: CGPoint(x: 10, y: 20), scale: 2, height: 792)
        XCTAssertEqual(point.x, 50, accuracy: 1e-12)
        XCTAssertEqual(point.y, 772, accuracy: 1e-12)
    }
}
