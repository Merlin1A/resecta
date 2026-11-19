import Testing
import Foundation
@testable import RedactionEngine

// The rule cases no existing test caught: each row states one rule of the
// Search rule set and is shown able to fail by a planted defect (the census
// patches in Mutants/search-rule-*.patch). One accepting and one rejecting row
// at least per rule; the rows run over the pure functions the rule lives in.

@Suite("Search rule cases the planted defects need", .tags(.search))
struct SearchRuleCaseTests {

    // MARK: with Whole Word on, a letter, a number or an underscore beside the match is not an edge

    struct EdgeRow: Sendable, CustomTestStringConvertible {
        let name: String
        let text: String
        let query: String
        let isWholeWord: Bool
        var testDescription: String { name }
    }

    static let edgeRows: [EdgeRow] = [
        EdgeRow(name: "spaces on both sides are edges", text: "ref 4471 due", query: "4471", isWholeWord: true),
        EdgeRow(name: "a hyphen is an edge", text: "ref-4471-due", query: "4471", isWholeWord: true),
        EdgeRow(name: "the text's start and end are edges", text: "4471", query: "4471", isWholeWord: true),
        EdgeRow(name: "an underscore before is not an edge", text: "ref_4471 due", query: "4471", isWholeWord: false),
        EdgeRow(name: "an underscore after is not an edge", text: "ref 4471_due", query: "4471", isWholeWord: false),
        EdgeRow(name: "a letter before is not an edge", text: "ref4471 due", query: "4471", isWholeWord: false),
    ]

    @Test("Whole Word: the edge rule on the text tier", arguments: edgeRows)
    func wholeWordEdge(_ row: EdgeRow) throws {
        let range = try #require(row.text.range(of: row.query))
        #expect(SearchCore.isWholeWord(range, in: row.text) == row.isWholeWord)
    }

    @Test("Whole Word: the same edge rule in base coordinates", arguments: edgeRows)
    func wholeWordEdgeInBase(_ row: EdgeRow) throws {
        let chars = Array(row.text)
        let range = try #require(row.text.range(of: row.query))
        let start = row.text.distance(from: row.text.startIndex, to: range.lowerBound)
        let end = row.text.distance(from: row.text.startIndex, to: range.upperBound)
        #expect(SearchCore.isWholeWordInBase(chars: chars, start: start, endExclusive: end) == row.isWholeWord)
    }

    // MARK: a run stops at maxResults result rows

    struct CapRow: Sendable, CustomTestStringConvertible {
        let name: String
        let alreadyYielded: Int
        let offered: Int
        let yielded: Int
        var testDescription: String { name }
    }

    static let capRows: [CapRow] = [
        CapRow(name: "under the limit: every result is listed", alreadyYielded: 0, offered: DocumentSearcher.maxResults - 1,
               yielded: DocumentSearcher.maxResults - 1),
        CapRow(name: "exactly the limit: every result is listed", alreadyYielded: 0, offered: DocumentSearcher.maxResults,
               yielded: DocumentSearcher.maxResults),
        CapRow(name: "one over the limit: the last is not listed", alreadyYielded: 0, offered: DocumentSearcher.maxResults + 1,
               yielded: DocumentSearcher.maxResults),
        CapRow(name: "one short of the limit, two offered: one is listed", alreadyYielded: DocumentSearcher.maxResults - 1, offered: 2,
               yielded: 1),
        CapRow(name: "at the limit already: none is listed", alreadyYielded: DocumentSearcher.maxResults, offered: 1, yielded: 0),
    ]

    static func result(_ index: Int) -> SearchResult {
        SearchResult(pageIndex: 0, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.01, height: 0.01),
                     matchedText: "x", contextSnippet: "x", source: .textLayer, term: "x")
    }

    @Test("The result limit: a run lists maxResults rows and no more", arguments: capRows)
    func resultLimit(_ row: CapRow) async {
        let searcher = DocumentSearcher()
        let (stream, continuation) = AsyncStream<SearchResult>.makeStream()
        var total = row.alreadyYielded
        await searcher.emitCapped((0..<row.offered).map(Self.result), into: continuation, total: &total)
        continuation.finish()
        var listed = 0
        for await _ in stream { listed += 1 }
        #expect(listed == row.yielded)
        #expect(total == row.alreadyYielded + row.yielded)
    }

    // MARK: inside a token that holds a digit, each look-alike class reads as one symbol

    struct ClassRow: Sendable, CustomTestStringConvertible {
        let name: String
        let a: String
        let b: String
        let same: Bool
        var testDescription: String { name }
    }

    static let classRows: [ClassRow] = [
        ClassRow(name: "{0 O o}: 1O4 reads as 104", a: "1O4", b: "104", same: true),
        ClassRow(name: "{0 O o}: 1o4 reads as 104", a: "1o4", b: "104", same: true),
        ClassRow(name: "{1 I i l}: 7I4 reads as 714", a: "7I4", b: "714", same: true),
        ClassRow(name: "{1 I i l}: 7l4 reads as 714", a: "7l4", b: "714", same: true),
        ClassRow(name: "{5 S s}: 7S4 reads as 754", a: "7S4", b: "754", same: true),
        ClassRow(name: "{8 B b}: 7B4 reads as 784", a: "7B4", b: "784", same: true),
        ClassRow(name: "{8 B b}: 7b4 reads as 784", a: "7b4", b: "784", same: true),
        ClassRow(name: "{2 Z z}: 7Z4 reads as 724", a: "7Z4", b: "724", same: true),
        ClassRow(name: "{6 G g}: 7G4 reads as 764", a: "7G4", b: "764", same: true),
        ClassRow(name: "a token of letters alone is left as read: BOB is not 808", a: "BOB 7", b: "808 7", same: false),
        ClassRow(name: "two classes stay apart: 7B4 is not 764", a: "7B4", b: "764", same: false),
        ClassRow(name: "a letter outside every class is kept: 7A4 is not 704", a: "7A4", b: "704", same: false),
    ]

    @Test("Look-alike classes in a token that holds a digit", arguments: classRows)
    func lookAlikeClass(_ row: ClassRow) {
        #expect((OCRMatchSkeleton.skeleton(row.a) == OCRMatchSkeleton.skeleton(row.b)) == row.same)
    }

    @Test("The case table's row count")
    func rowCount() {
        #expect(Self.edgeRows.count + Self.capRows.count + Self.classRows.count == 23)
    }
}
