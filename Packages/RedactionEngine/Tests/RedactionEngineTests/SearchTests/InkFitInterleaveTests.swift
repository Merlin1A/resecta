import Testing
import Foundation
import PDFKit
import CoreText
@testable import RedactionEngine

// A layer line an exporter interleaved, character by character, from two runs
// that share a printed band: a word matched inside it has no place of its own.

@Suite("Ink fit: interleaved layer lines")
struct InkFitInterleaveTests {
    static let printed = [("Employer's name, address, and ZIP code", CGFloat(72)), ("Foreign postal code", CGFloat(360))]
    static let garbled = "Emnploneyersr'sw noarmteh, aFdrdereigssh, anddfrieeslds cmodse, ZIP"

    /// The two runs printed on one band (`hidden` false), or a picture of them
    /// under one invisible layer line that interleaves them (`hidden` true).
    static func pagePDF(hidden: Bool) throws -> Data {
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
        func line(_ text: String) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font]))
        }
        func pdf(_ body: (CGContext) -> Void) throws -> Data {
            let data = NSMutableData()
            let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
            let ctx = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
            ctx.beginPDFPage(nil); body(ctx); ctx.endPDFPage(); ctx.closePDF()
            return data as Data
        }
        let ink = try pdf { ctx in
            for (text, x) in printed { ctx.textPosition = CGPoint(x: x, y: 600); CTLineDraw(line(text), ctx) }
            // Two ordinary lines below, which align.
            ctx.textPosition = CGPoint(x: 72, y: 560); CTLineDraw(line("Wages, tips, other compensation for the year"), ctx)
            ctx.textPosition = CGPoint(x: 72, y: 540); CTLineDraw(line("Federal income tax withheld from the wages"), ctx)
        }
        guard hidden else { return ink }
        let cg = try #require(PDFDocument(data: ink)?.page(at: 0)?.pageRef)
        let scale: CGFloat = 300 / 72
        let bitmap = try #require(CGContext(data: nil, width: Int(612 * scale), height: Int(792 * scale), bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        bitmap.setFillColor(gray: 1, alpha: 1); bitmap.fill(CGRect(x: 0, y: 0, width: 612 * scale, height: 792 * scale))
        bitmap.scaleBy(x: scale, y: scale); bitmap.drawPDFPage(cg)
        let picture = try #require(bitmap.makeImage())
        return try pdf { ctx in
            ctx.draw(picture, in: media)
            ctx.setTextDrawingMode(.invisible)
            ctx.textPosition = CGPoint(x: 72, y: 598); CTLineDraw(line(garbled), ctx)
            ctx.textPosition = CGPoint(x: 72, y: 558); CTLineDraw(line("Wages, tips, other compensation for the year"), ctx)
            ctx.textPosition = CGPoint(x: 72, y: 538); CTLineDraw(line("Federal income tax withheld from the wages"), ctx)
        }
    }

    @Test("A word matched inside an interleaved layer line gets its printed band, degraded, with no OCR-off report")
    func interleavedLineGetsItsBandAndThePageIsReported() async throws {
        let sourceDoc = try #require(PDFDocument(data: try Self.pagePDF(hidden: false)))
        let export = try #require(PDFDocument(data: try Self.pagePDF(hidden: true)))
        let page = try #require(export.page(at: 0)), source = try #require(sourceDoc.page(at: 0))
        let size = page.bounds(for: .cropBox).size
        await DocumentSearcher.prepareInkFit(page)
        // "and" as a substring of the garbled token "anddfrieeslds".
        let range = ((page.string ?? "") as NSString).range(of: "and")
        try #require(range.location != NSNotFound)
        let truthRange = ((source.string ?? "") as NSString).range(of: " and ")
        let truth = try #require(source.selection(for: NSRange(location: truthRange.location + 1, length: 3))
            .flatMap { DocumentSearcher().normalizedRect(for: $0, page: source) })
        let fit = try #require(PageImageInkFitTests.settled({ DocumentSearcher().textLayerAndInkRects(for: range, page: page) },
                                                           degraded: { _ in false }))
        #expect(fit.degraded, "a word on an interleaved line is degraded")
        let painted = fit.paint.map { PageImageInkFitTests.points($0, size) }
        let outside = try PageImageInkFitTests.inkOutside(page, word: PageImageInkFitTests.points(truth, size), boxes: painted)
        #expect(outside.share == 0, "the printed \"and\" outside the band: \(outside.share * 100)%")
        // An ordinary line on the same page still fits.
        let wages = ((page.string ?? "") as NSString).range(of: "Wages")
        let ordinary = try #require(DocumentSearcher().textLayerAndInkRects(for: wages, page: page))
        #expect(!ordinary.degraded, "a line the read agrees with is fitted")
        // A whole line fitted by its text (as an address line is): the band too.
        let lineRange = ((page.string ?? "") as NSString).lineRange(for: NSRange(location: range.location, length: 0))
        let lineText = ((page.string ?? "") as NSString).substring(with: lineRange).trimmingCharacters(in: .newlines)
        let lineBox = try #require(page.selection(for: lineRange).flatMap { DocumentSearcher().normalizedRect(for: $0, page: page) })
        let whole = DocumentSearcher.inkFit(lineBox, page: page, text: lineText, range: nil, paintOnly: true)
        #expect(whole.degraded, "an interleaved line fitted by its text is degraded")
        let wholeOutside = try PageImageInkFitTests.inkOutside(page, word: PageImageInkFitTests.points(truth, size),
                                                               boxes: [PageImageInkFitTests.points(whole.rect, size)])
        #expect(wholeOutside.share == 0, "the printed \"and\" outside the line's band: \(wholeOutside.share * 100)%")
        // The degraded box carries the notice; the OCR-off report (whose text
        // names OCR) is not raised for it.
        let reported = Reported()
        let searcher = DocumentSearcher()
        await searcher.setScannedRegionNotAnalyzedSink { reported.add($0) }
        // Recognition on, so the search's own OCR-off report (for a page with
        // image content searched without it) is not in play.
        var options = SearchOptions()
        options.includeOCR = true
        for await _ in searcher.search(SendablePDFDocument(export), mode: .text("and", options: options), progress: { _, _ in }) {}
        #expect(reported.pages.isEmpty, "no OCR-off report for an interleaved layer line: \(reported.pages)")
    }

    final class Reported: @unchecked Sendable {
        private let lock = NSLock()
        private var seen = Set<Int>()
        func add(_ page: Int) { lock.withLock { _ = seen.insert(page) } }
        var pages: Set<Int> { lock.withLock { seen } }
    }
}
