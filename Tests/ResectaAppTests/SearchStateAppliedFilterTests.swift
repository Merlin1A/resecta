import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// WU-18 — Applied-only / unapplied-only filter chip. `SearchState`
// gains a new post-scan filter that hides applied or unapplied results
// from `filteredResults`. Field participates in `_FilterCacheKey` per
// RR-01; resets to `.all` in both clear paths
// per D-28 / RR-26.
// Symmetric clear-paths assertions are pinned by
// `SearchStateClearTests`; this suite covers correctness, default,
// cache-invalidation wiring, Codable shape, and the chip a11y label.

@Suite("SearchState applied filter (WU-18)", .tags(.search))
@MainActor
struct SearchStateAppliedFilterTests {

    @Test("appliedFilter defaults to .all on a fresh SearchState")
    func defaultIsAll() {
        let state = SearchState()
        #expect(state.appliedFilter == .all)
    }

    @Test("appliedFilter == .all is a no-op — every result passes")
    func allKeepsEverything() {
        let state = SearchState()
        let a = makeResult()
        let b = makeResult()
        let c = makeResult()
        state.results = [a, b, c]
        state.appliedResultIDs = [a.id]

        state.appliedFilter = .all

        #expect(state.filteredResults.count == 3)
    }

    @Test("appliedFilter == .applied keeps only results in appliedResultIDs")
    func appliedKeepsOnlyApplied() {
        let state = SearchState()
        let a = makeResult()
        let b = makeResult()
        let c = makeResult()
        state.results = [a, b, c]
        state.appliedResultIDs = [a.id, c.id]

        state.appliedFilter = .applied

        let kept = state.filteredResults.map(\.id)
        #expect(kept.count == 2)
        #expect(Set(kept) == Set([a.id, c.id]))
    }

    @Test("appliedFilter == .unapplied keeps only results NOT in appliedResultIDs")
    func unappliedKeepsComplement() {
        let state = SearchState()
        let a = makeResult()
        let b = makeResult()
        let c = makeResult()
        state.results = [a, b, c]
        state.appliedResultIDs = [a.id, c.id]

        state.appliedFilter = .unapplied

        let kept = state.filteredResults.map(\.id)
        #expect(kept == [b.id])
    }

    @Test("appliedFilter == .applied with empty appliedResultIDs returns nothing")
    func appliedWithEmptyAppliedReturnsNothing() {
        let state = SearchState()
        state.results = [makeResult(), makeResult()]
        state.appliedResultIDs = []

        state.appliedFilter = .applied

        #expect(state.filteredResults.isEmpty)
    }

    @Test("appliedFilter == .unapplied with empty appliedResultIDs returns everything")
    func unappliedWithEmptyAppliedReturnsAll() {
        let state = SearchState()
        let r1 = makeResult()
        let r2 = makeResult()
        state.results = [r1, r2]
        state.appliedResultIDs = []

        state.appliedFilter = .unapplied

        #expect(state.filteredResults.count == 2)
    }

    @Test("appliedFilter changes invalidate the filter cache")
    func toggleInvalidatesCache() {
        let state = SearchState()
        let a = makeResult()
        let b = makeResult()
        state.results = [a, b]
        state.appliedResultIDs = [a.id]

        // Prime the cache with the default `.all` view, then flip the
        // filter — the cache key participation gate is whether the
        // post-flip read returns the new shape rather than the cached
        // `.all` shape.
        let primed = state.filteredResults
        #expect(primed.count == 2)

        state.appliedFilter = .applied

        let postFlip = state.filteredResults
        #expect(postFlip.count == 1)
        #expect(postFlip.first?.id == a.id)
    }

    @Test("AppliedFilter Codable round-trips every case via rawValue")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for state in AppliedFilter.allCases {
            let data = try encoder.encode(state)
            let decoded = try decoder.decode(AppliedFilter.self, from: data)
            #expect(decoded == state)
        }
    }

    @Test("AppliedFilter rawValues stay locked — case renames are migration events per RR-05")
    func rawValuesAreContractStrings() {
        // Pinning prevents accidental rename — `SavedSearchStore`
        // (post-WU-26) decodes against these strings.
        #expect(AppliedFilter.all.rawValue == "All")
        #expect(AppliedFilter.applied.rawValue == "Applied")
        #expect(AppliedFilter.unapplied.rawValue == "Unapplied")
    }

    @Test("Applied filter chip accessibility label surfaces the active state")
    func chipAccessibilityLabel() {
        #expect(
            SearchToolbarSection.appliedFilterChipAccessibilityLabel(active: .all)
                == "Applied state filter, currently All"
        )
        #expect(
            SearchToolbarSection.appliedFilterChipAccessibilityLabel(active: .applied)
                == "Applied state filter, currently Applied"
        )
        #expect(
            SearchToolbarSection.appliedFilterChipAccessibilityLabel(active: .unapplied)
                == "Applied state filter, currently Unapplied"
        )
    }

    @Test("UP-8 — applied-state chip shows only post-apply or with a non-default filter active")
    func chipVisibilityGate() {
        // Pre-apply, default filter: hidden (the chip would filter a set
        // with no applied members — every option shows the same list).
        #expect(SearchToolbarSection.appliedFilterChipShouldShow(
            hasAppliedResults: false, activeFilter: .all) == false)

        // Something applied: show, whatever the filter.
        #expect(SearchToolbarSection.appliedFilterChipShouldShow(
            hasAppliedResults: true, activeFilter: .all) == true)
        #expect(SearchToolbarSection.appliedFilterChipShouldShow(
            hasAppliedResults: true, activeFilter: .applied) == true)

        // Non-default filter with nothing applied (e.g. undo emptied
        // appliedResultIDs while .applied was active): the chip must
        // stay visible so the active filter never strands invisibly.
        #expect(SearchToolbarSection.appliedFilterChipShouldShow(
            hasAppliedResults: false, activeFilter: .applied) == true)
        #expect(SearchToolbarSection.appliedFilterChipShouldShow(
            hasAppliedResults: false, activeFilter: .unapplied) == true)
    }

    @Test("appliedFilter composes with PII category filter — both gates apply")
    func composesWithCategoryFilter() {
        let state = SearchState()
        let appliedSSN = makeResult(piiCategory: .ssn)
        let unappliedSSN = makeResult(piiCategory: .ssn)
        let appliedDOB = makeResult(piiCategory: .dateOfBirth)

        state.results = [appliedSSN, unappliedSSN, appliedDOB]
        state.appliedResultIDs = [appliedSSN.id, appliedDOB.id]
        state.piiCategoryFilter = [.ssn]
        state.appliedFilter = .applied

        let kept = state.filteredResults.map(\.id)
        #expect(kept == [appliedSSN.id])
    }

    // MARK: - §4.3 Navigation with appliedFilter active

    @Test("J/K navigation skips unapplied results when appliedFilter is .applied")
    func jkSkipsUnappliedWhenAppliedFilterActive() {
        let state = SearchState()
        let applied1 = makeResult()
        let unapplied = makeResult()
        let applied2 = makeResult()
        state.results = [applied1, unapplied, applied2]
        state.appliedResultIDs = [applied1.id, applied2.id]
        state.appliedFilter = .applied

        // filteredResults = [applied1, applied2] only.
        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResult?.id == applied1.id)
        #expect(state.currentResultFilteredPosition == 1)

        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResult?.id == applied2.id)
        #expect(state.currentResultFilteredPosition == 2)

        // Wraps back to applied1, skipping unapplied.
        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResult?.id == applied1.id)
    }

    @Test("currentResultFilteredPosition is nil when appliedFilter hides the current result")
    func filteredPositionNilWhenAppliedFilterHidesCurrent() {
        let state = SearchState()
        let unapplied = makeResult()
        let applied1  = makeResult()
        state.results = [unapplied, applied1]
        state.appliedResultIDs = [applied1.id]

        // Navigate to unapplied result while filter is .all.
        state.currentResultIndex = 0
        #expect(state.currentResultFilteredPosition == 1)

        // Activate the .applied filter — current result is now hidden.
        state.appliedFilter = .applied
        #expect(state.currentResultFilteredPosition == nil)
    }

    // MARK: - Helpers

    private func makeResult(
        piiCategory: PIICategory? = nil
    ) -> SearchResult {
        SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
            matchedText: "x",
            contextSnippet: "…",
            source: .textLayer,
            term: "x",
            isSelected: false,
            piiCategory: piiCategory,
            piiConfidence: piiCategory == nil ? nil : 0.8
        )
    }
}
