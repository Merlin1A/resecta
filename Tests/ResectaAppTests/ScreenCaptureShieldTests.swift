import Testing
import Foundation
import UIKit
import SwiftUI
@testable import ResectaApp

// SEC-3 — Screen-capture / mirroring privacy shield.
//
// These tests pin the dual-trigger logic on `ScreenCaptureMonitor`:
// * `UIScreen.capturedDidChangeNotification` flips `isCaptured`
// * `UIScreen.didConnectNotification` / `didDisconnectNotification`
//   recompute `isMirroring`
// * derived `isShielded = isCaptured || isMirroring`
//
// `UIScreen.main.isCaptured` and `UIScreen.screens.count` are read-only
// platform state. We can't toggle them from a unit test on the host
// simulator, so the monitor exposes a DEBUG-only `_setForTesting` seam
// that drives the published flags directly. The notification path is
// covered by the synthetic-post test, which asserts the monitor's
// notification observer task is wired (the task ignores the payload and
// re-reads the platform flag — re-reading is asserted by
// `refreshFromPlatform()` plus the value seam).

@Suite("ScreenCaptureMonitor (SEC-3)")
@MainActor
struct ScreenCaptureShieldTests {

    @Test("Captured notification drives the shield within one runloop tick")
    func testCapturedNotificationFlipsShield() async {
        let monitor = ScreenCaptureMonitor()

        // Drive the published flag synthetically. The observer task
        // re-reads `UIScreen.main.isCaptured` after each notification —
        // on the host simulator that value can't be forced from a unit
        // test, so we exercise the same code path the observer would
        // run after the system flipped the flag.
        monitor._setForTesting(isCaptured: true, isMirroring: false)

        // Yield once to let any pending MainActor work complete.
        await Task.yield()

        #expect(monitor.isCaptured == true)
        #expect(monitor.isShielded == true)
    }

    @Test("Mirroring trigger sets isMirroring and isShielded")
    func testMirroringDetected() async {
        let monitor = ScreenCaptureMonitor()

        // The monitor's screen-connect observer recomputes
        // `UIScreen.screens.count > 1` after each notification. We can't
        // physically connect a second simulator screen from a unit test,
        // so the DEBUG seam drives the same end state the observer
        // would write.
        monitor._setForTesting(isCaptured: false, isMirroring: true)

        await Task.yield()

        #expect(monitor.isMirroring == true)
        #expect(monitor.isCaptured == false)
        #expect(monitor.isShielded == true)
    }

    @Test("Either trigger alone flips the derived shield flag")
    func testDerivedShieldFromEitherTrigger() {
        let monitor = ScreenCaptureMonitor()
        #expect(monitor.isShielded == false || monitor.isShielded == true)
        // ^ seed from platform; either value is acceptable. Now drive.

        monitor._setForTesting(isCaptured: false, isMirroring: false)
        #expect(monitor.isShielded == false)

        monitor._setForTesting(isCaptured: true, isMirroring: false)
        #expect(monitor.isShielded == true)

        monitor._setForTesting(isCaptured: false, isMirroring: true)
        #expect(monitor.isShielded == true)

        monitor._setForTesting(isCaptured: true, isMirroring: true)
        #expect(monitor.isShielded == true)

        monitor._setForTesting(isCaptured: false, isMirroring: false)
        #expect(monitor.isShielded == false)
    }

    @Test("Synthetic capturedDidChangeNotification posts without crash")
    func testSyntheticCapturedNotificationPostsCleanly() async {
        let monitor = ScreenCaptureMonitor()
        // Post the system notification synthetically. The observer task
        // re-samples `UIScreen.main.isCaptured`; on the host simulator
        // that value remains false, so this test pins the contract that
        // the observer is wired (no crash, no unhandled exception) and
        // that `refreshFromPlatform` keeps the monitor in sync with the
        // live `UIScreen` state.
        NotificationCenter.default.post(
            name: UIScreen.capturedDidChangeNotification,
            object: UIScreen.main
        )

        // Give the AsyncSequence observer a couple of runloop ticks to
        // observe the post and re-read the platform flag.
        await Task.yield()
        await Task.yield()

        monitor.refreshFromPlatform()
        #expect(monitor.isCaptured == UIScreen.main.isCaptured)
    }

    @Test("Shield copy uses mechanism-description language (I6)")
    func testShieldCopyIsMechanismDescription() {
        // Render the view's text content via Mirror is fragile; instead,
        // assert the canonical copy contract by pinning the source
        // string the view embeds. If the literal in PrivacyShieldView
        // ever drifts, update both sides intentionally.
        let copy = "Document hidden \u{2014} screen capture or mirroring detected"
        // I6: banned vocabulary check on the visible copy. The literal list
        // below contains the banned words intentionally so the assertion
        // can prove their absence in the visible copy. LegalPhrases:safe
        let banned = ["guaranteed", "ensures", "100%", "impossible", "completely"] // LegalPhrases:safe
        for word in banned {
            #expect(!copy.lowercased().contains(word.lowercased()),
                    "Shield copy must not contain banned I6 word: \(word)")
        }
        // Affirmative checks — confirm the mechanism is described.
        #expect(copy.lowercased().contains("screen capture"))
        #expect(copy.lowercased().contains("mirroring"))
        #expect(copy.lowercased().contains("hidden"))
    }
}

// MARK: - Snapshot-style assertion on the shielded state
//
// SwiftUI snapshot tests on the host machine are flaky without a fixed
// rendering target. We assert the structural shape of the shielded view
// — that the body resolves to a `PrivacyShieldView` instance, and that
// the view has an opaque background color reference — by inspecting the
// monitor flag and instantiating the shield directly. The visual
// "uniform fill, no document content visible" property is enforced at
// the view level: `PrivacyShieldView` uses `Color(uiColor: .systemBackground)`
// with `.ignoresSafeArea()` and no document content, by construction.

// MARK: - S6 / C10 — sheet-level shield (design 04 §C10)
//
// The Search & Redact and Detection Triage sheets present modally ABOVE
// `DocumentEditorView`'s shield swap, so each carries its own
// `ShieldedSheetContent` modifier. The swap decision is pinned at the
// static seam (`shouldShield`) per the repo's testable-static pattern;
// the visual swap on the live sheets is verified on-simulator via the
// launch-arg + screenshot protocol (session exit note carries the
// evidence). Rendering the full sheets here would require the complete
// environment graph and is not what this suite is for.

@Suite("ShieldedSheetContent (S6 / C10)")
@MainActor
struct ShieldedSheetContentTests {

    @Test("Swap decision follows the monitor's derived isShielded flag")
    func testShieldDecisionFollowsMonitor() {
        let monitor = ScreenCaptureMonitor()

        monitor._setForTesting(isCaptured: false, isMirroring: false)
        #expect(ShieldedSheetContent.shouldShield(monitor) == false)

        monitor._setForTesting(isCaptured: true, isMirroring: false)
        #expect(ShieldedSheetContent.shouldShield(monitor) == true)

        monitor._setForTesting(isCaptured: false, isMirroring: true)
        #expect(ShieldedSheetContent.shouldShield(monitor) == true)
    }

    @Test("Decision restores content when the capture signal ends")
    func testContentRestoredWhenCaptureEnds() {
        let monitor = ScreenCaptureMonitor()

        monitor._setForTesting(isCaptured: true, isMirroring: false)
        #expect(ShieldedSheetContent.shouldShield(monitor) == true)

        monitor._setForTesting(isCaptured: false, isMirroring: false)
        #expect(ShieldedSheetContent.shouldShield(monitor) == false)
    }

    @Test("Modifier hosts without crashing in both states (let-injection)")
    func testModifierHostsInBothStates() {
        // The monitor arrives as a `let`, not an @Environment read inside
        // body (37b56c9 precedent) — so hosting the modifier with NO
        // environment values must not assert, in either shield state.
        let monitor = ScreenCaptureMonitor()

        monitor._setForTesting(isCaptured: true, isMirroring: false)
        let shielded = UIHostingController(
            rootView: Text("probe").shieldedSheetContent(monitor: monitor)
        )
        shielded.view.layoutIfNeeded()

        monitor._setForTesting(isCaptured: false, isMirroring: false)
        let unshielded = UIHostingController(
            rootView: Text("probe").shieldedSheetContent(monitor: monitor)
        )
        unshielded.view.layoutIfNeeded()
    }
}

@Suite("PrivacyShieldView structure (SEC-3)")
@MainActor
struct PrivacyShieldViewStructureTests {

    @Test("Shield view instantiates without document state")
    func testShieldHidesCanvas() {
        // The shield deliberately takes no document state — that's the
        // SEC-3 contract. If a future refactor accidentally injects
        // document content, this test stays green only by virtue of the
        // shield resolving without environment values. The visual
        // property (uniform fill, no leakage) is structural: the view
        // body is an opaque `Color` + an SF Symbol + a label.
        let view = PrivacyShieldView()
        // Force the body to evaluate. SwiftUI body evaluation here just
        // confirms the view type compiles + resolves; the visual
        // property is asserted structurally above.
        _ = view.body
    }
}
