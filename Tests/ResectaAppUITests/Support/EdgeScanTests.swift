import XCTest

/// Bitmaps drawn pixel by pixel for the scans' tests, row 0 at the top, in
/// the look's own colours: paper white, the page teal #0B646F, the ink
/// #14222B, and the veil (the ink at 18 % over white).
nonisolated enum SyntheticBitmap {
    typealias RGB = (r: Int, g: Int, b: Int)
    static let paper: RGB = (255, 255, 255)
    static let teal: RGB = (11, 100, 111)
    static let ink: RGB = (20, 34, 43)
    static let veil: RGB = (213, 215, 217)
    static let black: RGB = (0, 0, 0)

    static func make(width: Int, height: Int, _ colour: (Int, Int) -> RGB) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = colour(x, y), i = (y * width + x) * 4
                bytes[i] = UInt8(c.r); bytes[i + 1] = UInt8(c.g); bytes[i + 2] = UInt8(c.b); bytes[i + 3] = 255
            }
        }
        // The bytes are copied into the provider, so the image owns its pixels.
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// A teal ring three pixels wide on the rectangle x 10...29, y 7...22 of a 40 x 30 bitmap.
    static func onRing(_ x: Int, _ y: Int) -> Bool {
        let inX = (10...29).contains(x), inY = (7...22).contains(y)
        return (inY && ((10...12).contains(x) || (27...29).contains(x)))
            || (inX && ((7...9).contains(y) || (20...22).contains(y)))
    }
}

/// The edge scan (paper and not paper) and the classed reading (paper, line,
/// fill) of `CanvasPixelProbe`, on synthetic bitmaps.
///
/// nonisolated: plain functions of bitmaps; it touches no @MainActor state.
nonisolated final class EdgeScanTests: XCTestCase {
    typealias Probe = CanvasPixelProbe
    let paper = SyntheticBitmap.paper

    // MARK: - The edge scan

    func testACleanStep() {
        let bitmap = SyntheticBitmap.make(width: 40, height: 30) { x, y in
            (10...29).contains(x) && (5...24).contains(y) ? SyntheticBitmap.black : SyntheticBitmap.paper
        }
        XCTAssertEqual(Probe.edges(in: bitmap, row: 15, column: 20, paper: paper, step: 20),
                       Probe.Edges(left: 10, right: 29, top: 5, bottom: 24))
    }

    func testAStepWithOneMidTonePixel() {
        // A mid-tone pixel past the step counts as not paper; one within it does not.
        let bitmap = SyntheticBitmap.make(width: 40, height: 30) { x, y in
            if (10...29).contains(x) && (5...24).contains(y) { return SyntheticBitmap.black }
            if x == 9 && y == 15 { return (128, 128, 128) }
            if x == 30 && y == 15 { return (245, 245, 245) }
            return SyntheticBitmap.paper
        }
        XCTAssertEqual(Probe.edges(in: bitmap, row: 15, column: 20, paper: paper, step: 20),
                       Probe.Edges(left: 9, right: 29, top: 5, bottom: 24))
    }

    func testNoStepIsNil() {
        let bitmap = SyntheticBitmap.make(width: 40, height: 30) { _, _ in SyntheticBitmap.paper }
        XCTAssertNil(Probe.edges(in: bitmap, row: 15, column: 20, paper: paper, step: 20))
    }

    // MARK: - The classed reading

    func testTheLooksColoursFallInTheirClasses() {
        XCTAssertEqual(Probe.mark(SyntheticBitmap.teal, paper: paper, step: 20), .line)
        XCTAssertEqual(Probe.mark(SyntheticBitmap.ink, paper: paper, step: 20), .fill)
        XCTAssertEqual(Probe.mark(SyntheticBitmap.veil, paper: paper, step: 20), .fill)
        XCTAssertEqual(Probe.mark(SyntheticBitmap.black, paper: paper, step: 20), .fill)
        XCTAssertEqual(Probe.mark((245, 246, 247), paper: paper, step: 20), .paper)
    }

    func testAnOutlineWithNoFillInsideTheWindowGivesNoFillEdges() {
        let bitmap = SyntheticBitmap.make(width: 40, height: 30) { x, y in
            SyntheticBitmap.onRing(x, y) ? SyntheticBitmap.teal : SyntheticBitmap.paper
        }
        let reading = Probe.reading(in: bitmap, row: 15, column: 20, paper: paper, step: 20)
        XCTAssertNil(reading.fill, "an outline alone is not a fill")
        XCTAssertEqual(reading.lineOuter, Probe.Edges(left: 10, right: 29, top: 7, bottom: 22))
    }

    func testAFillThatShowsOutsideTheLineGivesTheFillsEdgeAndTheLinesTwoEnds() {
        let bitmap = SyntheticBitmap.make(width: 40, height: 30) { x, y in
            if SyntheticBitmap.onRing(x, y) { return SyntheticBitmap.teal }
            return (6...33).contains(x) && (3...26).contains(y) ? SyntheticBitmap.veil : SyntheticBitmap.paper
        }
        XCTAssertEqual(Probe.reading(in: bitmap, row: 15, column: 20, paper: paper, step: 20),
                       Probe.Reading(fill: .init(left: 6, right: 33, top: 3, bottom: 26),
                                     lineOuter: .init(left: 10, right: 29, top: 7, bottom: 22),
                                     lineInner: .init(left: 12, right: 27, top: 9, bottom: 20)))
    }

    func testAFillThatEndsUnderTheLineGivesTheFirstFillPixelInsideIt() {
        let bitmap = SyntheticBitmap.make(width: 40, height: 30) { x, y in
            if SyntheticBitmap.onRing(x, y) { return SyntheticBitmap.teal }
            return (11...28).contains(x) && (8...21).contains(y) ? SyntheticBitmap.veil : SyntheticBitmap.paper
        }
        let reading = Probe.reading(in: bitmap, row: 15, column: 20, paper: paper, step: 20)
        XCTAssertEqual(reading.fill, Probe.Edges(left: 13, right: 26, top: 10, bottom: 19))
    }

    func testAnInkLineBesideTheTealOneIsReadAsFill() {
        // Increase Contrast's opaque ink line beside the teal: why the screen test runs with it off.
        let bitmap = SyntheticBitmap.make(width: 40, height: 30) { x, y in
            if SyntheticBitmap.onRing(x, y) { return SyntheticBitmap.teal }
            if (x == 9 || x == 30) && (6...23).contains(y) { return SyntheticBitmap.ink }
            if (y == 6 || y == 23) && (9...30).contains(x) { return SyntheticBitmap.ink }
            return (13...26).contains(x) && (10...19).contains(y) ? SyntheticBitmap.veil : SyntheticBitmap.paper
        }
        let reading = Probe.reading(in: bitmap, row: 15, column: 20, paper: paper, step: 20)
        XCTAssertEqual(reading.fill, Probe.Edges(left: 9, right: 30, top: 6, bottom: 23))
    }
}
