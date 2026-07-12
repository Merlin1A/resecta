import Testing
import SwiftUI
@testable import ResectaApp

// Phase 4 redesign — pin the `columnMaxWidth` iPad row-width cap so
// `VerificationProgressView`'s regular-size-class layout can't silently
// drift back to "sparse iPad" mode. Mirrors Session 1's
// `DocumentEditorAutoReturnHomeTests` and Session 2's
// `VerificationResultsAutoExpandTests` static-helper pattern.
// See the Phase 4 redesign "iPad shimmer row width (locked)".

@Suite("Verification progress column width gate (Phase 4)")
@MainActor
struct VerificationProgressColumnWidthTests {

    @Test("Regular size class → panelMaxWidthRegular (420pt)")
    func regularReturnsRegularWidth() {
        #expect(
            VerificationProgressView.columnMaxWidth(for: .regular)
                == ResectaTokens.BrandedSurface.panelMaxWidthRegular
        )
    }

    @Test("Compact size class → panelMaxWidthCompact (380pt)")
    func compactReturnsCompactWidth() {
        #expect(
            VerificationProgressView.columnMaxWidth(for: .compact)
                == ResectaTokens.BrandedSurface.panelMaxWidthCompact
        )
    }

    @Test("Nil size class → compact width (defensive)")
    func nilReturnsCompactWidth() {
        #expect(
            VerificationProgressView.columnMaxWidth(for: nil)
                == ResectaTokens.BrandedSurface.panelMaxWidthCompact
        )
    }
}
