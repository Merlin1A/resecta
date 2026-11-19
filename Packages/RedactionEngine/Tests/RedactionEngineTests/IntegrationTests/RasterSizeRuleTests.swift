import Testing
import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

// The raster's size by the raster rule (`PixelPlan`): a page side of s points
// is S = ⌈64·s − 2⁻¹⁶⌉ sixty-fourths, and the raster has ⌈S·d / 4608⌉ pixels
// on that side at d dots per inch. Before, the size was the ceiling of a
// floating-point product, which gave a Letter page 3,301 rows at 300 and
// 1,651 at 150 dpi. The drawing scale stays d / 72 from the bottom-left
// corner, so the page does not move: a row or column the rule takes off or
// adds is blank paper past the page's edge.

@Suite("The raster's size by the raster rule")
struct RasterSizeRuleTests {

    struct Case: CustomTestStringConvertible, Sendable {
        let label: String
        let width: CGFloat, height: CGFloat, rotation: Int, dpi: CGFloat
        let pixels: (width: Int, height: Int)
        var testDescription: String { label }
    }

    /// One side tested at a time: a square page of that side.
    private static func side(_ s: CGFloat, _ name: String, _ dpi: CGFloat, _ px: Int) -> Case {
        Case(label: "\(name) at \(Int(dpi)) dpi: \(px)", width: s, height: s, rotation: 0, dpi: dpi, pixels: (px, px))
    }

    static let cases: [Case] = [
        side(612, "612 pt", 300, 2_550), side(612, "612 pt", 200, 1_700), side(612, "612 pt", 150, 1_275),
        side(792, "792 pt", 300, 3_300), side(792, "792 pt", 200, 2_200), side(792, "792 pt", 150, 1_650),
        side(595.276, "595.276 pt (A4)", 300, 2_481), side(595.276, "595.276 pt (A4)", 200, 1_654),
        side(595.276, "595.276 pt (A4)", 150, 1_241),
        side(841.89, "841.89 pt (A4)", 300, 3_508), side(841.89, "841.89 pt (A4)", 200, 2_339),
        side(841.89, "841.89 pt (A4)", 150, 1_754),
        // 600 pt is 38,400 sixty-fourths, 2,500 pixels exactly at 300 dpi.
        side(600 - 1.0 / 64, "a sixty-fourth below a pixel boundary", 300, 2_500),
        side(600 + 1.0 / 64, "a sixty-fourth above a pixel boundary", 300, 2_501),
        side(5_000, "the largest admitted side, 5,000 pt", 300, 20_834),
        // A 4 by 6 inch page's height: the floating-point product gave 1,801.
        side(432, "432 pt (a 4 by 6 inch page's height)", 300, 1_800),
        Case(label: "a quarter turn swaps the sides: Letter turned at 300 dpi", width: 612, height: 792,
             rotation: 90, dpi: 300, pixels: (3_300, 2_550)),
    ]

    @Test("The table has its 17 cases")
    func tableCount() {
        #expect(Self.cases.count == 17)
    }

    @Test("Each side's raster is the rule's count of pixels", arguments: cases)
    func rasterSize(_ c: Case) throws {
        let size = try #require(PageRasterizer.rasterPixelSize(
            bounds: CGRect(x: 0, y: 0, width: c.width, height: c.height), rotation: c.rotation, dpi: c.dpi))
        #expect(size.width == c.pixels.width && size.height == c.pixels.height,
                "\(c.label): got \(size.width) × \(size.height)")
    }
}

@Suite("The page does not move when its raster changes size", .serialized)
struct RasterSizeChangeTests {

    enum Change: Sendable { case none, lostRow, gainedRow, gainedColumn }

    struct Case: CustomTestStringConvertible, Sendable {
        let label: String
        let width: CGFloat, height: CGFloat, dpi: CGFloat
        let pixels: (width: Int, height: Int)
        let change: Change
        var testDescription: String { label }
    }

    // The three gaining sides are the first on a 0.001 pt step past 700, 500
    // and 700 pt that the rule rounds up past a pixel boundary at that quality.
    static let cases: [Case] = [
        Case(label: "Letter at 300 dpi: 3,300 rows, the old 3,301 without its top row",
             width: 612, height: 792, dpi: 300, pixels: (2_550, 3_300), change: .lostRow),
        Case(label: "Letter at 150 dpi: 1,650 rows, the old 1,651 without its top row",
             width: 612, height: 792, dpi: 150, pixels: (1_275, 1_650), change: .lostRow),
        Case(label: "Letter at 200 dpi: no change, the bitmap's bytes identical",
             width: 612, height: 792, dpi: 200, pixels: (1_700, 2_200), change: .none),
        Case(label: "a 700.079 pt height at 300 dpi gains a blank top row",
             width: 612, height: 700.079, dpi: 300, pixels: (2_550, 2_918), change: .gainedRow),
        Case(label: "a 500.032 pt width at 200 dpi gains a blank right-hand column",
             width: 500.032, height: 792, dpi: 200, pixels: (1_390, 2_200), change: .gainedColumn),
        Case(label: "a 700.313 pt height at 150 dpi gains a blank top row",
             width: 612, height: 700.313, dpi: 150, pixels: (1_275, 1_460), change: .gainedRow),
    ]

    @Test("The comparison has its 6 cases")
    func caseCount() {
        #expect(Self.cases.count == 6)
    }

    @Test("Compared from the bottom-left corner, the page is where it was", arguments: cases)
    func pageStays(_ c: Case) async throws {
        let page = try Self.fixturePage(width: c.width, height: c.height)
        let bounds = page.getBoxRect(.cropBox)
        let image = try await PageRasterizer().renderPageFromCGPage(
            page, bounds: bounds, rotation: 0, pageIndex: 0, dpi: c.dpi)
        #expect(image.width == c.pixels.width && image.height == c.pixels.height,
                "\(c.label): rendered \(image.width) × \(image.height)")

        // The test's own drawing, the render body's steps on a bitmap of a
        // given size. At the rendered size it must give the render's bytes,
        // so at the old size it is the bitmap the old rule made.
        let new = try Pixels(image)
        let same = try Pixels(Self.draw(page, bounds: bounds, dpi: c.dpi, width: image.width, height: image.height))
        #expect(same.rows == new.rows, "the test's drawing at the rendered size equals the render")

        let scale = c.dpi / 72.0
        let oldWidth = Int(ceil(bounds.width * scale)), oldHeight = Int(ceil(bounds.height * scale))
        let old = try Pixels(Self.draw(page, bounds: bounds, dpi: c.dpi, width: oldWidth, height: oldHeight))
        // Rows are held top first, so a row taken off or added at the top
        // shifts every index by one; the bottom-left corner stays put.
        switch c.change {
        case .none:
            #expect(oldWidth == image.width && oldHeight == image.height)
            #expect(old.rows == new.rows, "the bitmap's bytes are identical")
        case .lostRow:
            #expect(oldWidth == image.width && oldHeight == image.height + 1)
            #expect(old.rows.count == new.rows.count + 1)
            #expect(Array(old.rows.dropFirst()) == new.rows, "the old bitmap without its top row")
            #expect(old.rows.first.map(Pixels.isPaper) == true, "the row taken off was blank paper")
        case .gainedRow:
            #expect(oldWidth == image.width && oldHeight + 1 == image.height)
            #expect(Array(new.rows.dropFirst()) == old.rows, "the old bitmap with a row added at the top")
            #expect(new.rows.first.map(Pixels.isPaper) == true, "the row added is blank paper")
        case .gainedColumn:
            #expect(oldWidth + 1 == image.width && oldHeight == image.height)
            #expect(new.rows.map { Array($0.dropLast(4)) } == old.rows, "the old bitmap with a column added at the right")
            #expect(new.rows.allSatisfy { Pixels.isPaper(Array($0.suffix(4))) }, "the column added is blank paper")
        }
    }

    // MARK: - The page and the drawing

    /// A one-page PDF of the given size whose marks reach every edge: a
    /// square at each corner, a bar along the top, and slanted strokes at
    /// fractional positions, so a shifted row or column would show.
    static func fixturePage(width: CGFloat, height: CGFloat) throws -> CGPDFPage {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let ctx = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        for (x, y) in [(0.0, 0.0), (width - 30, 0), (0, height - 30), (width - 30, height - 30)] {
            ctx.fill(CGRect(x: x, y: y, width: 30, height: 30))
        }
        ctx.fill(CGRect(x: 40.3, y: height - 2.7, width: width - 80.6, height: 2.7))
        ctx.setStrokeColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        ctx.setLineWidth(0.7)
        for k in 0..<12 {
            ctx.move(to: CGPoint(x: 35.13 + CGFloat(k) * 41.7, y: 31.9))
            ctx.addLine(to: CGPoint(x: 52.77 + CGFloat(k) * 39.1, y: height - 7.3))
        }
        ctx.strokePath()
        ctx.endPDFPage()
        ctx.closePDF()
        let provider = try #require(CGDataProvider(data: data as CFData))
        return try #require(CGPDFDocument(provider)?.page(at: 1))
    }

    /// The render body's steps (`renderPageFromCGPage`) on a bitmap of the
    /// given size: paper, no font smoothing, scale d / 72, the page's
    /// drawing transform, the clip to its box, the page.
    static func draw(_ page: CGPDFPage, bounds: CGRect, dpi: CGFloat, width: Int, height: Int) throws -> CGImage {
        let ctx = try #require(createBitmapContext(width: width, height: height))
        #if canImport(UIKit)
        ctx.setFillColor(UIColor.white.cgColor)
        #else
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        #endif
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setShouldSmoothFonts(false)
        ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.setAllowsFontSubpixelPositioning(false)
        let transform = PageRasterizer.drawingTransform(
            for: page, box: .cropBox, rotation: 0,
            targetRect: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
        ctx.scaleBy(x: dpi / 72.0, y: dpi / 72.0)
        ctx.concatenate(transform)
        ctx.addRect(page.getBoxRect(.cropBox))
        ctx.clip()
        ctx.drawPDFPage(page)
        return try #require(ctx.makeImage())
    }

    /// An image's pixels as rows of bytes, top row first, without the
    /// padding at each row's end.
    struct Pixels {
        let rows: [[UInt8]]
        init(_ image: CGImage) throws {
            let data = try #require(image.dataProvider?.data) as Data
            let rowBytes = image.width * 4
            rows = (0..<image.height).map { r in
                Array(data[(r * image.bytesPerRow)..<(r * image.bytesPerRow + rowBytes)])
            }
        }
        static func isPaper(_ bytes: [UInt8]) -> Bool { bytes.allSatisfy { $0 == 0xFF } }
    }
}
