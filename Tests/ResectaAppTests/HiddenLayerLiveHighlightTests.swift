import Testing
import Foundation
import CoreGraphics
import CoreText
import PDFKit
import RedactionEngine
@testable import ResectaApp

// The live highlight on a page whose text is an invisible layer over a page
// image. The preview resolves its boxes on the main thread, which reads only
// the fits a search has made: once the search's fit lands
// (`DocumentSearcher.inkFitDidUpdate`, on which the sheet asks again) the
// highlight sits on the box Apply paints.

@Suite("Live highlight on a hidden layer")
@MainActor
struct HiddenLayerLiveHighlightTests {

    static let line = "Account holder Delia Hartwell"

    /// One letter page: a 300 dpi picture of a printed line, and the same line
    /// set in an invisible render mode in a monospaced face, 4 pt low and 5 pt
    /// to the right, as an earlier Searchable export leaves its layer.
    static func driftedLayerPage() throws -> PDFDocument {
        let size = CGSize(width: 612, height: 792)
        let scale: CGFloat = 300.0 / 72.0
        let bitmap = try #require(CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        bitmap.scaleBy(x: scale, y: scale)
        bitmap.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(Self.ctLine("Helvetica"), bitmap)
        let picture = try #require(bitmap.makeImage())

        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        pdf.beginPDFPage(nil)
        pdf.draw(picture, in: box)
        pdf.setTextDrawingMode(.invisible)
        pdf.textPosition = CGPoint(x: 77, y: 696)
        CTLineDraw(Self.ctLine("Courier"), pdf)
        pdf.endPDFPage()
        pdf.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }

    static func ctLine(_ face: String) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(
            string: line, attributes: [kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName(face as CFString, 14, nil)]))
    }

    static func same(_ a: [CGRect], _ b: [CGRect]) -> Bool {
        a.count == b.count && zip(a.sorted { $0.minX < $1.minX }, b.sorted { $0.minX < $1.minX }).allSatisfy { l, r in
            abs(l.minX - r.minX) < 0.0005 && abs(l.minY - r.minY) < 0.0005
                && abs(l.width - r.width) < 0.0005 && abs(l.height - r.height) < 0.0005
        }
    }

    @Test("once the page is read, the live highlight sits on the box Apply paints")
    func highlightMovesOntoThePaint() async throws {
        let document = try Self.driftedLayerPage()
        let page = try #require(document.page(at: 0))
        try #require((page.string ?? "").contains("Hartwell"), "the hidden layer is searchable")
        let searcher = DocumentSearcher()
        let mode = SearchMode.text("Hartwell", options: SearchOptions())
        let text = page.string
        let preview = await searcher.previewMatches(
            mode: mode, scope: .currentPage(pageIndex: 0), currentPageIndex: 0,
            totalPageCount: 1, pageTextProvider: { _ in text })

        // Listen before the search, whose fit posts the update the sheet asks
        // again on; the main thread reads only what a search has fitted.
        let updated = Task { @MainActor in
            for await _ in NotificationCenter.default.notifications(named: DocumentSearcher.inkFitDidUpdate) { return true }
            return false
        }
        var paints: [CGRect] = []
        for await result in searcher.search(SendablePDFDocument(document), mode: mode, progress: { _, _ in }) {
            paints.append(result.normalizedRect)
            #expect(result.textLayerRect != nil, "the page is a hidden layer over a page image")
        }
        try #require(paints.count == 1)
        let landed = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await updated.value }
            group.addTask { try? await Task.sleep(for: .seconds(20)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        updated.cancel()
        #expect(landed, "the fit posted its update")
        let highlight = PageHighlightOverlay.previewRects(for: preview, page: page, searcher: searcher)
        #expect(Self.same(highlight, paints), "highlight \(highlight) vs paint \(paints)")
    }
}
