import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// A name broken at its own hyphen across two lines, read through the real
// DocumentSearcher on raw pages. "Signed by Marisol Vance-" ends one line and
// "Oduya on the date below." starts the next; page.string reads "Vance-" LF
// "Oduya". The name as typed is found with one result per line, both lines
// sharing one occurrence, in Text and Multi-term modes; the live preview
// counts it once; Regex mode reads the line break as written. A Searchable
// export with the results applied carries neither part, and the Search
// Re-check lists nothing remaining.
//
// Privacy rule (audit-lint M-1): locate/match/cover vocabulary.

@Suite("Hyphen-break search", .tags(.search))
struct HyphenBreakSearchTests {

    static let hyphenPage = WrappedPhraseRectTests.courierPage(
        "BT /F1 12 Tf 72 700 Td (Signed by Marisol Vance-) Tj ET\nBT /F1 12 Tf 72 686 Td (Oduya on the date below.) Tj ET")
    static let dashPage = WrappedPhraseRectTests.courierPage(
        "BT /F1 12 Tf 72 700 Td (the item -) Tj ET\nBT /F1 12 Tf 72 686 Td (next one) Tj ET")
    /// A Courier page whose font maps byte 0xAD to U+00AD through a ToUnicode
    /// CMap (printable ASCII to itself), so page.string carries a soft hyphen
    /// inside "Jo-hanson" as a word processor's export does.
    static let softHyphenPage: Data = {
        let cmap = """
            /CIDInit /ProcSet findresource begin
            12 dict begin
            begincmap
            /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
            /CMapName /Adobe-Identity-UCS def
            /CMapType 2 def
            1 begincodespacerange
            <00> <FF>
            endcodespacerange
            1 beginbfrange
            <20> <7E> <0020>
            endbfrange
            1 beginbfchar
            <AD> <00AD>
            endbfchar
            endcmap
            CMapName currentdict /CMapResource defineresource pop
            end
            end
            """
        let stream = "BT /F1 12 Tf 72 700 Td (Witness Jo\\255hanson attended.) Tj ET"
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding /ToUnicode 6 0 R >>"),
            PDFObject(id: 6, content: "<< /Length \(cmap.utf8.count) >>\nstream\n\(cmap)\nendstream"),
        ], rootId: 1)
    }()

    static func results(_ data: Data, _ mode: SearchMode) async throws -> [SearchResult] {
        try await WrappedPhraseRectTests.results(data, mode: mode).1
    }

    /// Two results, one per line, each rect in its own line's band, one occurrence.
    static func expectTwoLines(_ hits: [SearchResult], matched: String? = nil, _ note: String) {
        #expect(hits.count == 2, "\(note): one result per line: \(hits.map(\.matchedText))")
        let sorted = hits.sorted { $0.normalizedRect.minY > $1.normalizedRect.minY }
        #expect(sorted.first.map { WrappedPhraseRectTests.band(y: 700).contains($0.normalizedRect.midY) } == true, "\(note)")
        #expect(sorted.last.map { WrappedPhraseRectTests.band(y: 686).contains($0.normalizedRect.midY) } == true, "\(note)")
        #expect(Set(hits.compactMap(\.occurrenceID)).count == 1 && hits.allSatisfy { $0.occurrenceID != nil },
                "\(note): the two lines share one occurrence")
        if let matched {
            #expect(hits.allSatisfy { $0.matchedText == matched }, "\(note): \(hits.map(\.matchedText))")
        }
    }

    @Test("The page reads 'Vance-' then a line feed then 'Oduya' (the producer fact)")
    func pageStringFact() throws {
        let doc = try #require(PDFDocument(data: Self.hyphenPage))
        #expect(doc.page(at: 0)?.string == "Signed by Marisol Vance-\nOduya on the date below.")
    }

    @Test("Text mode: the hyphenated name as typed is found on both lines")
    func textModeFindsTheName() async throws {
        let hits = try await Self.results(Self.hyphenPage, .text("Vance-Oduya", options: SearchOptions()))
        Self.expectTwoLines(hits, matched: "Vance-Oduya", "Vance-Oduya")
        let full = try await Self.results(Self.hyphenPage, .text("Marisol Vance-Oduya", options: SearchOptions()))
        Self.expectTwoLines(full, matched: "Marisol Vance-Oduya", "Marisol Vance-Oduya")
        #expect(full.allSatisfy { $0.contextSnippet.contains("Marisol Vance-Oduya") })
    }

    @Test("Text mode: one part of the name is still one result")
    func onePartIsOneResult() async throws {
        let hits = try await Self.results(Self.hyphenPage, .text("Oduya", options: SearchOptions()))
        #expect(hits.count == 1)
        #expect(hits.first?.occurrenceID == nil)
    }

    @Test("Whole word: the hyphenated name is found across the break")
    func wholeWord() async throws {
        let hits = try await Self.results(Self.hyphenPage, .text("Vance-Oduya", options: SearchOptions(wholeWord: true)))
        Self.expectTwoLines(hits, matched: "Vance-Oduya", "whole word")
    }

    @Test("Multi-term OR and AND match the name across the break")
    func multiTerm() async throws {
        let or = try await Self.results(Self.hyphenPage, .multiTerm(["Vance-Oduya", "Okafor"], options: SearchOptions()))
        Self.expectTwoLines(or, matched: "Vance-Oduya", "OR")
        let and = try await Self.results(
            Self.hyphenPage, .multiTerm(["Marisol Vance-Oduya", "date"], options: SearchOptions(multiTermConjunction: true)))
        let name = and.filter { $0.term == "Marisol Vance-Oduya" }
        Self.expectTwoLines(name, matched: "Marisol Vance-Oduya", "AND")
        #expect(and.filter { $0.term == "date" }.count == 1, "the page holds every term, so it survives the conjunction")
    }

    @Test("The live preview counts the name once, as the full tier's occurrences")
    func previewCount() async throws {
        let mode = SearchMode.text("Vance-Oduya", options: SearchOptions())
        let hits = try await Self.results(Self.hyphenPage, mode)
        let doc = try #require(PDFDocument(data: Self.hyphenPage))
        let text = doc.page(at: 0)?.string
        let preview = await DocumentSearcher().previewMatches(
            mode: mode, scope: .wholeDocument, currentPageIndex: 0, totalPageCount: 1,
            pageTextProvider: { _ in text })
        #expect(preview.totalCount == 1)
        #expect(preview.totalCount == Set(hits.map { $0.occurrenceID ?? $0.id }).count)
    }

    @Test("Regex mode reads the line break as written: Vance-\\s*Oduya matches on both lines")
    func regexReadsTheBreak() async throws {
        let hits = try await Self.results(Self.hyphenPage, .regex(#"Vance-\s*Oduya"#, options: SearchOptions()))
        Self.expectTwoLines(hits, "regex")
    }

    @Test("A dash after a space is not a word hyphen: the break stays a space")
    func dashAfterSpace() async throws {
        let spaced = try await Self.results(Self.dashPage, .text("item - next", options: SearchOptions()))
        Self.expectTwoLines(spaced, matched: "item - next", "item - next")
        let joined = try await Self.results(Self.dashPage, .text("item -next", options: SearchOptions()))
        #expect(joined.isEmpty, "\(joined.map(\.matchedText))")
    }

    @Test("A soft hyphen inside a word: page.string carries U+00AD and the word is found as typed")
    func softHyphenInsideAWord() async throws {
        let doc = try #require(PDFDocument(data: Self.softHyphenPage))
        #expect(doc.page(at: 0)?.string == "Witness Jo\u{00AD}hanson attended.", "the producer fact")
        let hits = try await Self.results(Self.softHyphenPage, .text("Johanson", options: SearchOptions()))
        #expect(hits.count == 1, "\(hits.map(\.matchedText))")
        #expect(hits.first?.matchedText == "Johanson")
        let page = try #require(doc.page(at: 0))
        let whole = try #require(DocumentSearcher().boundingRect(for: NSRange(location: 8, length: 9), page: page))
        #expect(hits.first?.normalizedRect == whole, "the box covers the raw word, the soft hyphen inside")
    }

    @Test("A Searchable export with both results applied carries neither part, and the re-check lists nothing remaining")
    func exportAndRecheck() async throws {
        let hits = try await Self.results(Self.hyphenPage, .text("Vance-Oduya", options: SearchOptions()))
        try #require(hits.count == 2)
        let regions = hits.map { RedactionRegion(id: UUID(), normalizedRect: $0.normalizedRect, source: .manual) }
        let url = try await TestPipeline.processAndExport(
            Self.hyphenPage, mode: .searchableRedaction, regions: [0: regions], fillColor: .black, dpi: 150)
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try #require(PDFDocument(url: url))
        let layer = output.page(at: 0)?.string ?? ""
        #expect(!layer.contains("Vance") && !layer.contains("Oduya"), "the rebuilt layer: \(layer)")
        let record = AppliedSearchRecord(
            query: AppliedSearchQuery(kind: .text("Vance-Oduya"), options: SearchOptions()), foundCount: hits.count)
        let request = SearchRecheckRequest(record: record, appliedCount: hits.count, appliedPages: [0])
        let recheck = try await SearchRecheck().run(outputDocument: SendablePDFDocument(output), requests: [request])
        if case .attention = recheck.status { Issue.record("a match remains on the output: \(recheck.status)") }
        #expect((recheck.reviewTermTexts ?? []).isEmpty)
    }
}
