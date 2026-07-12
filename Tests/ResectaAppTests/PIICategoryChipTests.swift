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

    @Test("Customize disclosure starts collapsed pre-scan per [OQ-21] / [D-34]")
    func customizeDisclosureCollapsedPreScan() {
        #expect(SearchToolbarSection.customizeDisclosureCollapsedPreScan == false)
    }

    @Test("Chip label format pins '<Category> (<count>)' per ACTION-WU-12")
    func chipLabelFormatPostScan() {
        #expect(SearchToolbarSection.pIICategoryChipLabel(for: .ssn, count: 12) == "SSN (12)")
        #expect(SearchToolbarSection.pIICategoryChipLabel(for: .email, count: 3) == "Email (3)")
        #expect(SearchToolbarSection.pIICategoryChipLabel(for: .phone, count: 7) == "Phone (7)")
    }

    @Test("Chip label format renders zero-count cleanly pre-scan")
    func chipLabelFormatPreScan() {
        // Pre-scan, every category reads 0 via the nil-coalesce path
        // `searchState.categoryCounts[category] ?? 0`.
        #expect(SearchToolbarSection.pIICategoryChipLabel(for: .ssn, count: 0) == "SSN (0)")
        #expect(SearchToolbarSection.pIICategoryChipLabel(for: .medicalRecord, count: 0) == "Medical Record (0)")
    }

    @Test("Chip a11y label surfaces toggle state + count for VoiceOver disambiguation")
    func chipAccessibilityLabelEnabledPlural() {
        let label = SearchToolbarSection.pIICategoryChipAccessibilityLabel(
            category: .ssn,
            isEnabled: true,
            count: 12
        )
        #expect(label == "SSN, enabled, 12 matches")
    }

    @Test("Chip a11y label uses singular 'match' when count is 1")
    func chipAccessibilityLabelSingular() {
        let label = SearchToolbarSection.pIICategoryChipAccessibilityLabel(
            category: .email,
            isEnabled: false,
            count: 1
        )
        #expect(label == "Email, disabled, 1 match")
    }

    @Test("Chip a11y label uses 'matches' for zero count (plural form)")
    func chipAccessibilityLabelZeroCount() {
        let label = SearchToolbarSection.pIICategoryChipAccessibilityLabel(
            category: .phone,
            isEnabled: true,
            count: 0
        )
        #expect(label == "Phone, enabled, 0 matches")
    }

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

        // The chip's nil-coalesce path renders '(0)' for absent
        // categories so the label stays stable across pre/post-scan.
        let phoneLabel = SearchToolbarSection.pIICategoryChipLabel(
            for: .phone,
            count: state.categoryCounts[.phone] ?? 0
        )
        #expect(phoneLabel == "Phone (0)")

        let ssnLabel = SearchToolbarSection.pIICategoryChipLabel(
            for: .ssn,
            count: state.categoryCounts[.ssn] ?? 0
        )
        #expect(ssnLabel == "SSN (3)")
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
