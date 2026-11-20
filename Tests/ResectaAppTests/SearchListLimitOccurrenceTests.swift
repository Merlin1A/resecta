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

    // MARK: a run that stopped at the limit ends as a cancelled run

    /// The engine stops at the limit and ends its stream, so a run at the
    /// limit reaches its end with its task not cancelled. It ends as a
    /// cancelled run all the same (`SearchState.runEndsCancelled`, run
    /// through the view's own end, `SearchAndRedactSheet.endRunState`):
    /// flushed and stopped, the completed flag down, and for a Scan no
    /// coverage report and no run record, so neither the deselection facts
    /// behind "You left N of M" nor a staged outcome can follow it.
    struct EndRow: Sendable, CustomTestStringConvertible {
        let name: String
        let scan: Bool
        let matches: Int
        let successorStarted: Bool
        let completes: Bool
        let staged: Bool
        /// The last match runs over two lines, and its second line still
        /// waits to be listed when the stream ends.
        var lastWraps: Bool = false
        var testDescription: String { name }
    }

    nonisolated static let endRows: [EndRow] = [
        EndRow(name: "Search, stopped at the limit: it ends as a cancelled run, the completed flag down",
               scan: false, matches: limit, successorStarted: false, completes: false, staged: false),
        EndRow(name: "Scan, stopped at the limit: it ends as a cancelled run, with no report, no run record and no left-unredacted line",
               scan: true, matches: limit, successorStarted: false, completes: false, staged: false),
        EndRow(name: "Search, under the limit: it completes",
               scan: false, matches: 3, successorStarted: false, completes: true, staged: false),
        EndRow(name: "Scan, under the limit: it completes, with its report and a staged run record",
               scan: true, matches: 3, successorStarted: false, completes: true, staged: true),
        EndRow(name: "Scan, stopped at the limit, its task cancelled by a successor: the successor's run is left as it stands",
               scan: true, matches: limit, successorStarted: true, completes: false, staged: false),
        EndRow(name: "Search, stopped at the limit with its last match's second line not yet listed: the end lists it",
               scan: false, matches: limit, successorStarted: false, completes: false, staged: false, lastWraps: true),
    ]

    @Test("A run that stopped at the limit ends as a cancelled run, in Search and in Scan", arguments: endRows)
    func runEnd(_ row: EndRow) {
        let state = SearchState()
        let redaction = RedactionState()
        redaction.activeSearch = state
        state.clearResults()
        state.searchModeType = row.scan ? .piiScan : .text
        let run = state.beginRun()
        state.isSearching = true
        state.activeSearchTask = Task {}
        state.totalPages = 40
        state.currentSearchPage = 12
        for _ in 0..<(row.lastWraps ? row.matches - 1 : row.matches) { state.appendResult(Self.single(), run: run) }
        if row.lastWraps {
            let last = UUID()
            state.appendResult(Self.line(of: last), run: run)
            state.appendResult(Self.line(of: last), run: run)
            #expect(!state.pendingResults.isEmpty, "the last line still waits to be listed")
        }
        #expect(state.resultsAtCap == (row.matches == Self.limit), "the limit marked")
        #expect(state.isSearching, "the limit alone does not stop the run")
        if row.successorStarted {
            // A successor cancels this run's task, then clears and begins its own.
            state.clearResults()
            _ = state.beginRun()
            state.isSearching = true
            state.activeSearchTask = Task {}
        }
        let scan = row.scan ? SearchAndRedactSheet.ScanRunFacts(enabled: [], startedAt: Date()) : nil
        let completed = SearchAndRedactSheet.endRunState(
            run: run, taskCancelled: row.successorStarted, scan: scan,
            searchState: state, redactionState: redaction)
        #expect(completed == row.completes, "the cleanup tail ran")
        #expect(state.hasCompletedRunSinceClear == row.completes, "the completed flag")
        #expect(state.pendingResults.isEmpty, "what the run holds is flushed")
        #expect(state.results.count == (row.successorStarted ? 0 : row.matches + (row.lastWraps ? 1 : 0)), "rows listed")
        #expect(state.isSearching == row.successorStarted, "still searching: only a successor's run")
        #expect((state.activeSearchTask == nil) == (!row.completes && !row.successorStarted),
                "the run's task let go at the limit; a successor's kept")
        #expect((state.lastCoverageReport != nil) == row.staged, "the Scan coverage report")
        #expect((redaction.lastDetectionRun?.outcome == .staged) == row.staged, "a staged run record")
        #expect((redaction.lastDetectionRun == nil) == !row.staged, "any run record")
        #expect(VerificationResultsView.shouldShowDeselectionRow(snapshot: redaction.runEntryDeselectionSnapshot()) == row.staged,
                "what the left-unredacted line reads")
    }

    /// A superseded run's end never takes the cap branch: the run token
    /// moved on, so the newer run is left going. Every run start today
    /// cancels the old task first, so this end is reached only here.
    @Test("A superseded run's end at the limit leaves the newer run going")
    func supersededEndAtTheLimit() {
        let state = SearchState()
        state.clearResults()
        let run = state.beginRun()
        state.isSearching = true
        state.totalPages = 40
        state.currentSearchPage = 12
        for _ in 0..<Self.limit { state.appendResult(Self.single(), run: run) }
        #expect(state.resultsAtCap, "the limit marked")
        _ = state.beginRun()  // a newer run, the old task not cancelled
        state.isSearching = true
        state.activeSearchTask = Task {}
        #expect(!state.runEndsCancelled(run: run, taskCancelled: false), "the old run's end takes no cap branch")
        #expect(state.isSearching, "the newer run still searching")
        #expect(state.activeSearchTask != nil, "the newer run's task kept")
    }

    /// The view's run end, read from the source: the run task ends through
    /// `finishSearchRun`, which asks `endRunState` first and stops there for
    /// a run that ends cancelled, before the sinks come down and before the
    /// VoiceOver completion line.
    @Test("The view's run end asks endRunState first and stops there for a cancelled run (source pin)")
    func finishSearchRunSourcePin() throws {
        let source = try Self.loadRepoFile("Sources/ResectaApp/Views/Search/SearchAndRedactSheet+Trigger.swift")
        #expect(source.contains("await finishSearchRun(prepared, cancelled: Task.isCancelled)"),
                "the run task ends through finishSearchRun")
        guard let start = source.range(of: "private func finishSearchRun("),
              let end = source.range(of: "private func tearDownEngineSinks()", range: start.upperBound..<source.endIndex)
        else {
            Issue.record("Could not locate finishSearchRun")
            return
        }
        let body = String(source[start.upperBound..<end.lowerBound])
        guard let gate = body.range(of: "guard Self.endRunState("),
              let stop = body.range(of: ") else { return }", range: gate.upperBound..<body.endIndex),
              let teardown = body.range(of: "await tearDownEngineSinks()"),
              let line = body.range(of: "UIAccessibility.post(")
        else {
            Issue.record("Could not locate the run end's steps")
            return
        }
        #expect(body[gate.upperBound..<stop.lowerBound].contains("run: prepared.run"),
                "the run's own token reaches the decision")
        #expect(body[gate.upperBound..<stop.lowerBound].contains("taskCancelled: cancelled"),
                "the task's cancel reaches the decision")
        #expect(stop.upperBound <= teardown.lowerBound, "the sinks come down only after the decision")
        #expect(teardown.upperBound <= line.lowerBound, "the completion line comes last")
        #expect(!body.contains("guard !cancelled"), "no decision of its own beside endRunState")
    }

    @Test("The case table's row count")
    func rowCount() {
        #expect(Self.rows.count == 5)
        #expect(Self.endRows.count == 6)
    }

    private static func loadRepoFile(_ relativePath: String, from file: StaticString = #filePath) throws -> String {
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
