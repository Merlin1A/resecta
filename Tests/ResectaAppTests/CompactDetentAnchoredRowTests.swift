import Testing
import SwiftUI
@testable import ResectaApp

// WU-28 → WA/D-75: pin the compact float detent's pure-function
// height (fixed title-only hug, clamped to the available height) and
// the detent-identity contract the anchored-row mechanism relies on.
// The ScrollViewReader anchor itself is driven from a SwiftUI
// `.onChange` and cannot run in a unit test without a UI host — these
// tests cover the parts that can be isolated as values.

@Suite("Compact float detent (WU-28)")
struct CompactDetentAnchoredRowTests {
    @Test("Hug height is constant across screen heights")
    func hugHeightConstantAcrossScreens() {
        // iPhone SE (568pt) / iPhone 17 (~844pt) / iPad-class (1024pt):
        // the title-only hug does not scale with the screen.
        #expect(CompactFloatDetent.compactHeight(maxDetentValue: 568) == CompactFloatDetent.hugHeight)
        #expect(CompactFloatDetent.compactHeight(maxDetentValue: 844) == CompactFloatDetent.hugHeight)
        #expect(CompactFloatDetent.compactHeight(maxDetentValue: 1024) == CompactFloatDetent.hugHeight)
    }

    @Test("Hug constant matches the WA/D-75 title-only contract")
    func hugConstantMatchesContract() {
        #expect(CompactFloatDetent.hugHeight == 60)
    }

    @Test("Clamped to the available height when it is below the hug")
    func clampsToAvailableHeight() {
        #expect(CompactFloatDetent.compactHeight(maxDetentValue: 40) == 40)
    }

    @Test("compactFloat detent is distinct from .medium and .large")
    func compactFloatIsDistinctDetent() {
        let compact: PresentationDetent = .compactFloat
        #expect(compact != .medium)
        #expect(compact != .large)
    }

    @Test("compactFloat detent equals itself")
    func compactFloatIdentity() {
        let a: PresentationDetent = .compactFloat
        let b: PresentationDetent = .compactFloat
        #expect(a == b)
    }
}
