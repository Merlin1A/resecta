import Testing
import SwiftUI
@testable import ResectaApp

// WU-28: pin the compact float detent's pure-function
// math (110pt floor + 0.15 fraction) and the detent-identity contract
// the anchored-row mechanism relies on. The ScrollViewReader anchor
// itself is driven from a SwiftUI `.onChange` and cannot run in a
// unit test without a UI host — these tests cover the parts that
// can be isolated as values.

@Suite("Compact float detent (WU-28)")
struct CompactDetentAnchoredRowTests {
    @Test("Floor enforced when 0.15 × maxDetentValue is below 110pt")
    func floorEnforcedOnSmallScreens() {
        // iPhone SE (568pt): 0.15 × 568 = 85.2pt → floor wins.
        #expect(CompactFloatDetent.compactHeight(maxDetentValue: 568) == 110)
    }

    @Test("Fraction(0.15) used when above the 110pt floor")
    func fractionUsedOnLargeScreens() {
        // iPhone 17 (~844pt): 0.15 × 844 = 126.6pt → above floor.
        let result = CompactFloatDetent.compactHeight(maxDetentValue: 844)
        #expect(abs(result - 126.6) < 0.001)
    }

    @Test("iPad-class height scales proportionally")
    func iPadFractionScales() {
        // iPad-class 1024pt: 0.15 × 1024 = 153.6pt.
        let result = CompactFloatDetent.compactHeight(maxDetentValue: 1024)
        #expect(abs(result - 153.6) < 0.001)
    }

    @Test("Boundary at floor crossover (~733pt)")
    func boundaryValue() {
        // 0.15 × X = 110 → X ≈ 733.33; just below returns floor.
        #expect(CompactFloatDetent.compactHeight(maxDetentValue: 733) == 110)
        // Just above returns the fraction.
        let above = CompactFloatDetent.compactHeight(maxDetentValue: 734)
        #expect(above > 110)
    }

    @Test("Floor + fraction constants match D-03 contract")
    func constantsMatchSpec() {
        #expect(CompactFloatDetent.minimumHeight == 110)
        #expect(CompactFloatDetent.fraction == 0.15)
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
