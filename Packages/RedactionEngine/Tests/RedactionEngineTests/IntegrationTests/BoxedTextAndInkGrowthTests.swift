import Testing
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import RedactionEngine

// A received document's own boxes and a box's own edges. A box drawn into the
// page over text — at the text's selection rectangle, at its ink bounds, or
// half a point inside the selection — covers the middle of each glyph's box
// but not the glyph box's one-pixel halo, so the ink test once read page
// colour in the halo, kept the text layer and exported the text the box hides.
// The middle of a letter or digit is now read on its own. And a box placed at
// a selection rectangle leaves the ink that crosses the rectangle — an accent
// above a capital, an italic overhang — on the page; a fill made from text now
// grows over it. At the parent, a probe of these fixtures recorded every
// boxed page keeping its text layer, and the accents and the overhang left
// beside their boxes.

@Suite("Boxed text and ink growth")
struct BoxedTextAndInkGrowthTests {

    static let mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let hidden = "QZXSECRET"

    static func makePDF(_ draw: (CGContext) -> Void) -> Data {
        let data = NSMutableData()
        var box = mediaBox
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil); draw(ctx); ctx.endPDFPage(); ctx.closePDF()
        return data as Data
    }

    static func drawText(_ ctx: CGContext, _ s: String, font: String = "Helvetica", size: CGFloat = 12,
                         at p: CGPoint, mode: CGTextDrawingMode = .fill) {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        ctx.saveGState(); ctx.setFillColor(gray: 0, alpha: 1); ctx.setTextDrawingMode(mode)
        ctx.textPosition = p; CTLineDraw(line, ctx); ctx.restoreGState()
    }

    static func page(_ ctx: CGContext, hiddenMode: CGTextDrawingMode = .fill) {
        drawText(ctx, "Ordinary visible line of text above the field 0123456789", at: CGPoint(x: 72, y: 700))
        drawText(ctx, "Name:", at: CGPoint(x: 72, y: 600))
        drawText(ctx, hidden, at: CGPoint(x: 120, y: 600), mode: hiddenMode)
        drawText(ctx, "Ordinary visible line of text below the field 0123456789", at: CGPoint(x: 72, y: 500))
    }

    static func selection(_ data: Data, _ word: String) throws -> CGRect {
        let page = try #require(PDFDocument(data: data)?.page(at: 0))
        let range = ((page.string ?? "") as NSString).range(of: word)
        try #require(range.location != NSNotFound)
        return try #require(page.selection(for: range)).bounds(for: page)
    }

    /// A gray render of page 0 (row 0 = top).
    static func render(_ data: Data, dpi: CGFloat) throws -> CGContext {
        let page = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!)?.page(at: 1))
        let s = dpi / 72, w = Int(mediaBox.width * s), h = Int(mediaBox.height * s)
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: s, y: s); ctx.drawPDFPage(page)
        return ctx
    }

    static func gray(_ ctx: CGContext, _ x: Int, _ yFromBottom: Int) -> UInt8 {
        ctx.data!.assumingMemoryBound(to: UInt8.self)[(ctx.height - 1 - yFromBottom) * ctx.bytesPerRow + x]
    }

    /// The bounds (points) of the pixels darker than mid-grey inside `near`, on a 600-dpi render.
    static func inkBounds(_ data: Data, near: CGRect) throws -> CGRect {
        let ctx = try render(data, dpi: 600), s: CGFloat = 600 / 72
        var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
        for y in Int(near.minY * s)..<Int(near.maxY * s) {
            for x in Int(near.minX * s)..<Int(near.maxX * s) where gray(ctx, x, y) < 128 {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        return CGRect(x: CGFloat(x0) / s, y: CGFloat(y0) / s, width: CGFloat(x1 - x0 + 1) / s, height: CGFloat(y1 - y0 + 1) / s)
    }

    static func rasterize(_ data: Data, regions: [RedactionRegion] = [], dpi: Int = 300) async throws -> RasterizeResult {
        let doc = try #require(PDFDocument(data: data)); let page = try #require(doc.page(at: 0))
        let pageData = PDFPageData(
            page: page, pageIndex: 0, regions: regions, fillColor: .black, targetDPI: dpi,
            pipelineMode: .searchableRedaction, rotation: page.rotation,
            cropBoxBounds: page.bounds(for: .cropBox), cgPage: page.pageRef, hasText: true)
        let result = try await PageRasterizer().rasterize(pageData)
        withExtendedLifetime(doc) {}
        return result
    }

    // MARK: - Boxes drawn over the text

    @Test("A box drawn over text at its selection, at its ink bounds or half a point inside the selection sends the page image-only",
          arguments: ["selection", "ink-bounds", "selection-inset"])
    func tightBoxSendsPageImageOnly(box: String) async throws {
        let plain = Self.makePDF { Self.page($0) }
        let selection = try Self.selection(plain, Self.hidden)
        let rect = switch box {
        case "selection": selection
        case "ink-bounds": try Self.inkBounds(plain, near: selection.insetBy(dx: -4, dy: -4))
        default: selection.insetBy(dx: 0.5, dy: 0.5)
        }
        let boxed = Self.makePDF { c in Self.page(c); c.setFillColor(gray: 0, alpha: 1); c.fill(rect) }
        for dpi in [300, 150] {
            let result = try await Self.rasterize(boxed, dpi: dpi)
            #expect(result.fallbackReason == .hiddenText, "\(box) at \(dpi) dpi")
            #expect(result.pageOutput.textLayerEntries == nil, "\(box) at \(dpi) dpi")
        }
        let output = try await TestPipeline.processAndExport(boxed, mode: .searchableRedaction, regions: [0: []], dpi: 300)
        defer { try? FileManager.default.removeItem(at: output) }
        let exported = PDFDocument(url: output)?.page(at: 0)?.string ?? ""
        #expect(!exported.contains(Self.hidden), "\(box): the export")
    }

    @Test("The same page with no box keeps its text layer and its text")
    func unboxedPageKeepsText() async throws {
        let plain = Self.makePDF { Self.page($0) }
        let result = try await Self.rasterize(plain)
        #expect(result.fallbackReason == nil)
        let output = try await TestPipeline.processAndExport(plain, mode: .searchableRedaction, regions: [0: []], dpi: 300)
        defer { try? FileManager.default.removeItem(at: output) }
        let exported = PDFDocument(url: output)?.page(at: 0)?.string ?? ""
        #expect(exported.contains(Self.hidden))
    }

    @Test("A glyph's core is the middle band across the font's height, rounded inward, on either page orientation")
    func glyphCoreBand() throws {
        let box = CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.1)
        let upright = try #require(InkContrastFloor.glyphCore(box, rotation: 0, bitmapWidth: 100, bitmapHeight: 100))
        #expect(upright == CGRect(x: 10, y: 24, width: 10, height: 2))
        let turned = try #require(InkContrastFloor.glyphCore(box, rotation: 90, bitmapWidth: 100, bitmapHeight: 100))
        #expect(turned == CGRect(x: 14, y: 20, width: 2, height: 10))
        #expect(InkContrastFloor.glyphCore(CGRect(x: 0.1, y: 0.1, width: 0.001, height: 0.001),
                                           rotation: 0, bitmapWidth: 100, bitmapHeight: 100) == nil)
    }

    @Test("A core reads uniform within one band, and inked with one pixel past it or a stroke through it")
    func coreUniformityWithinOneBand() throws {
        let ctx = try #require(createBitmapContext(width: 20, height: 20))
        let buffer = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        func set(_ x: Int, _ y: Int, _ v: Int) {
            let p = buffer + (ctx.height - 1 - y) * ctx.bytesPerRow + x * 4
            p[0] = UInt8(v); p[1] = UInt8(v); p[2] = UInt8(v); p[3] = 255
        }
        let t = InkContrastFloor.tolerance
        for y in 0..<20 { for x in 0..<20 { set(x, y, 20 + (x + y) % (t + 1)) } }
        let core = CGRect(x: 0, y: 0, width: 20, height: 20)
        #expect(try InkContrastFloor.isCoreNearUniform(context: ctx, rect: core))
        set(10, 10, 20 + t + 1)
        #expect(try !InkContrastFloor.isCoreNearUniform(context: ctx, rect: core), "one pixel past the band is ink")
        set(10, 10, 20)
        for y in 0..<20 { set(5, y, 255); set(6, y, 255) }
        #expect(try !InkContrastFloor.isCoreNearUniform(context: ctx, rect: core), "a stroke is ink")
    }

    /// A JPEG black bar with seeded uniform noise of `amplitude` levels, as
    /// a scanned bar under a stale text layer reads.
    static func noisyBar(size: CGSize, amplitude: Int) throws -> CGImage {
        let w = Int(size.width * 300 / 72), h = Int(size.height * 300 / 72)
        var state: UInt64 = 0x9E3779B97F4A7C15
        let bytes = (0..<(w * h)).map { _ -> UInt8 in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return UInt8(Int(state % UInt64(amplitude + 1)))
        }
        let raw = try #require(CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let jpeg = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(jpeg as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, raw, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        CGImageDestinationFinalize(dest)
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test("Invisible text over a scanned bar whose noise spans the wider band is not a text layer")
    func invisibleTextOverNoisyBarSendsPageImageOnly() async throws {
        let plain = Self.makePDF { Self.page($0) }
        let bar = try Self.selection(plain, Self.hidden).insetBy(dx: -8, dy: -5)
        let image = try Self.noisyBar(size: bar.size, amplitude: InkContrastFloor.texturedBand)
        let data = Self.makePDF { c in c.draw(image, in: bar); Self.page(c, hiddenMode: .invisible) }
        for dpi in [300, 150] {
            let result = try await Self.rasterize(data, dpi: dpi)
            #expect(result.fallbackReason == .hiddenText, "\(dpi) dpi")
        }
    }

    @Test("A glyph box on clean paper is read against the narrow band, one on textured content against the wider band")
    func bandFollowsTheSurroundings() throws {
        let ctx = try #require(createBitmapContext(width: 100, height: 100))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let box = CGRect(x: 40, y: 40, width: 20, height: 20)
        #expect(try InkContrastFloor.band(forBox: box, rotation: 0, context: ctx) == InkContrastFloor.tolerance)
        // Ink beside the box along the line (a neighbouring glyph) leaves the band narrow.
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 62, y: 40, width: 10, height: 20))
        #expect(try InkContrastFloor.band(forBox: box, rotation: 0, context: ctx) == InkContrastFloor.tolerance)
        // Texture above the box widens it; on a quarter-turned page the strips run beside the box.
        ctx.fill(CGRect(x: 45, y: 62, width: 2, height: 2))
        #expect(try InkContrastFloor.band(forBox: box, rotation: 0, context: ctx) == InkContrastFloor.texturedBand)
        #expect(try InkContrastFloor.band(forBox: box, rotation: 90, context: ctx) == InkContrastFloor.texturedBand)
        #expect(PageRasterizer.isLetterOrDigit("Q") && PageRasterizer.isLetterOrDigit("7") && PageRasterizer.isLetterOrDigit("字"))
        #expect(PageRasterizer.isLetterOrDigit("e\u{0301}"))
        #expect(!PageRasterizer.isLetterOrDigit("\u{0301}") && !PageRasterizer.isLetterOrDigit(".") && !PageRasterizer.isLetterOrDigit("ʰ"))
        #expect(!PageRasterizer.isLetterOrDigit("H\n\u{0303}") && !PageRasterizer.isLetterOrDigit("fi"))
    }

    // MARK: - Ink that crosses a box's edge

    static func witnessLine(font: String, word: String) -> Data {
        makePDF { c in
            drawText(c, "Ordinary visible line of text above 0123456789", at: CGPoint(x: 72, y: 700))
            drawText(c, "Witness", font: font, size: 16, at: CGPoint(x: 72, y: 600))
            drawText(c, word, font: font, size: 16, at: CGPoint(x: 160, y: 600))
            drawText(c, "signed", font: font, size: 16, at: CGPoint(x: 330, y: 600))
        }
    }

    static func region(_ r: CGRect, _ source: RedactionRegion.Source) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: CGRect(
            x: r.minX / 612, y: r.minY / 792, width: r.width / 612, height: r.height / 792), source: source)
    }

    /// Pixels in `rect` (points) of the 300-dpi export render that are not the black fill.
    static func unfilled(_ output: Data, in rect: CGRect) throws -> Int {
        let ctx = try render(output, dpi: 300), s: CGFloat = 300 / 72
        var n = 0
        for y in Int(ceil(rect.minY * s))..<Int(floor(rect.maxY * s)) {
            for x in Int(ceil(rect.minX * s))..<Int(floor(rect.maxX * s)) where gray(ctx, x, y) > 16 { n += 1 }
        }
        return n
    }

    @Test("A box made from text grows over an accent above the selection and an italic overhang past it",
          arguments: [("Helvetica", "ÉMILE ÅSTRÖM"), ("Helvetica-Oblique", "WALTER JAFFE"),
                      ("Helvetica-BoldOblique", "WALTER JAFFE")])
    func textBoxGrowsOverCrossingInk(font: String, word: String) async throws {
        let data = Self.witnessLine(font: font, word: word)
        let selection = try Self.selection(data, word)
        let ink = try Self.inkBounds(data, near: selection.insetBy(dx: -6, dy: -8))
        #expect(ink.maxY > selection.maxY + 0.5 || ink.maxX > selection.maxX + 0.5, "the fixture's ink crosses the selection")
        for mode in [PipelineMode.searchableRedaction, .secureRasterization] {
            let output = try await TestPipeline.processAndExport(
                data, mode: mode, regions: [0: [Self.region(selection, .searchMatch(term: word))]], dpi: 300)
            defer { try? FileManager.default.removeItem(at: output) }
            let painted = selection.union(ink).insetBy(dx: 0.3, dy: 0.3)
            #expect(try Self.unfilled(Data(contentsOf: output), in: painted) == 0, "\(font) \(mode)")
        }
    }

    @Test("A box the user drew is filled as drawn: the ink above it stays")
    func manualBoxIsFilledAsDrawn() async throws {
        let word = "ÉMILE ÅSTRÖM"
        let data = Self.witnessLine(font: "Helvetica", word: word)
        let selection = try Self.selection(data, word)
        let ink = try Self.inkBounds(data, near: selection.insetBy(dx: -6, dy: -8))
        let output = try await TestPipeline.processAndExport(
            data, mode: .secureRasterization, regions: [0: [Self.region(selection, .manual)]], dpi: 300)
        defer { try? FileManager.default.removeItem(at: output) }
        let above = CGRect(x: ink.minX, y: selection.maxY + 0.5, width: ink.width, height: ink.maxY - selection.maxY - 0.5)
        #expect(try Self.unfilled(Data(contentsOf: output), in: above) > 0)
    }

    @Test("Growth follows only ink that crosses the edge, and stops a quarter of the box's height past it")
    func growthIsBounded() throws {
        let ctx = try #require(createBitmapContext(width: 400, height: 200))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let fill = CGRect(x: 100, y: 80, width: 120, height: 40)
        // Nothing crosses the edge: no growth, even with ink nearby.
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 100, y: 125, width: 20, height: 4))
        #expect(try inkGrowthRect(context: ctx, fillRect: fill) == nil)
        // A rule through the box across the whole bitmap: growth along it stops at the limit.
        ctx.fill(CGRect(x: 0, y: 98, width: 400, height: 3))
        let limit = inkGrowthLimit(for: fill)
        #expect(limit == 10)
        let grown = try #require(try inkGrowthRect(context: ctx, fillRect: fill))
        #expect(grown == CGRect(x: 90, y: 80, width: 140, height: 40))
    }
}
