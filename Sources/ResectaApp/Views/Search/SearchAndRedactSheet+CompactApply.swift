import SwiftUI

// The compact handle's per-item Apply — split from
// `SearchAndRedactSheet.swift` under the M-6
// hub cap, the `+Trigger.swift` decomposition: the strip in the hub
// mounts `applyCurrentResultButton`; its gate and action live here
// beside it. Internal, not private, because the hub's strip is the
// caller.
//
// Compact is a glanceable handle — title
// + result-nav cluster + per-item Apply; every OTHER control lives at
// medium+, and the canvas owns interaction below the sheet. The Apply
// marks ONLY the walk's current match: one draft
// region through the one `applyFindings` seam — the single-result
// origin, resolved by id at call time — and ONE two-leg `commitApply`
// step on the same per-window UndoManager the editor toolbar's
// Undo/Redo pair drives. Apply and stay put: the sheet
// stays parked, the phase stays `.editing`, focus does not move; the
// button reads applied (disabled) and the user chevrons on; Undo
// restores it. Implicit accept — the checkbox neither gates nor is
// required (the wand / nudge precedent). No confirm dialog: the mark
// is undoable and toasted (no second presentation at
// compact). No keyboard shortcut — Return keeps its all-selected
// semantics. The parked sheet is drawn at 0.96 (the attached regime,
// `CompactFloatDetent`), so the 46-pt layout floor serves 44.2 pt
// effective.
//
// On the review origin — the staged detection review owning the Scan
// interface — the same slot holds SELECT, the row checkbox's sibling:
// one tap marks the review walk's current row selected (the
// `triageSelections` entry the checkbox drives; "Selected" reads back
// on the wash and stays tappable, the next tap deselects), and the
// header's "Apply N" commits, as it always did. No region is created
// from the strip on this origin, so nothing to undo and no toast; the
// haptic is the checkbox's. The id is the same; the label switches
// with the origin.

extension SearchAndRedactSheet {

    // MARK: - Toast clearance at the compact float

    /// How far the bottom toast hosts lift, from the one bottom-chrome
    /// model (`ParkedChromeLayout`, the editor's own inputs read here):
    /// the hug while this sheet is parked at the compact float — so the
    /// "Marked 1 …" toast clears the strip instead of sitting beneath it
    /// — plus the page bar's height while the bar is up and uncovered;
    /// zero with the sheet up at a taller detent, where the sheet-local
    /// host renders inside the sheet. `sheetPresented: false` is the
    /// value the sheet leaves behind on disappearance (the bar alone).
    func toastBottomClearance(sheetPresented: Bool) -> CGFloat {
        ParkedChromeLayout(
            sheetPresented: sheetPresented,
            detent: selectedDetent,
            walkLive: searchState.isWalkLive(reviewPending: redactionState.pendingTriage != nil),
            pageCount: documentState.pageCount,
            sizeClass: horizontalSizeClass,
            phase: documentState.phaseKind,
            hugHeight: CompactFloatDetent.hug(for: dynamicTypeSize)
        ).toastClearance
    }

    // MARK: - Per-item Apply (compact handle)

    /// A filled capsule — `BrandTeal.fill`, white headline label,
    /// `.capsulePress` — that reads applied once the current match is
    /// marked: ✓ "Applied" (the applied-filter chip's word) on the
    /// circle wash, `.secondary` label, disabled without the disabled
    /// dim; while there is nothing to apply (no current match, hidden
    /// by filters, regions locked) the capsule dims to the disabled
    /// opacity. The 46-pt LAYOUT floor and the `contentShape` sit AFTER
    /// the chrome — the hit area is the drawn frame, never an expansion.
    /// Identifier BEFORE `.disabled` so it stays on the AX surface while
    /// disabled (the detent-layout leg reads the disabled → enabled
    /// round-trip through it); the a11y label stays "Apply" in both
    /// states. The label's inset is `Spacing.md`; the strip adds the
    /// leading inset. On the review origin the slot mounts
    /// `reviewSelectButton` instead.
    func applyCurrentResultButton() -> some View {
        Group {
            if isReviewActive {
                reviewSelectButton()
            } else {
                searchApplyButton()
            }
        }
    }

    /// The search origin's builder — the capsule / ✓ "Applied" pair.
    private func searchApplyButton() -> some View {
        Group {
            if applyCurrentResultApplied {
                Button(action: applyCurrentResult) {
                    Label(AppliedFilter.applied.rawValue, systemImage: "checkmark")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, ResectaTokens.Spacing.md)
                        .frame(minHeight: ResectaTokens.TouchTarget.minimum)
                        .background(CircularIconButtonStyle.wash, in: Capsule())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Button(action: applyCurrentResult) {
                    Text("Apply")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, ResectaTokens.Spacing.md)
                        .frame(minHeight: ResectaTokens.TouchTarget.minimum)
                        .background(ResectaTokens.BrandTeal.fill, in: Capsule())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.capsulePress)
            }
        }
        .accessibilityLabel("Apply")
        .accessibilityHint("Marks the current match for redaction.")
        .accessibilityIdentifier("applyCurrentResultButton")
        .disabled(applyCurrentResultDisabled)
    }

    // MARK: - Per-item Select (the review origin)

    /// The review origin's sibling of the Apply capsule: "Select" on the
    /// same fill, or ✓ "Selected" on the wash — enabled either way (the
    /// second tap deselects), the selected trait for VoiceOver and the
    /// checkbox's haptic; dimmed with no current row (before the first
    /// step). The same identifier, the origin's own label; identifier
    /// BEFORE `.disabled` as on the search origin.
    private func reviewSelectButton() -> some View {
        let selected = reviewCurrentSelected
        return Group {
            if selected {
                Button(action: toggleReviewCurrentSelection) {
                    Label("Selected", systemImage: "checkmark")
                        .font(.headline)
                        .padding(.horizontal, ResectaTokens.Spacing.md)
                        .frame(minHeight: ResectaTokens.TouchTarget.minimum)
                        .background(CircularIconButtonStyle.wash, in: Capsule())
                        .contentShape(Rectangle())
                }
            } else {
                Button(action: toggleReviewCurrentSelection) {
                    Text("Select")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, ResectaTokens.Spacing.md)
                        .frame(minHeight: ResectaTokens.TouchTarget.minimum)
                        .background(ResectaTokens.BrandTeal.fill, in: Capsule())
                        .contentShape(Rectangle())
                }
            }
        }
        .buttonStyle(.capsulePress)
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityLabel("Select")
        .accessibilityHint("Selects the current detection for redaction; tap again to deselect.")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("applyCurrentResultButton")
        .disabled(liveReviewWalk.current == nil)
    }

    /// The review walk's current row is selected — the checkbox's read
    /// (an absent id is not selected).
    private var reviewCurrentSelected: Bool {
        guard let id = liveReviewWalk.currentID else { return false }
        return redactionState.triageSelections[id] ?? false
    }

    /// The checkbox's write for the current row, plus the conditional-
    /// dismiss mark the checkbox makes (a toggle is user selection work).
    private func toggleReviewCurrentSelection() {
        guard let id = liveReviewWalk.currentID else { return }
        ReviewWalk.toggleSelection(of: id, in: &redactionState.triageSelections)
        searchState.userModifiedSelections = true
    }

    // MARK: - The search origin's reads

    /// The applied read for the one result — `SearchState.isAppliedOrCovered`
    /// (applied ∪ dedup-covered), the header Apply's graying predicate.
    private var applyCurrentResultApplied: Bool {
        guard let current = searchState.currentResult else { return false }
        return searchState.isAppliedOrCovered(current.id)
    }

    /// Live only with a current match on board that the apply path
    /// still has work for, while regions can mutate. "Applied" is the
    /// header Apply's graying predicate (applied ∪ dedup-covered)
    /// read for the one result — `SearchState.isAppliedOrCovered`
    /// — so the applied-filter rows, the header button and this one
    /// agree by construction; the walk's "current" is
    /// `SearchState.currentResult` (nil until the first step).
    private var applyCurrentResultDisabled: Bool {
        guard let current = searchState.currentResult else { return true }
        return searchState.isAppliedOrCovered(current.id)
            || !documentState.canMutateRegions
    }

    /// One result, by id, through the one search-origin apply
    /// (`applySearchSelection`): the id is captured BEFORE the await
    /// (the walk or a re-flush can move `currentResult` while the apply
    /// waits its turn; the seam resolves the id against the live results
    /// and refuses a stale one with zero mutations). On success the
    /// survivors join the applied set and the dedup-covered ids the
    /// graying set, then the toast through the one `CommitFeedback`
    /// builder. Focus does not move and the page does not navigate.
    private func applyCurrentResult() {
        guard let id = searchState.currentResult?.id else { return }
        applySearchSelection(origin: .searchResult(id: id), navigateToFirst: false)
    }
}
