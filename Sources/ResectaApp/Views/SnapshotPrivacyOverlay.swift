import SwiftUI

// App-snapshot privacy overlay.
//
// Extracted from ContentView's inline `appSwitcherPlaceholder` and promoted to
// the `WindowGroup` root as a `ZStack` peer of the main content. Promoting it
// to the root is intended to cover the full window on iPad Stage Manager and
// split-view, where overlays nested inside ContentView's layout could leave
// gaps in the system snapshot.
//
// Behavior contract:
// - Opaque `Color(uiColor: .systemBackground)` fill (no transparency).
// - Branded placeholder: the `doc.text.redact` SF Symbol + "Resecta" label,
//   with `doc.viewfinder` as the fallback where the running OS has no such
//   symbol (the KI-3 guard, as on the home and EULA screens) — the overlay
//   never renders icon-less.
// - No taps, no gestures, no interactivity — the overlay must not race with
//   the system snapshotting path.
// - Reveal animation lives in the call site (ResectaApp) so this view stays
//   purely declarative.
//
// No animation change to the obscure path.
struct SnapshotPrivacyOverlay: View {
    /// KI-3: `doc.text.redact` availability is checked on the running OS;
    /// `doc.viewfinder` stands in where it resolves to nothing.
    static let symbolName: String =
        UIImage(systemName: "doc.text.redact") != nil ? "doc.text.redact" : "doc.viewfinder"

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            VStack(spacing: ResectaTokens.Spacing.sm) {
                Image(systemName: Self.symbolName)
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

// MARK: - The cover window

/// The cover's own window, above every other window of the scene. The
/// overlay inside the root `ZStack` covers the root content only — a sheet
/// presents above it, so the Search & Redact sheet or Settings → Custom
/// Terms reached the app-switcher snapshot with their text. This window
/// sits above the presentation layer (its level is above alerts), passes
/// no touches, and is shown and hidden with the same scene-phase policy.
final class SnapshotPrivacyWindowController {
    private(set) var window: UIWindow?

    /// Above `.alert`, so above every presentation in the main window.
    static let level = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)

    /// The scene the cover attaches to: the first connected window scene
    /// that is not unattached.
    static func foregroundScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState != .unattached }
    }

    func show(in scene: UIWindowScene? = foregroundScene()) {
        guard let scene else { return }
        if window == nil || window?.windowScene !== scene {
            let cover = UIWindow(windowScene: scene)
            cover.windowLevel = Self.level
            cover.rootViewController = UIHostingController(rootView: SnapshotPrivacyOverlay())
            cover.isUserInteractionEnabled = false
            cover.accessibilityViewIsModal = false
            window = cover
        }
        window?.isHidden = false
    }

    func hide() {
        window?.isHidden = true
    }
}

// MARK: - Scene-phase policy (testable seam)

/// Pure-function decision helper for the snapshot-privacy overlay's
/// scene-phase response. Extracted so tests can pin the synchronous-obscure
/// invariant without instantiating a SwiftUI scene.
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

// MARK: - Launch-hygiene policy (testable seam)

/// Pure-function decision helper for the orphaned-temp-file sweep's
/// scene-phase response. `cleanOrphanedTempFiles()` runs once at process
/// launch; this policy adds the return-to-foreground re-fire so a process
/// that stays resident across many foreground/background cycles still
/// reaps stale intermediates. Extracted beside `SnapshotPrivacyPolicy` so
/// tests can pin the phase mapping without instantiating a SwiftUI scene.
enum LaunchHygienePolicy {
    /// Whether the sweep should run for a scene-phase transition.
    /// `true` only for `.active`: the sweep is idempotent and TTL-bounded,
    /// so re-running it on every foreground return costs one directory
    /// listing. `.inactive` and `.background` are the snapshot-privacy
    /// phases — no filesystem work starts there.
    static func shouldSweepOrphans(on phase: ScenePhase) -> Bool {
        switch phase {
        case .active:
            return true
        case .inactive, .background:
            return false
        @unknown default:
            return false
        }
    }
}
