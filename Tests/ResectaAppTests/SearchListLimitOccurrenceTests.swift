import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

/// The list's limit counts matches, not rows, as the engine's does: a match
/// that runs over two lines is two rows sharing an occurrence id, and is
/// listed whole or not at all. A line of a match already listed is always
/// kept; a new match is kept only while fewer than `DocumentSearcher.maxResults`
/// are listed. The match that reaches the limit marks it and lets the run go
/// on, so that match's later lines still arrive; the first new match past the
/// limit is dropped and stops the run. A line with no box is a match of its
/// own (`SearchState.occurrenceKey`).
@Suite("The list's limit counts matches, not rows", .tags(.search))
@MainActor
struct SearchListLimitOccurrenceTests {

    enum Step: Sendable {
        case single                  // a new one-line match
        case wrapped(lines: Int)     // a new match over this many lines
        case laterLine               // one more line of the last wrapped match
        case unboxedLine             // a line with no box sharing the last wrapped match's id
    }

    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let singlesFirst: Int
        let then: [Step]
        let rowsKept: Int
        let atLimit: Bool
        let stillRunning: Bool
        var testDescription: String { name }
    }

    nonisolated static let limit = DocumentSearcher.maxResults

    nonisolated static let rows: [Row] = [
        Row(name: "under the limit: 998 one-line matches, then one over two lines, are 1000 rows of 999 matches, all kept, the run going on",
            singlesFirst: limit - 2, then: [.wrapped(lines: 2)], rowsKept: limit, atLimit: false, stillRunning: true),
        Row(name: "999 one-line matches, then one over two lines, then one more: the wrapped match is kept whole, the last is dropped",
            singlesFirst: limit - 1, then: [.wrapped(lines: 2), .single], rowsKept: limit + 1, atLimit: true, stillRunning: false),
        Row(name: "1000 one-line matches, then a new one: it is dropped and the run stops",
            singlesFirst: limit, then: [.single], rowsKept: limit, atLimit: true, stillRunning: false),
        Row(name: "the 1000th match's second line arrives after the limit is marked: it is kept, and the run goes on",
            singlesFirst: limit - 1, then: [.wrapped(lines: 1), .laterLine], rowsKept: limit + 1, atLimit: true, stillRunning: true),
        Row(name: "a line with no box sharing the 1000th match's id is a match of its own: dropped past the limit",
            singlesFirst: limit - 1, then: [.wrapped(lines: 1), .unboxedLine], rowsKept: limit, atLimit: true, stillRunning: false),
    ]

    static func single() -> SearchResult {
        SearchResult(pageIndex: 0, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.01),
                     matchedText: "Zebra Crossing", contextSnippet: "Zebra Crossing", source: .textLayer, term: "Zebra Crossing")
    }

    static func line(of occurrence: UUID, boxed: Bool = true) -> SearchResult {
        SearchResult(pageIndex: 0, normalizedRect: boxed ? CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.01) : .zero,
                     matchedText: "Zebra Crossing", contextSnippet: "Zebra Crossing", source: .textLayer, term: "Zebra Crossing",
                     occurrenceID: occurrence, hasBox: boxed)
    }

    @Test("The list's limit counts matches, and never splits one", arguments: rows)
    func listLimit(_ row: Row) {
        let state = SearchState()
        state.clearResults()
        let run = state.beginRun()
        state.isSearching = true
        state.totalPages = 40
        state.currentSearchPage = 12
        for _ in 0..<row.singlesFirst { state.appendResult(Self.single(), run: run) }
        var last = UUID()
        for step in row.then {
            switch step {
            case .single:
                state.appendResult(Self.single(), run: run)
            case .wrapped(let lines):
                last = UUID()
                for _ in 0..<lines { state.appendResult(Self.line(of: last), run: run) }
            case .laterLine:
                state.appendResult(Self.line(of: last), run: run)
            case .unboxedLine:
                state.appendResult(Self.line(of: last, boxed: false), run: run)
            }
        }
        state.flushPendingResults()
        #expect(state.results.count == row.rowsKept, "rows kept")
        #expect(state.resultsAtCap == row.atLimit, "the limit marked")
        #expect(state.isSearching == row.stillRunning, "the run still going")
        #expect(SearchState.occurrenceCount(state.results) <= Self.limit, "never more matches than the limit")
        if row.atLimit { #expect(state.capUnscannedPageCount == 28, "the unscanned remainder, snapshot once") }
    }

    @Test("The case table's row count")
    func rowCount() {
        #expect(Self.rows.count == 5)
    }
}
