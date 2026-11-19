import Testing
import Foundation
@testable import RedactionEngine

// Cases for search rules no other test caught: each row states one rule a
// search follows, and a planted fault in Mutants/search-rule-*.patch turns it
// red. Each rule has at least one accepting and one rejecting row. The edge
// and look-alike rows run the pure functions the rule lives in; the limit rows
// run a whole search in each mode, so the limit is held where results are made.

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
        EdgeRow(name: "a digit before is not an edge", text: "ref 74471 due", query: "4471", isWholeWord: false),
        EdgeRow(name: "a digit after is not an edge", text: "ref 44719 due", query: "4471", isWholeWord: false),
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

    // MARK: a whole search in each mode lists maxResults rows and no more

    enum LimitMode: String, Sendable { case text, pattern, scan, alwaysFlag }

    struct LimitRow: Sendable, CustomTestStringConvertible {
        let name: String
        let mode: LimitMode
        let perPage: [Int]
        let listed: Int
        var testDescription: String { name }
    }

    static let limitRows: [LimitRow] = [
        LimitRow(name: "typed search, under the limit: every match is listed", mode: .text, perPage: [300], listed: 300),
        LimitRow(name: "typed search, one page over the limit: the limit is listed", mode: .text, perPage: [1100], listed: DocumentSearcher.maxResults),
        LimitRow(name: "pattern, one page over the limit: the limit is listed", mode: .pattern, perPage: [1100], listed: DocumentSearcher.maxResults),
        LimitRow(name: "pattern, two pages over the limit together: the limit is listed", mode: .pattern, perPage: [600, 600], listed: DocumentSearcher.maxResults),
        LimitRow(name: "Scan, under the limit: every address is listed", mode: .scan, perPage: [300], listed: 300),
        LimitRow(name: "Scan, one page over the limit: the limit is listed", mode: .scan, perPage: [1100], listed: DocumentSearcher.maxResults),
        LimitRow(name: "Scan, two pages over the limit together: the limit is listed", mode: .scan, perPage: [600, 600], listed: DocumentSearcher.maxResults),
        LimitRow(name: "always-flag term, one page over the limit: the limit is listed", mode: .alwaysFlag, perPage: [1100], listed: DocumentSearcher.maxResults),
    ]

    /// Pages of small print, `count` tokens each, fourteen to a line: each
    /// token a distinct address (`u<n>@mail.com`) for Scan, else "Zebra".
    static func manyTokenPages(_ perPage: [Int], addresses: Bool) -> Data {
        var objects: [PDFObject] = [PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>")]
        let font = 3, firstPage = 4
        var kids: [String] = [], serial = 0
        for (k, count) in perPage.enumerated() {
            let pageId = firstPage + 2 * k, contentId = pageId + 1
            kids.append("\(pageId) 0 R")
            var lines: [String] = [], line: [String] = []
            for _ in 0..<count {
                serial += 1
                line.append(addresses ? "u\(serial)@mail.com" : "Zebra")
                if line.count == 14 { lines.append(line.joined(separator: " ")); line = [] }
            }
            if !line.isEmpty { lines.append(line.joined(separator: " ")) }
            let body = lines.map { "(\($0)) Tj 0 -7 Td" }.joined(separator: " ")
            let stream = "BT /F1 5 Tf 24 770 Td \(body) ET"
            objects.append(PDFObject(id: pageId, content: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(contentId) 0 R /Resources << /Font << /F1 \(font) 0 R >> >> >>"))
            objects.append(PDFObject(id: contentId, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"))
        }
        objects.append(PDFObject(id: 2, content: "<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count \(perPage.count) >>"))
        objects.append(PDFObject(id: font, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"))
        return buildRawPDF(objects: objects, rootId: 1)
    }

    @Test("The result limit: a whole search lists maxResults rows and no more, in each mode", arguments: limitRows)
    func searchLimit(_ row: LimitRow) async throws {
        let doc = try #require(PDFDocument(data: Self.manyTokenPages(row.perPage, addresses: row.mode == .scan)))
        let searcher = DocumentSearcher()
        let mode: SearchMode
        switch row.mode {
        case .text: mode = .text("Zebra", options: SearchOptions())
        case .pattern: mode = .regex("Zeb[a-z]+", options: SearchOptions())
        case .scan: mode = .piiScan(categories: [.email], options: SearchOptions())
        case .alwaysFlag:
            await searcher.setUserTerms(UserTermsIndex(matcher: UserTermMatcher.compile(
                alwaysFlag: [UserTerm(pattern: "Zebra", isRegex: false)], neverFlag: [])))
            mode = .piiScan(categories: [.ssn], options: SearchOptions())
        }
        var listed = 0
        for await _ in searcher.search(SendablePDFDocument(doc), mode: mode, progress: { _, _ in }) { listed += 1 }
        #expect(listed == row.listed, "\(row.mode.rawValue): \(row.perPage) tokens by page")
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

    @Test("Every rule has an accepting and a rejecting row")
    func eachRuleBothWays() {
        #expect(Set(Self.edgeRows.map(\.isWholeWord)) == [true, false])
        #expect(Self.capRows.contains { $0.yielded == $0.offered } && Self.capRows.contains { $0.yielded < $0.offered })
        #expect(Set(Self.classRows.map(\.same)) == [true, false])
        for mode in [LimitMode.text, .scan] {
            let rows = Self.limitRows.filter { $0.mode == mode }
            #expect(rows.contains { $0.listed == $0.perPage.reduce(0, +) } && rows.contains { $0.listed < $0.perPage.reduce(0, +) },
                    "\(mode.rawValue)")
        }
        #expect(Self.edgeRows.count + Self.capRows.count + Self.classRows.count + Self.limitRows.count == 33)
    }
}
