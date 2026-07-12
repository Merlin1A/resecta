import Testing
@testable import ResectaApp
@testable import RedactionEngine

// PD-5 disclosure surface: display copy for per-page fallback reasons on the
// verification-results page-mode chips and the sidebar thumbnail badges.
// Reasons render ONLY for pages whose mode fell back in a Searchable-mode
// run; secure-raster-mode runs (all-nil reasons) render none.

@Suite("Fallback Reason Display (PD-5)")
struct VerificationFallbackReasonDisplayTests {

    // nonisolated: read by the @Test(arguments:) macro expansion outside the
    // target's MainActor default isolation; an immutable constant is safe.
    private nonisolated static let allReasons: [TextLayerDetector.FallbackReason] = [
        .noExtractableText, .cjkEncodingFailure, .rtlText, .verticalText,
        .zeroSizeBounds, .unresolvedEncoding, .extractionFailed,
    ]

    @Test("Every reason has non-empty short copy",
          arguments: allReasons)
    func shortCopyNonEmpty(reason: TextLayerDetector.FallbackReason) {
        let copy = reason.shortReasonText
        #expect(!copy.isEmpty)
        // Factual register: lowercase phrase completing "Rasterized — …".
        #expect(copy.first?.isUppercase != true)
    }

    @Test("Reason copy pins (PD-5 copy pattern)")
    func reasonCopyPins() {
        #expect(TextLayerDetector.FallbackReason.rtlText.shortReasonText
                == "right-to-left text")
        #expect(TextLayerDetector.FallbackReason.verticalText.shortReasonText
                == "vertical text")
        #expect(TextLayerDetector.FallbackReason.noExtractableText.shortReasonText
                == "text could not be extracted")
        #expect(TextLayerDetector.FallbackReason.unresolvedEncoding.shortReasonText
                == "unresolved encoding")
        #expect(TextLayerDetector.FallbackReason.extractionFailed.shortReasonText
                == "extraction failed")
    }

    @Test("Chip reason row copy: page number + mode + reason")
    func chipReasonRowText() {
        let row = VerificationResultsView.fallbackReasonRowText(
            pageNumber: 2, reason: .rtlText)
        #expect(row == "Page 2 — Rasterized — right-to-left text")
    }

    @Test("Chip accessibility label carries the reason when present")
    func chipAccessibilityLabelWithReason() {
        let label = VerificationResultsView.pageChipAccessibilityLabel(
            pageNumber: 3, mode: .secureRasterization, reason: .unresolvedEncoding)
        #expect(label == "Page 3, Rasterized — unresolved encoding")
    }

    @Test("Chip accessibility label unchanged without a reason")
    func chipAccessibilityLabelWithoutReason() {
        let searchable = VerificationResultsView.pageChipAccessibilityLabel(
            pageNumber: 1, mode: .searchableRedaction, reason: nil)
        #expect(searchable == "Page 1, Searchable")
        let secure = VerificationResultsView.pageChipAccessibilityLabel(
            pageNumber: 2, mode: .secureRasterization, reason: nil)
        #expect(secure == "Page 2, Rasterized")
    }

    @Test("Thumbnail badge text: reasoned for fallback pages, plain otherwise")
    func thumbnailBadgeText() {
        #expect(PageThumbnailList.badgeText(
                    mode: .secureRasterization, reason: .verticalText)
                == "Rasterized — vertical text")
        #expect(PageThumbnailList.badgeText(
                    mode: .secureRasterization, reason: nil)
                == "Rasterized")
        #expect(PageThumbnailList.badgeText(
                    mode: .searchableRedaction, reason: nil)
                == "Searchable")
    }

    @Test("hasAnyFallbackReason gates the reason surface")
    func hasAnyFallbackReasonGate() {
        // Secure-raster-mode run / all-searchable run: all nil → no surface.
        let allNil: [TextLayerDetector.FallbackReason?] = [nil, nil, nil]
        #expect(allNil.hasAnyFallbackReason == false)
        // Empty (no per-page record at all) → no surface.
        let empty: [TextLayerDetector.FallbackReason?] = []
        #expect(empty.hasAnyFallbackReason == false)
        // Mixed Searchable-mode run with one fallback → surface renders.
        let mixed: [TextLayerDetector.FallbackReason?] = [nil, .rtlText, nil]
        #expect(mixed.hasAnyFallbackReason == true)
    }

    @Test("Report defaults to an empty reasons array (older construction sites)")
    func reportDefaultsEmptyReasons() {
        let report = VerificationReport(
            layers: [], overallStatus: .pass, durationSeconds: 0,
            perPageModes: [.searchableRedaction, .secureRasterization])
        #expect(report.perPageFallbackReasons.isEmpty)
        #expect(report.perPageFallbackReasons.hasAnyFallbackReason == false)
    }
}
