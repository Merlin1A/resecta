import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// Typed numbers, codes and names on a scanned page, read through the real
// DocumentSearcher on an image-only page whose recognised lines are seeded
// as Vision reads them (each with its word boxes). Scan's confusable
// normalizer rewrites a letter-majority line toward letters ("Suite 100" →
// "Suite IOO"); the OCR literal route now matches on the confusable classes
// on both sides, so the typed text matches the line as read, a misread
// "1OO" included. Each match is boxed on the words it covers, not the whole
// line; accents fold on both sides; the query's edge punctuation is trimmed.
// A text-layer page never takes the classes.
//
// Privacy rule (audit-lint M-1): locate/match/cover vocabulary.

@Suite("OCR confusable search", .tags(.search))
struct OCRConfusableSearchTests {

    /// A recognised line at `y`: each whitespace-separated word boxed at
    /// 0.01 of the page width per UTF-16 unit from x 0.1.
    static func line(_ text: String, y: CGFloat = 0.6) -> OCREngine.TextLine {
        let ns = text as NSString
        var boxes: [OCREngine.WordBox] = []
        var start: Int? = nil
        for i in 0...ns.length {
            let isSpace = i == ns.length || ns.character(at: i) == 0x20
            if !isSpace, start == nil { start = i }
            if isSpace, let s = start {
                boxes.append(OCREngine.WordBox(
                    range: NSRange(location: s, length: i - s),
                    normalizedRect: CGRect(x: 0.1 + 0.01 * CGFloat(s), y: y, width: 0.01 * CGFloat(i - s), height: 0.02)))
                start = nil
            }
        }
        return OCREngine.TextLine(
            text: text, normalizedRect: CGRect(x: 0.1, y: y, width: 0.01 * CGFloat(ns.length), height: 0.02),
            confidence: 0.9, wordBoxes: boxes)
    }

    static func results(_ lines: [OCREngine.TextLine], _ mode: SearchMode) async throws -> (PDFDocument, [SearchResult]) {
        let doc = try #require(PDFDocument(data: TestFixtures.imageOnlyPDF()))
        let searcher = DocumentSearcher()
        await searcher._testSeedOCRLines(lines, forPageIndex: 0)
        let stream = searcher.search(SendablePDFDocument(doc), mode: mode, progress: { _, _ in })
        var out: [SearchResult] = []
        for await r in stream { out.append(r) }
        return (doc, out)
    }

    static func text(_ query: String) -> SearchMode { .text(query, options: SearchOptions(includeOCR: true)) }

    /// The padded union of the boxes of words `first...last` of `line`.
    static func wordsBox(_ line: OCREngine.TextLine, _ words: ClosedRange<Int>, page: PDFPage) -> CGRect {
        let union = line.wordBoxes[words].map(\.normalizedRect).reduce(line.wordBoxes[words.lowerBound].normalizedRect) { $0.union($1) }
        return DocumentSearcher.paddedNormalizedRect(union, in: page)
    }

    /// The same box to within floating-point noise.
    static func same(_ a: CGRect?, _ b: CGRect) -> Bool {
        guard let a else { return false }
        return abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9 && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
    }

    @Test("Suite 100 on a letter-majority line: one result, boxed on its two words, the text as typed")
    func suiteNumber() async throws {
        let suite = Self.line("Suite 100, Lakeport, IL 61099")
        let (doc, hits) = try await Self.results([suite], Self.text("Suite 100"))
        let page = try #require(doc.page(at: 0))
        #expect(hits.count == 1, "\(hits.map(\.matchedText))")
        #expect(hits.first?.matchedText == "Suite 100")
        #expect(Self.same(hits.first?.normalizedRect, Self.wordsBox(suite, 0...1, page: page)), "the words Suite and 100,, not the line")
        #expect(!Self.same(hits.first?.normalizedRect, DocumentSearcher.paddedNormalizedRect(suite.normalizedRect, in: page)))
        #expect(hits.first?.occurrenceID == nil, "a match inside one line is one result, no occurrence")
        if case .ocr = hits.first?.source {} else { Issue.record("expected an OCR result") }
    }

    static let numbers: [(String, String)] = [
        ("Case No. 18-115 filed in Room 101", "18-115"),
        ("Case No. 18-115 filed in Room 101", "Room 101"),
        ("Total due: $1,000 for Apt 4B", "$1,000"),
        ("Total due: $1,000 for Apt 4B", "1,000"),
        ("Total due: $1,000 for Apt 4B", "Apt 4B"),
        ("Member ID SO5518 since 2015", "SO5518"),
        ("Call (414) 555-0193 or 262-555-0148", "(414) 555-0193"),
        ("Interpreter: Iñaki Zubizarreta-Núñez", "Iñaki Zubizarreta-Núñez"),
        ("Interpreter: Iñaki Zubizarreta-Núñez", "Inaki Zubizarreta-Nunez"),
        ("Interpreter: Inaki Zubizarreta-Nunez", "Iñaki Zubizarreta-Núñez"),
        ("Suite 1OO, Lakeport", "Suite 100"),
        ("Member ID S05518 since 2015", "SO5518"),
    ]

    @Test("Each typed number, code or name matches its line as Vision read it", arguments: numbers)
    func typedMatchesRead(line: String, query: String) async throws {
        let (_, hits) = try await Self.results([Self.line(line)], Self.text(query))
        #expect(hits.count == 1, "\(query) on \(line): \(hits.map(\.matchedText))")
    }

    @Test("$1,000: the currency sign is trimmed from the query, and the box still covers the word $1,000")
    func amountBox() async throws {
        let total = Self.line("Total due: $1,000 for Apt 4B")
        let (doc, hits) = try await Self.results([total], Self.text("$1,000"))
        let page = try #require(doc.page(at: 0))
        #expect(hits.count == 1)
        #expect(Self.same(hits.first?.normalizedRect, Self.wordsBox(total, 2...2, page: page)))
    }

    @Test("A token of letters alone keeps its letters: ID does not match the ld of field or held")
    func lettersOnlyTokens() async throws {
        let (_, id) = try await Self.results([Self.line("The field was held open")], Self.text("ID"))
        #expect(id.isEmpty, "\(id.map(\.matchedText))")
    }

    @Test("Letters Vision read as a digit match through the corrected reading: ID on a line read 1D State")
    func lettersReadAsDigits() async throws {
        let (_, hits) = try await Self.results([Self.line("Issued by the 1D State office")], Self.text("ID"))
        #expect(hits.count == 1, "\(hits.map(\.matchedText))")
        #expect(hits.first?.matchedText == "1D", "the text Vision read")
    }

    @Test("A text-layer page never takes the classes: SOO does not match a printed 500")
    func textLayerPrecision() async throws {
        let data = WrappedPhraseRectTests.courierPage("BT /F1 12 Tf 72 700 Td (Total 500 due) Tj ET")
        let (_, hits) = try await WrappedPhraseRectTests.results(data, mode: .text("SOO", options: SearchOptions()))
        #expect(hits.isEmpty, "\(hits.map(\.matchedText))")
        let (_, plain) = try await WrappedPhraseRectTests.results(data, mode: .text("500", options: SearchOptions()))
        #expect(plain.count == 1)
    }

    @Test("Multi-term OR matches both typed numbers on their lines")
    func multiTermOr() async throws {
        let lines = [Self.line("Suite 100, Lakeport, IL 61099", y: 0.7), Self.line("Total due: $1,000 for Apt 4B", y: 0.6)]
        let (_, hits) = try await Self.results(lines, .multiTerm(["Suite 100", "Apt 4B"], options: SearchOptions(includeOCR: true)))
        #expect(Set(hits.map(\.term)) == ["Suite 100", "Apt 4B"], "\(hits.map(\.term))")
        #expect(hits.count == 2)
    }

    @Test("A typed phrase across two recognised lines: one result per line, one occurrence, each on its words")
    func acrossLines() async throws {
        let first = Self.line("Total due:", y: 0.7), second = Self.line("$1,000 for Apt 4B", y: 0.67)
        let (doc, hits) = try await Self.results([first, second], Self.text("due: $1,000"))
        let page = try #require(doc.page(at: 0))
        #expect(hits.count == 2, "\(hits.map(\.matchedText))")
        #expect(Set(hits.compactMap(\.occurrenceID)).count == 1 && hits.allSatisfy { $0.occurrenceID != nil })
        let expected = [Self.wordsBox(first, 1...1, page: page), Self.wordsBox(second, 0...0, page: page)]
        #expect(expected.allSatisfy { box in hits.contains { Self.same($0.normalizedRect, box) } }, "\(hits.map(\.normalizedRect))")
    }

    @Test("The displayed text is sliced from the recognised line itself")
    func displayedTextIsTheRead() async throws {
        let (_, hits) = try await Self.results([Self.line("Suite 1OO, Lakeport")], Self.text("Suite 100"))
        #expect(hits.first?.matchedText == "Suite 1OO", "what the OCR Check reads, not the typed form")
    }
}
