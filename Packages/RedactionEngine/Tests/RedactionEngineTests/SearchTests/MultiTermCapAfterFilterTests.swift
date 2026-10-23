import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// AND mode: the result cap counts the matches that survive the
// every-term-on-the-page filter, not the raw hits before it. A page dense in
// one term and empty of the other contributes nothing and must not use up
// the cap for the pages that do.
//
// Privacy rule (audit-lint M-1): locate/match vocabulary.

@Suite("Multi-term cap after the filter", .tags(.search))
struct MultiTermCapAfterFilterTests {

    /// Two pages: the first carries `dense` copies of "alpha" and no "beta";
    /// the second carries "alpha beta" once.
    static func twoPagePDF(dense: Int) -> Data {
        let alphas = (0..<dense).map { i in "BT /F1 6 Tf \(20 + (i % 60) * 9) \(780 - (i / 60) * 8) Td (alpha) Tj ET" }.joined(separator: "\n")
        let second = "BT /F1 12 Tf 72 700 Td (alpha beta) Tj ET"
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(alphas.utf8.count) >>\nstream\n\(alphas)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>"),
            PDFObject(id: 6, content: """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
                /Contents 7 0 R /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 7, content: "<< /Length \(second.utf8.count) >>\nstream\n\(second)\nendstream"),
        ], rootId: 1)
    }

    @Test("A page dense in one term does not use up the cap for the page that carries both")
    func capCountsSurvivors() async throws {
        let dense = DocumentSearcher.maxResults + 100
        let doc = try #require(PDFDocument(data: Self.twoPagePDF(dense: dense)))
        #expect(doc.pageCount == 2)
        var options = SearchOptions()
        options.multiTermConjunction = true
        let searcher = DocumentSearcher()
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: .multiTerm(["alpha", "beta"], options: options), progress: { _, _ in })
        var hits: [SearchResult] = []
        for await hit in stream { hits.append(hit) }
        #expect(hits.count == 2, "both terms on the second page survive: \(hits.map { "\($0.pageIndex):\($0.term)" })")
        #expect(hits.allSatisfy { $0.pageIndex == 1 })
    }
}
