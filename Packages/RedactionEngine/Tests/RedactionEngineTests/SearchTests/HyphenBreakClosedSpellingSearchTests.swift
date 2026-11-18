import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The closed-spelling reading through the real DocumentSearcher. "Payments go
// to Bright-" ends one line and "water Benefit Services LLC today." starts
// the next; page.string reads "Bright-" LF "water". "Brightwater" as typed is
// found with one result per line, both lines sharing one occurrence, in Text
// and Multi-term modes and on the recognised route; the live preview counts
// it once; a pattern is never read this way. Across a page boundary a
// one-word search is not tried. After a Searchable export the Search
// Re-check reads the closed spelling too: nothing remains when both lines
// were applied, and an occurrence left unapplied is reported as remaining.
//
// Privacy rule (audit-lint M-1): locate/match/cover vocabulary.

@Suite("Hyphen break: closed spelling in search", .tags(.search))
struct HyphenBreakClosedSpellingSearchTests {

    static let brokenPage = WrappedPhraseRectTests.courierPage(
        "BT /F1 12 Tf 72 700 Td (Payments go to Bright-) Tj ET\nBT /F1 12 Tf 72 686 Td (water Benefit Services LLC today.) Tj ET")
    /// Two occurrences of the broken word, on lines 700/686 and 658/644.
    static let twicePage = WrappedPhraseRectTests.courierPage("""
        BT /F1 12 Tf 72 700 Td (Payments go to Bright-) Tj ET
        BT /F1 12 Tf 72 686 Td (water Benefit Services LLC today.) Tj ET
        BT /F1 12 Tf 72 658 Td (Refunds come from Bright-) Tj ET
        BT /F1 12 Tf 72 644 Td (water as well.) Tj ET
        """)

    static func results(_ data: Data, _ mode: SearchMode) async throws -> [SearchResult] {
        try await WrappedPhraseRectTests.results(data, mode: mode).1
    }

    @Test("The page reads 'Bright-' then a line feed then 'water' (the producer fact)")
    func pageStringFact() throws {
        let doc = try #require(PDFDocument(data: Self.brokenPage))
        #expect(doc.page(at: 0)?.string == "Payments go to Bright-\nwater Benefit Services LLC today.")
    }

    @Test("Text mode: the closed spelling is found on both lines, boxed on 'Bright-', shown as 'Bright-water'")
    func textModeFindsTheClosedSpelling() async throws {
        let hits = try await Self.results(Self.brokenPage, .text("Brightwater", options: SearchOptions()))
        HyphenBreakSearchTests.expectTwoLines(hits, matched: "Bright-water", "Brightwater")
        let doc = try #require(PDFDocument(data: Self.brokenPage))
        let page = try #require(doc.page(at: 0))
        let first = try #require(hits.max { $0.normalizedRect.midY < $1.normalizedRect.midY })
        let bright = try #require(DocumentSearcher().boundingRect(for: NSRange(location: 15, length: 7), page: page))
        #expect(first.normalizedRect == bright, "the first line's box is 'Bright-', the hyphen inside")
    }

    @Test("Text mode: a phrase that opens with the closed spelling is found on both lines")
    func textModeFindsThePhrase() async throws {
        let hits = try await Self.results(Self.brokenPage, .text("Brightwater Benefit Services", options: SearchOptions()))
        HyphenBreakSearchTests.expectTwoLines(hits, "Brightwater Benefit Services")
    }

    @Test("Multi-term any and all: the closed spelling is found on both lines")
    func multiTerm() async throws {
        let any = try await Self.results(Self.brokenPage, .multiTerm(["Brightwater", "Okafor"], options: SearchOptions()))
        HyphenBreakSearchTests.expectTwoLines(any, matched: "Bright-water", "any")
        let all = try await Self.results(
            Self.brokenPage, .multiTerm(["Brightwater", "today"], options: SearchOptions(multiTermConjunction: true)))
        HyphenBreakSearchTests.expectTwoLines(all.filter { $0.term == "Brightwater" }, matched: "Bright-water", "all")
        #expect(all.filter { $0.term == "today" }.count == 1)
    }

    @Test("The live preview counts the closed spelling once, as the full search's occurrences")
    func previewCount() async throws {
        let mode = SearchMode.text("Brightwater", options: SearchOptions())
        let hits = try await Self.results(Self.brokenPage, mode)
        let doc = try #require(PDFDocument(data: Self.brokenPage))
        let text = doc.page(at: 0)?.string
        let preview = await DocumentSearcher().previewMatches(
            mode: mode, scope: .wholeDocument, currentPageIndex: 0, totalPageCount: 1,
            pageTextProvider: { _ in text })
        #expect(preview.totalCount == 1)
        #expect(preview.totalCount == Set(hits.map { $0.occurrenceID ?? $0.id }).count)
    }

    @Test("Pattern mode is never read this way: 'Brightwater' matches nothing, 'Bright-\\s*water' matches both lines")
    func patternMode() async throws {
        let closed = try await Self.results(Self.brokenPage, .regex("Brightwater", options: SearchOptions()))
        #expect(closed.isEmpty, "\(closed.map(\.matchedText))")
        let written = try await Self.results(Self.brokenPage, .regex(#"Bright-\s*water"#, options: SearchOptions()))
        HyphenBreakSearchTests.expectTwoLines(written, "pattern")
    }

    @Test("The recognised route: lines joined across 'Bright-' and 'water' match the closed spelling, boxed on each word")
    func recognisedRoute() async throws {
        func line(_ text: String, y: CGFloat, words: [(String, CGFloat, CGFloat)]) -> OCREngine.TextLine {
            var line = OCREngine.TextLine(text: text, normalizedRect: CGRect(x: 0.1, y: y, width: 0.7, height: 0.03), confidence: 1)
            let ns = text as NSString
            line.wordBoxes = words.map { word, x, width in
                OCREngine.WordBox(range: ns.range(of: word), normalizedRect: CGRect(x: x, y: y, width: width, height: 0.03))
            }
            return line
        }
        let lines = [
            line("Payments go to Bright-", y: 0.6,
                 words: [("Payments", 0.1, 0.15), ("go", 0.27, 0.04), ("to", 0.33, 0.04), ("Bright-", 0.39, 0.13)]),
            line("water Benefit Services", y: 0.55,
                 words: [("water", 0.1, 0.1), ("Benefit", 0.22, 0.13), ("Services", 0.37, 0.16)]),
        ]
        let hits = await DocumentSearcher().recognisedMatches(lines: lines, query: "Brightwater")
        let doc = try #require(PDFDocument(data: WrappedPhraseRectTests.courierPage("")))
        let page = try #require(doc.page(at: 0))
        try #require(hits.count == 2, "\(hits.map(\.matchedText))")
        #expect(Set(hits.compactMap(\.occurrenceID)).count == 1 && hits.allSatisfy { $0.occurrenceID != nil })
        let bright = DocumentSearcher.paddedNormalizedRect(lines[0].wordBoxes[3].normalizedRect, in: page)
        let water = DocumentSearcher.paddedNormalizedRect(lines[1].wordBoxes[0].normalizedRect, in: page)
        #expect(Set(hits.map(\.normalizedRect.minX)) == [bright.minX, water.minX], "\(hits.map(\.normalizedRect))")
        #expect(hits.contains { $0.normalizedRect == bright } && hits.contains { $0.normalizedRect == water })
        // The raw reading matches on the skeleton page, which is rebuilt from
        // the prepared page: it keeps the closed-spelling hyphens, so a code
        // broken at a line end matches its closed spelling there too.
        let options = OCRMatchSkeleton.options(SearchOptions())
        let prepared = SearchCore.preparePage("Ref XK7Q-\nRT88", options: options)
        let skeleton = OCRMatchSkeleton.skeleton(prepared)
        #expect(!prepared.closedSpellingHyphens.isEmpty)
        #expect(skeleton.closedSpellingHyphens == prepared.closedSpellingHyphens)
        let query = SearchCore.preparedQuery(
            normalized: OCRMatchSkeleton.skeleton(SearchCore.normalizedText("XK7QRT88", options: options)), options: options)
        let spans = SearchCore.literalSpans(in: skeleton, query: query, comparison: [], wholeWord: false, cap: nil).spans
        #expect(spans.compactMap { skeleton.rawNSRange(of: $0) } == [NSRange(location: 4, length: 10)])
    }

    @Test("Across a page boundary: a one-word closed spelling is not tried; a phrase is found on both pages")
    func acrossAPageBoundary() async throws {
        let data = PageSeamPhraseTests.document([
            PageSeamPhraseTests.page(["The statement was sent on the date shown.", "Payments go to Bright-"]),
            PageSeamPhraseTests.page(["water Benefit Services LLC today.", "No further action is needed."]),
        ])
        let closed = try await Self.results(data, .text("Brightwater", options: SearchOptions()))
        #expect(closed.isEmpty, "a one-word search is not tried across a page: \(closed.map(\.matchedText))")
        let hyphenated = try await Self.results(data, .text("Bright-water", options: SearchOptions()))
        PageSeamPhraseTests.expectAcrossTheSeam(hyphenated, matched: "Bright-water", "Bright-water")
        let phrase = try await Self.results(data, .text("Brightwater Benefit", options: SearchOptions()))
        PageSeamPhraseTests.expectAcrossTheSeam(phrase, matched: "Bright-water Benefit", "Brightwater Benefit")
    }

    static func recheck(output: PDFDocument, foundCount: Int, appliedCount: Int) async throws -> SearchRecheck.Outcome {
        let record = AppliedSearchRecord(
            query: AppliedSearchQuery(kind: .text("Brightwater"), options: SearchOptions()), foundCount: foundCount)
        let request = SearchRecheckRequest(record: record, appliedCount: appliedCount, appliedPages: [0])
        return try await SearchRecheck().run(outputDocument: SendablePDFDocument(output), requests: [request])
    }

    @Test("A Searchable export with both lines applied carries neither part, and the re-check lists nothing remaining")
    func exportAndRecheck() async throws {
        let hits = try await Self.results(Self.brokenPage, .text("Brightwater", options: SearchOptions()))
        try #require(hits.count == 2)
        let regions = hits.map { RedactionRegion(id: UUID(), normalizedRect: $0.normalizedRect, source: .manual) }
        let url = try await TestPipeline.processAndExport(
            Self.brokenPage, mode: .searchableRedaction, regions: [0: regions], fillColor: .black, dpi: 150)
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try #require(PDFDocument(url: url))
        let layer = output.page(at: 0)?.string ?? ""
        #expect(!layer.contains("Bright") && !layer.contains("water"), "the rebuilt layer: \(layer)")
        let outcome = try await Self.recheck(output: output, foundCount: hits.count, appliedCount: hits.count)
        if case .attention = outcome.status { Issue.record("a match remains on the output: \(outcome.status)") }
        #expect((outcome.reviewTermTexts ?? []).isEmpty)
    }

    @Test("A Searchable export with one of two occurrences applied: the re-check reads the other as remaining and asks")
    func searchableExportWithOneLeft() async throws {
        let hits = try await Self.results(Self.twicePage, .text("Brightwater", options: SearchOptions()))
        try #require(hits.count == 4, "\(hits.map(\.matchedText))")
        #expect(Set(hits.compactMap(\.occurrenceID)).count == 2)
        let firstOccurrence = try #require(hits.max { $0.normalizedRect.midY < $1.normalizedRect.midY }?.occurrenceID)
        let applied = hits.filter { $0.occurrenceID == firstOccurrence }
        try #require(applied.count == 2)
        let regions = applied.map { RedactionRegion(id: UUID(), normalizedRect: $0.normalizedRect, source: .manual) }
        let url = try await TestPipeline.processAndExport(
            Self.twicePage, mode: .searchableRedaction, regions: [0: regions], fillColor: .black, dpi: 150)
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try #require(PDFDocument(url: url))
        let outcome = try await Self.recheck(output: output, foundCount: hits.count, appliedCount: applied.count)
        guard case .attention = outcome.status else { Issue.record("expected the re-check to ask, got \(outcome.status)"); return }
        #expect(outcome.reviewTermTexts == ["Brightwater"])
    }

    @Test("The recognised route of an exported image: the unapplied occurrence's lines read as remaining and the re-check asks")
    func recognisedOutputWithOneLeft() async throws {
        func line(_ text: String, y: CGFloat) -> OCREngine.TextLine {
            OCREngine.TextLine(text: text, normalizedRect: CGRect(x: 0.1, y: y, width: 0.7, height: 0.03), confidence: 1)
        }
        // The output's recognised lines: the applied occurrence is boxed
        // away, the other is left as printed.
        let lines = [line("Payments go to", y: 0.8), line("Benefit Services LLC today.", y: 0.75),
                     line("Refunds come from Bright-", y: 0.6), line("water as well.", y: 0.55)]
        let remaining = await DocumentSearcher().recognisedMatches(lines: lines, query: "Brightwater")
        try #require(remaining.count == 2, "\(remaining.map(\.matchedText))")
        #expect(Set(remaining.compactMap(\.occurrenceID)).count == 1, "one occurrence remains")
        let record = AppliedSearchRecord(
            query: AppliedSearchQuery(kind: .text("Brightwater"), options: SearchOptions()), foundCount: 4)
        let request = SearchRecheckRequest(record: record, appliedCount: 2, appliedPages: [0])
        let observation = RecheckObservation(
            pageIndex: 0, route: .ocr, regexTimedOut: false,
            counts: [0: RecheckObservation.Count(remaining: remaining.count, hitCap: false, perTerm: ["Brightwater": remaining.count])])
        let outcome = SearchRecheck.fold(requests: [request], observations: [observation], pageCount: 1)
        guard case .attention = outcome.status else { Issue.record("expected the re-check to ask, got \(outcome.status)"); return }
        #expect(outcome.reviewTermTexts == ["Brightwater"])
    }
}

extension DocumentSearcher {
    /// The recognised route's literal matches for hand-built lines, on a
    /// blank US Letter page made inside the searcher.
    func recognisedMatches(lines: [OCREngine.TextLine], query: String) -> [SearchResult] {
        guard let page = PDFDocument(data: WrappedPhraseRectTests.courierPage(""))?.page(at: 0) else { return [] }
        return ocrLiteralMatches(
            lines: lines, query: query, options: SearchOptions(), page: page, pageIndex: 0, term: query)
    }
}
