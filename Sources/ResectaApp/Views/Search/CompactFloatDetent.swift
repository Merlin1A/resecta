import SwiftUI

// Compact float detent for the Search & Redact sheet.
//
// WA/D-75: the compact detent hugs the title-only handle — the
// grabber capsule plus the centered interface title
// (`compactFloatStrip`) — so the document stays the primary surface
// while the sheet is parked. Height is a fixed hug clamped to the
// available height. The prior max(110pt, 15%-of-screen) contract
// sized a control strip (search bar + nav controls + first result
// row) that no longer renders at compact.
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

    /// Grabber inset (~15pt) + one headline line + breathing room —
    /// tuned live on the iPhone 17 sim (WA-IMPL-2, B-1): grabber and
    /// title fully visible, no clip, canvas exposed behind.
    static let hugHeight: CGFloat = 60
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
