import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The optional-space reading through the real DocumentSearcher. A Courier
// line written as one run, "betweenHalvorsenMarineSupply,Inc.", reads with
// no space on every iOS; "Halvorsen Marine Supply, Inc." as typed is found
// on it, boxed on the phrase's own Characters. The live preview counts it
// once; the recognised route matches a pair a reading ran together; a pattern
// is never read this way. After a Searchable export the Search Re-check
// reads it too: nothing remains when both occurrences were applied, and a
// run-together occurrence left unapplied is reported as remaining.
//
// Privacy rule (audit-lint M-1): locate/match/cover vocabulary.

@Suite("Optional space: the second walk in search", .tags(.search))
struct OptionalSpaceSearchTests {

    static let value = "Halvorsen Marine Supply, Inc."
    static let runPage = WrappedPhraseRectTests.courierPage("BT /F1 12 Tf 72 700 Td (betweenHalvorsenMarineSupply,Inc.) Tj ET")
    static let twoLinePage = WrappedPhraseRectTests.courierPage(
        "BT /F1 12 Tf 72 700 Td (betweenHalvorsenMarine) Tj ET\nBT /F1 12 Tf 72 686 Td (Supply,Inc.) Tj ET")
    /// One spaced occurrence on line 700, one run together on line 672.
    static let bothPage = WrappedPhraseRectTests.courierPage("""
        BT /F1 12 Tf 72 700 Td (Payments to Halvorsen Marine Supply, Inc. today.) Tj ET
        BT /F1 12 Tf 72 672 Td (andbetweenHalvorsenMarineSupply,Inc.and) Tj ET
        """)

    static func results(_ data: Data, _ mode: SearchMode) async throws -> [SearchResult] {
        try await WrappedPhraseRectTests.results(data, mode: mode).1
    }

    static func line(_ text: String, y: CGFloat, words: [(String, CGFloat, CGFloat)]) -> OCREngine.TextLine {
        var line = OCREngine.TextLine(text: text, normalizedRect: CGRect(x: 0.1, y: y, width: 0.7, height: 0.03), confidence: 1)
        let ns = text as NSString
        line.wordBoxes = words.map { word, x, width in
            OCREngine.WordBox(range: ns.range(of: word), normalizedRect: CGRect(x: x, y: y, width: width, height: 0.03))
        }
        return line
    }

    @Test("A run-together line: one result, boxed on the phrase's own Characters and on no glyph of 'between'")
    func runTogetherLine() async throws {
        let doc = try #require(PDFDocument(data: Self.runPage))
        let page = try #require(doc.page(at: 0))
        #expect(page.string == "betweenHalvorsenMarineSupply,Inc.")
        let hits = try await Self.results(Self.runPage, .text(Self.value, options: SearchOptions()))
        try #require(hits.count == 1, "\(hits.map(\.matchedText))")
        let phrase = try #require(DocumentSearcher().boundingRect(for: NSRange(location: 7, length: 26), page: page))
        let between = try #require(DocumentSearcher().boundingRect(for: NSRange(location: 0, length: 7), page: page))
        #expect(hits[0].normalizedRect == phrase, "the box is the phrase's own range")
        #expect(hits[0].normalizedRect.minX >= between.maxX, "no glyph of 'between' inside the box")
    }

    @Test("A run-together phrase across two lines: two results, one per line, one occurrence")
    func acrossTwoLines() async throws {
        let doc = try #require(PDFDocument(data: Self.twoLinePage))
        #expect(doc.page(at: 0)?.string == "betweenHalvorsenMarine\nSupply,Inc.")
        let hits = try await Self.results(Self.twoLinePage, .text(Self.value, options: SearchOptions()))
        HyphenBreakSearchTests.expectTwoLines(hits, "two lines")
    }

    @Test("The live preview counts the run-together phrase once, as the full search does")
    func previewCount() async throws {
        let mode = SearchMode.text(Self.value, options: SearchOptions())
        let hits = try await Self.results(Self.runPage, mode)
        let doc = try #require(PDFDocument(data: Self.runPage))
        let text = doc.page(at: 0)?.string
        let preview = await DocumentSearcher().previewMatches(
            mode: mode, scope: .wholeDocument, currentPageIndex: 0, totalPageCount: 1,
            pageTextProvider: { _ in text })
        #expect(preview.totalCount == 1)
        #expect(preview.totalCount == hits.count)
    }

    @Test("The recognised route: a pair read run together is found, boxed on its word")
    func recognisedRoute() async throws {
        let lines = [Self.line("through MarineSupply today", y: 0.6,
                               words: [("through", 0.1, 0.12), ("MarineSupply", 0.24, 0.2), ("today", 0.46, 0.09)])]
        let hits = await DocumentSearcher().recognisedMatches(lines: lines, query: "Marine Supply")
        try #require(hits.count == 1, "\(hits.map(\.matchedText))")
        let doc = try #require(PDFDocument(data: WrappedPhraseRectTests.courierPage("")))
        let page = try #require(doc.page(at: 0))
        #expect(hits[0].normalizedRect == DocumentSearcher.paddedNormalizedRect(lines[0].wordBoxes[1].normalizedRect, in: page))
    }

    @Test("Across a page boundary: a spaced phrase is found on both pages, as before")
    func acrossAPageBoundary() async throws {
        let data = PageSeamPhraseTests.document([
            PageSeamPhraseTests.page(["The statement was sent on the date shown.", "Payments go to Halvorsen"]),
            PageSeamPhraseTests.page(["Marine Supply today.", "No further action is needed."]),
        ])
        let hits = try await Self.results(data, .text("Halvorsen Marine Supply", options: SearchOptions()))
        PageSeamPhraseTests.expectAcrossTheSeam(hits, matched: "Halvorsen Marine Supply", "spaced phrase")
    }

    @Test("Pattern mode is never read this way: a pattern that needs a space matches nothing, one that allows none matches it")
    func patternMode() async throws {
        let spaced = try await Self.results(Self.runPage, .regex(#"Halvorsen\s+Marine"#, options: SearchOptions()))
        #expect(spaced.isEmpty, "\(spaced.map(\.matchedText))")
        let open = try await Self.results(Self.runPage, .regex(#"Halvorsen\s*Marine"#, options: SearchOptions()))
        #expect(open.count == 1, "\(open.map(\.matchedText))")
    }

    static func recheck(output: PDFDocument, foundCount: Int, appliedCount: Int) async throws -> SearchRecheck.Outcome {
        let record = AppliedSearchRecord(
            query: AppliedSearchQuery(kind: .text(Self.value), options: SearchOptions()), foundCount: foundCount)
        let request = SearchRecheckRequest(record: record, appliedCount: appliedCount, appliedPages: [0])
        return try await SearchRecheck().run(outputDocument: SendablePDFDocument(output), requests: [request])
    }

    static func export(_ applied: [SearchResult]) async throws -> PDFDocument {
        let regions = applied.map { RedactionRegion(id: UUID(), normalizedRect: $0.normalizedRect, source: .manual) }
        let url = try await TestPipeline.processAndExport(
            Self.bothPage, mode: .searchableRedaction, regions: [0: regions], fillColor: .black, dpi: 150)
        defer { try? FileManager.default.removeItem(at: url) }
        return try #require(PDFDocument(url: url))
    }

    @Test("A Searchable export: both applied, the re-check lists nothing; only the spaced one applied, it asks")
    func exportAndRecheck() async throws {
        let hits = try await Self.results(Self.bothPage, .text(Self.value, options: SearchOptions()))
        try #require(hits.count == 2, "\(hits.map(\.matchedText))")
        let both = try await Self.export(hits)
        let all = try await Self.recheck(output: both, foundCount: 2, appliedCount: 2)
        if case .attention = all.status { Issue.record("a match remains on the output: \(all.status)") }
        #expect((all.reviewTermTexts ?? []).isEmpty)
        let spaced = try #require(hits.max { $0.normalizedRect.midY < $1.normalizedRect.midY })
        let one = try await Self.export([spaced])
        let left = try await Self.recheck(output: one, foundCount: 2, appliedCount: 1)
        guard case .attention = left.status else { Issue.record("expected the re-check to ask, got \(left.status)"); return }
        #expect(left.reviewTermTexts == [Self.value])
    }

    @Test("The recognised route decides on the page's own Characters: a phrase with an initial is not found, a pair is")
    func recognisedRouteEdges() async throws {
        let lines = [
            Self.line("through PlanAsummary today", y: 0.6,
                      words: [("through", 0.1, 0.12), ("PlanAsummary", 0.24, 0.2), ("today", 0.46, 0.09)]),
            Self.line("through MarineSupply today", y: 0.5,
                      words: [("through", 0.1, 0.12), ("MarineSupply", 0.24, 0.2), ("today", 0.46, 0.09)]),
        ]
        let initial = await DocumentSearcher().recognisedMatches(lines: lines, query: "Plan A summary")
        #expect(initial.isEmpty, "\(initial.map(\.matchedText))")
        let pair = await DocumentSearcher().recognisedMatches(lines: lines, query: "Marine Supply")
        #expect(pair.count == 1, "\(pair.map(\.matchedText))")
    }
}
