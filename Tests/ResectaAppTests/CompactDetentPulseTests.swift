import Testing
import SwiftUI
@testable import ResectaApp

// WU-59: pin the per-sheet-session pulse predicate so
// the first compact-drop fires once, subsequent compact-drops in the
// same session stay silent, and Reduce Motion suppresses the pulse
// entirely. The view-side wiring (scaleEffect on the grabber capsule
// + deferred reset) is UI-only and deferred to manual on-device
// verification per CLAUDE.md.

@Suite("Compact-detent grabber pulse (WU-59)")
struct CompactDetentPulseTests {
    @Test("First compact-drop fires the pulse")
    func firstDropPulses() {
        let result = CompactFloatDetent.shouldPulseGrabber(
            transitioningTo: .compactFloat,
            hasAlreadyPulsed: false,
            reduceMotion: false
        )
        #expect(result == true)
    }

    @Test("Subsequent compact-drops within the same sheet session do NOT pulse")
    func subsequentDropsSilent() {
        let result = CompactFloatDetent.shouldPulseGrabber(
            transitioningTo: .compactFloat,
            hasAlreadyPulsed: true,
            reduceMotion: false
        )
        #expect(result == false)
    }

    @Test("Reduce Motion suppresses the pulse")
    func reduceMotionSuppresses() {
        let result = CompactFloatDetent.shouldPulseGrabber(
            transitioningTo: .compactFloat,
            hasAlreadyPulsed: false,
            reduceMotion: true
        )
        #expect(result == false)
    }

    @Test("Reduce Motion + already-pulsed combine to suppress")
    func reduceMotionAndAlreadyPulsed() {
        let result = CompactFloatDetent.shouldPulseGrabber(
            transitioningTo: .compactFloat,
            hasAlreadyPulsed: true,
            reduceMotion: true
        )
        #expect(result == false)
    }

    @Test("Transitions to .medium do NOT pulse")
    func mediumTransitionSkips() {
        let result = CompactFloatDetent.shouldPulseGrabber(
            transitioningTo: .medium,
            hasAlreadyPulsed: false,
            reduceMotion: false
        )
        #expect(result == false)
    }

    @Test("Transitions to .large do NOT pulse")
    func largeTransitionSkips() {
        let result = CompactFloatDetent.shouldPulseGrabber(
            transitioningTo: .large,
            hasAlreadyPulsed: false,
            reduceMotion: false
        )
        #expect(result == false)
    }

    @Test("attentionPulse animation token is reachable")
    func attentionPulseTokenExists() {
        // Smoke test — confirms the static token is reachable and typed
        // as a SwiftUI `Animation`. The internal value
        // `.easeInOut(duration: 0.45).repeatCount(1, autoreverses: true)`
        // is opaque (no Equatable / property accessors) so we can only
        // assert reachability + type, not equality with a literal.
        let _: Animation = ResectaTokens.Anim.attentionPulse
    }

    @Test("Per-sheet-session reset re-enables the pulse")
    func resetReEnablesPulse() {
        // After a sheet dismiss, `hasPulsedGrabberThisSession` resets
        // to false (via .onDisappear + @State destruction); next
        // session's first compact-drop must pulse again. This pins
        // the [RR-16] reset contract at the predicate seam.
        let beforeReset = CompactFloatDetent.shouldPulseGrabber(
            transitioningTo: .compactFloat,
            hasAlreadyPulsed: true,
            reduceMotion: false
        )
        #expect(beforeReset == false)

        let afterReset = CompactFloatDetent.shouldPulseGrabber(
            transitioningTo: .compactFloat,
            hasAlreadyPulsed: false,
            reduceMotion: false
        )
        #expect(afterReset == true)
    }
}
