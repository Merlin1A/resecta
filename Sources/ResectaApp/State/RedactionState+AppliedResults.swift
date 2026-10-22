import Foundation

// The join between the applied-match audit and the live regions: which
// search results are applied NOW. The sheet's `appliedResultIDs` is a
// view-state copy that a later region mutation wipes (the ✓ markers); the
// Redact gate, the Home dialog and the sheet's dismiss rule read this join
// instead, so an undone apply uncovers its rows and nothing else does.

extension RedactionState {

    /// The result ids whose applied region is still on its page.
    var liveAppliedSearchResultIDs: Set<UUID> {
        let live = Set(regions.values.joined().map(\.id))
        return Set(appliedMatchAudit.values.lazy
            .filter { live.contains($0.regionID) }
            .map(\.resultID))
    }
}
