import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// A phrase that starts at the end of one page and continues at the top of
// the next, read through the real DocumentSearcher on raw multi-page
// documents whose pages carry a running header (and in one case a page
// footer). The phrase as typed is found with one result per line per page,
// every part sharing one occurrence; the seam joins only adjacent pages, only
// past repeated header and footer lines, only for a query that holds a space
// or a hyphen; the live preview, which reads one page at a time, does not
// count a seam match.
//
// Privacy rule (audit-lint M-1): locate/match/cover vocabulary.

@Suite("Page seam phrase", .tags(.search))
struct PageSeamPhraseTests {

    static let header = "BT /F1 12 Tf 72 750 Td (CONFIDENTIAL - FICTIONAL DATA) Tj ET"

    /// A Courier document, one content stream per page.
    static func document(_ pages: [String]) -> Data {
        var objects = [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 3, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>"),
        ]
        var kids: [String] = []
        for (i, stream) in pages.enumerated() {
            let pageID = 10 + 2 * i, contentID = 11 + 2 * i
            kids.append("\(pageID) 0 R")
            objects.append(PDFObject(id: pageID, content: """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
                /Contents \(contentID) 0 R /Resources << /Font << /F1 3 0 R >> >> >>
                """))
            objects.append(PDFObject(id: contentID, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"))
        }
        objects.insert(PDFObject(id: 2, content: "<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count \(pages.count) >>"), at: 1)
        return buildRawPDF(objects: objects, rootId: 1)
    }

    static func page(_ lines: [String], header: Bool = true, footer: String? = nil) -> String {
        var parts = header ? [Self.header] : []
        for (i, line) in lines.enumerated() {
            parts.append("BT /F1 12 Tf 72 \(700 - 14 * i) Td (\(line)) Tj ET")
        }
        if let footer { parts.append("BT /F1 12 Tf 72 60 Td (\(footer)) Tj ET") }
        return parts.joined(separator: "\n")
    }

    static let pageOne = page(["The hearing was held on the date shown below.", "The claimant is Marisol"])
    static let pageTwo = page(["Vance-Oduya and her counsel.", "The motion was taken under advisement."])
    static let seamDocument = document([pageOne, pageTwo])

    static func results(_ data: Data, _ mode: SearchMode) async throws -> [SearchResult] {
        try await WrappedPhraseRectTests.results(data, mode: mode).1
    }

    /// One result on page 0 at y 686 and one on page 1 at y 700, one occurrence.
    static func expectAcrossTheSeam(_ hits: [SearchResult], matched: String, _ note: String) {
        #expect(hits.count == 2, "\(note): \(hits.map { "p\($0.pageIndex) \($0.matchedText)" })")
        let first = hits.first { $0.pageIndex == 0 }, second = hits.first { $0.pageIndex == 1 }
        #expect(first.map { WrappedPhraseRectTests.band(y: 686).contains($0.normalizedRect.midY) } == true, "\(note): page 0's part on its last line")
        #expect(second.map { WrappedPhraseRectTests.band(y: 700).contains($0.normalizedRect.midY) } == true, "\(note): page 1's part on its first line")
        #expect(Set(hits.compactMap(\.occurrenceID)).count == 1 && hits.allSatisfy { $0.occurrenceID != nil }, "\(note): one occurrence")
        #expect(hits.allSatisfy { $0.matchedText == matched }, "\(note): \(hits.map(\.matchedText))")
        #expect(hits.allSatisfy { $0.contextSnippet.contains(matched) }, "\(note): \(hits.map(\.contextSnippet))")
    }

    @Test("The page texts: the header first, then the body lines (the fixture shape)")
    func pageTexts() throws {
        let doc = try #require(PDFDocument(data: Self.seamDocument))
        #expect(doc.pageCount == 2)
        #expect(doc.page(at: 0)?.string?.hasSuffix("The claimant is Marisol") == true, "\(doc.page(at: 0)?.string ?? "")")
        #expect(doc.page(at: 1)?.string?.hasPrefix("CONFIDENTIAL - FICTIONAL DATA") == true, "\(doc.page(at: 1)?.string ?? "")")
    }

    @Test("Text mode: a phrase across the page break, past the running header, is found on both pages")
    func phraseAcrossThePageBreak() async throws {
        let hits = try await Self.results(Self.seamDocument, .text("Marisol Vance-Oduya", options: SearchOptions()))
        Self.expectAcrossTheSeam(hits, matched: "Marisol Vance-Oduya", "Marisol Vance-Oduya")
    }

    @Test("A phrase wholly on one page is that page's one result, with no seam duplicate")
    func phraseOnOnePage() async throws {
        let hits = try await Self.results(Self.seamDocument, .text("Vance-Oduya", options: SearchOptions()))
        #expect(hits.count == 1, "\(hits.map { "p\($0.pageIndex)" })")
        #expect(hits.first?.pageIndex == 1)
    }

    @Test("A name broken at its hyphen across the page break is found on both pages")
    func hyphenAcrossThePageBreak() async throws {
        let data = Self.document([
            Self.page(["The hearing was held on the date shown below.", "The claimant is Marisol Vance-"]),
            Self.page(["Oduya and her counsel.", "The motion was taken under advisement."]),
        ])
        let hits = try await Self.results(data, .text("Vance-Oduya", options: SearchOptions()))
        Self.expectAcrossTheSeam(hits, matched: "Vance-Oduya", "Vance- | Oduya")
    }

    @Test("A page footer with the page number is skipped (digits masked)")
    func footerSkipped() async throws {
        let data = Self.document([
            Self.page(["The hearing was held on the date shown below.", "The claimant is Marisol"], footer: "Page 1 of 2"),
            Self.page(["Vance-Oduya and her counsel.", "The motion was taken under advisement."], footer: "Page 2 of 2"),
        ])
        let hits = try await Self.results(data, .text("Marisol Vance-Oduya", options: SearchOptions()))
        Self.expectAcrossTheSeam(hits, matched: "Marisol Vance-Oduya", "footer")
    }

    @Test("A first line that does not repeat ends the seam: no result across it")
    func nonRepeatingLineBounds() async throws {
        let data = Self.document([
            Self.pageOne,
            Self.page(["Exhibit A", "Vance-Oduya and her counsel."]),
        ])
        let hits = try await Self.results(data, .text("Marisol Vance-Oduya", options: SearchOptions()))
        #expect(hits.isEmpty, "\(hits.map { "p\($0.pageIndex) \($0.matchedText)" })")
    }

    @Test("Only adjacent pages join: no seam between pages 0 and 2")
    func onlyAdjacentPages() async throws {
        let data = Self.document([
            Self.pageOne,
            Self.page(["Nothing on this page continues the name."]),
            Self.pageTwo,
        ])
        let hits = try await Self.results(data, .text("Marisol Vance-Oduya", options: SearchOptions()))
        #expect(hits.isEmpty, "\(hits.map { "p\($0.pageIndex) \($0.matchedText)" })")
    }

    @Test("A one-word query never takes the seam")
    func oneWordQuery() async throws {
        let data = Self.document([
            Self.page(["The claimant is Mari"]),
            Self.page(["sol and her counsel."]),
        ])
        let hits = try await Self.results(data, .text("Marisol", options: SearchOptions()))
        #expect(hits.isEmpty, "\(hits.map { "p\($0.pageIndex) \($0.matchedText)" })")
    }

    @Test("Multi-term OR matches the phrase across the seam beside the other term")
    func multiTermOr() async throws {
        let hits = try await Self.results(
            Self.seamDocument, .multiTerm(["Marisol Vance-Oduya", "motion"], options: SearchOptions()))
        Self.expectAcrossTheSeam(hits.filter { $0.term == "Marisol Vance-Oduya" }, matched: "Marisol Vance-Oduya", "OR")
        #expect(hits.filter { $0.term == "motion" }.count == 1)
    }

    @Test("Multi-term AND: the seam match counts for page n+1 and streams with it")
    func multiTermAnd() async throws {
        let and = SearchOptions(multiTermConjunction: true)
        let kept = try await Self.results(Self.seamDocument, .multiTerm(["Marisol Vance-Oduya", "motion"], options: and))
        Self.expectAcrossTheSeam(kept.filter { $0.term == "Marisol Vance-Oduya" }, matched: "Marisol Vance-Oduya", "AND kept")
        #expect(kept.filter { $0.term == "motion" }.count == 1)
        let dropped = try await Self.results(Self.seamDocument, .multiTerm(["Marisol Vance-Oduya", "hearing"], options: and))
        #expect(dropped.filter { $0.term == "Marisol Vance-Oduya" }.isEmpty,
                "page 1 lacks 'hearing', so its batch (the seam match included) does not stream: \(dropped.map { "p\($0.pageIndex) \($0.term)" })")
    }

    @Test("The live preview reads one page at a time: it does not count a seam match")
    func previewExcludesTheSeam() async throws {
        let doc = try #require(PDFDocument(data: Self.seamDocument))
        let texts: [String?] = (0..<doc.pageCount).map { doc.page(at: $0)?.string }
        let preview = await DocumentSearcher().previewMatches(
            mode: .text("Marisol Vance-Oduya", options: SearchOptions()), scope: .wholeDocument,
            currentPageIndex: 0, totalPageCount: 2, pageTextProvider: { texts[$0] })
        #expect(preview.totalCount == 0)
    }
}
