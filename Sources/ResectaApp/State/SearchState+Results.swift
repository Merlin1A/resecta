import Foundation
import RedactionEngine

extension SearchState {
    // MARK: - Results

    /// All results after source/confidence/category filters applied.
    /// Memoized on the filter shape; recomputed on a resultVersion
    /// change or a filter change (P3).
    var filteredResults: [SearchResult] {
        memo(\.filtered) { applyFilters(to: results) }
    }

    /// Results grouped by page, with source/confidence filters applied.
    /// Memoized on the filter shape (P3).
    var resultsByPage: [Int: [SearchResult]] {
        memo(\.byPage) { Dictionary(grouping: filteredResults, by: \.pageIndex) }
    }

    /// U3: Result rows grouped by search term (one per match), filters applied.
    var resultsByTerm: [String: [SearchResult]] {
        memo(\.byTerm) { Dictionary(grouping: Self.occurrenceRows(filteredResults), by: \.term) }
    }

    /// Filtered match count (respects the filters; a wrapped match counts once).
    var filteredCount: Int { Self.occurrenceCount(filteredResults) }

    /// Matches a filter hides, ticked or not, for the statement's hidden
    /// count (`SearchStatement`). A wrapped match counts once.
    var hiddenByFilterCount: Int { max(0, totalCount - filteredCount) }

    /// 1-based position of `currentResult` within `filteredResults`.
    /// Returns nil when there is no current result or when the current
    /// result is not present in `filteredResults` (i.e. it is hidden by
    /// the active filter). Used by the counter in `SearchAndRedactSheet`
    /// to display the position within the visible filtered set.
    var currentResultFilteredPosition: Int? {
        guard let current = currentResult else { return nil }
        return Self.occurrenceRows(filteredResults).firstIndex { Self.occurrenceKey($0) == Self.occurrenceKey(current) }.map { $0 + 1 }
    }

    /// Count of selected results within the currently filtered set.
    var selectedFilteredCount: Int {
        Self.occurrenceCount(filteredResults.filter(\.isSelected))
    }

    /// Whether any OCR results exist (controls filter UI visibility).
    var hasOCRResults: Bool {
        results.contains { if case .ocr = $0.source { return true }; return false }
    }

    /// Results grouped by PII category, with filters applied.
    var resultsByCategory: [PIICategory: [SearchResult]] {
        memo(\.byCategory) {
            let piiOnly = filteredResults.filter { $0.piiCategory != nil }
            return Dictionary(grouping: piiOnly, by: { $0.piiCategory! })
        }
    }

    /// Counts of results per PII category (for badge display).
    var categoryCounts: [PIICategory: Int] {
        resultsByCategory.mapValues(\.count)
    }

    /// Custom-term matches in the session: results with no detector
    /// category (the "Custom" chip's count).
    var customTermMatchCount: Int {
        results.lazy.filter { $0.piiCategory == nil }.count
    }

    /// Whether any PII results exist (controls PII filter UI visibility).
    var hasPIIResults: Bool {
        results.contains { $0.piiCategory != nil }
    }

    /// One slot read: a hit on `key` returns the stored value; a miss
    /// builds, stores and returns it. The build runs BETWEEN the read
    /// and the write of `_filterCache` — never inside an access to it —
    /// because a grouping build reads `filteredResults`, itself a slot.
    private func memo<Key: Equatable, Value>(
        _ slot: WritableKeyPath<FilterCache, FilterCache.Slot<Key, Value>>,
        key: Key,
        _ build: () -> Value
    ) -> Value {
        if let hit = _filterCache[keyPath: slot].value(for: key) { return hit }
        let built = build()
        _filterCache[keyPath: slot].store(built, for: key)
        return built
    }

    /// The filter-shape slots, keyed on `_currentCacheKey`.
    private func memo<Value>(
        _ slot: WritableKeyPath<FilterCache, FilterCache.Slot<_FilterCacheKey, Value>>,
        _ build: () -> Value
    ) -> Value {
        memo(slot, key: _currentCacheKey, build)
    }

    /// Live result lookup by ID — O(1) through the version-keyed index
    /// map. The id re-check plus the linear rescue keep the lookup
    /// exactly equivalent to the scan it replaces even against a direct
    /// `results` assignment that skipped the version bump (test seams
    /// do this); a genuinely absent id still returns nil. Reads the
    /// same observed inputs as the former scan (`results`,
    /// `resultVersion`).
    func result(for id: UUID) -> SearchResult? {
        let index = memo(\.indexByID, key: resultVersion) {
            var map = [UUID: Int](minimumCapacity: results.count)
            for (position, result) in results.enumerated() {
                map[result.id] = position
            }
            return map
        }
        if let position = index[id], position < results.count,
           results[position].id == id {
            return results[position]
        }
        return results.first(where: { $0.id == id })
    }

    private var _currentCacheKey: _FilterCacheKey {
        _FilterCacheKey(
            version: resultVersion,
            source: sourceFilter,
            minOCRConfidence: minimumOCRConfidence,
            piiCategoryFilter: piiCategoryFilter,
            customTermMatchesInFilter: customTermMatchesInFilter,
            sortOrder: sortOrder,
            appliedResultIDs: appliedResultIDs,
            appliedFilter: appliedFilter
        )
    }

    private func applyFilters(to results: [SearchResult]) -> [SearchResult] {
        var filtered = results.filter { result in
            // Source filter
            switch sourceFilter {
            case .all: break
            case .textOnly:
                guard result.source == .textLayer else { return false }
            case .ocrOnly:
                guard result.source != .textLayer else { return false }
            }
            // OCR confidence filter
            if minimumOCRConfidence > 0, case .ocr(let conf) = result.source {
                guard conf >= minimumOCRConfidence else { return false }
            }
            // PII category filter
            if let categoryFilter = piiCategoryFilter {
                if let cat = result.piiCategory {
                    guard categoryFilter.contains(cat) else { return false }
                } else {
                    guard customTermMatchesInFilter else { return false }
                }
            }
            // The PII confidence post-filter is retired with the
            // per-run Confidence slider — every above-threshold result
            // the engine returns is listed; the confidence sort is the
            // one review-side confidence tool (the Select where… ≥75/≥90
            // predicates are retired too).
            // Applied-state filter. `.all` no-ops; `.applied`
            // keeps only results whose IDs are in `appliedResultIDs`;
            // `.unapplied` keeps the complement.
            switch appliedFilter {
            case .all:
                break
            case .applied:
                guard appliedResultIDs.contains(result.id) else { return false }
            case .unapplied:
                guard !appliedResultIDs.contains(result.id) else { return false }
            }
            return true
        }

        // Apply sort order
        switch sortOrder {
        case .discoveryOrder:
            break // Already in discovery order
        case .confidenceDescending:
            filtered.sort { ($0.piiConfidence ?? 0) > ($1.piiConfidence ?? 0) }
        case .pageAscending:
            filtered.sort { $0.pageIndex < $1.pageIndex }
        }

        return filtered
    }

    /// Total selected count (matches: a wrapped match counts once).
    var selectedCount: Int {
        Self.occurrenceCount(results.filter(\.isSelected))
    }

    /// True when the selection is non-empty and every selected result
    /// already carries an applied marker. The toolbar Apply disables on
    /// it — re-applying an all-applied selection can only no-op through
    /// the overlap guard ("Marked 0 … already covered").
    var selectionFullyApplied: Bool {
        let selected = results.filter(\.isSelected)
        guard !selected.isEmpty else { return false }
        return selected.allSatisfy { isAppliedOrCovered($0.id) }
    }

    /// The one Apply-graying predicate for a single result: the apply
    /// path has nothing left to do for it — it produced a region
    /// (`appliedResultIDs`) or was dedup-skipped as already covered
    /// (`coveredResultIDs`; a covered result counts as
    /// applied for graying, though it earns no badge). Folded over the
    /// selection by `selectionFullyApplied`; folded over the current
    /// match's lines for the compact handle's per-item Apply
    /// (`currentMatchAppliedOrCovered`).
    func isAppliedOrCovered(_ id: UUID) -> Bool {
        appliedResultIDs.contains(id) || coveredResultIDs.contains(id)
    }

    /// The match the result `id` is a line of has nothing left for the
    /// apply path: every one of its lines with a box is applied or covered
    /// (`isAppliedOrCovered`). A match wrapped onto two lines is applied
    /// only when both are, so a first line covered by an earlier box does
    /// not read the second as done. A result with no box reads as itself.
    func isMatchAppliedOrCovered(_ id: UUID) -> Bool {
        let boxed = pieces(of: id).filter(\.hasBox)
        guard !boxed.isEmpty else { return isAppliedOrCovered(id) }
        return boxed.allSatisfy { isAppliedOrCovered($0.id) }
    }

    /// `isMatchAppliedOrCovered` for the walk's current match; false
    /// before the first step. The walk stops once per match, at its lead
    /// line, so the current result alone does not say whether the match
    /// is done.
    var currentMatchAppliedOrCovered: Bool {
        guard let current = currentResult else { return false }
        return isMatchAppliedOrCovered(current.id)
    }

    /// Count of matches the user left un-checked in triage, by occurrence
    /// (the complement of `selectedCount`). Folded into
    /// `CoverageReport.deselectedCount` at the panel + audit-export boundary
    /// by `coverageReportForDisplay()`. Derived from live `isSelected` state,
    /// so it returns to 0 with `results` on `clear()` / `clearResults()`.
    var deselectedCount: Int {
        Self.occurrenceCount(results.filter { !$0.isSelected && $0.hasBox })
    }

    /// Total match count (a match wrapped onto two lines counts once).
    var totalCount: Int { Self.occurrenceCount(results) }

    // MARK: - Result Navigation

    /// The currently focused result, if any.
    var currentResult: SearchResult? {
        guard let idx = currentResultIndex, results.indices.contains(idx) else { return nil }
        return results[idx]
    }

    /// Return only the results visible in the active navigation scope.
    /// `.wholeDocument` returns all results; `.currentPage` filters to the
    /// page the caller currently has loaded.
    /// Sources from `filteredResults` so J/K navigation respects
    /// active source/confidence/category/applied filters — results hidden
    /// by the filter are skipped during traversal. One stop per match: a
    /// wrapped match is visited at its lead line (`occurrenceRows`).
    func scopedResults(currentPageIndex: Int) -> [SearchResult] {
        switch navigationScope {
        case .wholeDocument: return Self.occurrenceRows(filteredResults)
        case .currentPage: return Self.occurrenceRows(filteredResults).filter { $0.pageIndex == currentPageIndex }
        }
    }

    /// Navigate to the next result within the current scope. Wraps. No-op
    /// when the scope is empty (e.g. `.currentPage` on a page with no hits).
    func navigateToNext(currentPageIndex: Int) {
        let scoped = scopedResults(currentPageIndex: currentPageIndex)
        guard !scoped.isEmpty else { return }
        let currentID = currentResult.map(Self.occurrenceKey)
        let scopedIdx = scoped.firstIndex(where: { Self.occurrenceKey($0) == currentID })
        let nextScopedIdx: Int
        if let scopedIdx { nextScopedIdx = (scopedIdx + 1) % scoped.count }
        else { nextScopedIdx = 0 }
        if let realIdx = results.firstIndex(where: { $0.id == scoped[nextScopedIdx].id }) {
            currentResultIndex = realIdx
        }
    }

    /// Navigate to the previous result within the current scope. Wraps.
    func navigateToPrevious(currentPageIndex: Int) {
        let scoped = scopedResults(currentPageIndex: currentPageIndex)
        guard !scoped.isEmpty else { return }
        let currentID = currentResult.map(Self.occurrenceKey)
        let scopedIdx = scoped.firstIndex(where: { Self.occurrenceKey($0) == currentID })
        let prevScopedIdx: Int
        if let scopedIdx { prevScopedIdx = (scopedIdx - 1 + scoped.count) % scoped.count }
        else { prevScopedIdx = scoped.count - 1 }
        if let realIdx = results.firstIndex(where: { $0.id == scoped[prevScopedIdx].id }) {
            currentResultIndex = realIdx
        }
    }

    // MARK: - Review Shortcuts

    /// Space-key handler. Toggles `isSelected` on the focused result
    /// (same field the checkbox drives), so the existing apply pipeline
    /// picks it up without parallel state.
    func toggleSelectionForCurrentMatch() {
        guard let id = currentResult?.id else { return }
        toggleSelection(for: id)
    }

    /// Return-key prelude. If nothing is selected, mark the focused
    /// result so the caller can apply via the existing `RedactionState`
    /// path. Returns true when the apply path should run.
    @discardableResult
    func selectCurrentMatchIfNoneSelected() -> Bool {
        if results.contains(where: { $0.isSelected }) { return true }
        guard let id = currentResult.flatMap({ $0.hasBox ? $0.id : nil }) else { return false }
        toggleSelection(for: id)
        return true
    }
}
