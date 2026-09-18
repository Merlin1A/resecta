import Testing
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

// Every `SearchResult` producer must yield a `contextSnippet` that contains
// its `matchedText` verbatim: the reverse-rationale sheet locates the match
// inside the snippet by string containment and falls back to appending the
// match when it cannot. A producer whose snippet drifts from its match
// (a different text source, a different offset space, a flattened line
// break inside the match) silently takes that fallback. This suite drives
// each producer path with a seeded page and pins the invariant on the
// producer — never on the sheet's fallback.
//
// Privacy rule: every value is fixture vocabulary; test names use the
// locate/match/resolve vocabulary (audit-lint M-1).

@Suite("Context snippet carries the displayed match", .tags(.search))
struct ContextSnippetInvariantTests {

    // MARK: - Helpers

    private func collect(
        _ searcher: DocumentSearcher, _ doc: PDFDocument, _ mode: SearchMode
    ) async -> [SearchResult] {
        let stream = searcher.search(SendablePDFDocument(doc), mode: mode, progress: { _, _ in })
        var results: [SearchResult] = []
        for await result in stream { results.append(result) }
        return results
    }

    private func imageOnlyPDF() -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return renderer.pdfData { context in
            context.beginPage()
            UIColor.blue.setFill()
            UIBezierPath(ovalIn: CGRect(x: 200, y: 300, width: 200, height: 200)).fill()
        }
    }

    private func line(_ text: String, y: CGFloat = 0.5) -> OCREngine.TextLine {
        OCREngine.TextLine(
            text: text, normalizedRect: CGRect(x: 0.1, y: y, width: 0.6, height: 0.05), confidence: 0.9)
    }

    /// The invariant, checked on every result of one producer path.
    private func check(_ results: [SearchResult], path: String) {
        #expect(!results.isEmpty, "\(path): the seeded page produced no result")
        for result in results {
            #expect(result.contextSnippet.contains(result.matchedText),
                    "\(path): snippet does not contain the match — snippet \"\(result.contextSnippet)\" match \"\(result.matchedText)\"")
            if let range = result.matchRangeInSnippet {
                let chars = Array(result.contextSnippet)
                #expect(range.upperBound <= chars.count, "\(path): matchRangeInSnippet past the snippet")
                if range.upperBound <= chars.count {
                    #expect(String(chars[range]) == result.matchedText,
                            "\(path): the snippet's match slice is not the match")
                }
            }
        }
    }

    // MARK: - Text-layer producers

    @Test("Text literal search: the window contains the match")
    func textLiteral() async {
        guard let doc = PDFDocument(data: TestFixtures.textLayerPDF(
            text: "Account holder Delia R. Hartwell, statement period ends")) else {
            Issue.record("PDFDocument creation failed"); return
        }
        let results = await collect(DocumentSearcher(), doc, .text("Hartwell", options: SearchOptions()))
        check(results, path: "text literal")
    }

    @Test("Text regex search: the window contains the match")
    func textRegex() async {
        guard let doc = PDFDocument(data: TestFixtures.textLayerPDF(
            text: "Reference SSN: 123-45-6789 on record")) else {
            Issue.record("PDFDocument creation failed"); return
        }
        let results = await collect(
            DocumentSearcher(), doc, .regex(#"\d{3}-\d{2}-\d{4}"#, options: SearchOptions()))
        check(results, path: "text regex")
    }

    @Test("PII scan on the text layer: the window contains the detector's match")
    func piiText() async {
        guard let doc = PDFDocument(data: TestFixtures.textLayerPDF(
            text: "Reference SSN: 123-45-6789 on record")) else {
            Issue.record("PDFDocument creation failed"); return
        }
        let results = await collect(
            DocumentSearcher(), doc, .piiScan(categories: [.ssn], options: SearchOptions()))
        check(results.filter { $0.piiCategory == .ssn }, path: "PII text")
    }

    @Test("Always-flag synthetic hit on the text layer: the window contains the match")
    func alwaysFlagText() async {
        guard let doc = PDFDocument(data: TestFixtures.textLayerPDF(
            text: "Invoice from Acme Corp dated 2025-01-01")) else {
            Issue.record("PDFDocument creation failed"); return
        }
        let searcher = DocumentSearcher()
        let matcher = UserTermMatcher.compile(
            alwaysFlag: [UserTerm(pattern: "Acme Corp", isRegex: false)], neverFlag: [])
        await searcher.setUserTerms(UserTermsIndex(matcher: matcher))
        let results = await collect(searcher, doc, .piiScan(categories: [.ssn], options: SearchOptions()))
        check(results.filter { $0.term == "Custom" }, path: "always-flag text")
    }

    // MARK: - OCR producers (seeded lines, no Vision)

    @Test("PII scan over OCR lines: the window contains the detector's match")
    func piiOCR() async {
        guard let doc = PDFDocument(data: imageOnlyPDF()) else {
            Issue.record("PDFDocument creation failed"); return
        }
        let searcher = DocumentSearcher()
        await searcher._testSeedOCRLines([line("Reference SSN 123-45-6789 on file")], forPageIndex: 0)
        let results = await collect(
            searcher, doc, .piiScan(categories: [.ssn], options: SearchOptions(includeOCR: true)))
        check(results.filter { $0.piiCategory == .ssn }, path: "PII OCR")
    }

    @Test("Literal search over OCR lines: the window contains the match")
    func literalOCR() async {
        guard let doc = PDFDocument(data: imageOnlyPDF()) else {
            Issue.record("PDFDocument creation failed"); return
        }
        let searcher = DocumentSearcher()
        await searcher._testSeedOCRLines([line("Quarterly report for Delia Hartwell")], forPageIndex: 0)
        let results = await collect(
            searcher, doc, .text("Hartwell", options: SearchOptions(includeOCR: true)))
        check(results, path: "OCR literal")
    }

    @Test("Regex search over OCR lines: the window contains the match")
    func regexOCR() async {
        guard let doc = PDFDocument(data: imageOnlyPDF()) else {
            Issue.record("PDFDocument creation failed"); return
        }
        let searcher = DocumentSearcher()
        await searcher._testSeedOCRLines([line("Case 12-AB-123456 filed")], forPageIndex: 0)
        let results = await collect(
            searcher, doc, .regex(#"\d{2}-[A-Z]{2}-\d{4,6}"#, options: SearchOptions(includeOCR: true)))
        check(results, path: "OCR regex fallback")
    }

    @Test("Always-flag synthetic hit over OCR lines: the window contains the match")
    func alwaysFlagOCR() async {
        guard let doc = PDFDocument(data: imageOnlyPDF()) else {
            Issue.record("PDFDocument creation failed"); return
        }
        let searcher = DocumentSearcher()
        await searcher._testSeedOCRLines([line("Invoice from Acme Corp dated today")], forPageIndex: 0)
        let matcher = UserTermMatcher.compile(
            alwaysFlag: [UserTerm(pattern: "Acme Corp", isRegex: false)], neverFlag: [])
        await searcher.setUserTerms(UserTermsIndex(matcher: matcher))
        let results = await collect(
            searcher, doc, .piiScan(categories: [.ssn], options: SearchOptions(includeOCR: true)))
        check(results.filter { $0.term == "Custom" }, path: "always-flag OCR")
    }

    // MARK: - The shared window builder

    @Test("The window keeps a match that spans a line break verbatim; the flattening stays outside the match")
    func windowKeepsLineBreakInsideMatch() async {
        let searcher = DocumentSearcher()
        let text = "alpha\nbeta gamma\ndelta"
        // "alpha\nbeta" — 10 Characters from offset 0.
        let window = await searcher.contextSnippet(text: text, matchStart: 0, matchLength: 10)
        #expect(window.snippet.contains("alpha\nbeta"),
                "the match must survive verbatim inside the window; got \"\(window.snippet)\"")
        #expect(window.matchRange == 0..<10)
        #expect(!window.snippet.hasSuffix("\ndelta") && window.snippet.contains(" delta"),
                "line breaks outside the match still flatten to spaces; got \"\(window.snippet)\"")
    }
}
