import Testing
import Foundation
import PDFKit
import CoreText
@testable import RedactionEngine

// The ink fit on text the ink threshold does not read (`PageImageInkFitTests`):
// grey text lighter than it, and white text on a dark band. The painted box
// holds the word's glyphs: fitted to them, or the drift envelope.

extension PageImageInkFitTests {
    /// The lines of the shaded page: the text, its grey (0 black … 1 white),
    /// and the grey of a band behind it (nil: none).
    static let shadedLines: [(text: String, grey: CGFloat, band: CGFloat?)] = [
        ("Account number 4100773265 on file", 150.0 / 255, nil),
        ("Statement period ending Sunday", 190.0 / 255, nil),
        ("Balance summary for Hartwell", 1, 40.0 / 255),
    ]

    /// A page of `shadedLines` (Helvetica 12 pt): drawn as ink (`hidden`
    /// false), or as a picture of that page under the same lines in invisible
    /// text, each glyph 0.3 pt closer to the last and the line 4 pt low (a
    /// fixed-pitch layer's drift), as a re-imported Searchable export is.
    static func shadedPagePDF(hidden: Bool) throws -> Data {
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        func draw(_ ctx: CGContext, kern: CGFloat, drop: CGFloat, ink: Bool) {
            for (index, line) in shadedLines.enumerated() {
                let y = 700 - CGFloat(index) * 40
                if ink, let band = line.band {
                    ctx.setFillColor(gray: band, alpha: 1)
                    ctx.fill(CGRect(x: 60, y: y - 6, width: 300, height: 22))
                }
                let color = CGColor(gray: line.grey, alpha: 1)
                let attributed = NSAttributedString(string: line.text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                    NSAttributedString.Key(kCTKernAttributeName as String): kern])
                ctx.textPosition = CGPoint(x: 72, y: y - drop)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
            }
        }
        func pdf(_ body: (CGContext) -> Void) throws -> Data {
            let data = NSMutableData()
            let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
            let ctx = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
            ctx.beginPDFPage(nil); body(ctx); ctx.endPDFPage(); ctx.closePDF()
            return data as Data
        }
        let ink = try pdf { draw($0, kern: 0, drop: 0, ink: true) }
        guard hidden else { return ink }
        let page = try #require(PDFDocument(data: ink)?.page(at: 0)?.pageRef)
        let scale: CGFloat = 300 / 72
        let bitmap = try #require(CGContext(data: nil, width: Int(612 * scale), height: Int(792 * scale), bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        bitmap.setFillColor(gray: 1, alpha: 1); bitmap.fill(CGRect(x: 0, y: 0, width: 612 * scale, height: 792 * scale))
        bitmap.scaleBy(x: scale, y: scale); bitmap.drawPDFPage(page)
        let picture = try #require(bitmap.makeImage())
        return try pdf { ctx in
            ctx.draw(picture, in: media)
            ctx.setTextDrawingMode(.invisible)
            draw(ctx, kern: -0.3, drop: 4, ink: false)
        }
    }

    @Test("Text the ink threshold does not read (grey 150, grey 190, white on a dark band): the painted box holds its glyphs",
          arguments: ["4100773265", "period", "summary"])
    func shadedTextPaintHoldsItsGlyphs(word: String) async throws {
        let source = try #require(PDFDocument(data: try Self.shadedPagePDF(hidden: false)))
        let export = try #require(PDFDocument(data: try Self.shadedPagePDF(hidden: true)))
        let page = try #require(export.page(at: 0)), sourcePage = try #require(source.page(at: 0))
        let cgPage = try #require(page.pageRef)
        let size = page.bounds(for: .cropBox).size
        #expect(DocumentSearcher.carriesHiddenTextOverImage(page, cgPage: cgPage), "the page is a picture under a hidden layer")
        await DocumentSearcher.prepareInkFit(page)
        let searcher = DocumentSearcher()
        let range = ((page.string ?? "") as NSString).range(of: word)
        let sourceRange = ((sourcePage.string ?? "") as NSString).range(of: word)
        try #require(range.location != NSNotFound && sourceRange.location != NSNotFound, "\(word) is in both layers")
        // The word's glyph box: its selection on the page where the text is the ink.
        let glyphs = try #require(sourcePage.selection(for: sourceRange).flatMap { searcher.normalizedRect(for: $0, page: sourcePage) })
        let fit = try #require(Self.settled({ searcher.textLayerAndInkRects(for: range, page: page) }, degraded: \.degraded))
        let painted = fit.paint.map { Self.points($0, size) }
        let held = Self.points(glyphs, size).insetBy(dx: 0.3, dy: 0.3)
        // Read as ink at a lighter threshold, or as light ink on its dark
        // band, the box is the glyphs' own: as tall as they are (with the
        // margins), never the read word's box alone, which reaches into the
        // leading. Degraded, it is the envelope and holds them.
        if !fit.degraded {
            #expect(painted.allSatisfy { $0.height <= Self.points(glyphs, size).height + 3 },
                    "\(word): a fitted box \(painted) is the glyphs' own height (\(Self.points(glyphs, size).height) pt), not a read word's box")
        }
        #expect(painted.contains { $0.contains(held) },
                "\(word): the painted box \(painted) does not hold its glyphs \(held) (degraded \(fit.degraded))")
    }

    @Test("With the render stalled, a lone word with an ascender and a descender keeps them inside its read box")
    func stalledRenderReadBoxHoldsAscenders() async throws {
        // One lower-case word alone on its line (no taller neighbour to widen
        // the band), drawn as ink and as a picture under a drifted layer.
        func page(hidden: Bool) throws -> Data {
            var media = CGRect(x: 0, y: 0, width: 612, height: 792)
            let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            func draw(_ ctx: CGContext, kern: CGFloat, drop: CGFloat) {
                let attributed = NSAttributedString(string: "period", attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTKernAttributeName as String): kern])
                ctx.textPosition = CGPoint(x: 200, y: 600 - drop)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
            }
            func pdf(_ body: (CGContext) -> Void) throws -> Data {
                let data = NSMutableData()
                let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
                let ctx = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
                ctx.beginPDFPage(nil); body(ctx); ctx.endPDFPage(); ctx.closePDF()
                return data as Data
            }
            let ink = try pdf { draw($0, kern: 0, drop: 0) }
            guard hidden else { return ink }
            let cg = try #require(PDFDocument(data: ink)?.page(at: 0)?.pageRef)
            let scale: CGFloat = 300 / 72
            let bitmap = try #require(CGContext(data: nil, width: Int(612 * scale), height: Int(792 * scale), bitsPerComponent: 8,
                                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            bitmap.setFillColor(gray: 1, alpha: 1); bitmap.fill(CGRect(x: 0, y: 0, width: 612 * scale, height: 792 * scale))
            bitmap.scaleBy(x: scale, y: scale); bitmap.drawPDFPage(cg)
            let picture = try #require(bitmap.makeImage())
            return try pdf { ctx in ctx.draw(picture, in: media); ctx.setTextDrawingMode(.invisible); draw(ctx, kern: -0.3, drop: 3) }
        }
        let source = try #require(PDFDocument(data: try page(hidden: false)))
        let export = try #require(PDFDocument(data: try page(hidden: true)))
        let exportPage = try #require(export.page(at: 0)), sourcePage = try #require(source.page(at: 0))
        let cgPage = try #require(exportPage.pageRef)
        let size = exportPage.bounds(for: .cropBox).size
        await DocumentSearcher.prepareInkFit(exportPage)
        let key = InkTokenCache.key(page: exportPage, cgPage: cgPage, visual: size)
        DocumentSearcher.inkFitInjectedRenderStalls.set((2.0, 0.3), for: key)
        defer { DocumentSearcher.inkFitInjectedRenderStalls.set(nil, for: key) }
        let range = ((exportPage.string ?? "") as NSString).range(of: "period")
        let raw = try #require(exportPage.selection(for: range).flatMap { DocumentSearcher().normalizedRect(for: $0, page: exportPage) })
        let truth = try #require(sourcePage.selection(for: ((sourcePage.string ?? "") as NSString).range(of: "period"))
            .flatMap { DocumentSearcher().normalizedRect(for: $0, page: sourcePage) })
        let fit = DocumentSearcher.inkFit(raw, page: exportPage, text: "period", range: range, paintOnly: true)
        #expect(fit.degraded, "a fit without its render is degraded")
        let outside = try Self.inkOutside(exportPage, word: Self.points(truth, size), boxes: [Self.points(fit.rect, size)])
        #expect(outside.share == 0, "period's ascender and descender ink outside its box: \(outside.share * 100)%, up to \(outside.reach) pt")
    }
}
