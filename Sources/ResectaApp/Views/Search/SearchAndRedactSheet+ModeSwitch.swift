import SwiftUI
import RedactionEngine

// Mode-switch discard helpers
// (DiscardUndo routing). Extracted into a
// sibling file so the toast composition + gating logic is testable
// without driving a SwiftUI host.
//
// UXF-19 evolution: the original shape warned BEFORE the clear
// ("Switching mode will clear N unapplied matches.") and offered no
// recovery; pack 01 also flagged that an all-applied result list cleared
// with no toast at all (the warning gated on `unappliedCount > 0`).
// Mode-switch clears route through a non-modal undo pattern
// (originally shared with the old two-tap Done discard flow, which the
// one-tap Dismiss has since replaced): snapshot the session before the
// clear, clear, then enqueue a toast whose Undo action restores the
// prior mode and its results. The toast fires for ANY user-initiated
// clear that dropped at least one result — applied-only lists included —
// so no path clears silently. Programmatic transitions (saved-search
// recall, ST-95) still skip both the clear and the toast by design.

extension SearchAndRedactSheet {

    /// WU-09: number of search results that have NOT been applied as
    /// `RedactionRegion`s. Pure-data; safe to call from any actor since
    /// it reads only `searchState.results.count` and
    /// `searchState.appliedResultIDs.count`. Negative differences clamp
    /// to zero in case applied IDs ever outpace results (e.g. between
    /// region-version `.onChange` resets).
    @MainActor
    static func unappliedMatchCount(in searchState: SearchState) -> Int {
        max(0, searchState.results.count - searchState.appliedResultIDs.count)
    }

    /// UXF-19: the slice of session state a mode-switch clear destroys
    /// and the undo action restores. Value-type snapshot — lives in the
    /// toast's action closure and expires with the toast, mirroring the
    /// `+DiscardUndo` snapshot-lifetime contract (no long-lived field on
    /// `SearchState`).
    struct ModeSwitchSnapshot {
        let mode: SearchModeType
        let results: [SearchResult]
        let appliedResultIDs: Set<UUID>
        let piiCategoryFilter: Set<PIICategory>?
        let sortOrder: ResultSortOrder
        let appliedFilter: AppliedFilter
    }

    /// Capture the pre-clear session slice. Must run BEFORE
    /// `clearResults()` per [RR-04] reset-after-check ordering —
    /// `previousMode` comes from the `.onChange(oldValue:)` parameter
    /// since `searchState.searchModeType` already holds the new mode
    /// when the handler fires.
    @MainActor
    static func modeSwitchSnapshot(
        of searchState: SearchState,
        previousMode: SearchModeType
    ) -> ModeSwitchSnapshot {
        ModeSwitchSnapshot(
            mode: previousMode,
            results: searchState.results,
            appliedResultIDs: searchState.appliedResultIDs,
            piiCategoryFilter: searchState.piiCategoryFilter,
            sortOrder: searchState.sortOrder,
            appliedFilter: searchState.appliedFilter
        )
    }

    /// UXF-19: enqueue the post-clear undo toast when the gate admits it
    /// (user-initiated transition AND the clear dropped at least one
    /// result). The message names the unapplied count when unapplied
    /// matches were lost; an all-applied clear (the former silent
    /// carve-out) says so instead of staying quiet. Severity is `.info`
    /// (bottom position) — observed
    /// on-sim: a `.warning` toast routes to the TOP position, which
    /// while this sheet is presented is the editor's dimming scrim, so
    /// tapping its Undo button dismissed the whole sheet.
    ///
    /// The Undo handler restores the previous mode FIRST — flagging the
    /// transition programmatic so the `.onChange` handler in the hub
    /// view preserves rather than re-clears — then re-applies the
    /// snapshotted results, applied markers, filter, and sort order.
    /// `[weak searchState]`: if the
    /// SearchState is gone by the time Undo is tapped, the closure
    /// no-ops. Coverage report / doctype explanation are NOT restored —
    /// they belong to a completed scan, not to the visible list.
    @MainActor
    static func enqueueModeSwitchUndoToast(
        on toastManager: ToastQueueManager,
        searchState: SearchState,
        snapshot: ModeSwitchSnapshot,
        isProgrammatic: Bool,
        unappliedCount: Int
    ) {
        guard !isProgrammatic, !snapshot.results.isEmpty else { return }
        // Scan↔Search transitions route through the same handler (the
        // interface derives from `searchModeType`); the toast names
        // which switch the user actually made.
        let verb = snapshot.mode.interface != searchState.searchModeType.interface
            ? "Interface switch"
            : "Mode switch"
        let message: String
        if unappliedCount > 0 {
            let suffix = unappliedCount == 1 ? "" : "es"
            message = "\(verb) cleared \(unappliedCount) unapplied match\(suffix)."
        } else {
            let count = snapshot.results.count
            let suffix = count == 1 ? "" : "es"
            message = "\(verb) cleared \(count) match\(suffix) (all already applied)."
        }
        toastManager.enqueue(
            message,
            severity: .info,
            actionLabel: discardUndoActionLabel,
            actionHandler: { [weak searchState] in
                // Deferral pattern: the restore flips
                // searchModeType and repopulates results — a larger
                // @Observable mutation than the sibling selection
                // restore — so defer it one runloop turn past the
                // toast's own synchronous dismiss transaction.
                Task { @MainActor [weak searchState] in
                    guard let searchState else { return }
                    Self.restoreModeSwitchSnapshot(snapshot, in: searchState)
                }
            }
        )
    }

    /// Undo action body: put the session back the way the mode switch
    /// found it. Pinned by `ModeSwitchToastTests`.
    @MainActor
    static func restoreModeSwitchSnapshot(
        _ snapshot: ModeSwitchSnapshot,
        in searchState: SearchState
    ) {
        // Route the mode change through the existing programmatic hook
        // (ST-95's reserved flag) so the hub's `.onChange` handler treats
        // the restore like a saved-search recall — no re-clear, no toast.
        searchState.isProgrammaticModeChange = true
        searchState.searchModeType = snapshot.mode
        searchState.results = snapshot.results
        searchState.appliedResultIDs = snapshot.appliedResultIDs
        searchState.piiCategoryFilter = snapshot.piiCategoryFilter
        searchState.sortOrder = snapshot.sortOrder
        // `clearResults()` reset this to `.all`; the restore puts the
        // user's applied-state chip back too.
        searchState.appliedFilter = snapshot.appliedFilter
    }
}
