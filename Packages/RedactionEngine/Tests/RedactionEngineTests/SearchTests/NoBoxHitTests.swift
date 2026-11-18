import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

/// A match that is found but cannot be given a box is listed with its
/// page and no box, never dropped (the product rule), at every site that used to
/// drop it. Planted cases: a word drawn under a zero text matrix (PDFKit gives
/// its characters no bounds), a line wholly outside the visible page, and, at
/// the three recognition sites no real reading reaches today, the DEBUG seam
/// that leaves a recognised line out of the box lookup.
@Suite("A hit with no box is listed", .tags(.search))
struct NoBoxHitTests {

    // MARK: - Fixtures

    /// Two pages: page 1 an ordinary visible line, page 2 `hidden` alone,
    /// drawn under a zero text matrix (extracted, with no bounds). On a page
    /// with a visible line PDFKit gives such a word that line's geometry, so
    /// the planted word has a page of its own.
    static func pageWithUnboxableWord(visible: String = "Quarterly statement for the account",
                                      hidden: String) -> Data {
        let first = "BT /F1 12 Tf 72 700 Td (\(visible)) Tj ET"
        let second = "BT /F1 12 Tf 0 0 0 0 100 600 Tm (\(hidden)) Tj ET"
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(first.utf8.count) >>\nstream\n\(first)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
            PDFObject(id: 6, content: """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
                /Contents 7 0 R /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 7, content: "<< /Length \(second.utf8.count) >>\nstream\n\(second)\nendstream"),
        ], rootId: 1)
    }

    /// Two pages: page 1 ends "... Delia" (visible); page 2 begins with
    /// "Hartwell" under a zero text matrix (no bounds).
    static func seamWithUnboxedSecondPart() -> Data {
        let first = "BT /F1 12 Tf 72 700 Td (Payment received from Delia) Tj ET"
        let second = "BT /F1 12 Tf 0 0 0 0 72 700 Tm (Hartwell on the date shown) Tj ET"
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(first.utf8.count) >>\nstream\n\(first)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
            PDFObject(id: 6, content: """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
                /Contents 7 0 R /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 7, content: "<< /Length \(second.utf8.count) >>\nstream\n\(second)\nendstream"),
        ], rootId: 1)
    }

    static func results(_ data: Data, _ mode: SearchMode, searcher: DocumentSearcher = DocumentSearcher()) async throws -> [SearchResult] {
        let doc = try #require(PDFDocument(data: data))
        var out: [SearchResult] = []
        for await r in searcher.search(SendablePDFDocument(doc), mode: mode, progress: { _, _ in }) { out.append(r) }
        return out
    }

    /// A recognised page (no text layer) whose one line is `text`, with that
    /// line left out of the box lookup through the DEBUG seam.
    static func recognisedUnplaced(_ text: String, _ mode: SearchMode, alwaysFlag: String? = nil) async throws -> [SearchResult] {
        let searcher = DocumentSearcher()
        if let alwaysFlag {
            await searcher.setUserTerms(UserTermsIndex(matcher: UserTermMatcher.compile(
                alwaysFlag: [UserTerm(pattern: alwaysFlag, isRegex: false)], neverFlag: [])))
        }
        await searcher._testSeedOCRLines(
            [OCREngine.TextLine(text: text, normalizedRect: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.03), confidence: 0.9)],
            forPageIndex: 0)
        DocumentSearcher.injectedUnplacedLines.insert(text)
        defer { DocumentSearcher.injectedUnplacedLines.remove(text) }
        return try await results(TestFixtures.imageOnlyPDF(), mode, searcher: searcher)
    }

    static func expectOneUnboxed(_ hits: [SearchResult], page: Int = 0, offPage: Bool = false, _ note: String) {
        #expect(hits.count == 1, "\(note): one row, not dropped: \(hits.map(\.matchedText))")
        guard let hit = hits.first else { return }
        #expect(hit.pageIndex == page, "\(note): its page")
        #expect(!hit.hasBox && hit.normalizedRect == .zero && !hit.isSelected, "\(note): no box, not selected")
        #expect(hit.liesOffVisiblePage == offPage, "\(note): the off-page reason")
    }

    // MARK: - The cases

    @Test("typed search: a word with no width is one row with its page and no box")
    func typed() async throws {
        let hits = try await Self.results(Self.pageWithUnboxableWord(hidden: "QUARTZ7"), .text("QUARTZ7", options: SearchOptions()))
        Self.expectOneUnboxed(hits, page: 1, "typed")
    }

    @Test("a pattern that matches the word with no width is one row with no box")
    func pattern() async throws {
        let hits = try await Self.results(Self.pageWithUnboxableWord(hidden: "QUARTZ7"), .regex("QUARTZ\\d", options: SearchOptions()))
        Self.expectOneUnboxed(hits, page: 1, "pattern")
    }

    @Test("Scan: an e-mail address with no width is one row with no box")
    func scanText() async throws {
        let hits = try await Self.results(Self.pageWithUnboxableWord(hidden: "jane.doe@example.com"),
                                          .piiScan(categories: [.email], options: SearchOptions()))
            .filter { $0.piiCategory == .email }
        Self.expectOneUnboxed(hits, page: 1, "scan, text layer")
    }

    @Test("an ordinary hit keeps its box")
    func ordinary() async throws {
        let hits = try await Self.results(Self.pageWithUnboxableWord(hidden: "QUARTZ7"), .text("statement", options: SearchOptions()))
        #expect(hits.count == 1)
        #expect(hits.first.map { $0.hasBox && $0.normalizedRect.width > 0 && !$0.liesOffVisiblePage } == true)
    }

    @Test("the Search Re-check on an output where an unboxed match remains reads one remaining")
    func recheckCountsIt() async throws {
        // An output page whose text layer the Re-check trusts, holding a match
        // with no box (its line lies outside the visible page). A word with no
        // width cannot stand in here: such a page is re-read by recognition,
        // which cannot see the word, as no export carries it.
        let data = TestFixtures.offCropBoxTextPDF(cropBoxPastMediaBox: true)
        let observation = try await OutputRecheck.observePage(
            OutputRecheck.PageWork(index: 0, data: data, requestIndices: [0]),
            requests: [TestFixtures.textRequest("PLANT-ENGCROP-01")], regexTimeoutOverride: nil)
        #expect(observation.counts[0]?.remaining == 1,
                "the match remains, so the Re-check asks (route \(String(describing: observation.route)))")
    }

    @Test("Scan on a recognised page: a match with no line to be placed on is one row with no box")
    func scanRecognised() async throws {
        let hits = try await Self.recognisedUnplaced("Contact jane.doe@example.com today",
                                                     .piiScan(categories: [.email], options: SearchOptions(includeOCR: true)))
            .filter { $0.piiCategory == .email }
        Self.expectOneUnboxed(hits, "scan, recognised")
    }

    @Test("a line wholly outside the visible page is one row with no box, marked off the page")
    func offVisiblePage() async throws {
        let hits = try await Self.results(TestFixtures.offCropBoxTextPDF(cropBoxPastMediaBox: true),
                                          .text("PLANT-ENGCROP-01", options: SearchOptions()))
        Self.expectOneUnboxed(hits, offPage: true, "off the visible page")
    }

    @Test("an always-flag term with no width is one row with no box")
    func alwaysFlagText() async throws {
        let searcher = DocumentSearcher()
        await searcher.setUserTerms(UserTermsIndex(matcher: UserTermMatcher.compile(
            alwaysFlag: [UserTerm(pattern: "QUARTZ7", isRegex: false)], neverFlag: [])))
        let hits = try await Self.results(Self.pageWithUnboxableWord(hidden: "QUARTZ7"),
                                          .piiScan(categories: [.ssn], options: SearchOptions()), searcher: searcher)
            .filter { $0.term == "Custom" }
        Self.expectOneUnboxed(hits, page: 1, "always-flag, text layer")
    }

    @Test("an always-flag term on a recognised page with no line to be placed on is one row with no box")
    func alwaysFlagRecognised() async throws {
        let hits = try await Self.recognisedUnplaced("Ref QUARTZ7 filed", .piiScan(categories: [.ssn], options: SearchOptions(includeOCR: true)),
                                                     alwaysFlag: "QUARTZ7")
            .filter { $0.term == "Custom" }
        Self.expectOneUnboxed(hits, "always-flag, recognised")
    }

    @Test("a pattern on a recognised page with no line to be placed on is one row with no box")
    func patternRecognised() async throws {
        let hits = try await Self.recognisedUnplaced("Invoice INV-00731 due", .regex("INV-\\d+", options: SearchOptions(includeOCR: true)))
        Self.expectOneUnboxed(hits, "pattern, recognised")
    }

    @Test("a match across a page break whose second part has no box: both parts listed, one boxed")
    func pageSeam() async throws {
        let hits = try await Self.results(Self.seamWithUnboxedSecondPart(), .text("Delia Hartwell", options: SearchOptions()))
        #expect(hits.count == 2, "both parts listed: \(hits.map { ($0.pageIndex, $0.hasBox) })")
        #expect(hits.first(where: { $0.pageIndex == 0 })?.hasBox == true, "the first part keeps its box")
        #expect(hits.first(where: { $0.pageIndex == 1 })?.hasBox == false, "the second part has none")
        #expect(Set(hits.compactMap(\.occurrenceID)).count == 1 && hits.allSatisfy { $0.occurrenceID != nil },
                "one occurrence, neither merged into the other")
    }

    @Test("Two readings of one unboxed match are one row; two unboxed matches are never grouped by the zero rect")
    func fastUnionKeepsUnboxedApart() {
        func unboxed(_ text: String) -> SearchResult {
            .unboxed(pageIndex: 0, matchedText: text, contextSnippet: text, source: .ocr(confidence: 0.9), term: "T")
        }
        let a1 = unboxed("INV-1"), a2 = unboxed("INV-2")
        let merged = DocumentSearcher.unionFastOCRResults(accurate: [a1, a2], fast: [unboxed("INV-1"), unboxed("INV-3")])
        #expect(merged.map(\.matchedText) == ["INV-1", "INV-2", "INV-3"], "INV-1's fast repeat is one row; INV-3 is added")
        #expect(merged.allSatisfy { !$0.hasBox })
    }
}
