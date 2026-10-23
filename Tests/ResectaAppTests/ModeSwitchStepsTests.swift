import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// The mode-switch steps run outside the sheet: the hub's handler builds
// the plan and the snapshot, then hands every input the steps touch to
// `SearchAndRedactSheet.applyModeSwitchSteps`. Driven here on a plain
// session, with no SwiftUI host.
@Suite("Mode-switch steps", .tags(.search))
@MainActor
struct ModeSwitchStepsTests {

    private func session() -> SearchState {
        let state = SearchState(defaults: makeScratchDefaults().0)
        state.results = [SearchResult(
            pageIndex: 0, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03),
            matchedText: "alpha", contextSnippet: "…alpha…", source: .textLayer, term: "alpha", isSelected: true)]
        state.piiCategoryFilter = [.ssn]
        state.sortOrder = .pageAscending
        return state
    }

    @Test("Clearing the results and resetting the filters empties the list and restores the defaults, with no toast and no preview")
    func clearAndResetFilters() {
        let state = session()
        let toasts = ToastQueueManager()
        let snapshot = SearchAndRedactSheet.modeSwitchSnapshot(of: state, previousMode: .text)
        var previews = 0

        SearchAndRedactSheet.applyModeSwitchSteps(
            SearchAndRedactSheet.ModeSwitchPlan(previousMode: .text, steps: [.clearResults, .resetFilters]),
            to: state,
            toastManager: toasts,
            redactionState: RedactionState(),
            snapshot: snapshot,
            isProgrammatic: false,
            unappliedCount: 1,
            scheduleLivePreview: { previews += 1 }
        )

        #expect(state.results.isEmpty)
        #expect(state.piiCategoryFilter == nil)
        #expect(state.sortOrder == .discoveryOrder)
        #expect(toasts.activeToasts.isEmpty, "no step asked for the undo toast")
        #expect(previews == 0)
    }

    @Test("Resetting the filters alone keeps the results")
    func resetFiltersKeepsResults() {
        let state = session()
        SearchAndRedactSheet.applyModeSwitchSteps(
            SearchAndRedactSheet.ModeSwitchPlan(previousMode: .text, steps: [.resetFilters]),
            to: state,
            toastManager: ToastQueueManager(),
            redactionState: RedactionState(),
            snapshot: SearchAndRedactSheet.modeSwitchSnapshot(of: state, previousMode: .text),
            isProgrammatic: false,
            unappliedCount: 1,
            scheduleLivePreview: {}
        )
        #expect(state.results.count == 1)
        #expect(state.piiCategoryFilter == nil)
        #expect(state.sortOrder == .discoveryOrder)
    }
}
