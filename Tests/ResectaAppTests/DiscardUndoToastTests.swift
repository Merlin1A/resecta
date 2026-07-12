import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// Dismissal helpers for the search sheet's one-tap Dismiss. Formerly
// the WU-19 two-tap discard-via-undo-toast flow: the undo toast and
// its `enqueueDiscardUndoToast` / `restoreSelection` helpers are gone —
// Dismiss now deselects in-place and closes in the same tap. Still
// pinned here: the selection snapshot/clear helpers the Dismiss
// handler runs, the shared Undo action label the mode-switch toast
// reuses, and the UXF-27 dismissal message.

@Suite("Search dismiss selection helpers")
@MainActor
struct DiscardUndoToastTests {

    // MARK: - Static contracts

    @Test("Undo action label pins the SAFE-classified copy")
    func undoActionLabel() {
        #expect(SearchAndRedactSheet.discardUndoActionLabel == "Undo")
    }

    // MARK: - Snapshot

    @Test("currentSelectionSnapshot returns IDs of selected results only")
    func snapshotCapturesSelectedOnly() {
        let state = SearchState()
        let r1 = makeResult()
        let r2 = makeResult()
        let r3 = makeResult()
        state.results = [r1, r2, r3]
        // Mark r1 + r3 selected.
        state.results[0].isSelected = true
        state.results[2].isSelected = true

        let snapshot = SearchAndRedactSheet.currentSelectionSnapshot(in: state)

        #expect(snapshot == [r1.id, r3.id])
    }

    @Test("currentSelectionSnapshot is empty when no results are selected")
    func snapshotEmptyWhenNothingSelected() {
        let state = SearchState()
        state.results = [makeResult(), makeResult()]
        let snapshot = SearchAndRedactSheet.currentSelectionSnapshot(in: state)
        #expect(snapshot.isEmpty)
    }

    // MARK: - clearSelection

    @Test("clearSelection deselects matching IDs in-place")
    func clearSelectionDeselectsMatchingIDs() {
        let state = SearchState()
        let r1 = makeResult()
        let r2 = makeResult()
        let r3 = makeResult()
        state.results = [r1, r2, r3]
        state.results[0].isSelected = true
        state.results[1].isSelected = true
        state.results[2].isSelected = true

        SearchAndRedactSheet.clearSelection(in: state, snapshot: [r1.id, r3.id])

        #expect(state.results[0].isSelected == false)
        #expect(state.results[1].isSelected == true)  // not in snapshot — untouched
        #expect(state.results[2].isSelected == false)
    }

    // MARK: - Dismissal copy (UXF-27)

    @Test("dismissClearedMessage names the unapplied loss at the dismiss decision point")
    func dismissMessageNamesUnappliedLoss() {
        #expect(SearchAndRedactSheet.dismissClearedMessage(unappliedCount: 27)
                == "Search closed — 27 unapplied matches cleared.")
        #expect(SearchAndRedactSheet.dismissClearedMessage(unappliedCount: 1)
                == "Search closed — 1 unapplied match cleared.")
    }

    @Test("dismissClearedMessage is nil when nothing unapplied is lost")
    func dismissMessageNilWhenNothingLost() {
        #expect(SearchAndRedactSheet.dismissClearedMessage(unappliedCount: 0) == nil)
    }

    // MARK: - Fixtures

    private func makeResult() -> SearchResult {
        SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05),
            matchedText: "x",
            contextSnippet: "…x…",
            source: .textLayer,
            term: "x"
        )
    }
}
