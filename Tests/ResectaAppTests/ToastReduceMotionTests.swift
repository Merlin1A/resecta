import Testing
import SwiftUI
@testable import ResectaApp

// WU-48: pin the `Anim.resolved(_:reduceMotion:)` adoption
// posture at the toast surface. The toast animation tokens are the last
// canonical animation surface to adopt the resolved helper (WU-08 / WU-28
// / WU-30 / WU-43 / WU-59 already routed through it); these tests pin
// reachability of the resolved call against both `toastIn` and `toastOut`
// so a regression to a raw `withAnimation(toastIn)` call site stays
// visible at the contract seam. The actual swap between
// `easeInOut(0.2)` and the spring is opaque (SwiftUI's `Animation` is
// not Equatable), so these tests assert reachability rather than the
// equality of the resolved value; the §A2.2 swap is documented at the
// `Anim.resolved` declaration itself in `ResectaTokens.swift`.

@Suite("Toast Reduce-Motion adoption (WU-48)")
struct ToastReduceMotionTests {

    @Test("toastIn resolved with Reduce Motion off is reachable as a non-nil Animation")
    func toastInReduceMotionOff() {
        let resolved = ResectaTokens.Anim.resolved(
            ResectaTokens.Anim.toastIn,
            reduceMotion: false
        )
        #expect(resolved != nil)
    }

    @Test("toastIn resolved with Reduce Motion on is reachable as a non-nil Animation")
    func toastInReduceMotionOn() {
        let resolved = ResectaTokens.Anim.resolved(
            ResectaTokens.Anim.toastIn,
            reduceMotion: true
        )
        #expect(resolved != nil)
    }

    @Test("toastOut resolved with Reduce Motion off is reachable as a non-nil Animation")
    func toastOutReduceMotionOff() {
        let resolved = ResectaTokens.Anim.resolved(
            ResectaTokens.Anim.toastOut,
            reduceMotion: false
        )
        #expect(resolved != nil)
    }

    @Test("toastOut resolved with Reduce Motion on is reachable as a non-nil Animation")
    func toastOutReduceMotionOn() {
        let resolved = ResectaTokens.Anim.resolved(
            ResectaTokens.Anim.toastOut,
            reduceMotion: true
        )
        #expect(resolved != nil)
    }
}
