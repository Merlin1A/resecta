import Foundation
import RedactionEngine

// The join between the applied-match audit and the live regions: which
// search results are applied NOW. The sheet's `appliedResultIDs` is a
// view-state copy that a later region mutation wipes (the ✓ markers); the
// Redact gate, the Home dialog, the sheet's dismiss rule and the run's
// deselection facts read this join instead, so an undone apply uncovers
// its rows and nothing else does.

extension RedactionState {

    /// The result ids whose applied region is still on its page.
    var liveAppliedSearchResultIDs: Set<UUID> {
        let live = Set(regions.values.joined().map(\.id))
        return Set(appliedMatchAudit.values.lazy
            .filter { live.contains($0.regionID) }
            .map(\.resultID))
    }

    /// The snapshot pipeline entry should record for this run: the
    /// apply-commit snapshot when one is pending (the common path — see
    /// `pendingRunDeselection`), else the live search session's, less
    /// every result whose applied region is live. The strip's single
    /// Apply and the nudge's accept leave a result unticked by design,
    /// so the session's un-checked list still names it; filtering at
    /// read time puts an undone apply's result back in the count.
    func runEntryDeselectionSnapshot() -> DeselectionSnapshot? {
        guard let snapshot = pendingRunDeselection ?? activeSearch?.deselectionSnapshotForRun() else {
            return nil
        }
        let applied = liveAppliedSearchResultIDs
        return DeselectionSnapshot(
            items: snapshot.items.filter { !applied.contains($0.id) },
            totalCount: snapshot.totalCount)
    }

    /// The sheet's markers, derived from the live document: the results
    /// whose applied region is live, and the results a live region covers
    /// (`resultIsCovered`, the apply's own skip rule). Never stored apart
    /// from the regions, so an unrelated edit cannot wipe a marker and an
    /// undo or a redo moves it with its region.
    func derivedSearchMarkers(for results: [SearchResult]) -> (applied: Set<UUID>, covered: Set<UUID>) {
        let applied = liveAppliedSearchResultIDs.intersection(results.map(\.id))
        var covered: Set<UUID> = []
        for result in results where !applied.contains(result.id) {
            let rects = regions[result.pageIndex]?.map(\.normalizedRect) ?? []
            if resultIsCovered(result.normalizedRect, by: rects) { covered.insert(result.id) }
        }
        return (applied, covered)
    }

    /// Write the derived markers onto `search`, only where they changed.
    func refreshSearchMarkers(on search: SearchState) {
        let markers = derivedSearchMarkers(for: search.results)
        if search.appliedResultIDs != markers.applied { search.appliedResultIDs = markers.applied }
        if search.coveredResultIDs != markers.covered { search.coveredResultIDs = markers.covered }
    }
}
