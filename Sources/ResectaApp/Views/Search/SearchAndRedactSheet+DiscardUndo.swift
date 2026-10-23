import SwiftUI

// Dismissal helpers for the search sheet's Dismiss control.
//
// The live contract has TWO branches, both landing on the
// shared `performDismiss(afterConfirmation:)` (below, with the dismiss copy)
// that this file's `currentSelectionSnapshot` / `clearSelection` helpers
// underpin:
//
// - Silent route: when `DocumentState.hasUnappliedSelections` is
//   false, tapping `Dismiss` deselects every selected result in-place
//   and dismisses the sheet in the same tap. The selection only feeds
//   Apply, and re-running the search restores it, so nothing
//   irreversible is dropped — no confirmation is needed.
// - Confirm route: when `hasUnappliedSelections` is
//   true — a selected result no live applied region covers — Dismiss
//   instead raises
//   the "Discard selections?" `.confirmationDialog`
//   (`SearchAndRedactSheet.dismissTitle` / `.dismissMessage`); only a
//   confirmed tap calls through with `afterConfirmation: true`.
//
// The prior two-tap flow (deselect + non-modal undo toast, then a
// second Done tap to dismiss) and its `enqueueDiscardUndoToast` /
// `restoreSelection` helpers are gone — superseded by the two branches
// above.
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

    /// Message for the dismiss decision point. Dismiss with 0
    /// selected closes instantly by construction; when the session
    /// still holds unapplied matches (piiScan results arrive
    /// deselected), the close drops them with no other signal. Returns
    /// nil when nothing unapplied is lost so the common dismiss stays
    /// toast-free. The leading noun follows the interface
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

    /// The notice a re-run posts when it clears unapplied matches with the
    /// previous results; nil when none were unapplied.
    static func rerunClearedMessage(unappliedCount: Int) -> String? {
        guard unappliedCount > 0 else { return nil }
        let suffix = unappliedCount == 1 ? "" : "es"
        return "Search re-run — \(unappliedCount) unapplied match\(suffix) cleared."
    }

    /// The notice read from a live session: what every dismissal that
    /// drops the session posts, the sheet's own Dismiss and a system
    /// dismissal (a swipe or a scrim tap) the editor's sheet binding sees.
    static func dismissClearedMessage(for searchState: SearchState) -> String? {
        dismissClearedMessage(
            unappliedCount: unappliedMatchCount(in: searchState),
            interface: searchState.searchModeType.interface
        )
    }

    // MARK: - Dismiss (conditional dismiss)

    /// Dismiss-confirmation copy — the single source of truth for both
    /// the production `.alert` and the copy-pin banned-word
    /// sweep (`SearchSheetDismissRuleTests`), so a copy rename can't
    /// drift past the sweep. Covers both result origins; the message
    /// names the concrete loss — selected matches that will not be
    /// applied — rather than a generic "not saved".
    static let dismissTitle = "Discard selections?"
    static let dismissMessage = "Selected matches will not be applied to the document."

    /// Escape's dismiss, the Dismiss button's rule: ask first while the
    /// session holds selected matches no live region covers, else close.
    func requestDismiss() {
        if DocumentState.hasUnappliedSelections(redactionState) {
            showDismissConfirmation = true
        } else {
            performDismiss(afterConfirmation: false)
        }
    }

    /// The notice a dismissal posts: the unapplied matches it clears,
    /// with or without a selection on board, unless the confirmation
    /// already named the drop (a dialog and a toast on one dismiss would
    /// say it twice).
    static func dismissalNotice(afterConfirmation: Bool, in searchState: SearchState) -> String? {
        afterConfirmation ? nil : dismissClearedMessage(for: searchState)
    }

    /// Shared dismiss path for the direct and confirmed routes: the
    /// notice (the toast manager outlives the sheet), a live selection
    /// deselected in place, then the session dropped.
    func performDismiss(afterConfirmation: Bool) {
        if let message = Self.dismissalNotice(afterConfirmation: afterConfirmation, in: searchState) {
            toastManager.enqueue(message, severity: .info)
        }
        if searchState.selectedCount > 0 {
            let snapshot = Self.currentSelectionSnapshot(in: searchState)
            Self.clearSelection(in: searchState, snapshot: snapshot)
        }
        redactionState.activeSearch = nil
    }
}
