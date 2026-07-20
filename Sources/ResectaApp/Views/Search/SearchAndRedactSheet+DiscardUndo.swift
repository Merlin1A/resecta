import SwiftUI

// Dismissal helpers for the search sheet's one-tap Dismiss.
//
// Behavior: tapping `Dismiss` with `searchState.selectedCount > 0`
// deselects every selected result in-place and dismisses the sheet in
// the same tap — silently. The selection only feeds Apply, and
// re-running the search restores it, so nothing irreversible is
// dropped. The prior two-tap flow (deselect + non-modal undo toast,
// then a second Done tap to dismiss) and its
// `enqueueDiscardUndoToast` / `restoreSelection` helpers are gone.
//
// `discardUndoActionLabel` stays: the mode-switch undo toast
// (`+ModeSwitch.swift`) shares it.

extension SearchAndRedactSheet {

    /// Snapshot the currently-selected result IDs in the
    /// SearchState. Captures the selection set BEFORE clearing.
    @MainActor
    static func currentSelectionSnapshot(in searchState: SearchState) -> Set<UUID> {
        Set(searchState.results.filter(\.isSelected).map(\.id))
    }

    /// Deselect every result whose ID is in `snapshot`. Mutates
    /// `searchState.results` in-place. Used by the Dismiss handler
    /// on the way out of the sheet.
    @MainActor
    static func clearSelection(in searchState: SearchState, snapshot: Set<UUID>) {
        for index in searchState.results.indices where snapshot.contains(searchState.results[index].id) {
            searchState.results[index].isSelected = false
        }
    }

    /// Undo-action button label — a UI
    /// affordance label (mechanism-description for the action it
    /// triggers). Shared with the mode-switch undo toast.
    static let discardUndoActionLabel: String = "Undo"

    /// UXF-27: message for the dismiss decision point. Dismiss with 0
    /// selected closes instantly by construction; when the session
    /// still holds unapplied matches (piiScan results arrive
    /// deselected), the close drops them with no other signal. Returns
    /// nil when nothing unapplied is lost so the common dismiss stays
    /// toast-free. BH-B-03 — the leading noun follows the interface
    /// (the UP-era adaptive-copy posture: save alert, displayName
    /// split): a Scan-interface dismissal says "Scan closed", not
    /// "Search closed". Pinned by `DiscardUndoToastTests`.
    static func dismissClearedMessage(
        unappliedCount: Int,
        interface: SearchInterface
    ) -> String? {
        guard unappliedCount > 0 else { return nil }
        let noun = interface == .scan ? "Scan" : "Search"
        let suffix = unappliedCount == 1 ? "" : "es"
        return "\(noun) closed — \(unappliedCount) unapplied match\(suffix) cleared."
    }
}
