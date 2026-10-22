import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// A phrase that wraps onto a second line, read through the real
// DocumentSearcher on raw pages: the text search and the regex search each
// return one result per line the match touches, with a rect on that line;
// a phrase with a control character between its words (what PDFKit emits
// for a tab byte) is one result with one rect; the live preview counts what
// the full tier returns; the rebuilt text layer of a Searchable export with
// those results applied carries neither word, and the Search Re-check on
// that output lists nothing remaining.
//
// Privacy rule (audit-lint M-1): locate/match/cover vocabulary.

@Suite("Wrapped phrase rects", .tags(.search))
struct WrappedPhraseRectTests {

    /// A Courier page from a content stream. "Jane" at y 700 and "Doe" at
    /// y 686 read as "Jane\nDoe" in page.string (the census fact).
    static func courierPage(_ stream: String) -> Data {
        buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>"),
        ], rootId: 1)
    }

    static let wrappedPage = courierPage("BT /F1 12 Tf 72 700 Td (Jane) Tj ET\nBT /F1 12 Tf 72 686 Td (Doe) Tj ET")
    static let tabPage = courierPage("BT /F1 12 Tf 72 700 Td (Jane\\011Doe) Tj ET")

    static func results(_ data: Data, mode: SearchMode) async throws -> (PDFDocument, [SearchResult]) {
        let doc = try #require(PDFDocument(data: data))
        let searcher = DocumentSearcher()
        let stream = searcher.search(SendablePDFDocument(doc), mode: mode, progress: { _, _ in })
        var out: [SearchResult] = []
        for await r in stream { out.append(r) }
        return (doc, out)
    }

    /// The normalized band of a line drawn at `y` (12-pt Courier): the rect
    /// sits between the baseline's descent and the ascent.
    static func band(y: CGFloat) -> ClosedRange<CGFloat> { ((y - 4) / 792)...((y + 12) / 792) }

    @Test("A wrapped phrase in Text mode: one result per line, each rect on its line, the full phrase as the match")
    func wrappedPhraseTextMode() async throws {
        let (doc, hits) = try await Self.results(Self.wrappedPage, mode: .text("Jane Doe", options: SearchOptions()))
        #expect(doc.page(at: 0)?.string == "Jane\nDoe", "the census fact: a wrap is a line feed")
        #expect(hits.count == 2, "one result per line: \(hits.map(\.normalizedRect))")
        let sorted = hits.sorted { $0.normalizedRect.minY > $1.normalizedRect.minY }
        #expect(sorted.first.map { Self.band(y: 700).contains($0.normalizedRect.midY) } == true)
        #expect(sorted.last.map { Self.band(y: 686).contains($0.normalizedRect.midY) } == true)
        #expect(hits.allSatisfy { $0.matchedText == "Jane Doe" }, "the match is the whole phrase: \(hits.map(\.matchedText))")
        #expect(hits.allSatisfy { $0.contextSnippet.contains("Jane Doe") })
    }

    @Test("A wrapped phrase in Regex mode: the same per-line rects")
    func wrappedPhraseRegexMode() async throws {
        let (_, hits) = try await Self.results(Self.wrappedPage, mode: .regex(#"Jane\s+Doe"#, options: SearchOptions()))
        #expect(hits.count == 2, "\(hits.map(\.normalizedRect))")
    }

    @Test("A control character between the words: one result, one rect from the J to the e")
    func controlCharacterBetweenTheWords() async throws {
        let (doc, hits) = try await Self.results(Self.tabPage, mode: .text("Jane Doe", options: SearchOptions()))
        let page = try #require(doc.page(at: 0))
        #expect(page.string?.contains("\u{0000}") == true, "PDFKit emits a control character for the tab byte")
        #expect(hits.count == 1, "\(hits.map(\.matchedText))")
        let whole = try #require(DocumentSearcher().boundingRect(for: NSRange(location: 0, length: 8), page: page))
        #expect(hits.first?.normalizedRect == whole)
    }

    @Test("The live preview counts what the full tier returns")
    func previewCountEqualsFullCount() async throws {
        for data in [Self.wrappedPage, Self.tabPage] {
            let (doc, hits) = try await Self.results(data, mode: .text("Jane Doe", options: SearchOptions()))
            let texts: [String?] = (0..<doc.pageCount).map { doc.page(at: $0)?.string }
            let preview = await DocumentSearcher().previewMatches(
                mode: .text("Jane Doe", options: SearchOptions()), scope: .wholeDocument,
                currentPageIndex: 0, totalPageCount: 1,
                pageTextProvider: { index in texts[index] })
            #expect(preview.totalCount == hits.count, "the preview count agrees with the full tier")
        }
    }

    @Test("A Searchable export with the per-line results applied carries neither word, and the re-check lists nothing remaining")
    func exportAndRecheck() async throws {
        let (_, hits) = try await Self.results(Self.wrappedPage, mode: .text("Jane Doe", options: SearchOptions()))
        let regions = hits.map { RedactionRegion(id: UUID(), normalizedRect: $0.normalizedRect, source: .manual) }
        let url = try await TestPipeline.processAndExport(
            Self.wrappedPage, mode: .searchableRedaction, regions: [0: regions], fillColor: .black, dpi: 150)
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try #require(PDFDocument(url: url))
        let layer = output.page(at: 0)?.string ?? ""
        #expect(!layer.contains("Jane") && !layer.contains("Doe"), "the rebuilt layer: \(layer)")
        let record = AppliedSearchRecord(
            query: AppliedSearchQuery(kind: .text("Jane Doe"), options: SearchOptions()), foundCount: hits.count)
        let request = SearchRecheckRequest(record: record, appliedCount: hits.count, appliedPages: [0])
        let recheck = try await SearchRecheck().run(outputDocument: SendablePDFDocument(output), requests: [request])
        if case .attention = recheck.status { Issue.record("a match remains on the output: \(recheck.status)") }
        #expect((recheck.reviewTermTexts ?? []).isEmpty)
    }
}
