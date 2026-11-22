import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

/// The grown box on the routes that carry it further: a match across a page
/// seam, and the hybrid leg's merge with the page image's recognised text.
@Suite("Grown boxes across a page seam and in the hybrid merge")
struct ContentGlyphRouteTests {
    static let sliver = ContentGlyphWalkTests.visible + "\nBT /F1 12 Tf 0 0 0 0 72 700 Tm (QUARTZ7) Tj ET"

    /// Two Letter pages, each drawn by its own content in Helvetica.
    static func twoPages(_ first: String, _ second: String) throws -> PDFDocument {
        let data = buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 >>"),
            PDFObject(id: 3, content: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>"),
            PDFObject(id: 4, content: "<< /Length \(first.utf8.count) >>\nstream\n\(first)\nendstream"),
            PDFObject(id: 5, content: ContentGlyphWalkTests.helvetica),
            PDFObject(id: 6, content: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R /Resources << /Font << /F1 5 0 R >> >> >>"),
            PDFObject(id: 7, content: "<< /Length \(second.utf8.count) >>\nstream\n\(second)\nendstream"),
        ], rootId: 1)
        return try #require(PDFDocument(data: data))
    }

    static func points(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * 612, y: r.minY * 792, width: r.width * 612, height: r.height * 792)
    }

    @Test("A match across a page seam: the part on the first page, a word a TJ draws back, covers its first letter; the part on the next keeps PDFKit's box")
    func acrossTheSeam() async throws {
        let doc = try Self.twoPages("BT /F1 12 Tf 72 700 Td [(Inv) -250 (oice) 1200 (Total)] TJ ET",
                                    "BT /F1 12 Tf 72 700 Td (holder named below) Tj ET")
        let page1 = try #require(doc.page(at: 0))
        let range1 = ((try #require(page1.string)) as NSString).range(of: "Total")
        let short = try #require(page1.selection(for: range1)?.bounds(for: page1))
        try #require(short.minX > 100, "precondition: PDFKit's box on page 1 starts at \(short.minX); page text \((page1.string ?? "").debugDescription)")
        var options = SearchOptions()
        options.includeOCR = false
        options.wholeWord = false
        var hits: [SearchResult] = []
        for await r in DocumentSearcher().search(SendablePDFDocument(doc), mode: .text("Total holder", options: options), progress: { _, _ in }) {
            hits.append(r)
        }
        let firstPart = hits.filter { $0.pageIndex == 0 }.map { Self.points($0.normalizedRect) }
        let second = hits.filter { $0.pageIndex == 1 }.map { Self.points($0.normalizedRect) }
        try #require(firstPart.count == 1 && second.count == 1, "one part on each page, page 1 text \((page1.string ?? "").debugDescription): \(hits.map { "\($0.pageIndex) \(Self.points($0.normalizedRect))" })")
        #expect(Set(hits.map(\.occurrenceID)).count == 1, "both parts share one occurrence")
        #expect(firstPart[0].minX <= 98.616 + DocumentSearcher.growthSlack, "the first part starts at \(firstPart[0].minX); the T starts at 98.616")
        let page2 = try #require(doc.page(at: 1))
        let range = ((try #require(page2.string)) as NSString).range(of: "holder")
        let today = try #require(page2.selection(for: range)?.bounds(for: page2))
        #expect(ContentGlyphBoxTests.close(second[0], today, 0.001), "\(second[0]) against PDFKit's \(today)")
    }

    @Test("The hybrid merge with a grown box: the recognised result on the same word is dropped, its twin drawn in the page image just past it is kept")
    func hybridTwinKept() async throws {
        let grown = try #require(try await ContentGlyphBoxTests.boxes(Self.sliver, "account").first)
        try #require(grown.maxX >= 260.088 - DocumentSearcher.growthSlack, "precondition: the box is grown, to \(grown.maxX)")
        func ocr(_ r: CGRect) -> SearchResult {
            SearchResult(pageIndex: 0, normalizedRect: CGRect(x: r.minX / 612, y: r.minY / 792, width: r.width / 612, height: r.height / 792),
                         matchedText: "account", contextSnippet: "account", source: .ocr(confidence: 1), term: "account")
        }
        let normalized = CGRect(x: grown.minX / 612, y: grown.minY / 792, width: grown.width / 612, height: grown.height / 792)
        // The same word read from the page image, and a twin drawn in the
        // image half a point past the grown box's end, on the same line.
        let same = ocr(CGRect(x: 218.3, y: 697.6, width: 41.6, height: 11.0))
        let twin = ocr(CGRect(x: grown.maxX + 0.5, y: 697.6, width: 41.6, height: 11.0))
        let kept = DocumentSearcher.mergeHybridResults(textLayerRects: [normalized], ocr: [same, twin])
        #expect(kept.map(\.id) == [twin.id], "kept \(kept.map { Self.points($0.normalizedRect) })")
    }

    @Test("The hybrid merge tells a grown text-layer match by its box before the growth: a recognised occurrence beside it that the grown box would swallow is kept, and the grown box still covers its word")
    func hybridNeighbourBesideTheGrowth() async throws {
        let doc = try ContentGlyphWalkTests.document("BT /F1 12 Tf 72 700 Td [(Inv) -250 (oice) 1200 (Total)] TJ ET")
        var options = SearchOptions()
        options.includeOCR = false
        options.wholeWord = false
        var hits: [SearchResult] = []
        for await r in DocumentSearcher().search(SendablePDFDocument(doc), mode: .text("Total", options: options), progress: { _, _ in }) {
            hits.append(r)
        }
        let hit = try #require(hits.first, "one match")
        let grown = Self.points(hit.normalizedRect)
        let identity = Self.points(try #require(hit.identityRect, "the grown match carries the box it is told by"))
        try #require(grown.minX <= 98.616 + DocumentSearcher.growthSlack && identity.minX > grown.minX + 1,
                     "precondition: the box grew to the T at 98.616, \(grown), from \(identity)")
        // The grown box covers its word; what it is told by is today's box.
        let page = try #require(doc.page(at: 0))
        let range = ((try #require(page.string)) as NSString).range(of: "Total")
        let selection = try #require(page.selection(for: range))
        let today = try #require(DocumentSearcher().normalizedRect(for: selection, page: page))
        #expect(ContentGlyphBoxTests.close(identity, Self.points(today), 0.5), "identity \(identity), today's box \(Self.points(today))")
        func ocr(_ r: CGRect) -> SearchResult {
            SearchResult(pageIndex: 0, normalizedRect: CGRect(x: r.minX / 612, y: r.minY / 792, width: r.width / 612, height: r.height / 792),
                         matchedText: "Total", contextSnippet: "Total", source: .ocr(confidence: 1), term: "Total")
        }
        // The same word read from the page image, at today's box; and an
        // occurrence only the page image holds, beside it on the line, that
        // reaches just past the grown box's centre and covers less than half
        // of today's box.
        let same = ocr(identity)
        let beside = ocr(CGRect(x: grown.midX + 0.1 - identity.width, y: identity.minY, width: identity.width, height: identity.height))
        try #require(DocumentSearcher.mergeHybridResults(textLayerRects: [hit.normalizedRect], ocr: [beside]).isEmpty,
                     "precondition: told by the grown box, the occurrence beside it is taken for a repeat")
        let kept = DocumentSearcher.mergeHybridResults(textLayerRects: hits.map(\.mergeIdentity), ocr: [same, beside])
        #expect(kept.map(\.id) == [beside.id], "kept \(kept.map { Self.points($0.normalizedRect) }); grown \(grown), identity \(identity)")
    }
}
