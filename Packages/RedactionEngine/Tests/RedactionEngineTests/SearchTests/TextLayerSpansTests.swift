import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

// `TextLayerSpans.words(fullyInside:polygon:on:)` — the word-span primitive:
// the words of a page's text layer whose boxes lie fully inside a
// normalized region rect (the displayed frame, bottom-left origin), in
// reading order, with a 0.5-pt tolerance on the region's edges; a polygon
// narrows the rect to the words whose centre lies inside it. The rects it
// returns are the frame `DocumentSearcher.boundingRect(for:page:)` uses,
// so the search path and the capture agree on every rotation. The
// whole-page skip is the caller's (the whole-page rule), not the primitive's.

@Suite("TextLayerSpans — words fully inside a region")
struct TextLayerSpansTests {

    private enum TestError: Error { case failed }

    /// Three lines of Helvetica 24 at known positions on a 612 × 792 page:
    /// "ALPHA BRAVO CHARLIE" (upper left), "DELTA ECHO" (below it) and
    /// "FOXTROT" (lower right). Reading order is the content order.
    private static func wordsPDF() -> Data {
        let stream = """
            BT /F1 24 Tf 72 700 Td (ALPHA BRAVO CHARLIE) Tj ET
            BT /F1 24 Tf 72 600 Td (DELTA ECHO) Tj ET
            BT /F1 24 Tf 360 90 Td (FOXTROT) Tj ET
            """
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ], rootId: 1)
    }

    private static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    private func page(_ data: Data) throws -> PDFPage {
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else {
            throw TestError.failed
        }
        return page
    }

    /// Every word on the page keyed by text (the unit rect admits all).
    private func wordRects(_ page: PDFPage) -> [String: CGRect] {
        Dictionary(TextLayerSpans.words(fullyInside: Self.unit, on: page).map { ($0.text, $0.normalizedRect) },
                   uniquingKeysWith: { a, _ in a })
    }

    /// A normalized inset of `points` PDF points on every edge of the page's
    /// displayed frame.
    private func inset(_ rect: CGRect, points: CGFloat, on page: PDFPage) -> CGRect {
        let size = effectiveBounds(page.bounds(for: .cropBox), rotation: page.rotation).size
        return rect.insetBy(dx: points / size.width, dy: points / size.height)
    }

    @Test("The unit rect returns every word in reading order")
    func unitRectReturnsEveryWordInReadingOrder() throws {
        let page = try page(Self.wordsPDF())
        let spans = TextLayerSpans.words(fullyInside: Self.unit, on: page)
        #expect(spans.map(\.text) == ["ALPHA", "BRAVO", "CHARLIE", "DELTA", "ECHO", "FOXTROT"])
        for span in spans {
            #expect(span.normalizedRect.width > 0 && span.normalizedRect.height > 0)
            #expect(Self.unit.contains(span.normalizedRect))
        }
    }

    @Test("A rect covering two whole words returns exactly those two")
    func rectCoveringTwoWordsReturnsThem() throws {
        let page = try page(Self.wordsPDF())
        let rects = wordRects(page)
        let alpha = try #require(rects["ALPHA"]); let bravo = try #require(rects["BRAVO"])
        let region = inset(alpha.union(bravo), points: -1, on: page)
        let spans = TextLayerSpans.words(fullyInside: region, on: page)
        #expect(spans.map(\.text) == ["ALPHA", "BRAVO"])
        #expect(spans.map(\.normalizedRect) == [alpha, bravo])
    }

    @Test("A rect clipping a word's edge excludes that word")
    func rectClippingAWordExcludesIt() throws {
        let page = try page(Self.wordsPDF())
        let rects = wordRects(page)
        let alpha = try #require(rects["ALPHA"]); let bravo = try #require(rects["BRAVO"])
        // ALPHA whole, BRAVO's left half only.
        var region = alpha.union(bravo)
        region.size.width = bravo.midX - region.minX
        region = inset(region, points: -1, on: page)
        #expect(TextLayerSpans.words(fullyInside: region, on: page).map(\.text) == ["ALPHA"])
    }

    @Test("The 0.5-pt edge tolerance admits a word whose box touches the region edge; 1 pt does not")
    func edgeTolerance() throws {
        let page = try page(Self.wordsPDF())
        let alpha = try #require(wordRects(page)["ALPHA"])
        #expect(TextLayerSpans.words(fullyInside: alpha, on: page).map(\.text) == ["ALPHA"])
        #expect(TextLayerSpans.words(fullyInside: inset(alpha, points: 0.4, on: page), on: page).map(\.text) == ["ALPHA"])
        #expect(TextLayerSpans.words(fullyInside: inset(alpha, points: 1.0, on: page), on: page).isEmpty)
    }

    @Test("An L-shaped polygon excludes the word in its notch")
    func polygonExcludesTheNotch() throws {
        let page = try page(Self.wordsPDF())
        let rects = wordRects(page)
        let alpha = try #require(rects["ALPHA"]); let charlie = try #require(rects["CHARLIE"])
        let delta = try #require(rects["DELTA"]); let echo = try #require(rects["ECHO"])
        // The bounding rect spans both upper lines; the notch (top-right)
        // cuts CHARLIE out, DELTA/ECHO sit under the full-width lower arm.
        let bounds = inset(alpha.union(charlie).union(delta).union(echo), points: -2, on: page)
        let notchX = (rects["BRAVO"]!.maxX + charlie.minX) / 2
        let notchY = (echo.maxY + alpha.minY) / 2
        let lShape = [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: notchY),
            CGPoint(x: notchX, y: notchY),
            CGPoint(x: notchX, y: bounds.maxY),
            CGPoint(x: bounds.minX, y: bounds.maxY),
        ]
        let spans = TextLayerSpans.words(fullyInside: bounds, polygon: lShape, on: page)
        #expect(spans.map(\.text) == ["ALPHA", "BRAVO", "DELTA", "ECHO"])
        // Without the polygon the bounding rect admits the notch's word too.
        #expect(TextLayerSpans.words(fullyInside: bounds, on: page).map(\.text) == ["ALPHA", "BRAVO", "CHARLIE", "DELTA", "ECHO"])
    }

    @Test("A rotated page: the region drawn in the displayed frame returns the word under it",
          arguments: [0, 90, 180, 270])
    func rotatedPageUsesTheDisplayedFrame(rotation: Int) throws {
        let page = try page(TestFixtures.rotatedTextPDF(rotation: rotation))
        #expect(page.rotation == rotation)
        let text = try #require(page.string)
        let anchorRange = (text as NSString).range(of: "ANCHOR")
        // The search path's inverse mapping is the frame of record.
        let anchorRect = try #require(DocumentSearcher().boundingRect(for: anchorRange, page: page))
        let spans = TextLayerSpans.words(fullyInside: inset(anchorRect, points: -1, on: page), on: page)
        #expect(spans.map(\.text) == ["ANCHOR"])
    }

    @Test("Every span's rect is the search path's rect for the same word",
          arguments: [0, 90, 180, 270])
    func spanRectsMatchTheSearchFrame(rotation: Int) throws {
        let page = try page(TestFixtures.rotatedTextPDF(rotation: rotation))
        let text = try #require(page.string) as NSString
        let searcher = DocumentSearcher()
        let spans = TextLayerSpans.words(fullyInside: Self.unit, on: page)
        #expect(spans.map(\.text) == ["ANCHOR", "MARKER"])
        for span in spans {
            let expected = try #require(searcher.boundingRect(for: text.range(of: span.text), page: page))
            #expect(abs(span.normalizedRect.minX - expected.minX) < 1e-6, "\(rotation)° \(span.text) minX")
            #expect(abs(span.normalizedRect.minY - expected.minY) < 1e-6, "\(rotation)° \(span.text) minY")
            #expect(abs(span.normalizedRect.width - expected.width) < 1e-6, "\(rotation)° \(span.text) width")
            #expect(abs(span.normalizedRect.height - expected.height) < 1e-6, "\(rotation)° \(span.text) height")
        }
    }

    @Test("An image-only page has no words")
    func imageOnlyPageHasNoWords() throws {
        let page = try page(TestFixtures.imageOnlyPDF())
        #expect(TextLayerSpans.words(fullyInside: Self.unit, on: page).isEmpty)
    }

    @Test("An empty or degenerate region admits nothing")
    func degenerateRegionAdmitsNothing() throws {
        let page = try page(Self.wordsPDF())
        #expect(TextLayerSpans.words(fullyInside: .zero, on: page).isEmpty)
        #expect(TextLayerSpans.words(fullyInside: CGRect(x: 0.95, y: 0.95, width: 0.05, height: 0.05), on: page).isEmpty)
    }

    @Test("TextSpan is a plain value")
    func textSpanIsAValue() {
        let a = TextSpan(text: "x", normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        let b = TextSpan(text: "x", normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        #expect(a == b)
        #expect(a.text == "x")
    }
}
