import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
import RedactionEngine

// A match that runs onto a second line is returned as one result per line,
// the lines sharing one occurrence id. The sheet shows it as ONE row: the
// row's tick selects every line, the counts and the walk count it once,
// and Apply boxes every line. Before, each line was its own row, so one
// line could be applied without the other. The canvas list stays per line
// (both lines highlighted).

@Suite("Search sheet — one row per wrapped match", .tags(.search))
@MainActor
struct SearchStateOccurrenceRowsTests {

    /// A wrapped name on page 0 (two lines, one occurrence) and a single
    /// line match on page 1, appended the way a run appends them.
    private func session() -> (SearchState, wrapped: [SearchResult], single: SearchResult) {
        let state = SearchState(defaults: makeScratchDefaults().0)
        let occurrence = UUID()
        let wrapped = [
            SearchResult(pageIndex: 0, normalizedRect: CGRect(x: 0.60, y: 0.60, width: 0.20, height: 0.03),
                         matchedText: "Marisol Vance-Oduya", contextSnippet: "…the claimant is Marisol Vance-Oduya and…",
                         source: .textLayer, term: "Marisol Vance-Oduya", occurrenceID: occurrence),
            SearchResult(pageIndex: 0, normalizedRect: CGRect(x: 0.10, y: 0.56, width: 0.22, height: 0.03),
                         matchedText: "Marisol Vance-Oduya", contextSnippet: "…the claimant is Marisol Vance-Oduya and…",
                         source: .textLayer, term: "Marisol Vance-Oduya", occurrenceID: occurrence),
        ]
        let single = SearchResult(pageIndex: 1, normalizedRect: CGRect(x: 0.30, y: 0.40, width: 0.25, height: 0.03),
                                  matchedText: "Marisol Vance-Oduya", contextSnippet: "…Marisol Vance-Oduya signed…",
                                  source: .textLayer, term: "Marisol Vance-Oduya")
        for result in wrapped + [single] { state.appendResult(result) }
        state.flushPendingResults()
        return (state, wrapped, single)
    }

    /// No route leaves one line of an occurrence selected and the other not.
    private func expectWhole(_ state: SearchState, _ wrapped: [SearchResult], sourceLocation: SourceLocation = #_sourceLocation) {
        let states = wrapped.compactMap { piece in state.results.first { $0.id == piece.id }?.isSelected }
        #expect(states.count == 2 && Set(states).count == 1, "half an occurrence selected: \(states)", sourceLocation: sourceLocation)
    }

    @Test("Rows: one per occurrence; the canvas list keeps both lines")
    func oneRowPerOccurrence() {
        let (state, wrapped, single) = session()
        #expect(state.rowsByPage[0]?.map(\.id) == [wrapped[0].id])
        #expect(state.rowsByPage[1]?.map(\.id) == [single.id])
        #expect(state.resultsByTerm["Marisol Vance-Oduya"]?.count == 2)
        #expect(state.resultsByPage[0]?.count == 2, "both lines stay highlighted")
    }

    @Test("Counts read occurrences: 2 found, 0 of 2 selected, the walk at 1/2")
    func countsReadOccurrences() {
        let (state, wrapped, _) = session()
        #expect(state.totalCount == 2)
        #expect(state.filteredCount == 2)
        #expect(state.selectedFilteredCount == 0)
        state.currentResultIndex = state.results.firstIndex { $0.id == wrapped[0].id }
        #expect(state.currentOccurrenceIndex == 0)
        #expect(state.currentResultFilteredPosition == 1)
        // The second line, focused from the canvas, is the same occurrence.
        state.currentResultIndex = state.results.firstIndex { $0.id == wrapped[1].id }
        #expect(state.currentOccurrenceIndex == 0)
    }

    @Test("The row's tick selects and clears both lines; select all then untick the row leaves neither selected")
    func tickMovesTheWholeOccurrence() {
        let (state, wrapped, single) = session()
        state.toggleSelection(for: wrapped[0].id)
        expectWhole(state, wrapped)
        #expect(state.results.first { $0.id == wrapped[1].id }?.isSelected == true)
        #expect(state.selectedFilteredCount == 1)
        state.toggleSelection(for: wrapped[0].id)
        expectWhole(state, wrapped)
        #expect(state.results.first { $0.id == wrapped[1].id }?.isSelected == false)
        state.toggleSelectAll()
        expectWhole(state, wrapped)
        #expect(state.selectedFilteredCount == 2)
        state.toggleSelection(for: wrapped[0].id)
        expectWhole(state, wrapped)
        #expect(state.results.filter(\.isSelected).map(\.id) == [single.id])
        // A tick through the second line (the canvas focus) moves both too.
        state.toggleSelection(for: wrapped[1].id)
        expectWhole(state, wrapped)
        // A predicate that names one line decides for its whole occurrence by the lead line.
        state.setSelection { $0.id == wrapped[1].id }
        expectWhole(state, wrapped)
    }

    @Test("Apply boxes every line: three regions, Marked 2, Mark 2 Instances; one undo removes all three")
    func applyBoxesEveryLine() async {
        let (state, wrapped, _) = session()
        state.toggleSelectAll()
        let redaction = RedactionState()
        redaction.activeSearch = state
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let outcome = await redaction.applyFindings(.selectedSearchResults, undoManager: undo)
        undo.endUndoGrouping()
        let regionCount = redaction.regions.values.reduce(0) { $0 + $1.count }
        #expect(regionCount == 3, "a box on each line of the wrapped name, and the single")
        #expect(redaction.regions[0]?.count == 2)
        #expect(undo.undoActionName == "Mark 2 Instances")
        let counts = state.markedCounts(outcome)
        #expect(CommitFeedback.markedMessage(applied: counts.applied, alreadyCovered: counts.alreadyCovered)?
            .hasPrefix("Marked 2 for redaction") == true)
        #expect(outcome.map { Set(wrapped.map(\.id)).isSubset(of: $0.appliedResultIDs) } == true)
        undo.undo()
        #expect(redaction.regions.values.reduce(0) { $0 + $1.count } == 0)
    }

    @Test("The compact handle's per-item Apply on the row boxes both lines")
    func perItemApplyBoxesBothLines() async {
        let (state, wrapped, _) = session()
        let redaction = RedactionState()
        redaction.activeSearch = state
        let outcome = await redaction.applyFindings(.searchResult(id: wrapped[0].id), undoManager: nil)
        #expect(redaction.regions[0]?.count == 2)
        #expect(outcome?.appliedResultIDs == Set(wrapped.map(\.id)))
        let counts = state.markedCounts(outcome)
        #expect(counts.applied == 1)
    }

    @Test("Dismiss with the wrapped name unapplied counts it once: 2 unapplied matches")
    func unappliedCountsOccurrences() {
        let (state, wrapped, single) = session()
        #expect(SearchAndRedactSheet.unappliedMatchCount(in: state) == 2)
        state.appliedResultIDs = Set(wrapped.map(\.id))
        #expect(SearchAndRedactSheet.unappliedMatchCount(in: state) == 1)
        state.appliedResultIDs = [single.id]
        #expect(SearchAndRedactSheet.unappliedMatchCount(in: state) == 1)
    }

    @Test("The walk steps occurrence → single → occurrence, never onto the second line")
    func walkStepsByOccurrence() {
        let (state, wrapped, single) = session()
        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResult?.id == wrapped[0].id)
        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResult?.id == single.id)
        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResult?.id == wrapped[0].id)
        state.navigateToPrevious(currentPageIndex: 0)
        #expect(state.currentResult?.id == single.id)
        // From the second line (focused on the canvas), next is the single.
        state.currentResultIndex = state.results.firstIndex { $0.id == wrapped[1].id }
        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResult?.id == single.id)
    }

    @Test("A session with no wrapped match reads exactly as before: one row per result")
    func noOccurrencesUnchanged() {
        let state = SearchState(defaults: makeScratchDefaults().0)
        for index in 0..<3 {
            state.appendResult(SearchResult(
                pageIndex: index % 2, normalizedRect: CGRect(x: 0.1, y: 0.1 + 0.2 * CGFloat(index), width: 0.2, height: 0.03),
                matchedText: "123-45-6789", contextSnippet: "…", source: .textLayer, term: "SSN", piiCategory: .ssn))
        }
        state.flushPendingResults()
        #expect(state.totalCount == 3)
        #expect(state.rowsByPage.values.reduce(0) { $0 + $1.count } == 3)
        #expect(state.rowsByPage[0]?.count == state.resultsByPage[0]?.count)
    }
}
