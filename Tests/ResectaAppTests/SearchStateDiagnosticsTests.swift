import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// W9 — SearchState session-scoped diagnostic fields.

@Suite("SearchState W9 diagnostics", .tags(.search))
@MainActor
struct SearchStateDiagnosticsTests {

    @Test("setDoctypeExplanation stores and clear() resets")
    func setAndClearDoctypeExplanation() {
        let state = SearchState()
        let explanation = DoctypeExplanation(
            primary: .medical,
            primaryProbability: 0.82,
            topProbabilities: [(.medical, 0.82), (.generic, 0.12), (.court, 0.03)],
            keywordContributors: [],
            structuralBonuses: []
        )
        state.setDoctypeExplanation(explanation)
        #expect(state.lastDoctypeExplanation?.primary == .medical)

        state.clear()
        #expect(state.lastDoctypeExplanation == nil)
    }

    @Test("setCoverageReport stores and clearResults() resets")
    func setAndClearCoverageReport() {
        let state = SearchState()
        let report = CoverageReport(
            scannedPageCount: 3,
            enabledCategories: [.ssn, .name],
            candidateCountByCategory: [.ssn: 1],
            appliedCount: 0,
            deselectedCount: 0,
            belowThresholdSuppressedCount: 0,
            overlapSuppressedCountByCategory: [:],
            startedAt: Date(),
            completedAt: Date()
        )
        state.setCoverageReport(report)
        #expect(state.lastCoverageReport?.scannedPageCount == 3)

        state.clearResults()
        #expect(state.lastCoverageReport == nil)
    }
}
