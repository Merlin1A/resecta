import CoreGraphics

extension PageRasterizer {
    /// A Searchable page's text layer as it crosses the render: the
    /// surviving characters, their digest, the removal rectangles the line
    /// assembly reads, the page's fallback reason and its count of runs left
    /// out. `prepareTextLayer` writes it; after the render, the ink test and
    /// the plan's widened boxes (`dropTextLayer`) may drop the text layer,
    /// each through `drop(reason:)`, and record why.
    struct TextLayerState {
        var entries: [CharacterInfo]?
        var digest: PageFilterDigest?
        var removalRects: [CGRect]
        var fallbackReason: TextLayerDetector.FallbackReason?
        var runsLeftOut: Int = 0
        /// The entries' lines as the text path laid them out, for the writer.
        var hiddenTextLines: HiddenTextLines? = nil

        /// Drops the text layer after the render: every field the writer
        /// reads is cleared, and `reason` is recorded. The one drop both the
        /// ink test and the plan's widened boxes use, so neither keeps a
        /// field the other clears.
        mutating func drop(reason: TextLayerDetector.FallbackReason) {
            entries = nil
            removalRects = []
            digest = nil
            runsLeftOut = 0
            hiddenTextLines = nil
            fallbackReason = reason
        }
    }
}
