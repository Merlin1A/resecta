import RedactionEngine

// UI display copy for TextLayerDetector.FallbackReason (PD-5). Centralized
// here following the same pattern as PipelineMode+Display.swift. Shown on the
// verification-results page-mode chips and the sidebar thumbnail badges for
// pages that fell back to Secure Rasterization in a Searchable-mode run.

extension TextLayerDetector.FallbackReason {
    /// Short factual phrase completing "Rasterized — …". States what the
    /// page's text layer looked like, not a verdict or a promise.
    var shortReasonText: String {
        switch self {
        case .noExtractableText: "text could not be extracted"
        case .cjkEncodingFailure: "unsupported text encoding"
        case .rtlText: "right-to-left text"
        case .verticalText: "vertical text"
        case .zeroSizeBounds: "text position data unavailable"
        case .unresolvedEncoding: "unresolved encoding"
        case .extractionFailed: "extraction failed"
        }
    }
}

extension Array where Element == TextLayerDetector.FallbackReason? {
    /// True when at least one page carries a fallback reason — i.e. this was
    /// a Searchable-mode run where some page's mode fell back. Secure-raster
    /// runs and all-searchable runs are all-nil and render no reasons.
    var hasAnyFallbackReason: Bool {
        contains(where: { $0 != nil })
    }
}
