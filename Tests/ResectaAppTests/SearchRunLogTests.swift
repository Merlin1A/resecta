import CoreGraphics
import Foundation
import Testing
@testable import ResectaApp
import RedactionEngine

// The document's run log for the stop at Redact: every run that started
// reading, oldest first, with the query it ran; a replaced run, which kept
// no account, is not among the closed runs.

@MainActor
@Suite("Redact stop: the document's run log")
struct SearchRunLogTests {

    @Test("A run that opens an account logs its query, as it started")
    func openingLogsTheQuery() {
        let search = SearchState(defaults: makeScratchDefaults().0)
        search.searchModeType = .text
        search.queryText = "Delia"
        var logged: [AppliedSearchQuery] = []
        search.accountOpenedSink = { _, query in logged.append(query) }
        let run = search.beginRun()
        search.beginAccount(run: run, pageCount: 3)
        #expect(logged == [AppliedSearchQuery(kind: .text("Delia"), options: search.options)])
    }

    @Test("A run replaced after an Apply tells the document it was replaced; one replaced unapplied, or completed, does not")
    func replacedRunIsReported() throws {
        var replaced: [UUID] = []
        let store = SearchAccountLifecycleTests.Store()
        let (applied, _) = SearchAccountLifecycleTests.running(store)
        applied.accountReplacedSink = { replaced.append($0) }
        let token = try #require(applied.appliedSearchRecord()?.accountToken)
        applied.closeAccount(.replaced)
        #expect(replaced == [token])
        let (unapplied, _) = SearchAccountLifecycleTests.running(store)
        unapplied.accountReplacedSink = { replaced.append($0) }
        unapplied.closeAccount(.replaced)
        let (completed, run) = SearchAccountLifecycleTests.running(store)
        completed.accountReplacedSink = { replaced.append($0) }
        _ = completed.appliedSearchRecord()
        completed.closeAccount(.completed, run: run)
        #expect(replaced == [token])
    }

    @Test("Closed runs come oldest first with their queries; a replaced run is left out")
    func closedRunsInOrder() {
        let state = RedactionState()
        let first = UUID(), replaced = UUID(), last = UUID()
        let a = AppliedSearchQuery(kind: .text("Delia"), options: SearchOptions())
        let b = AppliedSearchQuery(kind: .text("Deli"), options: SearchOptions())
        let c = AppliedSearchQuery(kind: .regex("[0-9]+"), options: SearchOptions())
        state.recordSearchRunOpened(token: first, query: a)
        state.recordSearchRunOpened(token: replaced, query: b)
        state.recordSearchRunOpened(token: last, query: c)
        var account = SearchAccount(pageCount: 1)
        account.end(.completed)
        state.recordSearchAccount(account, token: last)
        state.recordSearchAccount(account, token: first)
        #expect(state.closedSearchRuns.map(\.query) == [a, c])
    }

    @Test("Apply, edit the query, then delete the boxes: the replaced run counts while its boxes remain, and not after")
    func replacedRunCountsWhileItsBoxesRemain() {
        let token = UUID()
        let query = AppliedSearchQuery(kind: .text("Delia"), options: SearchOptions())
        let record = AppliedSearchRecord(query: query, foundCount: 1, accountToken: token)
        let region = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.04),
                                     source: .searchMatch(term: "Delia", rationale: nil))
        let snapshot = MatchAuditSnapshot(
            origin: .search, resultID: UUID(), regionID: region.id, pageIndex: 0, matchedText: "Delia",
            source: .textLayer, piiCategory: nil, piiConfidence: nil, rationale: nil, term: "Delia",
            appliedAt: Date(), searchRecord: record)
        #expect(RedactionState.liveAccountTokens(regions: [0: [region]], audit: [region.id: snapshot]) == [token])
        #expect(RedactionState.liveAccountTokens(regions: [:], audit: [region.id: snapshot]).isEmpty, "the boxes deleted")

        let state = RedactionState()
        state.recordSearchRunOpened(token: token, query: query)
        var account = SearchAccount(pageCount: 2)
        account.end(.stopped(page: 0))
        state.recordSearchRunReplaced(token: token)
        state.recordSearchAccount(account, token: token)
        #expect(state.closedSearchRuns.isEmpty, "no region from the replaced run is on the document")
    }
}
