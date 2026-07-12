import Testing
import PDFKit
@testable import RedactionEngine

@Suite("DocumentSearcher.previewMatches", .tags(.search))
struct LivePreviewTests {

    // MARK: - Fixtures

    /// Two-page PDF: page 0 has 7 occurrences of "alpha", page 1 has 5.
    private func twoPageFixture() -> PDFDocument {
        let p0 = "alpha alpha alpha alpha alpha alpha alpha"
        let p1 = "alpha alpha alpha alpha alpha"
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let data = renderer.pdfData { context in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 18),
                .foregroundColor: UIColor.black
            ]
            context.beginPage()
            (p0 as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: attrs)
            context.beginPage()
            (p1 as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: attrs)
        }
        return PDFDocument(data: data)!
    }

    private func providerFor(_ doc: PDFDocument) -> @Sendable (Int) async -> String? {
        let texts: [String] = (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
        return { idx in
            guard idx >= 0 && idx < texts.count else { return nil }
            return texts[idx]
        }
    }

    // MARK: - Scope behavior

    @Test("currentPage scope counts visible page only and returns its highlights")
    func currentPageScope() async {
        let doc = twoPageFixture()
        let searcher = DocumentSearcher()
        let mode = SearchMode.text("alpha", options: SearchOptions())

        let result = await searcher.previewMatches(
            mode: mode,
            scope: .currentPage(pageIndex: 0),
            currentPageIndex: 0,
            totalPageCount: doc.pageCount,
            pageTextProvider: providerFor(doc)
        )

        #expect(result.totalCount == 7)
        #expect(result.currentPageMatches.count == 7)
        #expect(result.saturated == false)
        #expect(result.regexInvalid == false)
    }

    @Test("currentPage scope on non-visible page yields no highlights")
    func currentPageScopeOffVisible() async {
        let doc = twoPageFixture()
        let searcher = DocumentSearcher()
        let mode = SearchMode.text("alpha", options: SearchOptions())

        let result = await searcher.previewMatches(
            mode: mode,
            scope: .currentPage(pageIndex: 1),
            currentPageIndex: 0,
            totalPageCount: doc.pageCount,
            pageTextProvider: providerFor(doc)
        )

        // Walked page 1 (5 matches), but visible page is 0 → no highlights.
        #expect(result.totalCount == 5)
        #expect(result.currentPageMatches.isEmpty)
    }

    @Test("wholeDocument scope counts all pages, highlights only visible page")
    func wholeDocumentScope() async {
        let doc = twoPageFixture()
        let searcher = DocumentSearcher()
        let mode = SearchMode.text("alpha", options: SearchOptions())

        let result = await searcher.previewMatches(
            mode: mode,
            scope: .wholeDocument,
            currentPageIndex: 0,
            totalPageCount: doc.pageCount,
            pageTextProvider: providerFor(doc)
        )

        #expect(result.totalCount == 12)
        #expect(result.currentPageMatches.count == 7)
        #expect(result.saturated == false)
    }

    // MARK: - Regex paths

    @Test("Invalid regex is rejected, no highlights drawn")
    func invalidRegex() async {
        let doc = twoPageFixture()
        let searcher = DocumentSearcher()
        // Nested quantifiers — caught by hasNestedQuantifiers heuristic.
        let mode = SearchMode.regex("(a+)+b", options: SearchOptions())

        let result = await searcher.previewMatches(
            mode: mode,
            scope: .wholeDocument,
            currentPageIndex: 0,
            totalPageCount: doc.pageCount,
            pageTextProvider: providerFor(doc)
        )

        #expect(result.totalCount == 0)
        #expect(result.currentPageMatches.isEmpty)
        #expect(result.regexInvalid == true)
        #expect(result.saturated == false)
    }

    @Test("Valid regex counts and highlights the visible page")
    func validRegex() async {
        let doc = twoPageFixture()
        let searcher = DocumentSearcher()
        let mode = SearchMode.regex("alph[a-z]+", options: SearchOptions())

        let result = await searcher.previewMatches(
            mode: mode,
            scope: .wholeDocument,
            currentPageIndex: 0,
            totalPageCount: doc.pageCount,
            pageTextProvider: providerFor(doc)
        )

        #expect(result.totalCount == 12)
        #expect(result.currentPageMatches.count == 7)
        #expect(result.regexInvalid == false)
    }

    // MARK: - Saturation

    @Test("Saturation flips on at the cap and counts stop")
    func saturation() async {
        // Force >maxPreviewMatches by repeating a token many times on one page.
        // Each "x" on a single page line.
        let many = String(repeating: "x ", count: DocumentSearcher.maxPreviewMatches + 1)
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: pageRect).pdfData { context in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 6),
                .foregroundColor: UIColor.black
            ]
            context.beginPage()
            (many as NSString).draw(in: pageRect.insetBy(dx: 12, dy: 12), withAttributes: attrs)
        }
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to build saturation fixture")
            return
        }

        let searcher = DocumentSearcher()
        let mode = SearchMode.text("x", options: SearchOptions())

        let result = await searcher.previewMatches(
            mode: mode,
            scope: .wholeDocument,
            currentPageIndex: 0,
            totalPageCount: doc.pageCount,
            pageTextProvider: providerFor(doc)
        )

        #expect(result.totalCount == DocumentSearcher.maxPreviewMatches)
        #expect(result.saturated == true)
        // Highlights still capped at maxCurrentPageHighlights.
        #expect(result.currentPageMatches.count <= DocumentSearcher.maxCurrentPageHighlights)
    }

    // MARK: - PII guard

    @Test("piiScan mode returns empty result")
    func piiScanIgnored() async {
        let doc = twoPageFixture()
        let searcher = DocumentSearcher()
        let mode = SearchMode.piiScan(categories: Set(PIICategory.allCases), options: SearchOptions())

        let result = await searcher.previewMatches(
            mode: mode,
            scope: .wholeDocument,
            currentPageIndex: 0,
            totalPageCount: doc.pageCount,
            pageTextProvider: providerFor(doc)
        )

        #expect(result.totalCount == 0)
        #expect(result.currentPageMatches.isEmpty)
    }

    // MARK: - Empty / boundary inputs

    @Test("Empty query yields zero matches without crashing")
    func emptyQuery() async {
        let doc = twoPageFixture()
        let searcher = DocumentSearcher()
        let mode = SearchMode.text("", options: SearchOptions())

        let result = await searcher.previewMatches(
            mode: mode,
            scope: .wholeDocument,
            currentPageIndex: 0,
            totalPageCount: doc.pageCount,
            pageTextProvider: providerFor(doc)
        )

        #expect(result.totalCount == 0)
        #expect(result.currentPageMatches.isEmpty)
    }
}
