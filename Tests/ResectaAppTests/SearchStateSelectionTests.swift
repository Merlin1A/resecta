import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// `SearchState`'s predicate-driven selection primitive.
// `setSelection(where:)` is the REPLACE primitive
// (`isSelected := predicate(result)`); `toggleSelectAll` composes with
// it for its filtered-only select/deselect-all contract. The
// "Add to selection…" footer menu and its additive
// `addToSelection(where:)` sibling retired together with
// their predicate pins and the 10k perf gate that rode on them.

@Suite("SearchState selection primitives (select-where retired)", .tags(.search))
@MainActor
struct SearchStateSelectionTests {

    // MARK: - setSelection(where:) base contract (replace primitive)

    @Test("setSelection(where:) replaces isSelected with predicate value")
    func setSelectionReplaces() {
        let state = SearchState()
        let pre = makeResult(piiConfidence: 0.85, isSelected: true)
        let mid = makeResult(piiConfidence: 0.6, isSelected: true)
        let post = makeResult(piiConfidence: 0.95, isSelected: false)
        state.results = [pre, mid, post]

        state.setSelection { ($0.piiConfidence ?? 0) >= 0.8 }

        #expect(state.results[0].isSelected == true)
        #expect(state.results[1].isSelected == false)
        #expect(state.results[2].isSelected == true)
    }

    @Test("setSelection(where:) bumps resultVersion exactly once per call")
    func setSelectionResultVersionBumps() {
        let state = SearchState()
        state.results = [makeResult(), makeResult(), makeResult()]
        let before = state.resultVersion

        state.setSelection { _ in true }

        #expect(state.resultVersion == before + 1)
    }

    @Test("setSelection(where:) on empty results no-ops cleanly")
    func setSelectionEmptyResultsNoOp() {
        let state = SearchState()
        state.results = []
        let before = state.resultVersion

        state.setSelection { _ in true }

        // Empty array → for-in loop does no iterations → no per-result
        // mutations. The single resultVersion bump is the contract; UI
        // observers re-derive on the bump but the array itself is
        // unchanged.
        #expect(state.results.isEmpty)
        #expect(state.resultVersion == before + 1)
    }

    // MARK: - toggleSelectAll preserves prior filtered-only behavior

    @Test("toggleSelectAll selects all when some filtered are deselected")
    func toggleSelectAllSelectsWhenMixed() {
        let state = SearchState()
        state.results = [
            makeResult(isSelected: true),
            makeResult(isSelected: false),
            makeResult(isSelected: true)
        ]

        state.toggleSelectAll()

        let allSelected = state.results.allSatisfy { $0.isSelected }
        #expect(allSelected)
    }

    @Test("toggleSelectAll deselects all when all filtered are selected")
    func toggleSelectAllDeselectsWhenAll() {
        let state = SearchState()
        state.results = [
            makeResult(isSelected: true),
            makeResult(isSelected: true)
        ]

        state.toggleSelectAll()

        let noneSelected = state.results.allSatisfy { !$0.isSelected }
        #expect(noneSelected)
    }

    @Test("toggleSelectAll respects filteredResults — outside-filter rows retain isSelected")
    func toggleSelectAllPreservesUnfiltered() {
        let state = SearchState()
        let textHit = makeResult(source: .textLayer, isSelected: true)
        let ocrHit = makeResult(source: .ocr(confidence: 0.8), isSelected: false)
        state.results = [textHit, ocrHit]
        state.sourceFilter = .textOnly

        // filtered = [textHit]; allSelected = true → deselect filtered.
        // ocrHit is outside the filter; should retain isSelected = false.
        state.toggleSelectAll()

        #expect(state.results.first(where: { $0.id == textHit.id })?.isSelected == false)
        #expect(state.results.first(where: { $0.id == ocrHit.id })?.isSelected == false)

        // Now ocrHit was already deselected; bring it back to true and
        // toggle again — filtered is fully deselected so the toggle
        // selects filtered, ocrHit's true preserves.
        state.results[1].isSelected = true
        state.toggleSelectAll()
        #expect(state.results.first(where: { $0.id == textHit.id })?.isSelected == true)
        #expect(state.results.first(where: { $0.id == ocrHit.id })?.isSelected == true)
    }

    // MARK: - J/K Filter Respect

    @Test("J/K navigation skips OCR results when sourceFilter is .textOnly")
    func jkNavigationRespectsSourceFilter() {
        let state = SearchState()
        let textA = makeResult(source: .textLayer)
        let ocrA  = makeResult(source: .ocr(confidence: 0.9))
        let textB = makeResult(source: .textLayer)
        let ocrB  = makeResult(source: .ocr(confidence: 0.85))
        state.results = [textA, ocrA, textB, ocrB]
        state.sourceFilter = .textOnly

        // With filter active, filteredResults = [textA, textB].
        // J forward from nothing → textA.
        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResult?.id == textA.id)

        // J again → textB (skips ocrA entirely).
        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResult?.id == textB.id)

        // J wraps back → textA (skips ocrB).
        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResult?.id == textA.id)

        // K backwards from textA → textB (wraps, skips ocrB, ocrA).
        state.navigateToPrevious(currentPageIndex: 0)
        #expect(state.currentResult?.id == textB.id)
    }

    @Test("filteredCount reflects source filter and currentResultFilteredPosition tracks position")
    func counterShowsFilteredCount() {
        let state = SearchState()
        let textA = makeResult(source: .textLayer)
        let ocrA  = makeResult(source: .ocr(confidence: 0.9))
        let textB = makeResult(source: .textLayer)
        state.results = [textA, ocrA, textB]
        state.sourceFilter = .textOnly

        // filteredCount < totalCount when filter is active.
        #expect(state.filteredCount == 2)
        #expect(state.totalCount == 3)

        // Navigate to the first text result; filtered position = 1.
        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResult?.id == textA.id)
        #expect(state.currentResultFilteredPosition == 1)

        // Navigate to the second text result; filtered position = 2.
        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResult?.id == textB.id)
        #expect(state.currentResultFilteredPosition == 2)
    }

    @Test("currentResultFilteredPosition is nil when current result is hidden by filter")
    func currentResultHiddenByFilter() {
        let state = SearchState()
        let ocrA  = makeResult(source: .ocr(confidence: 0.9))
        let textA = makeResult(source: .textLayer)
        let textB = makeResult(source: .textLayer)
        state.results = [ocrA, textA, textB]

        // Land on the OCR result while no filter is active.
        state.currentResultIndex = 0
        #expect(state.currentResult?.id == ocrA.id)
        #expect(state.currentResultFilteredPosition == 1)

        // Apply filter that hides OCR results.
        state.sourceFilter = .textOnly

        // currentResult is now hidden — position should be nil.
        #expect(state.currentResultFilteredPosition == nil)

        // J/K from a hidden position lands on the first filtered result.
        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResult?.id == textA.id)
        #expect(state.currentResultFilteredPosition == 1)
    }

    @Test("minimumPIIConfidence no longer hides results from the counter or J/K traversal")
    func counterIgnoresRetiredPIIConfidenceThreshold() {
        // The per-run confidence slider is retired (Settings' Detection
        // Sensitivity preset is the one engine-level control), so its
        // former client-side post-filter must not hide results — every
        // above-threshold result the engine returns is listed and
        // traversable. The property survives for saved-search schema
        // compat only.
        let state = SearchState()
        let high = makeResult(piiCategory: .ssn, piiConfidence: 0.9)
        let low  = makeResult(piiCategory: .ssn, piiConfidence: 0.4)
        let mid  = makeResult(piiCategory: .ssn, piiConfidence: 0.7)
        state.results = [high, low, mid]
        state.minimumPIIConfidence = 0.65

        #expect(state.filteredCount == 3)
        #expect(state.totalCount == 3)

        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResultFilteredPosition == 1)
        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResultFilteredPosition == 2)
        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResultFilteredPosition == 3)
    }

    @Test("filteredCount reflects piiCategoryFilter restriction")
    func counterReflectsPIICategoryFilter() {
        let state = SearchState()
        let ssnR = makeResult(piiCategory: .ssn, piiConfidence: 0.9)
        let dobR = makeResult(piiCategory: .dateOfBirth, piiConfidence: 0.85)
        let ssn2 = makeResult(piiCategory: .ssn, piiConfidence: 0.8)
        state.results = [ssnR, dobR, ssn2]
        state.piiCategoryFilter = [.ssn]

        // Only SSN results pass.
        #expect(state.filteredCount == 2)
        #expect(state.totalCount == 3)

        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResult?.id == ssnR.id)
        #expect(state.currentResultFilteredPosition == 1)

        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResult?.id == ssn2.id)
        #expect(state.currentResultFilteredPosition == 2)
    }

    @Test("J/K with .currentPage scope respects active filter on the page")
    func jkCurrentPageScopeRespectsFilter() {
        let state = SearchState()
        let textP0 = makePagedResult(source: .textLayer, page: 0)
        let ocrP0  = makePagedResult(source: .ocr(confidence: 0.9), page: 0)
        let textP1 = makePagedResult(source: .textLayer, page: 1)
        state.results = [textP0, ocrP0, textP1]
        state.sourceFilter = .textOnly
        state.navigationScope = .currentPage

        // On page 0, only textP0 is visible after filter.
        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResult?.id == textP0.id)

        // Wraps within page 0's filtered set (only 1 result).
        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResult?.id == textP0.id)

        // On page 1, only textP1 is visible.
        state.navigateToNext(currentPageIndex: 1)
        #expect(state.currentResult?.id == textP1.id)
    }

    // MARK: - result(for:) O(1) lookup

    @Test("result(for:) returns the live value by id and nil for absent ids")
    func resultForIDLookup() {
        let state = SearchState()
        let a = makeResult(isSelected: false)
        let b = makeResult(piiConfidence: 0.9, isSelected: true)
        let c = makeResult()
        state.results = [a, b, c]

        #expect(state.result(for: b.id)?.id == b.id)
        #expect(state.result(for: b.id)?.isSelected == true)
        #expect(state.result(for: c.id)?.id == c.id)
        #expect(state.result(for: UUID()) == nil)

        // In-place mutation through the public set-side contract stays
        // visible through the lookup (the map holds indices, not
        // snapshots; `toggleSelection` bumps `resultVersion`).
        state.toggleSelection(for: a.id)
        #expect(state.result(for: a.id)?.isSelected == true)
    }

    @Test("result(for:) stays exact under direct results replacement (rescue path)")
    func resultForIDRescueOnDirectReplacement() {
        let state = SearchState()
        let old = makeResult()
        state.results = [old]
        // Warm the map at the current version.
        #expect(state.result(for: old.id)?.id == old.id)

        // Replace the array WITHOUT a version bump (the direct-assignment
        // seam the linear rescue exists for): lookups must reflect the
        // new array exactly — new ids found (map-miss rescue), removed
        // ids nil (stale-index id-mismatch rescue).
        let fresh = makeResult(piiCategory: .ssn, piiConfidence: 0.95)
        state.results = [fresh]
        #expect(state.result(for: fresh.id)?.id == fresh.id)
        #expect(state.result(for: old.id) == nil)
    }

    // MARK: - Helpers

    private func makeResult(
        source: SearchSource = .textLayer,
        piiCategory: PIICategory? = nil,
        piiConfidence: Double? = nil,
        isSelected: Bool = false
    ) -> SearchResult {
        SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
            matchedText: "x",
            contextSnippet: "...",
            source: source,
            term: "x",
            isSelected: isSelected,
            piiCategory: piiCategory,
            piiConfidence: piiConfidence
        )
    }

    private func makePagedResult(
        source: SearchSource = .textLayer,
        page: Int
    ) -> SearchResult {
        SearchResult(
            pageIndex: page,
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
            matchedText: "x",
            contextSnippet: "...",
            source: source,
            term: "x",
            isSelected: false,
            piiCategory: nil,
            piiConfidence: nil
        )
    }
}
