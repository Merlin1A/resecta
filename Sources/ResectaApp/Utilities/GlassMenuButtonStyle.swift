import SwiftUI

// D15 / KI-6: Workaround for iOS 26.1 regression where Menu inside a
// GlassEffectContainer breaks morphing animation.
// WORKAROUND: Remove when Apple fixes this regression (file radar).
// Apply this style to all Menu elements rendered inside glass containers
// (e.g., toolbar menus, action bar menus).

/// A button style that applies glass appearance to Menu triggers without
/// relying on GlassEffectContainer's automatic morphing, which is broken
/// in iOS 26.1 for Menu elements.
struct GlassMenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                .regularMaterial,
                in: Capsule()
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

extension ButtonStyle where Self == GlassMenuButtonStyle {
    /// Glass-styled button for use with Menu triggers inside glass containers.
    /// Workaround for iOS 26.1 GlassEffectContainer morphing regression (D15/KI-6).
    static var glassMenu: GlassMenuButtonStyle { GlassMenuButtonStyle() }
}
