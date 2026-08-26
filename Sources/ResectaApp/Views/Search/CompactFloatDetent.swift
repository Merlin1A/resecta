import SwiftUI

// Compact float detent for the Search & Redact sheet.
//
// WA/D-75 (as AMENDED by UXC-44 / D-116 / RB-94): the compact detent
// hugs the glanceable handle — the grabber capsule plus the centered
// interface title with the result-nav cluster (‹ › + k/N) overlaid
// at its trailing edge (`compactFloatStrip`) — so the document stays
// the primary surface while the sheet is parked and the result walk
// continues from the handle. Height is a fixed hug clamped to the
// available height. The prior max(110pt, 15%-of-screen) contract
// sized a control strip (search bar + nav controls + first result
// row) that no longer renders at compact; the D-75 title-only hug
// (60) pre-dates the cluster's 46-pt layout floors.
//
// The pure-function `compactHeight(maxDetentValue:)` helper isolates
// the math from the SwiftUI runtime so tests can verify the hug +
// clamp contract without constructing a `Context` value (the type
// has no public initializer).

struct CompactFloatDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        compactHeight(maxDetentValue: context.maxDetentValue)
    }

    /// Fixed title hug, never exceeding the available height.
    static func compactHeight(maxDetentValue: CGFloat) -> CGFloat {
        min(hugHeight, maxDetentValue)
    }

    /// Grabber inset (6+5+4 = 15pt) + the result-nav cluster's 46-pt
    /// layout floor (RB-54/RB-67 — the title rides inside that row) +
    /// breathing room — tuned live on the iPhone 17 and the 390-pt
    /// iPhone 17e sims (UXC-44, FB-3): grabber, title, chevrons and
    /// counter fully visible, no clip, canvas exposed behind. Was 60
    /// under the D-75 title-only handle (WA-IMPL-2, B-1).
    static let hugHeight: CGFloat = 72
}

extension PresentationDetent {
    /// Convenience accessor matching the call sites that compare
    /// `selectedDetent` against the compact detent (e.g. tap-on-row
    /// drop-to-compact). Equivalent to `.custom(CompactFloatDetent.self)`.
    static let compactFloat: PresentationDetent = .custom(CompactFloatDetent.self)
}

// MARK: - WU-59 Grabber Pulse Predicate

extension CompactFloatDetent {
    /// WU-59: returns `true` when the sheet's grabber should fire a
    /// one-shot pulse on a detent transition. Pulse fires only on
    /// the FIRST compact-drop within a sheet session and is
    /// suppressed entirely under Reduce Motion (a hint affordance,
    /// not a state-change cue — `Anim.resolved` is bypassed at this
    /// gate). The `hasAlreadyPulsed` flag is `@State` scoped to the
    /// sheet per [RR-16], so it resets on `.onDisappear` and the
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
