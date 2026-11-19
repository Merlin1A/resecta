import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

// Fill coverage when the raster dimension is not an integer multiple
// of the page's point size. `renderPageFromCGPage` sizes the bitmap by the
// raster rule (`PageRasterizer.rasterPixelSize`: ⌈S·d / 4608⌉ for a side of
// S sixty-fourths) while the content is drawn spanning exactly
// `points × dpi/72`; on a side the rule gains a row on, the bitmap is up to
// 1.06 px larger than the content. A box mapped by the BITMAP's count could
// then sit more than the 1-px halo off the content near the far edge. This
// suite draws content on the content basis, maps regions through the
// production fill path, and asserts coverage on the content basis.
//
// A4 at 150/200/300 DPI has a non-integral raster dimension at every tier
// (595.2756 × 841.8898 pt), so all three tiers exercise the mismatch.
//
// Fill color is WHITE on a white background with black bars: any bar pixel
// the fill misses stays black and the assert sees it — a black fill would
// render the residue invisible against the bar's own ink.

@Suite("Fill coverage across raster bases")
struct FillCoverageBasisTests {

    private enum FixtureError: Error { case contextFailed }

    /// A4 in PostScript points.
    private static let pageWidthPt: CGFloat = 595.2756
    private static let pageHeightPt: CGFloat = 841.8898

    /// Bars in point coordinates (non-integral placements — the mismatch is
    /// coordinate-dependent, so several placements are checked per tier).
    /// Each bar's redaction region equals the bar extent exactly.
    private static let barsPt: [CGRect] = [
        CGRect(x: 101.3, y: 200.7, width: 150.4, height: 20.6),
        CGRect(x: 320.9, y: 455.1, width: 180.2, height: 14.3),
        CGRect(x: 55.5, y: 700.2, width: 240.8, height: 30.1),
        CGRect(x: 402.6, y: 90.4, width: 120.7, height: 22.9),
    ]

    @Test("A4 bar extents are fully covered at 150/200/300 DPI",
          arguments: [150, 200, 300])
    func a4BarExtentsFullyCovered(dpi: Int) throws {
        let scale = CGFloat(dpi) / 72.0
        // The production bitmap sizing: the raster rule.
        let raster = try #require(PageRasterizer.rasterPixelSize(
            bounds: CGRect(x: 0, y: 0, width: Self.pageWidthPt, height: Self.pageHeightPt),
            rotation: 0, dpi: CGFloat(dpi)))
        let pw = raster.width, ph = raster.height
        guard let ctx = createBitmapContext(width: pw, height: ph) else {
            throw FixtureError.contextFailed
        }

        // White page background.
        ctx.setShouldAntialias(false)
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))

        // Draw the bars BLACK on the CONTENT basis: point coordinates under
        // a dpi/72 CTM scale, exactly how page content reaches the raster.
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        for bar in Self.barsPt {
            ctx.fill(bar)
        }
        ctx.restoreGState()

        // Regions equal the bar extents exactly, in normalized page space.
        let regions = Self.barsPt.map { bar in
            RedactionRegion(
                id: UUID(),
                normalizedRect: CGRect(
                    x: bar.minX / Self.pageWidthPt,
                    y: bar.minY / Self.pageHeightPt,
                    width: bar.width / Self.pageWidthPt,
                    height: bar.height / Self.pageHeightPt
                ),
                source: .manual
            )
        }

        // The production fill path, on the content basis the rasterizer passes.
        let content = try #require(PageRasterizer.rasterContentSize(
            bounds: CGRect(x: 0, y: 0, width: Self.pageWidthPt, height: Self.pageHeightPt),
            rotation: 0, dpi: CGFloat(dpi)))
        try applyRedactionFills(context: ctx, regions: regions, fillColor: .white, content: content)

        // Assert on the CONTENT basis: every pixel the bar's ink could
        // occupy must now be white. Content pixel extent = the bar's point
        // extent × scale, floor/ceil to cover its antialiasing-free edges.
        let data = try #require(ctx.data)
        let buf = data.assumingMemoryBound(to: UInt8.self)
        let bpr = ctx.bytesPerRow
        for (barIndex, bar) in Self.barsPt.enumerated() {
            let minX = max(0, Int(floor(bar.minX * scale)))
            let maxX = min(pw, Int(ceil(bar.maxX * scale)))
            let minY = max(0, Int(floor(bar.minY * scale)))
            let maxY = min(ph, Int(ceil(bar.maxY * scale)))
            var residue = 0
            var firstResidue: (Int, Int)?
            for y in minY..<maxY {
                let memoryRow = ph - 1 - y
                for x in minX..<maxX {
                    let off = memoryRow * bpr + x * 4
                    // BGRA — white is (255, 255, 255, 255).
                    if buf[off] != 255 || buf[off + 1] != 255 || buf[off + 2] != 255 {
                        residue += 1
                        if firstResidue == nil { firstResidue = (x, y) }
                    }
                }
            }
            #expect(residue == 0,
                    "bar \(barIndex) at \(dpi) DPI: \(residue) non-fill pixel(s) inside the bar extent, first at \(String(describing: firstResidue))")
        }
    }

    /// A side the raster rule gains a pixel on, a DPI, and where a bar starts
    /// on that side, in points: the bar runs from there to the side's end, so
    /// its first row or column holds only a sliver of anti-aliased ink. Each is
    /// the side with the largest gain (bitmap less content) at its DPI, or the
    /// side 302.626 pt, and the start that leaves the most ink in that row when
    /// a box is mapped by the bitmap's count (0.054 px at 300 DPI, 0.036 at
    /// 200, 0.025 at 150).
    struct GainedSide: Sendable, CustomTestStringConvertible {
        let side: CGFloat, dpi: Int, start: CGFloat, across: Bool
        /// Where the bar ends; nil runs it to the side's end.
        var end: CGFloat? = nil
        var testDescription: String {
            "\(across ? "width" : "height") \(side) pt at \(dpi) DPI, bar from \(start)\(end.map { " to \($0)" } ?? "")"
        }
        var barLength: CGFloat { (end ?? side) - start }
    }

    static let gainedSides: [GainedSide] = [
        GainedSide(side: 302.626, dpi: 300, start: 301.667, across: false),
        GainedSide(side: 302.626, dpi: 300, start: 287.279, across: false),
        GainedSide(side: 302.626, dpi: 300, start: 301.667, across: true),
        GainedSide(side: 203.266, dpi: 300, start: 202.547, across: false),
        GainedSide(side: 656.266, dpi: 200, start: 654.827, across: false),
        GainedSide(side: 656.266, dpi: 200, start: 654.827, across: true),
        GainedSide(side: 209.266, dpi: 150, start: 208.788, across: false),
        // Short of the edge: the fill's far side is not clipped by the bitmap,
        // so a fill and its readback on different bases do not meet.
        GainedSide(side: 302.626, dpi: 300, start: 280.5, across: false, end: 295.4),
        // The near edges: the content basis moves a fill down or left by up
        // to a pixel, so a bar near the bottom or left whose far edge leaves
        // a sliver of ink in its last row or column (0.02 px) must stay
        // covered on both bases.
        GainedSide(side: 302.626, dpi: 300, start: 0, across: false, end: 2.4048),
        GainedSide(side: 302.626, dpi: 300, start: 0.7, across: true, end: 9.6048),
        GainedSide(side: 203.266, dpi: 300, start: 0, across: false, end: 1.2048),
        GainedSide(side: 656.266, dpi: 200, start: 0, across: false, end: 2.5272),
        GainedSide(side: 656.266, dpi: 200, start: 0.4, across: true, end: 7.5672),
        GainedSide(side: 209.266, dpi: 150, start: 0.5, across: true, end: 4.8096),
    ]

    /// The cases whose first line CoreGraphics' own anti-aliased fill inks.
    /// (A bar from 287.279 pt leaves 0.004 px there: CoreGraphics draws it
    /// blank, while a page rendered from its PDF inks it, so that case is
    /// read only on the whole-page path below.)
    static let drawnSides = gainedSides.filter { $0.start != 287.279 }

    @Test("On a side the raster rule gains a pixel on, an anti-aliased bar at the far edge is covered",
          arguments: drawnSides)
    func gainedSideFarEdgeCovered(_ gained: GainedSide) throws {
        let other: CGFloat = 100
        let pageWidth = gained.across ? gained.side : other
        let pageHeight = gained.across ? other : gained.side
        let scale = CGFloat(gained.dpi) / 72.0
        let raster = try #require(PageRasterizer.rasterPixelSize(
            bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight),
            rotation: 0, dpi: CGFloat(gained.dpi)))
        let pw = raster.width, ph = raster.height
        guard let ctx = createBitmapContext(width: pw, height: ph) else {
            throw FixtureError.contextFailed
        }
        ctx.setShouldAntialias(false)
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))

        // The bar, black and anti-aliased as a glyph's edge is, on the content basis.
        let bar = gained.across
            ? CGRect(x: gained.start, y: 40, width: gained.barLength, height: 20)
            : CGRect(x: 40, y: gained.start, width: 20, height: gained.barLength)
        ctx.saveGState()
        ctx.setShouldAntialias(true)
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(bar)
        ctx.restoreGState()

        let data = try #require(ctx.data)
        let buf = data.assumingMemoryBound(to: UInt8.self)
        let bpr = ctx.bytesPerRow
        let minX = max(0, Int(floor(bar.minX * scale))), maxX = min(pw, Int(ceil(bar.maxX * scale)))
        let minY = max(0, Int(floor(bar.minY * scale))), maxY = min(ph, Int(ceil(bar.maxY * scale)))
        func inked() -> [(Int, Int, UInt8)] {
            var out: [(Int, Int, UInt8)] = []
            for y in minY..<maxY {
                for x in minX..<maxX {
                    let off = (ph - 1 - y) * bpr + x * 4
                    let least = min(buf[off], buf[off + 1], buf[off + 2])
                    if least != 255 { out.append((x, y, least)) }
                }
            }
            return out
        }
        // The bar's first row (or column) must hold ink, or the case shows nothing.
        let edge = inked().filter { gained.across ? $0.0 == minX : $0.1 == minY }
        print("[fill-basis] \(gained.testDescription): bitmap \(pw)×\(ph), first line inked \(edge.count) px, lightest ink \(edge.map(\.2).max().map(String.init) ?? "none")")
        #expect(!edge.isEmpty, "the bar's first line carries no ink: the case shows nothing")

        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: bar.minX / pageWidth, y: bar.minY / pageHeight,
                                   width: bar.width / pageWidth, height: bar.height / pageHeight),
            source: .manual)
        // The production fill path, on the content basis the rasterizer passes.
        let content = try #require(PageRasterizer.rasterContentSize(
            bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight),
            rotation: 0, dpi: CGFloat(gained.dpi)))
        try applyRedactionFills(context: ctx, regions: [region], fillColor: .white, content: content)

        let left = inked()
        #expect(left.isEmpty, "\(left.count) inked pixel(s) left inside the bar, first \(String(describing: left.first))")
    }

    /// A one-page PDF of the given size whose content is one black bar.
    private static func barPage(width: CGFloat, height: CGFloat, bar: CGRect) -> Data {
        let stream = "0 g \(bar.minX) \(bar.minY) \(bar.width) \(bar.height) re f"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(width) \(height)] /Contents 4 0 R >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
        ]
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, object) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    @Test("A page rasterized whole: a box over a bar at the far edge of a gained side leaves no ink",
          arguments: gainedSides.filter { $0.dpi == 300 })
    func rasterizedPageFarEdgeCovered(_ gained: GainedSide) async throws {
        let other: CGFloat = 100
        let pageWidth = gained.across ? gained.side : other
        let pageHeight = gained.across ? other : gained.side
        let bar = gained.across
            ? CGRect(x: gained.start, y: 40, width: gained.barLength, height: 20)
            : CGRect(x: 40, y: gained.start, width: 20, height: gained.barLength)
        let doc = try #require(PDFDocument(data: Self.barPage(width: pageWidth, height: pageHeight, bar: bar)))
        let page = try #require(doc.page(at: 0))
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: bar.minX / pageWidth, y: bar.minY / pageHeight,
                                   width: bar.width / pageWidth, height: bar.height / pageHeight),
            source: .manual)
        let pageData = PDFPageData(
            page: page, pageIndex: 0, regions: [region], fillColor: .white, targetDPI: 300,
            pipelineMode: .secureRasterization, rotation: page.rotation,
            cropBoxBounds: page.bounds(for: .cropBox), cgPage: page.pageRef, hasText: false)
        let image = try await PageRasterizer().rasterize(pageData, dpiCap: 300).pageOutput.image
        let scale = CGFloat(300) / 72
        let pw = image.width, ph = image.height
        // The output image read back into a known layout (BGRA, bottom-left rows below).
        let ctx = try #require(createBitmapContext(width: pw, height: ph))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: pw, height: ph))
        let buf = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        let bpr = ctx.bytesPerRow
        let minX = max(0, Int(floor(bar.minX * scale))), maxX = min(pw, Int(ceil(bar.maxX * scale)))
        let minY = max(0, Int(floor(bar.minY * scale))), maxY = min(ph, Int(ceil(bar.maxY * scale)))
        var left: [(Int, Int, UInt8)] = []
        for y in minY..<maxY {
            for x in minX..<maxX {
                let off = (ph - 1 - y) * bpr + x * 4
                let least = min(buf[off], buf[off + 1], buf[off + 2])
                if least != 255 { left.append((x, y, least)) }
            }
        }
        print("[fill-basis] rasterized \(gained.testDescription): image \(pw)×\(ph), inked left \(left.count), first \(String(describing: left.first))")
        #expect(left.isEmpty, "\(left.count) inked pixel(s) left inside the bar, first \(String(describing: left.first))")
    }

    @Test("A page rasterized whole with a black fill reads each box back on the basis it was painted on",
          arguments: gainedSides.filter { $0.dpi == 300 && $0.end != nil })
    func rasterizedPageReadsBackItsFill(_ gained: GainedSide) async throws {
        // Black on white paper: a row the readback reads that the fill did
        // not paint is white and fails the readback, as a white fill on
        // white paper would not show.
        let other: CGFloat = 100
        let pageWidth = gained.across ? gained.side : other
        let pageHeight = gained.across ? other : gained.side
        let bar = gained.across
            ? CGRect(x: gained.start, y: 40, width: gained.barLength, height: 20)
            : CGRect(x: 40, y: gained.start, width: 20, height: gained.barLength)
        let doc = try #require(PDFDocument(data: Self.barPage(width: pageWidth, height: pageHeight, bar: bar)))
        let page = try #require(doc.page(at: 0))
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: bar.minX / pageWidth, y: bar.minY / pageHeight,
                                   width: bar.width / pageWidth, height: bar.height / pageHeight),
            source: .manual)
        let pageData = PDFPageData(
            page: page, pageIndex: 0, regions: [region], fillColor: .black, targetDPI: 300,
            pipelineMode: .secureRasterization, rotation: page.rotation,
            cropBoxBounds: page.bounds(for: .cropBox), cgPage: page.pageRef, hasText: false)
        let image = try await PageRasterizer().rasterize(pageData, dpiCap: 300).pageOutput.image
        print("[fill-basis] read back black \(gained.testDescription): image \(image.width)×\(image.height)")
    }

    @Test("The content basis lies under d/4608 px past the drawn content and under one pixel short of the raster",
          arguments: [(612.0, 792.0), (595.2756, 841.8898), (302.626, 203.266), (656.266, 209.266)], [150, 200, 300])
    func contentBasisSitsBetweenTheContentAndTheRaster(_ size: (Double, Double), dpi: Int) throws {
        let bounds = CGRect(x: 0, y: 0, width: size.0, height: size.1)
        let content = try #require(PageRasterizer.rasterContentSize(bounds: bounds, rotation: 0, dpi: CGFloat(dpi)))
        let raster = try #require(PageRasterizer.rasterPixelSize(bounds: bounds, rotation: 0, dpi: CGFloat(dpi)))
        let step = CGFloat(dpi) / 4608
        for (basis, drawn, pixels) in [(content.width, size.0 * Double(dpi) / 72, raster.width),
                                       (content.height, size.1 * Double(dpi) / 72, raster.height)] {
            #expect(basis >= CGFloat(drawn) - 1e-9 && basis - CGFloat(drawn) < step,
                    "basis \(basis) against the drawn span \(drawn)")
            #expect(CGFloat(pixels) - basis >= 0 && CGFloat(pixels) - basis < 1, "basis \(basis) against \(pixels) px")
        }
        // Quarter-turned: the sides swap.
        let turned = try #require(PageRasterizer.rasterContentSize(bounds: bounds, rotation: 90, dpi: CGFloat(dpi)))
        #expect(turned.width == content.height && turned.height == content.width)
    }
}
