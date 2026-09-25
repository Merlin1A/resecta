import SwiftUI

// Compact float detent for the Search & Redact sheet.
//
// The compact detent hugs the glanceable handle — the grabber capsule,
// the walk's match line (kind · page · text) and one row of full-size
// controls: the per-item Apply capsule and the ‹ › cluster with its
// counter (`compactFloatStrip`, `+CompactStrip.swift`) — so the document
// stays the primary surface while the sheet is parked and the result
// walk, with its one-tap mark, continues from the handle. Height is a
// fixed hug clamped to the available height, lifted at accessibility
// type sizes for the taller line.
//
// Two presentation regimes, measured on the iPhone 17 simulator (iOS 26):
// up to a hug of 100 the system draws the parked sheet as a floating
// capsule whose scale grows with the hug (0.877 at 80 → 0.957 at 100,
// the grabber hidden from ≈94); from 101 it draws an attached sheet at
// 0.96 with an 8-pt inset, the bottom safe area added under the content
// and the grabber visible. The hug below sits in the attached regime,
// where a 46-pt control frame shows at 44.2 pt — the effective floor
// holds with the shared token. `CompactDetentAnchoredRowTests` pins the
// regime and the hug arithmetic.
//
// History: 60 (the title-only handle) → 72 (the ‹ › cluster) → 80 (the
// per-item Apply) → 108 (the match line + full-size controls; 120 at
// accessibility sizes).
//
// The pure-function `compactHeight(maxDetentValue:accessibilitySize:)`
// helper isolates the math from the SwiftUI runtime so tests can verify
// the hug + clamp contract without constructing a `Context` value (the
// type has no public initializer).

struct CompactFloatDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        // `Context` is `@dynamicMemberLookup` over `EnvironmentValues`,
        // so the detent reads the type size the sheet is laid out at.
        compactHeight(
            maxDetentValue: context.maxDetentValue,
            accessibilitySize: context.dynamicTypeSize.isAccessibilitySize
        )
    }

    /// Fixed hug for the type-size class, never exceeding the available height.
    static func compactHeight(maxDetentValue: CGFloat, accessibilitySize: Bool = false) -> CGFloat {
        min(accessibilitySize ? accessibilityHugHeight : hugHeight, maxDetentValue)
    }

    /// The ONE hug value the chrome outside the sheet reads — the
    /// page-bar / parked-canvas inset and the toast clearance, through
    /// `ParkedChromeLayout` — keyed to the type size so those consumers
    /// move with the hug the detent reports.
    static func hug(for size: DynamicTypeSize) -> CGFloat {
        size.isAccessibilitySize ? accessibilityHugHeight : hugHeight
    }

    /// Grabber inset + the match line + the 4-pt gap + the controls
    /// row's 46-pt layout floor + breathing room (15 + 24 + 4 + 46 + 19).
    /// Stays ≥ 101: the attached regime (see the file comment).
    static let hugHeight: CGFloat = 108
    /// The hug at accessibility type sizes: the match line grows to 36
    /// (the line is capped at `.accessibility2`), the row keeps its
    /// floor (15 + 36 + 4 + 46 + 19). Ceiling 120.
    static let accessibilityHugHeight: CGFloat = 120
    /// The grabber capsule's inset above the content (6 + 5 + 4).
    static let grabberInset: CGFloat = 15
    /// The match line's reserved height (`ResectaTokens.Spacing.lg`) —
    /// reserved in every state so the layout never jumps.
    static let matchLineHeight: CGFloat = 24
    /// The match line's reserved height at accessibility type sizes.
    static let accessibilityMatchLineHeight: CGFloat = 36
    /// Breathing room under the controls row.
    static let bottomInset: CGFloat = 19
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
