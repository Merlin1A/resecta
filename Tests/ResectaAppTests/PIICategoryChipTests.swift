import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// WU-12 — Pre-scan, the PII category chip row inside `piiScanOptions`
// wraps in a `DisclosureGroup("Customize")` collapsed by default per
// [OQ-21] / [D-34] (Hybrid IA novice default; pros one tap away). Each
// chip label gains a count badge `"\(category.rawValue) (\(count))"`
// — pre-scan all counts read 0, post-scan they reflect
// `SearchState.categoryCounts`. Plan sub-agent (D-15) confirmed pre-scan
// chips remain inside `piiScanOptions`; post-scan filter chips stay in
// `chipRowSubstrate` per [RR-22] substrate invariants — substrate
// gating (`anyChipsToShow`) remains post-scan-only.

@Suite("PII category chip count badges + Customize disclosure (WU-12)", .tags(.search))
@MainActor
struct PIICategoryChipTests {

    @Test("categoryCounts populates per-category totals post-scan")
    func categoryCountsReflectResults() {
        let state = SearchState()
        state.searchModeType = .piiScan
        state.results = [
            makePIIResult(category: .ssn, page: 0),
            makePIIResult(category: .ssn, page: 1),
            makePIIResult(category: .ssn, page: 2),
            makePIIResult(category: .email, page: 0),
        ]

        #expect(state.categoryCounts[.ssn] == 3)
        #expect(state.categoryCounts[.email] == 1)
        #expect(state.categoryCounts[.phone] == nil)
    }

    @Test("hasPIIResults flips true when at least one PII result lands; drives auto-expand")
    func hasPIIResultsDrivesAutoExpand() {
        let state = SearchState()
        state.searchModeType = .piiScan
        #expect(state.hasPIIResults == false)

        state.results = [makePIIResult(category: .ssn, page: 0)]
        #expect(state.hasPIIResults == true)

        // Auto-expand contract: the SearchToolbarSection.onChange handler
        // sets customizeExpanded = newValue when hasPIIResults flips —
        // pinned at the gate level here; the @State flip itself is a
        // SwiftUI-host concern not exercised in this unit suite.
    }

    private func makePIIResult(category: PIICategory, page: Int) -> SearchResult {
        SearchResult(
            pageIndex: page,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05),
            matchedText: "fixture",
            contextSnippet: "…fixture…",
            source: .textLayer,
            term: "fixture",
            piiCategory: category,
            piiConfidence: 0.85
        )
    }
}
