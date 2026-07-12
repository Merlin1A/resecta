import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// W10 — SearchState.pendingOverlapSuppressed accumulation path.
// Unit-level tests for the accumulator + reset hooks; end-to-end
// collision behavior is covered by DetectionOrchestratorOverlapTests.

@Suite("SearchState overlap coverage (W10)", .tags(.search))
@MainActor
struct SearchStateOverlapCoverageTests {

    @Test("accumulateOverlapSuppression sums per-page counts")
    func accumulatesCountsAcrossPages() {
        let state = SearchState()
        state.accumulateOverlapSuppression([.phone: 1, .licensePlate: 2])
        state.accumulateOverlapSuppression([.phone: 3])
        #expect(state.pendingOverlapSuppressed[.phone] == 4)
        #expect(state.pendingOverlapSuppressed[.licensePlate] == 2)
    }

    @Test("resetOverlapSuppression clears the running tally")
    func resetClearsTally() {
        let state = SearchState()
        state.accumulateOverlapSuppression([.phone: 2])
        state.resetOverlapSuppression()
        #expect(state.pendingOverlapSuppressed.isEmpty)
    }

    @Test("clearResults() also resets the overlap tally")
    func clearResultsResetsTally() {
        let state = SearchState()
        state.accumulateOverlapSuppression([.phone: 5])
        state.clearResults()
        #expect(state.pendingOverlapSuppressed.isEmpty)
    }

    @Test("clear() also resets the overlap tally")
    func clearResetsTally() {
        let state = SearchState()
        state.accumulateOverlapSuppression([.licensePlate: 1])
        state.clear()
        #expect(state.pendingOverlapSuppressed.isEmpty)
    }
}
