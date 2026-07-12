import Testing
import SwiftUI
@testable import ResectaApp

// WU-52 — pins the AX5 line-limit predicate that
// `InlineWarningBanner` reads via `@Environment(\.dynamicTypeSize)`. The
// predicate lifts the warning text from `.lineLimit(2)` to `.lineLimit(3)`
// at `.accessibility5` so the message stays readable at the largest
// accessibility text size (ACCESSIBILITY.md §9.3).

@Suite("InlineWarningBanner AX5 line-limit predicate (WU-52)")
struct InlineWarningLineLimitTests {

    @Test("AX5 lifts the line cap to 3")
    func ax5LiftsToThreeLines() {
        #expect(InlineWarningBanner.lineLimit(for: .accessibility5) == 3)
    }

    @Test("AX4 stays at 2 lines (boundary below AX5)")
    func ax4StaysAtTwoLines() {
        #expect(InlineWarningBanner.lineLimit(for: .accessibility4) == 2)
    }

    @Test("AX3 stays at 2 lines")
    func ax3StaysAtTwoLines() {
        #expect(InlineWarningBanner.lineLimit(for: .accessibility3) == 2)
    }

    @Test("Default (.large) stays at 2 lines")
    func defaultStaysAtTwoLines() {
        #expect(InlineWarningBanner.lineLimit(for: .large) == 2)
    }

    @Test("xSmall stays at 2 lines")
    func xSmallStaysAtTwoLines() {
        #expect(InlineWarningBanner.lineLimit(for: .xSmall) == 2)
    }

    @Test("Larger-than-AX5 sentinel collapses to AX5 in DynamicTypeSize",
          arguments: [DynamicTypeSize.accessibility5])
    func sentinelLargerSizesStillLift(size: DynamicTypeSize) {
        // DynamicTypeSize has no case larger than .accessibility5, but the
        // predicate uses `>= .accessibility5` so a future Apple addition
        // (or a synthetic value larger than .accessibility5) would still
        // lift to 3. The argument list covers .accessibility5; documents
        // the contract for future readers.
        #expect(InlineWarningBanner.lineLimit(for: size) == 3)
    }
}
