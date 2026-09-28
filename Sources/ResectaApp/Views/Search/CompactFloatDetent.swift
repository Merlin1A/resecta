import SwiftUI

// Compact float detent for the Search & Redact sheet.
//
// The compact detent hugs the glanceable handle — the grabber capsule
// and one row of full-size controls: the per-item Apply capsule (Select
// on the review origin) and the ‹ › cluster with its counter
// (`compactFloatStrip`, `+CompactStrip.swift`) — so the document stays
// the primary surface while the sheet is parked and the walk — the
// search results or the staged detection review — continues from the
// handle with its one-tap mark. Height is a fixed hug clamped to the
// available height, the same at every type size (the row keeps its
// floor; the counter hides from XXXL up).
//
// Two presentation regimes, measured on the iPhone 17 simulator (iOS 26):
// up to a hug of 100 the system draws the parked sheet as a floating
// capsule whose scale grows with the hug (0.877 at 80 → 0.957 at 100,
// the grabber hidden from ≈94); from 101 it draws an attached sheet at
// 0.96 with an 8-pt inset, the bottom safe area added under the content
// and the grabber visible. The hug below sits ON the attached regime's
// edge, where a 46-pt control frame shows at 44.2 pt — the effective
// floor holds with the shared token; a capsule at 80 would draw the
// controls at ~40 pt, under the floor, which is why the row alone does
// not go lower. `CompactDetentAnchoredRowTests` pins the regime and the
// hug arithmetic.
//
// History: 60 (the title-only handle) → 72 (the ‹ › cluster) → 80 (the
// per-item Apply) → 108 (a match line + full-size controls; 120 at
// accessibility sizes) → 108 unchanged when the staged detection review
// took the same handle (the review walk: the pair, the counter, Select
// in the Apply slot — `ReviewWalk`) → 101 when the match line was
// retired (2026-09-28): the row alone, the smallest attached hug.
//
// The pure-function `compactHeight(maxDetentValue:)` helper isolates
// the math from the SwiftUI runtime so tests can verify the hug + clamp
// contract without constructing a `Context` value (the type has no
// public initializer).

struct CompactFloatDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        compactHeight(maxDetentValue: context.maxDetentValue)
    }

    /// The fixed hug, never exceeding the available height.
    static func compactHeight(maxDetentValue: CGFloat) -> CGFloat {
        min(hugHeight, maxDetentValue)
    }

    /// The ONE hug value the chrome outside the sheet reads — the
    /// page-bar / parked-canvas inset and the toast clearance, through
    /// `ParkedChromeLayout`. One hug for every type size since the match
    /// line retired; the seam keeps its type-size key so its consumers
    /// stay put should a size-keyed hug ever return.
    static func hug(for size: DynamicTypeSize) -> CGFloat {
        hugHeight
    }

    /// Grabber inset + the controls row's 46-pt layout floor + breathing
    /// room (15 + 46 + 40). Stays ≥ 101: the attached regime (see the
    /// file comment).
    static let hugHeight: CGFloat = 101
    /// The grabber capsule's inset above the content (6 + 5 + 4).
    static let grabberInset: CGFloat = 15
    /// Breathing room under the controls row — what the smallest
    /// attached hug leaves once the grabber inset and the row are paid.
    static let bottomInset: CGFloat = 40
}

extension PresentationDetent {
    /// Convenience accessor matching the call sites that compare
    /// `selectedDetent` against the compact detent (e.g. tap-on-row
    /// drop-to-compact). Equivalent to `.custom(CompactFloatDetent.self)`.
    static let compactFloat: PresentationDetent = .custom(CompactFloatDetent.self)
}

// MARK: - Grabber Pulse Predicate

extension CompactFloatDetent {
    /// Returns `true` when the sheet's grabber should fire a
    /// one-shot pulse on a detent transition. Pulse fires only on
    /// the FIRST compact-drop within a sheet session and is
    /// suppressed entirely under Reduce Motion (a hint affordance,
    /// not a state-change cue — `Anim.resolved` is bypassed at this
    /// gate). The `hasAlreadyPulsed` flag is `@State` scoped to the
    /// sheet, so it resets on `.onDisappear` and the
    /// next sheet session re-enables the pulse.
    static func shouldPulseGrabber(
        transitioningTo newDetent: PresentationDetent,
        hasAlreadyPulsed: Bool,
        reduceMotion: Bool
    ) -> Bool {
        guard newDetent == .compactFloat else { return false }
        guard !hasAlreadyPulsed else { return false }
        guard !reduceMotion else { return false }
        return true
    }
}
