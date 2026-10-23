import Foundation

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
}
