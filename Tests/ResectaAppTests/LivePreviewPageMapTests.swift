import Testing
import Foundation
import CoreGraphics
import UIKit
import PDFKit
import RedactionEngine
@testable import ResectaApp

// The live preview's highlight sits on the box Apply places. The full search
// maps each match to the raw page text (`PDFPage.string`) and places one box
// per line the match spans; the preview's own ranges are in the searched
// text's coordinates, which shift on a page the search normalizes (an
// ellipsis before the match, which it reads as three dots; PDFKit keeps the
// "…" in the page text, where a drawn ligature comes back as two letters),
// and one bounding rect per range joined a match that
// wraps into one box across the gap. Read through a real `DocumentSearcher`
// on in-memory pages, as the sheet reads them: the preview from
// `previewMatches` over `page.string`, the boxes from the full search.

@Suite("Live preview on the page map")
@MainActor
struct LivePreviewPageMapTests {

    /// A one-page document with each line drawn at its own baseline.
    private static func document(lines: [String]) throws -> PDFDocument {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            ctx.beginPage()
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 16)]
            for (i, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 72, y: 100 + CGFloat(i) * 24), withAttributes: attributes)
            }
        }
        return try #require(PDFDocument(data: data))
    }

    private static func appliedBoxes(_ mode: SearchMode, in document: PDFDocument, searcher: DocumentSearcher) async -> [CGRect] {
        var boxes: [CGRect] = []
        for await result in searcher.search(SendablePDFDocument(document), mode: mode, progress: { _, _ in }) {
            boxes.append(result.normalizedRect)
        }
        return boxes
    }

    private static func preview(_ mode: SearchMode, page: PDFPage, searcher: DocumentSearcher) async -> SearchPreviewResult {
        let text = page.string
        return await searcher.previewMatches(
            mode: mode, scope: .currentPage(pageIndex: 0), currentPageIndex: 0,
            totalPageCount: 1, pageTextProvider: { _ in text })
    }

    private static func same(_ a: [CGRect], _ b: [CGRect]) -> Bool {
        a.count == b.count && zip(a.sorted { $0.minY < $1.minY }, b.sorted { $0.minY < $1.minY }).allSatisfy { l, r in
            abs(l.minX - r.minX) < 0.001 && abs(l.minY - r.minY) < 0.001
                && abs(l.width - r.width) < 0.001 && abs(l.height - r.height) < 0.001
        }
    }

    @Test("After an ellipsis, the preview's highlight sits on the box Apply places, for Text and Regex")
    func highlightSitsOnTheBoxAfterAnEllipsis() async throws {
        let document = try Self.document(lines: ["Note\u{2026} SSN 123-45-6789 on file."])
        let page = try #require(document.page(at: 0))
        try #require((page.string ?? "").contains("\u{2026}"), "the page's text keeps the ellipsis, so the search maps it")
        let searcher = DocumentSearcher()
        var separatorFold = SearchOptions()
        separatorFold.stripDigitSeparators = true
        for mode in [SearchMode.text("123-45-6789", options: SearchOptions()),
                     .regex(#"\d{3}-\d{2}-\d{4}"#, options: SearchOptions()),
                     .text("123456789", options: separatorFold)] {
            let boxes = await Self.appliedBoxes(mode, in: document, searcher: searcher)
            try #require(boxes.count == 1, "the full search places one box")
            let preview = await Self.preview(mode, page: page, searcher: searcher)
            try #require(preview.currentPageMatches != preview.currentPageRawRanges, "\(mode): the page needs the map")
            let highlight = PageHighlightOverlay.previewRects(for: preview, page: page, searcher: searcher)
            #expect(Self.same(highlight, boxes), "\(mode): highlight \(highlight) vs box \(boxes)")
        }
    }

    @Test("A match on two lines gets a highlight on each line, as Apply places a box on each")
    func highlightPerLine() async throws {
        let document = try Self.document(lines: ["Please contact Delia", "Hartwell at the office."])
        let page = try #require(document.page(at: 0))
        let searcher = DocumentSearcher()
        let mode = SearchMode.text("Delia Hartwell", options: SearchOptions())
        let boxes = await Self.appliedBoxes(mode, in: document, searcher: searcher)
        try #require(boxes.count == 2, "the full search places a box on each line (read \(boxes.count))")
        let preview = await Self.preview(mode, page: page, searcher: searcher)
        let highlight = PageHighlightOverlay.previewRects(for: preview, page: page, searcher: searcher)
        #expect(Self.same(highlight, boxes), "highlight \(highlight) vs boxes \(boxes)")
    }
}
