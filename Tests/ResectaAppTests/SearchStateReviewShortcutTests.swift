import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

@Suite("SearchState review shortcuts (W7)", .tags(.search))
@MainActor
struct SearchStateReviewShortcutTests {

    private func makeResult(page: Int = 0, term: String = "x") -> SearchResult {
        SearchResult(
            pageIndex: page,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.04),
            matchedText: term,
            contextSnippet: "…\(term)…",
            source: .textLayer,
            term: term
        )
    }

    @Test("toggleSelectionForCurrentMatch flips current isSelected")
    func toggleCurrent() {
        let state = SearchState()
        state.results = [makeResult(), makeResult(), makeResult()]
        state.currentResultIndex = 1

        state.toggleSelectionForCurrentMatch()
        #expect(state.results[1].isSelected == true)

        state.toggleSelectionForCurrentMatch()
        #expect(state.results[1].isSelected == false)
    }

    @Test("toggleSelectionForCurrentMatch with no current match is a no-op")
    func toggleNoCurrentNoOp() {
        let state = SearchState()
        state.results = [makeResult()]
        // currentResultIndex left nil

        state.toggleSelectionForCurrentMatch()
        #expect(state.results[0].isSelected == false)
    }

    @Test("Selection is per-result and deduplicated by id")
    func selectionUnique() {
        let state = SearchState()
        state.results = [makeResult(), makeResult(), makeResult()]
        state.currentResultIndex = 0
        state.toggleSelectionForCurrentMatch()
        state.currentResultIndex = 2
        state.toggleSelectionForCurrentMatch()
        // Re-toggle same one — should turn it off.
        state.toggleSelectionForCurrentMatch()

        #expect(state.results[0].isSelected == true)
        #expect(state.results[1].isSelected == false)
        #expect(state.results[2].isSelected == false)
        #expect(state.selectedCount == 1)
    }

    @Test("selectCurrentMatchIfNoneSelected returns true and selects current when empty")
    func selectsCurrentWhenEmpty() {
        let state = SearchState()
        state.results = [makeResult(), makeResult()]
        state.currentResultIndex = 1

        let didSelect = state.selectCurrentMatchIfNoneSelected()
        #expect(didSelect == true)
        #expect(state.results[1].isSelected == true)
        #expect(state.results[0].isSelected == false)
    }

    @Test("selectCurrentMatchIfNoneSelected leaves existing selection alone")
    func leavesExistingSelectionAlone() {
        let state = SearchState()
        state.results = [makeResult(), makeResult(), makeResult()]
        state.results[0].isSelected = true
        state.results[2].isSelected = true
        state.currentResultIndex = 1

        let didSelect = state.selectCurrentMatchIfNoneSelected()
        #expect(didSelect == true)
        // The current (index 1) should NOT have been toggled.
        #expect(state.results[1].isSelected == false)
        #expect(state.results[0].isSelected == true)
        #expect(state.results[2].isSelected == true)
    }

    @Test("selectCurrentMatchIfNoneSelected returns false when nothing to apply")
    func returnsFalseWhenNothingSelectable() {
        let state = SearchState()
        state.results = []
        let didSelect = state.selectCurrentMatchIfNoneSelected()
        #expect(didSelect == false)
    }
}
