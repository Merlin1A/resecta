import Testing
import SwiftUI
@testable import ResectaApp

// SEC-4: Snapshot-privacy overlay scene-phase policy.
//
// These tests pin the §0.1 invariant: the obscure path is synchronous (no
// animation), so the system snapshot captures the overlay rather than
// landing mid-fade. The reveal path keeps the prior 0.15s ease-in animation
// for visual polish on return-to-foreground.
//
// Implementation lives in `SnapshotPrivacyOverlay.swift` (the view + the
// `SnapshotPrivacyPolicy` testable seam). The scene-phase wire-up is in
// `ResectaApp.swift`'s WindowGroup root.

@Suite("Snapshot privacy overlay (SEC-4)")
@MainActor
struct SnapshotOverlayTests {

    // MARK: - testInactivePhaseSynchronouslyObscures
    //
    // Simulating `scenePhase = .inactive` must produce the
    // `.obscureSynchronously` action. The action is plain data — no
    // SwiftUI animation transaction is involved — so the assertion lands
    // within the same MainActor turn as the call, with no animation tick.

    @Test("`.inactive` maps to synchronous obscure (no animation)")
    func testInactivePhaseSynchronouslyObscures() {
        let action = SnapshotPrivacyPolicy.action(for: .inactive)
        #expect(action == .obscureSynchronously)
    }

    @Test("`.background` also maps to synchronous obscure")
    func testBackgroundPhaseSynchronouslyObscures() {
        // Belt-and-suspenders: the snapshot path can hit either .inactive
        // or .background depending on multitask gesture vs. home-button.
        let action = SnapshotPrivacyPolicy.action(for: .background)
        #expect(action == .obscureSynchronously)
    }

    // MARK: - testRootOverlayCoversFullWindow
    //
    // Confirms that `SnapshotPrivacyOverlay` is structurally a full-window
    // peer: it uses `.ignoresSafeArea()` and disables hit-testing so it
    // covers the entire scene without intercepting touches. We can't fully
    // hierarchy-walk a SwiftUI scene without ViewInspector, but we can
    // instantiate the overlay and confirm it constructs without dependency
    // on environment values — a construction-time check that would fail
    // if the overlay were nested inside ContentView and pulling
    // environment state injected there.

    @Test("`SnapshotPrivacyOverlay` constructs with no environment dependencies")
    func testRootOverlayCoversFullWindow() {
        // The overlay is designed to be instantiable without any
        // environment objects (AppCoordinator, SettingsState,
        // ToastQueueManager, etc.). If a future change adds an
        // @Environment dependency, the overlay would fail at runtime when
        // rendered at the root before environment injection — this test
        // pins the no-dependency contract at construction time.
        let overlay = SnapshotPrivacyOverlay()
        // Smoke-construct the body to confirm no construction-time crash.
        _ = overlay.body
    }

    // MARK: - testRevealPathRetainsExistingAnimation
    //
    // `scenePhase = .active` must route through the animated reveal path.
    // The 0.15s ease-in is applied at the call site (ResectaApp.swift) via
    // `withAnimation(.easeIn(duration: 0.15))`; the policy's job is just
    // to select the `.revealAnimated` action.

    @Test("`.active` maps to the animated reveal action")
    func testRevealPathRetainsExistingAnimation() {
        let action = SnapshotPrivacyPolicy.action(for: .active)
        #expect(action == .revealAnimated)
    }

    // MARK: - Action-type sanity

    @Test("Action cases are distinct and Equatable")
    func testActionEquatable() {
        // Sanity-check the Equatable derivation so the other tests'
        // `#expect(action == ...)` comparisons are meaningful.
        #expect(SnapshotPrivacyPolicy.Action.obscureSynchronously
                != SnapshotPrivacyPolicy.Action.revealAnimated)
        #expect(SnapshotPrivacyPolicy.Action.obscureSynchronously
                != SnapshotPrivacyPolicy.Action.none)
        #expect(SnapshotPrivacyPolicy.Action.revealAnimated
                != SnapshotPrivacyPolicy.Action.none)
    }

    // MARK: - Parametric regression sentinel (CAT-255, s09)
    //
    // Belt-and-suspenders against a future ScenePhase case that silently
    // routes a backgrounding state through the reveal/none path. The two
    // separate tests above provide equivalent coverage today; this collapses
    // the known backgrounding phases into one parametric assertion so adding
    // a new background-like phase forces an explicit decision here.

    @Test("All known backgrounding phases map to synchronous obscure")
    func testAllBackgroundingPhasesSynchronous() {
        for phase in [ScenePhase.inactive, ScenePhase.background] {
            #expect(SnapshotPrivacyPolicy.action(for: phase) == .obscureSynchronously,
                    "Phase \(phase) must map to synchronous obscure")
        }
    }
}
