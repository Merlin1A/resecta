import Testing
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

// Design 04 §4.5 — AND mode for multi-term search.
//
// Verifies that `SearchOptions.multiTermConjunction = true` restricts
// results to pages where EVERY queried term has at least one match,
// and that `multiTermConjunction = false` (default OR mode) retains
// the historical behavior of returning results from all matching pages.

@Suite("SearchMultiTermConjunction", .tags(.search))
struct SearchMultiTermConjunctionTests {

    // MARK: - Fixture

    /// Three-page text-layer PDF for conjunction tests:
    ///   page 0: "routing"
    ///   page 1: "routing account"
    ///   page 2: "routing account name"
    ///
    /// AND query for all three terms should return results only from page 2.
    private func threePageTermsPDF() -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 24),
            .foregroundColor: UIColor.black
        ]
        return renderer.pdfData { ctx in
            ctx.beginPage()
            ("routing" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: attrs)
            ctx.beginPage()
            ("routing account" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: attrs)
            ctx.beginPage()
            ("routing account name" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: attrs)
        }
    }

    // MARK: - Tests

    @Test("AND mode returns results only from pages where all terms match")
    func andModeOnlyReturnsPagesWithAllTerms() async {
        let data = threePageTermsPDF()
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        let options = SearchOptions(multiTermConjunction: true)
        let mode = SearchMode.multiTerm(["routing", "account", "name"], options: options)
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        let pageIndices = Set(results.map(\.pageIndex))
        // Only page index 2 has all three terms; pages 0 and 1 are excluded.
        #expect(!results.isEmpty, "AND query should return results from the page with all terms")
        #expect(pageIndices == [2], "AND mode should include only the page with all three terms")
        #expect(!pageIndices.contains(0), "Page 0 (routing only) must be excluded by AND mode")
        #expect(!pageIndices.contains(1), "Page 1 (routing + account) must be excluded by AND mode")
    }

    @Test("OR mode retains results from all pages that have at least one term")
    func orModeRetainsAllPages() async {
        let data = threePageTermsPDF()
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        // Default SearchOptions has multiTermConjunction = false (OR mode).
        let mode = SearchMode.multiTerm(["routing", "account", "name"], options: SearchOptions())
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        let pageIndices = Set(results.map(\.pageIndex))
        // All three pages have at least one term; OR mode returns results from all.
        #expect(pageIndices.contains(0), "OR mode should include page 0 (routing)")
        #expect(pageIndices.contains(1), "OR mode should include page 1 (routing + account)")
        #expect(pageIndices.contains(2), "OR mode should include page 2 (all three terms)")
    }

    @Test("AND mode returns no results when no single page has all terms")
    func andModeEmptyResultWhenNoPageHasAll() async {
        // Build a two-page PDF where no page contains both "alpha" and "beta".
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 24),
            .foregroundColor: UIColor.black
        ]
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            ("alpha only page" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: attrs)
            ctx.beginPage()
            ("beta only page" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: attrs)
        }

        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        let options = SearchOptions(multiTermConjunction: true)
        let mode = SearchMode.multiTerm(["alpha", "beta"], options: options)
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        #expect(results.isEmpty, "AND mode must return zero results when no page has all queried terms")
    }

    @Test("AND mode with a single term produces the same result set as OR mode")
    func andModeWithOneTermMatchesEverything() async {
        let data = threePageTermsPDF()
        guard let docAnd = PDFDocument(data: data),
              let docOr  = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocuments")
            return
        }

        let searcher = DocumentSearcher()
        let terms = ["routing"]

        let andStream = searcher.search(
            SendablePDFDocument(docAnd),
            mode: .multiTerm(terms, options: SearchOptions(multiTermConjunction: true)),
            progress: { _, _ in }
        )
        var andResults: [SearchResult] = []
        for await r in andStream { andResults.append(r) }

        let orStream = searcher.search(
            SendablePDFDocument(docOr),
            mode: .multiTerm(terms, options: SearchOptions(multiTermConjunction: false)),
            progress: { _, _ in }
        )
        var orResults: [SearchResult] = []
        for await r in orStream { orResults.append(r) }

        // With a single term, AND and OR should both match all pages that have
        // that term — the conjunction constraint adds no additional restriction.
        #expect(andResults.count == orResults.count,
                "Single-term AND and OR modes must return the same number of results")
        #expect(Set(andResults.map(\.pageIndex)) == Set(orResults.map(\.pageIndex)),
                "Single-term AND and OR modes must return results from the same pages")
    }
}
