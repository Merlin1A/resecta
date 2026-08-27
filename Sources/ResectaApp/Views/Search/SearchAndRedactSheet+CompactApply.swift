import SwiftUI

// The compact handle's per-item Apply (UXC-51, D-128 / RB-123 items
// 3/4; REV-17) — split from `SearchAndRedactSheet.swift` under the M-6
// hub cap, the `+Trigger.swift` decomposition: the strip in the hub
// mounts `applyCurrentResultButton`; its gate and action live here
// beside it. Internal, not private, because the hub's strip is the
// caller.
//
// CONTRACT (WA/D-75 as AMENDED by UXC-44 / D-116 / RB-92/94 and again
// by UXC-51 / D-128 / RB-123): compact is a glanceable handle — title
// + result-nav cluster + per-item Apply; every OTHER control lives at
// medium+, and the canvas owns interaction below the sheet (BH-A-04
// grant). The Apply marks ONLY the walk's current match: one draft
// region through the one `applyFindings` seam — the single-result
// origin, resolved by id at call time — and ONE two-leg `commitApply`
// step on the same per-window UndoManager the editor toolbar's
// Undo/Redo pair drives. Apply and stay put (RB-123 item 3): the sheet
// stays parked, the phase stays `.editing`, focus does not move; the
// button reads applied (disabled) and the user chevrons on; Undo
// restores it. Implicit accept — the checkbox neither gates nor is
// required (the wand / nudge precedent). No confirm dialog: the mark
// is undoable and toasted (REV-15 / T4 — no second presentation at
// compact). No keyboard shortcut — Return keeps its all-selected
// semantics. iOS 26 renders the float at ≈0.86 scale, so the 46-pt
// layout floor serves ≈40 pt effective — documented-accepted
// (`result-nav-evidence-2026-08-26/NOTES.md`).

extension SearchAndRedactSheet {

    // MARK: - Toast clearance at the compact float

    /// UXC-51: how far ContentView's bottom toast host lifts while this
    /// sheet is parked at the compact float — the hug, read symbolically
    /// (RB-42) — so the "Marked 1 …" toast clears the strip instead of
    /// sitting beneath it; zero at every other detent, where the sheet
    /// covers that host and renders its own copy. Pure; the detent
    /// tests pin it beside the hug.
    static func toastBottomClearance(for detent: PresentationDetent) -> CGFloat {
        detent == .compactFloat ? CompactFloatDetent.hugHeight : 0
    }

    // MARK: - Per-item Apply (compact handle)

    /// Text "Apply", semibold tint, `.plain` (the `searchApplyButton`
    /// idiom; default-styled buttons in the sheet's fixed chrome are
    /// the 18-SCROLL-ARCH §10 arbitration poison), the disabled state
    /// falling to `.tertiary`. RB-67: the 46-pt LAYOUT floor and the
    /// `contentShape` sit AFTER the chrome — the hit area is the drawn
    /// frame, never an expansion. Identifier BEFORE `.disabled` so it
    /// stays on the AX surface while disabled (the detent-layout leg
    /// reads the disabled → enabled round-trip through it). Carries
    /// its own leading inset so both strip branches mount it bare.
    var applyCurrentResultButton: some View {
        Button(action: applyCurrentResult) {
            Text("Apply")
                .frame(minHeight: ResectaTokens.TouchTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fontWeight(.semibold)
        .foregroundStyle(applyCurrentResultDisabled
            ? AnyShapeStyle(.tertiary)
            : AnyShapeStyle(.tint))
        .accessibilityLabel("Apply")
        .accessibilityHint("Marks the current match for redaction.")
        .accessibilityIdentifier("applyCurrentResultButton")
        .disabled(applyCurrentResultDisabled)
        .padding(.leading, ResectaTokens.Spacing.md)
    }

    /// Live only with a current match on board that the apply path
    /// still has work for, while regions can mutate. "Applied" is the
    /// header Apply's graying predicate (applied ∪ dedup-covered,
    /// BH-A-03) read for the one result — `SearchState.isAppliedOrCovered`
    /// — so the applied-filter rows, the header button and this one
    /// agree by construction; the walk's "current" is
    /// `SearchState.currentResult` (nil until the first step).
    private var applyCurrentResultDisabled: Bool {
        guard let current = searchState.currentResult else { return true }
        return searchState.isAppliedOrCovered(current.id)
            || !documentState.canMutateRegions
    }

    /// One result, by id, through the one `applyFindings` seam — the
    /// Apply Group wiring shape with the toolbar Apply's bookkeeping.
    /// The id is captured BEFORE the await (REV-09 / T5: the walk or a
    /// re-flush can move `currentResult` while the apply waits its
    /// turn; the seam resolves the id against the live results and
    /// refuses a stale one with zero mutations). On success the
    /// survivors join the applied set (QW-1) and the dedup-covered ids
    /// the graying set (BH-A-03), then the UXF-11 toast through the
    /// one `CommitFeedback` builder. Focus does not move. `isApplying`
    /// is the sheet-wide one-apply-at-a-time flag the toolbar and
    /// shortcut paths share; the mutation guard is re-checked inside
    /// the seam.
    private func applyCurrentResult() {
        guard !isApplying else { return }
        guard documentState.canMutateRegions else { return }
        guard let id = searchState.currentResult?.id else { return }
        isApplying = true
        Task { @MainActor in
            defer { isApplying = false }
            guard let outcome = await redactionState.applyFindings(
                .searchResult(id: id),
                undoManager: undoManager,
                documentState: documentState
            ) else { return }
            searchState.appliedResultIDs.formUnion(outcome.appliedResultIDs)
            searchState.coveredResultIDs.formUnion(outcome.coveredResultIDs)
            if let message = CommitFeedback.markedMessage(
                applied: outcome.applied,
                alreadyCovered: outcome.skippedOverlaps
            ) {
                toastManager.enqueue(message, severity: .success)
            }
        }
    }
}
