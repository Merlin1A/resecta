import SwiftUI

// REV-01 (device-review-uifix packet §7.2, RB-66/RB-67): custom
// interaction styles for the search sheet's redrawn compact chrome.
//
// Why custom: the system `.bordered` style cannot draw a small circle
// under an outer layout floor — it wraps the WHOLE (floored) label in
// its wash, which is exactly the ~64pt slab REV-01 ruled not
// shippable. The chrome therefore moves into each button's LABEL
// (drawn Ø44 circle / 36pt capsule, floored to
// `ResectaTokens.TouchTarget.minimum` with the floor placed AFTER the
// background — RB-67's layout-floor law), and these styles supply
// only the interaction states the system styles used to provide.

/// States for the Ø44 drawn-circle icon buttons (saved-searches
/// bookmark, the two ↻ rescan controls, and the result-nav chevron
/// pair — packet §7.2 items 3–4). Pressed = wash darken (≈0.7
/// composite via a whole-label dim, the system pressed treatment) +
/// 0.96 scale; disabled = 0.4 opacity on the whole control — the two
/// states stay visibly distinct (RB-66).
struct CircularIconButtonStyle: ButtonStyle {
    /// Drawn circle diameter (board value, RB-66).
    static let diameter: CGFloat = 44
    /// SF glyph point size inside the circle (board value, RB-66).
    static let glyphPointSize: CGFloat = 18
    /// Circle wash — matched by eye to the retired `.bordered`
    /// small-control background on both appearances.
    static let wash = Color(.tertiarySystemFill)

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(stateOpacity(isPressed: configuration.isPressed))
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
    }

    private func stateOpacity(isPressed: Bool) -> Double {
        guard isEnabled else { return ResectaTokens.Opacity.disabled }
        return isPressed ? 0.7 : 1.0
    }
}

extension ButtonStyle where Self == CircularIconButtonStyle {
    static var circularIcon: CircularIconButtonStyle { .init() }
}

/// Pressed/disabled states for the custom prominent Select All
/// capsule (packet §7.2 item 5) — fill darken via a whole-label dim,
/// no scale, matching the system `.borderedProminent` pressed
/// treatment the custom chrome replaces.
struct CapsulePressButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled
                ? (configuration.isPressed ? 0.7 : 1.0)
                : ResectaTokens.Opacity.disabled)
    }
}

extension ButtonStyle where Self == CapsulePressButtonStyle {
    static var capsulePress: CapsulePressButtonStyle { .init() }
}
