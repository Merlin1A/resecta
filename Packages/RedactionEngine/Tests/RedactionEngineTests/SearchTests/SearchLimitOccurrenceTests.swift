import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The result limit counts occurrences, not rows. A match over two lines is
// one occurrence listed as two rows; at the limit it is listed whole or not
// at all, so applying every listed row never covers part of a match. Each row
// runs a whole search over pages of "Zebra Crossing", some broken after
// "Zebra" so that "Crossing" starts the next line or the next page.

@Suite("The result limit keeps each match whole", .tags(.search))
struct SearchLimitOccurrenceTests {

    enum Phrase: Sendable { case oneLine, wrapped, acrossPage }
    enum Mode: String, Sendable { case text, pattern, alwaysFlag }

    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let mode: Mode
        /// Phrases page by page; `.acrossPage` ends its page with "Zebra".
        let pages: [[Phrase]]
        let rows: Int
        let occurrences: Int
        /// Matches listed as more than one row; each must show all its rows.
        let wholeSplitMatches: Int
        var testDescription: String { name }
    }

    static func phrases(_ oneLine: Int, then others: [Phrase] = []) -> [Phrase] {
        Array(repeating: .oneLine, count: oneLine) + others
    }

    static let limit = DocumentSearcher.maxResults

    static let rows: [Row] = [
        Row(name: "typed search, three lines broken at the limit: 1000 matches, each whole", mode: .text,
            pages: [phrases(limit - 2, then: [.wrapped, .wrapped, .wrapped])], rows: limit + 2, occurrences: limit, wholeSplitMatches: 2),
        Row(name: "typed search, the 1000th match broken over two lines: both its lines are listed", mode: .text,
            pages: [phrases(limit - 1, then: [.wrapped])], rows: limit + 1, occurrences: limit, wholeSplitMatches: 1),
        Row(name: "typed search, a broken match past the limit: none of its lines is listed", mode: .text,
            pages: [phrases(limit, then: [.wrapped])], rows: limit, occurrences: limit, wholeSplitMatches: 0),
        Row(name: "typed search, under the limit: every line of every match is listed", mode: .text,
            pages: [phrases(20, then: Array(repeating: .wrapped, count: 10))], rows: 40, occurrences: 30, wholeSplitMatches: 10),
        Row(name: "typed search, the 1000th match across the page break: both parts are listed", mode: .text,
            pages: [phrases(limit - 1, then: [.acrossPage]), []], rows: limit + 1, occurrences: limit, wholeSplitMatches: 1),
        Row(name: "pattern, broken lines on the first of two pages: 1000 matches, each whole", mode: .pattern,
            pages: [phrases(598, then: [.wrapped, .wrapped]), phrases(402)], rows: limit + 2, occurrences: limit, wholeSplitMatches: 2),
        Row(name: "pattern, a broken match past the limit: none of its lines is listed", mode: .pattern,
            pages: [phrases(limit, then: [.wrapped])], rows: limit, occurrences: limit, wholeSplitMatches: 0),
        Row(name: "always-flag term, broken matches at the limit: each is one row, counted once", mode: .alwaysFlag,
            pages: [phrases(limit - 1, then: [.wrapped, .wrapped])], rows: limit, occurrences: limit, wholeSplitMatches: 0),
    ]

    /// Small print, eight phrases to a line, five points apart, then plain lines.
    static func pagesPDF(_ pages: [[Phrase]]) -> Data {
        var objects: [PDFObject] = [PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>")]
        let font = 3, firstPage = 4
        var kids: [String] = []
        var carry = false
        for (k, phrases) in pages.enumerated() {
            let pageId = firstPage + 2 * k, contentId = pageId + 1
            kids.append("\(pageId) 0 R")
            var lines: [String] = [], line: [String] = carry ? ["Crossing"] : []
            carry = false
            func flush() { if !line.isEmpty { lines.append(line.joined(separator: " ")); line = [] } }
            for phrase in phrases {
                switch phrase {
                case .oneLine:
                    line.append("Zebra Crossing")
                    if line.count >= 8 { flush() }
                case .wrapped:
                    line.append("Zebra"); flush(); line = ["Crossing"]
                case .acrossPage:
                    line.append("Zebra"); carry = true
                }
            }
            flush()
            // Plain lines after the phrases, so every page reads as a full text
            // layer; none on a page whose last match runs on to the next page.
            if !carry { lines += Array(repeating: "Harbour account entries for the quarter", count: 12) }
            let body = lines.map { "(\($0)) Tj 0 -5 Td" }.joined(separator: " ")
            let stream = "BT /F1 4 Tf 24 775 Td \(body) ET"
            objects.append(PDFObject(id: pageId, content: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(contentId) 0 R /Resources << /Font << /F1 \(font) 0 R >> >> >>"))
            objects.append(PDFObject(id: contentId, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"))
        }
        objects.append(PDFObject(id: 2, content: "<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count \(pages.count) >>"))
        objects.append(PDFObject(id: font, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"))
        return buildRawPDF(objects: objects, rootId: 1)
    }

    @Test("The result limit counts matches and lists each one whole", arguments: rows)
    func limitKeepsMatchesWhole(_ row: Row) async throws {
        let doc = try #require(PDFDocument(data: Self.pagesPDF(row.pages)))
        let searcher = DocumentSearcher()
        let mode: SearchMode
        switch row.mode {
        case .text: mode = .text("Zebra Crossing", options: SearchOptions())
        case .pattern: mode = .regex(#"Zebra\s+Crossing"#, options: SearchOptions())
        case .alwaysFlag:
            await searcher.setUserTerms(UserTermsIndex(matcher: UserTermMatcher.compile(
                alwaysFlag: [UserTerm(pattern: #"Zebra\s+Crossing"#, isRegex: true)], neverFlag: [])))
            mode = .piiScan(categories: [.ssn], options: SearchOptions())
        }
        var listed: [SearchResult] = []
        for await result in searcher.search(SendablePDFDocument(doc), mode: mode, progress: { _, _ in }) { listed.append(result) }
        let byMatch = Dictionary(grouping: listed.filter { $0.occurrenceID != nil }, by: { $0.occurrenceID! })
        #expect(listed.count == row.rows, "rows")
        #expect(Set(listed.map(DocumentSearcher.occurrenceKey)).count == row.occurrences, "matches")
        #expect(byMatch.count == row.wholeSplitMatches, "matches over two lines or pages")
        #expect(byMatch.values.allSatisfy { $0.count == 2 }, "each such match lists both its parts")
        if row.pages.count == 2, row.mode == .text, let parts = byMatch.values.first {
            #expect(Set(parts.map(\.pageIndex)) == [0, 1], "the parts lie on both pages")
        }
    }

    // MARK: the Search Re-check reads a page as stopped at the limit by its matches, not its rows

    struct RecheckRow: Sendable, CustomTestStringConvertible {
        let name: String
        let phrases: [Phrase]
        let remaining: Int
        let stoppedAtLimit: Bool
        var testDescription: String { name }
    }

    static let recheckRows: [RecheckRow] = [
        RecheckRow(name: "999 matches, one over two lines: 1000 rows remain, and the page is read in full",
                   phrases: phrases(limit - 2, then: [.wrapped]), remaining: limit, stoppedAtLimit: false),
        RecheckRow(name: "1000 matches, the last over two lines: 1001 rows remain, and the page stopped at the limit",
                   phrases: phrases(limit - 1, then: [.wrapped]), remaining: limit + 1, stoppedAtLimit: true),
        RecheckRow(name: "1001 matches on one line each: 1000 remain, and the page stopped at the limit",
                   phrases: phrases(limit + 1), remaining: limit, stoppedAtLimit: true),
    ]

    @Test("The Search Re-check stops a page at maxResults matches, not rows", arguments: recheckRows)
    func recheckStopsAtMatches(_ row: RecheckRow) async throws {
        let observation = try await OutputRecheck.observePage(
            OutputRecheck.PageWork(index: 0, data: Self.pagesPDF([row.phrases]), requestIndices: [0]),
            requests: [TestFixtures.textRequest("Zebra Crossing")], regexTimeoutOverride: nil)
        let count = try #require(observation.counts[0])
        #expect(count.remaining == row.remaining, "rows remaining")
        #expect(count.hitCap == row.stoppedAtLimit, "stopped at the limit")
    }

    @Test("Every mode has a row under the limit or past it, and a row at it")
    func rowsCoverEachMode() {
        #expect(Self.rows.count == 8)
        #expect(Set(Self.rows.map(\.mode)) == [.text, .pattern, .alwaysFlag])
        #expect(Self.rows.contains { $0.rows > $0.occurrences && $0.occurrences == Self.limit })
        #expect(Self.rows.contains { $0.occurrences < Self.limit })
    }
}
