import SwiftUI

// Compact float detent for the Search & Redact sheet.
//
// Replaces the prior fixed `.height(120)` floor with a fraction-based
// detent that scales with screen height (15%) but never drops below
// 110pt — keeping the search bar + nav controls + first result row
// visible on small screens. On a typical iPhone 17 (844pt), the
// detent resolves to ~127pt; on a smaller iPhone SE 1 (568pt) the
// 110pt floor kicks in.
//
// The pure-function `compactHeight(maxDetentValue:)` helper isolates
// the math from the SwiftUI runtime so tests can verify the floor +
// fraction contract without constructing a `Context` value (the type
// has no public initializer).

struct CompactFloatDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        compactHeight(maxDetentValue: context.maxDetentValue)
    }

    /// 110pt floor; fraction(0.15) of the available height when larger.
    static func compactHeight(maxDetentValue: CGFloat) -> CGFloat {
        max(minimumHeight, maxDetentValue * fraction)
    }

    static let minimumHeight: CGFloat = 110
    static let fraction: CGFloat = 0.15
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
