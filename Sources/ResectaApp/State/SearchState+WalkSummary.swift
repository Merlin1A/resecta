import Foundation

// The result walk's published state for the chrome outside the sheet.
//
// `walkLive` is the ONE read of "a walk is on" — the editor's bottom-chrome
// model hides the page bar on it, and the sheet's compact strip mounts its
// ‹ › cluster and per-item Apply on the same predicate — so the two
// surfaces cannot drift. Live = search results on board and no pipeline
// review pending on the Scan interface (stale sheet-scan results must not
// show a walk over a detections list, which has no "current").

extension SearchState {
    /// Whether the result walk is live for this search session.
    /// `reviewPending` is the store's `pendingTriage != nil`, passed in
    /// because the review belongs to `RedactionState`.
    func isWalkLive(reviewPending: Bool) -> Bool {
        !results.isEmpty && !(reviewPending && searchModeType.interface == .scan)
    }
}

extension RedactionState {
    /// The one published read of the walk's liveness for the editor:
    /// false with no sheet session; else the session's own predicate
    /// against this store's pending review.
    var walkLive: Bool {
        activeSearch?.isWalkLive(reviewPending: pendingTriage != nil) ?? false
    }
}
