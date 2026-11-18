import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// A match on a recognised line is boxed on the words it touches, from the
// recogniser's word boxes. When a word it touches has no box of its own,
// the union of the other words' boxes would leave that word outside the
// box and readable, so the part is boxed by the whole line instead. The
// lines are built by hand (`PrintLayout`); no recognition runs.

enum MatchedWordsBoxExpectation: Sendable {
    case wholeLine
    case words([Int])
}

/// The box expected on one line the match touches.
struct MatchedWordsBoxPart: Sendable {
    let line: Int
    let box: MatchedWordsBoxExpectation
    init(_ line: Int, _ box: MatchedWordsBoxExpectation) { self.line = line; self.box = box }
}

struct MatchedWordsBoxCase: Sendable, CustomTestStringConvertible {
    let name: String
    let lines: [PrintedLine]
    /// For each line, the words (by their order in the line) left without a box.
    let unboxed: [[Int]]
    let query: String
    /// Through the whole matcher (`ocrLiteralMatches`); otherwise
    /// `matchedWordsRect` on the first line alone.
    let searched: Bool
    let expect: [MatchedWordsBoxPart]
    var testDescription: String { name }
}

@Suite("OCR match box: the whole line when a matched word has no box")
struct OCRMatchedWordsBoxTests {
    static let sentence = [PrintLayout.line("Please contact Jane Doe about the claim", x: 72, top: 300)]

    static let cases: [MatchedWordsBoxCase] = [
        MatchedWordsBoxCase(name: "the first matched word has no box: the line's box", lines: sentence, unboxed: [[2]],
                            query: "Jane Doe", searched: false, expect: [MatchedWordsBoxPart(0, .wholeLine)]),
        MatchedWordsBoxCase(name: "the last matched word has no box: the line's box", lines: sentence, unboxed: [[3]],
                            query: "Jane Doe", searched: false, expect: [MatchedWordsBoxPart(0, .wholeLine)]),
        MatchedWordsBoxCase(name: "a middle matched word has no box: the line's box", lines: sentence, unboxed: [[2]],
                            query: "contact Jane Doe", searched: false, expect: [MatchedWordsBoxPart(0, .wholeLine)]),
        MatchedWordsBoxCase(name: "a word outside the match has no box: the matched words' boxes", lines: sentence, unboxed: [[4]],
                            query: "Jane Doe", searched: false, expect: [MatchedWordsBoxPart(0, .words([2, 3]))]),
        MatchedWordsBoxCase(name: "no word has a box: the line's box", lines: sentence, unboxed: [Array(0..<7)],
                            query: "Jane Doe", searched: false, expect: [MatchedWordsBoxPart(0, .wholeLine)]),
        MatchedWordsBoxCase(
            name: "across two lines, the second line's first word has no box: the first line by its word, the second whole",
            lines: [PrintLayout.line("Please contact Jane", x: 72, top: 300), PrintLayout.line("Doe Smith about the claim", x: 72, top: 320)],
            unboxed: [[], [0]], query: "Jane Doe Smith", searched: true, expect: [MatchedWordsBoxPart(0, .words([2])), MatchedWordsBoxPart(1, .wholeLine)]),
        MatchedWordsBoxCase(name: "every word boxed, a match inside one word: that word's box", lines: sentence, unboxed: [[]],
                            query: "ane", searched: false, expect: [MatchedWordsBoxPart(0, .words([2]))]),
        MatchedWordsBoxCase(name: "every word boxed, a value wrapping over two lines of a column: the same boxes as before",
                            lines: TurnedPrintLayouts.column, unboxed: [], query: TurnedPrintLayouts.wrappedValue.query, searched: true,
                            expect: TurnedPrintLayouts.wrappedValue.parts.map { MatchedWordsBoxPart($0.line, .words($0.words)) }),
    ]

    static func recognised(_ row: MatchedWordsBoxCase) -> [OCREngine.TextLine] {
        var lines = PrintLayout.recognised(row.lines, page: PrintLayout.letter)
        for (index, unboxed) in row.unboxed.enumerated() {
            let names = Set(unboxed.map { lines[index].wordBoxes[$0].range })
            lines[index].wordBoxes.removeAll { names.contains($0.range) }
        }
        return lines
    }

    static func union(_ line: OCREngine.TextLine, _ words: [Int], allWords: [OCREngine.WordBox]) -> CGRect? {
        let rects = words.map { allWords[$0].normalizedRect }
        return rects.first.map { first in rects.dropFirst().reduce(first) { $0.union($1) } }
    }

    @Test("the suite holds 8 rows")
    func rowCount() {
        #expect(Self.cases.count == 8)
    }

    @Test("a match's box on a recognised line", arguments: cases)
    func box(_ row: MatchedWordsBoxCase) async throws {
        let lines = Self.recognised(row)
        let boxed = PrintLayout.recognised(row.lines, page: PrintLayout.letter)
        if !row.searched {
            let local = (lines[0].text as NSString).range(of: row.query)
            try #require(local.location != NSNotFound)
            let rect = DocumentSearcher.matchedWordsRect(lines[0], local: local)
            switch try #require(row.expect.first).box {
            case .wholeLine:
                #expect(rect == nil, "a part touching a word with no box falls back to the line: got \(String(describing: rect))")
            case .words(let words):
                let expected = try #require(Self.union(lines[0], words, allWords: boxed[0].wordBoxes))
                #expect(rect == expected, "got \(String(describing: rect)), expected \(expected)")
            }
            return
        }
        var options = SearchOptions()
        options.includeOCR = true
        let page = OCRLineJoinDirectionTests.blankPage(PrintLayout.letter)
        let hits = await DocumentSearcher().ocrLiteralMatches(lines: lines, query: row.query, options: options,
                                                              page: page, pageIndex: 0, term: row.query)
        #expect(hits.count == row.expect.count, "\(hits.count) results, \(hits.map(\.matchedText))")
        guard hits.count == row.expect.count else { return }
        let reference = OCRLineJoinDirectionTests.blankPage(PrintLayout.letter)
        // The results come in the order of the lines the match touches.
        for (hit, part) in zip(hits, row.expect) {
            let lineIndex = part.line
            let unpadded: CGRect
            switch part.box {
            case .wholeLine: unpadded = lines[lineIndex].normalizedRect
            case .words(let words): unpadded = try #require(Self.union(lines[lineIndex], words, allWords: boxed[lineIndex].wordBoxes))
            }
            let expected = DocumentSearcher.paddedNormalizedRect(unpadded, in: reference)
            #expect(OCRLineJoinDirectionTests.close(hit.normalizedRect, expected),
                    "line \(lineIndex) boxed \(hit.normalizedRect), expected \(expected)")
        }
    }
}
