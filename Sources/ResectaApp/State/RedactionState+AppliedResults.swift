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

    /// One search session's deselection facts in the pending set, keyed
    /// by the session's id.
    typealias RunDeselectionPart = (session: UUID, snapshot: DeselectionSnapshot)

    /// The pending deselection parts after an apply from `search`: its
    /// facts replace its own earlier part (its unchecked list is that
    /// session's current view) or join as a new part; a session with no
    /// facts (a typed search) leaves the parts as they are, so a later
    /// apply keeps an earlier Scan's unchecked results.
    func runDeselectionParts(after search: SearchState) -> [RunDeselectionPart] {
        guard let snapshot = search.deselectionSnapshotForRun() else { return pendingRunDeselectionParts }
        return pendingRunDeselectionParts.filter { $0.session != search.id } + [(search.id, snapshot)]
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
            let pageRegions = regions[result.pageIndex] ?? []
            if resultIsCovered(result, paints: pageRegions.map(\.normalizedRect),
                               strips: pageRegions.compactMap(\.textLayerRect)) { covered.insert(result.id) }
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

extension RedactionState.DeselectionSnapshot {
    /// Several sessions' facts as one: every part's unchecked results over
    /// the sum of the parts' result counts. Nil when there is no part.
    init?(merging parts: [Self]) {
        guard !parts.isEmpty else { return nil }
        self.init(items: parts.flatMap(\.items), totalCount: parts.reduce(0) { $0 + $1.totalCount })
    }
}

/// A typed search applied while a box already held every result it selected:
/// no region carries its record, so the run's re-check reads it from here
/// (`PipelineCoordinator.appliedSearches(fromRegions:audit:deselected:covered:)`).
struct CoveredSearchRecord: Equatable {
    let record: AppliedSearchRecord
    let appliedAt: Date
    let pages: Set<Int>
}

extension RedactionState {

    /// Keep the record of a search whose apply created nothing because a box
    /// already held every selected result, so the verifier still re-runs it.
    func noteCoveredSearch(_ record: AppliedSearchRecord?, selected: [SearchResult],
                           covered: Set<UUID>, at appliedAt: Date) {
        guard let record, !covered.isEmpty else { return }
        let pages = Set(selected.filter { covered.contains($0.id) }.map(\.pageIndex))
        coveredSearchRecords.removeAll { $0.record.query == record.query }
        coveredSearchRecords.append(CoveredSearchRecord(record: record, appliedAt: appliedAt, pages: pages))
    }
}
