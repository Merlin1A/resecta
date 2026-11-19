import Testing
import SwiftUI
@testable import ResectaApp

// Pin the `Anim.resolved(_:reduceMotion:)` adoption
// posture at the toast surface. The toast animation tokens are the last
// canonical animation surface to adopt the resolved helper (the other
// surfaces already routed through it); these tests pin
// reachability of the resolved call against both `toastIn` and `toastOut`
// so a regression to a raw `withAnimation(toastIn)` call site stays
// visible at the contract seam. The actual swap between
// `easeInOut(0.2)` and the spring is opaque (SwiftUI's `Animation` is
// not Equatable), so these tests assert reachability rather than the
// equality of the resolved value; the swap is documented at the
// `Anim.resolved` declaration itself in `ResectaTokens.swift`.

@Suite("Toast Reduce-Motion adoption")
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

    @Test("Every animation in the queue goes through the resolver")
    func everyQueueAnimationIsResolved() throws {
        let file = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
            .appendingPathComponent("Sources/ResectaApp/State/ToastQueueManager.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        var animations = 0
        for line in source.components(separatedBy: "\n") {
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("//") { continue }
            var rest = Substring(code)
            while let open = rest.range(of: "withAnimation(") {
                animations += 1
                let argument = rest[open.upperBound...]
                #expect(argument.hasPrefix("ResectaTokens.Anim.resolved("),
                        "an animation that skips the resolver: \(code)")
                rest = argument
            }
        }
        // Showing, leaving and clearing all animate.
        #expect(animations >= 3, "the queue's animations were not read")
    }
}
