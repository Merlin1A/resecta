import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// Regex anchors match per line: a user typing `^Total$` means the line, not
// the whole page. Read through the real searcher on a raw two-line page.
//
// Privacy rule (audit-lint M-1): locate/match vocabulary.

@Suite("Regex anchors per line", .tags(.search))
struct RegexAnchorsPerLineTests {

    @Test("A start and end anchor around a word on the second line matches that line")
    func anchorsMatchTheSecondLine() async throws {
        let doc = try #require(PDFDocument(data: WrappedPhraseRectTests.wrappedPage))
        #expect(doc.page(at: 0)?.string == "Jane\nDoe")
        let searcher = DocumentSearcher()
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: .regex("^Doe$", options: SearchOptions()), progress: { _, _ in })
        var hits: [SearchResult] = []
        for await hit in stream { hits.append(hit) }
        #expect(hits.count == 1, "the anchored pattern matches the second line: \(hits.map(\.matchedText))")
        #expect(hits.first?.matchedText == "Doe")
    }

    @Test("An anchored pattern that spans no line keeps matching nothing")
    func anchoredPatternAcrossLinesMatchesNothing() async throws {
        let doc = try #require(PDFDocument(data: WrappedPhraseRectTests.wrappedPage))
        let searcher = DocumentSearcher()
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: .regex("^Jane Doe$", options: SearchOptions()), progress: { _, _ in })
        var hits: [SearchResult] = []
        for await hit in stream { hits.append(hit) }
        #expect(hits.isEmpty)
    }
}
