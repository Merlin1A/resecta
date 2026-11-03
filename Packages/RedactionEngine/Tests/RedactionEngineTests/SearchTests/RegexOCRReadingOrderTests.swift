import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// A regex over a scanned page runs on two readings of its recognized lines:
// as Vision read them, and through the confusable correction ("1D" → "ID").
// A match only the corrected reading holds takes its place in page order
// among the others, as a match only the fast read holds does.

@Suite("Regex search over a scanned page: matches in page order", .tags(.search))
struct RegexOCRReadingOrderTests {

    /// Whether `a` comes before `b` in page order: on one row, left to right;
    /// otherwise top to bottom (bottom-left origin).
    private func precedes(_ a: CGRect, _ b: CGRect) -> Bool {
        if DocumentSearcher.sharesRow(a, b) { return a.minX < b.minX }
        return a.midY > b.midY
    }

    private func outOfOrder(_ results: [SearchResult]) -> [(CGRect, CGRect)] {
        zip(results, results.dropFirst()).compactMap { pair in
            precedes(pair.1.normalizedRect, pair.0.normalizedRect) ? (pair.0.normalizedRect, pair.1.normalizedRect) : nil
        }
    }

    @Test("A match only the corrected reading holds is listed where it sits on the page")
    func correctedOnlyMatchIsInPageOrder() async throws {
        let doc = try #require(PDFDocument(data: TestFixtures.imageOnlyPDF()))
        let above = CGRect(x: 0.075, y: 0.78, width: 0.34, height: 0.018)
        let left = CGRect(x: 0.072, y: 0.669, width: 0.05, height: 0.015)
        let right = CGRect(x: 0.553, y: 0.665, width: 0.28, height: 0.02)
        let searcher = DocumentSearcher()
        await searcher._testSeedOCRLines([
            OCREngine.TextLine(text: "Borrower ID 4471-22", normalizedRect: above, confidence: 0.9),
            OCREngine.TextLine(text: "1D State", normalizedRect: left, confidence: 0.9),
            OCREngine.TextLine(text: "Proof of ID attached", normalizedRect: right, confidence: 0.9),
        ], forPageIndex: 0)
        var options = SearchOptions()
        options.includeOCR = true
        var results: [SearchResult] = []
        for await r in searcher.search(SendablePDFDocument(doc), mode: .regex(#"\bID\b"#, options: options),
                                       progress: { _, _ in }) { results.append(r) }
        #expect(results.count == 3, "three occurrences, one only in the corrected reading: \(results.map(\.normalizedRect))")
        #expect(outOfOrder(results).isEmpty, "listed out of page order: \(results.map(\.normalizedRect))")
        let lefts = results.map(\.normalizedRect.minX)
        #expect(lefts.count == 3 && lefts[1] < lefts[2], "on the shared row, the left match comes first: \(lefts)")
    }

    @Test("The scanned loan packet's page 10: every `ID` match is in page order")
    func scannedPacketPageTenIsInPageOrder() async throws {
        let doc = try #require(PDFDocument(data: try TestFixtures.loanPacketScanSimPDF()))
        var options = SearchOptions()
        options.includeOCR = true
        var results: [SearchResult] = []
        for await r in DocumentSearcher().search(SendablePDFDocument(doc), mode: .regex(#"\bID\b"#, options: options),
                                                 progress: { _, _ in }) { results.append(r) }
        let page = results.filter { $0.pageIndex == 9 }
        #expect(!page.isEmpty, "the page holds ID matches")
        #expect(outOfOrder(page).isEmpty, "listed out of page order: \(page.map(\.normalizedRect))")
    }
}
