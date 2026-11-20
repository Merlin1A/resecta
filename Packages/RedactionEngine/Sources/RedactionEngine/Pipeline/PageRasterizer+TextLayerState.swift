import CoreGraphics

extension PageRasterizer {
    /// A Searchable page's text layer as it crosses the render: the
    /// surviving characters, their digest, the removal rectangles the line
    /// assembly reads, the page's fallback reason and its count of runs left
    /// out. `prepareTextLayer` writes it; after the render, only the ink test
    /// changes it: it may drop the text layer and record why.
    struct TextLayerState {
        var entries: [CharacterInfo]?
        var digest: PageFilterDigest?
        var removalRects: [CGRect]
        var fallbackReason: TextLayerDetector.FallbackReason?
        var runsLeftOut: Int = 0
        /// The entries' lines as the text path laid them out, for the writer.
        var hiddenTextLines: HiddenTextLines? = nil
    }
}
