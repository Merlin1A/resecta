import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// WU-17 — `SearchState.selectWhere(_:)` is the predicate-driven
// helper that powers the "Select where…" Menu in
// `SearchResultsSection`. Each Menu Section corresponds to one
// predicate kind: confidence threshold, source, category, applied
// state. The helper replaces (not toggles) `isSelected` on every
// result, so a predicate that matches a subset deselects the rest.
// `toggleSelectAll` is refactored on top of `selectWhere` while
// preserving its filtered-only contract (results outside the active
// filter retain their existing `isSelected`).
//
// Performance budget: predicate evaluation on 10k synthetic results
// stays under 100ms — the load-bearing test for the perf gate
// called out in ACTION-WU-17.

@Suite("SearchState selectWhere (WU-17)", .tags(.search))
@MainActor
struct SearchStateSelectionTests {

    // MARK: - selectWhere base contract

    @Test("selectWhere replaces isSelected with predicate value")
    func selectWhereReplaces() {
        let state = SearchState()
        let pre = makeResult(piiConfidence: 0.85, isSelected: true)
        let mid = makeResult(piiConfidence: 0.6, isSelected: true)
        let post = makeResult(piiConfidence: 0.95, isSelected: false)
        state.results = [pre, mid, post]

        state.selectWhere { ($0.piiConfidence ?? 0) >= 0.8 }

        #expect(state.results[0].isSelected == true)
        #expect(state.results[1].isSelected == false)
        #expect(state.results[2].isSelected == true)
    }

    @Test("selectWhere bumps resultVersion exactly once per call")
    func resultVersionBumps() {
        let state = SearchState()
        state.results = [makeResult(), makeResult(), makeResult()]
        let before = state.resultVersion

        state.selectWhere { _ in true }

        #expect(state.resultVersion == before + 1)
    }

    @Test("selectWhere on empty results no-ops cleanly")
    func emptyResultsNoOp() {
        let state = SearchState()
        state.results = []
        let before = state.resultVersion

        state.selectWhere { _ in true }

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

    // MARK: - Menu predicate kinds

    @Test("Predicate: by confidence threshold ≥ 75% selects only PII results above the floor")
    func predicateConfidence75() {
        let state = SearchState()
        let above = makeResult(piiConfidence: 0.80)
        let between = makeResult(piiConfidence: 0.74)
        let nilConf = makeResult()
        state.results = [above, between, nilConf]

        state.selectWhere { ($0.piiConfidence ?? 0) >= 0.75 }

        #expect(state.results.first(where: { $0.id == above.id })?.isSelected == true)
        #expect(state.results.first(where: { $0.id == between.id })?.isSelected == false)
        #expect(state.results.first(where: { $0.id == nilConf.id })?.isSelected == false)
    }

    @Test("Predicate: by confidence threshold ≥ 90% selects only the high-confidence subset")
    func predicateConfidence90() {
        let state = SearchState()
        let r80 = makeResult(piiConfidence: 0.80)
        let r92 = makeResult(piiConfidence: 0.92)
        state.results = [r80, r92]

        state.selectWhere { ($0.piiConfidence ?? 0) >= 0.90 }

        #expect(state.results.first(where: { $0.id == r80.id })?.isSelected == false)
        #expect(state.results.first(where: { $0.id == r92.id })?.isSelected == true)
    }

    @Test("Predicate: by source 'Text' selects only text-layer rows")
    func predicateSourceText() {
        let state = SearchState()
        let textHit = makeResult(source: .textLayer)
        let ocrHit = makeResult(source: .ocr(confidence: 0.7))
        state.results = [textHit, ocrHit]

        state.selectWhere { $0.source == .textLayer }

        #expect(state.results.first(where: { $0.id == textHit.id })?.isSelected == true)
        #expect(state.results.first(where: { $0.id == ocrHit.id })?.isSelected == false)
    }

    @Test("Predicate: by source 'OCR' selects only OCR rows")
    func predicateSourceOCR() {
        let state = SearchState()
        let textHit = makeResult(source: .textLayer)
        let ocrHit = makeResult(source: .ocr(confidence: 0.9))
        state.results = [textHit, ocrHit]

        state.selectWhere { $0.source != .textLayer }

        #expect(state.results.first(where: { $0.id == textHit.id })?.isSelected == false)
        #expect(state.results.first(where: { $0.id == ocrHit.id })?.isSelected == true)
    }

    @Test("Predicate: by category selects only matching PII rows (PII Scan mode)")
    func predicateCategory() {
        let state = SearchState()
        let ssn1 = makeResult(piiCategory: .ssn)
        let ssn2 = makeResult(piiCategory: .ssn)
        let dob = makeResult(piiCategory: .dateOfBirth)
        state.results = [ssn1, ssn2, dob]

        state.selectWhere { $0.piiCategory == .ssn }

        #expect(state.results.first(where: { $0.id == ssn1.id })?.isSelected == true)
        #expect(state.results.first(where: { $0.id == ssn2.id })?.isSelected == true)
        #expect(state.results.first(where: { $0.id == dob.id })?.isSelected == false)
    }

    @Test("Predicate: by applied state 'Applied' selects only rows in appliedResultIDs")
    func predicateAppliedState() {
        let state = SearchState()
        let a = makeResult()
        let b = makeResult()
        let c = makeResult()
        state.results = [a, b, c]
        state.appliedResultIDs = [a.id, c.id]

        let applied = state.appliedResultIDs
        state.selectWhere { applied.contains($0.id) }

        #expect(state.results.first(where: { $0.id == a.id })?.isSelected == true)
        #expect(state.results.first(where: { $0.id == b.id })?.isSelected == false)
        #expect(state.results.first(where: { $0.id == c.id })?.isSelected == true)
    }

    @Test("Predicate: by applied state 'Unapplied' selects the complement")
    func predicateUnappliedState() {
        let state = SearchState()
        let a = makeResult()
        let b = makeResult()
        state.results = [a, b]
        state.appliedResultIDs = [a.id]

        let applied = state.appliedResultIDs
        state.selectWhere { !applied.contains($0.id) }

        #expect(state.results.first(where: { $0.id == a.id })?.isSelected == false)
        #expect(state.results.first(where: { $0.id == b.id })?.isSelected == true)
    }

    // MARK: - Performance gate

    @Test("selectWhere stays under 100ms on 10k synthetic results")
    func performanceBudget10k() {
        let state = SearchState()
        let count = 10_000
        var results: [SearchResult] = []
        results.reserveCapacity(count)
        for i in 0..<count {
            results.append(
                makeResult(
                    piiConfidence: i.isMultiple(of: 2) ? 0.85 : 0.65,
                    isSelected: false
                )
            )
        }
        state.results = results

        let start = ContinuousClock.now
        state.selectWhere { ($0.piiConfidence ?? 0) >= 0.75 }
        let elapsed = start.duration(to: .now)
        let elapsedMs = Double(elapsed.components.seconds) * 1000.0
            + Double(elapsed.components.attoseconds) / 1e15

        // Half the synthetic set passes the predicate; assertion pins
        // the divide so a regression in the inner loop surfaces here.
        let selected = state.results.lazy.filter(\.isSelected).count
        #expect(selected == count / 2)

        // Performance gate from ACTION-WU-17 — predicate evaluation on
        // 10k results stays under 100ms.
        #expect(elapsedMs < 100.0, "selectWhere on 10k results took \(elapsedMs)ms; budget is 100ms")
    }

    // MARK: - §4.3 J/K Filter Respect

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

    @Test("filteredCount reflects minimumPIIConfidence threshold")
    func counterReflectsPIIConfidence() {
        let state = SearchState()
        let high = makeResult(piiCategory: .ssn, piiConfidence: 0.9)
        let low  = makeResult(piiCategory: .ssn, piiConfidence: 0.4)
        let mid  = makeResult(piiCategory: .ssn, piiConfidence: 0.7)
        state.results = [high, low, mid]
        state.minimumPIIConfidence = 0.65

        // Only high and mid pass the threshold.
        #expect(state.filteredCount == 2)
        #expect(state.totalCount == 3)

        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResultFilteredPosition == 1)
        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResultFilteredPosition == 2)
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
