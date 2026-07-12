import SwiftUI

// SEC-4: App-snapshot privacy overlay.
//
// Extracted from ContentView's inline `appSwitcherPlaceholder` and promoted to
// the `WindowGroup` root as a `ZStack` peer of the main content. Promoting it
// to the root is intended to cover the full window on iPad Stage Manager and
// split-view, where overlays nested inside ContentView's layout could leave
// gaps in the system snapshot.
//
// Behavior contract (UI_UX §7.1):
// - Opaque `Color(uiColor: .systemBackground)` fill (no transparency).
// - Branded placeholder: `doc.text.redact` SF Symbol + "Resecta" label.
// - No taps, no gestures, no interactivity — the overlay must not race with
//   the system snapshotting path.
// - Reveal animation lives in the call site (ResectaApp) so this view stays
//   purely declarative.
//
// See also SEC-4 and §0.1 (no animation change to the obscure path).
struct SnapshotPrivacyOverlay: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            VStack(spacing: ResectaTokens.Spacing.sm) {
                Image(systemName: "doc.text.redact")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Resecta")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .ignoresSafeArea()
        // Accessibility: keep VoiceOver silent on the overlay — it's a
        // transient system-snapshot mask, not a user-facing surface.
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

// MARK: - Scene-phase policy (testable seam)

/// Pure-function decision helper for the snapshot-privacy overlay's
/// scene-phase response. Extracted so tests can pin the synchronous-obscure
/// invariant (§0.1) without instantiating a SwiftUI scene.
enum SnapshotPrivacyPolicy {
    /// How the overlay should respond to a scene-phase transition.
    enum Action: Equatable {
        /// Obscure immediately, with no animation. Used on `.inactive` and
        /// `.background` so the system snapshot captures the overlay, not
        /// document content. The synchronous path is load-bearing — adding
        /// any animation here would let the snapshot land mid-fade.
        case obscureSynchronously
        /// Reveal the content. The 0.15s ease-in animation is the only
        /// animated path in the overlay flow.
        case revealAnimated
        /// No change. Reserved for unknown phases.
        case none
    }

    /// Maps a new `ScenePhase` to the overlay action.
    /// - Parameter newPhase: the phase reported by SwiftUI's `scenePhase`
    ///   environment value.
    static func action(for newPhase: ScenePhase) -> Action {
        switch newPhase {
        case .background, .inactive:
            return .obscureSynchronously
        case .active:
            return .revealAnimated
        @unknown default:
            return .none
        }
    }
}
