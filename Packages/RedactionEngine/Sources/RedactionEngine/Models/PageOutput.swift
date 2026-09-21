import CoreGraphics
import Foundation

/// Per-page output from the redaction pipeline.
public struct PageOutput: Sendable {
    public let image: CGImage            // CGImage is Sendable
    public let size: CGSize
    /// Surviving text entries for invisible layer (Searchable Redaction mode only).
    /// Nil for Secure Rasterization mode.
    public let textLayerEntries: [CharacterInfo]?
    /// Redaction rectangles in PDF-point-space: the text-layer line
    /// assembly never bridges a gap across one. Empty for
    /// Secure Rasterization pages and pages without regions.
    public let redactionRectsInPoints: [CGRect]

    public init(image: CGImage, size: CGSize,
                textLayerEntries: [CharacterInfo]?,
                redactionRectsInPoints: [CGRect] = []) {
        self.image = image
        self.size = size
        self.textLayerEntries = textLayerEntries
        self.redactionRectsInPoints = redactionRectsInPoints
    }
}

/// Wrapper returned by PageRasterizer.rasterize() containing both the page output
/// and the optional filter digest. The coordinator stores the digest separately
/// and passes pageOutput to the PDFStreamReconstructor.
public struct RasterizeResult: Sendable {
    public let pageOutput: PageOutput
    /// Lightweight digest for Layer 7 character count cross-check.
    /// Nil for Secure Rasterization pages.
    public let filterDigest: PageFilterDigest?
    /// The EFFECTIVE reason this page rasterized in a Searchable-mode
    /// run — the pre-flight reason carried in from `PDFPageData`, or the
    /// runtime reason when the fallback happened inside `rasterize()`
    /// (extraction threw, replacement-character ratio, empty extraction).
    /// Nil for pages that kept searchable mode and for secure-raster-mode
    /// runs. Non-nil implies `filterDigest == nil`.
    public let fallbackReason: TextLayerDetector.FallbackReason?

    public init(pageOutput: PageOutput, filterDigest: PageFilterDigest?,
                fallbackReason: TextLayerDetector.FallbackReason? = nil) {
        self.pageOutput = pageOutput
        self.filterDigest = filterDigest
        self.fallbackReason = fallbackReason
    }
}

/// Lightweight per-page digest retaining only the integer counts and boundary
/// character metadata needed by the verification engine (Layer 7 cross-check).
/// The full FilterResult (and its [CharacterInfo] array) is released when the
/// page's autoreleasepool exits.
public struct PageFilterDigest: Sendable {
    public let pageIndex: Int
    public let extractedCount: Int
    public let excludedCount: Int
    public let survivingCount: Int
    public let boundaryCharacters: [BoundaryCharacterInfo]
    /// SHA-256 over the surviving character sequence in canonical order.
    /// Layer 9 (Character Lineage) recomputes the same hash from output PDFKit
    /// composed-character iteration and reports mismatch. Two distinct
    /// "empty" values: a page whose filter kept NO survivor carries the
    /// empty-set digest (`SandwichVerification.emptyLineageDigest`, the
    /// SHA-256 of zero updates), which the output walk of a textless page
    /// reproduces; an empty `Data()` means the digest was constructed by a
    /// caller that pre-dates the lineage field ("no lineage recorded" —
    /// Layer 9 passes without comparing).
    public let lineageHash: Data
    /// Count of surviving characters whose text is NOT lineage-whitespace —
    /// the Layer 7 comparison domain. PDFKit synthesizes inter-run
    /// whitespace on the output side and the extraction stream legitimately
    /// carries word-spacing entries, so only the non-whitespace count is
    /// comparable across the two views. Callers that omit it get
    /// `survivingCount` (correct wherever the surviving set carries no
    /// whitespace entries).
    public let survivingNonWhitespaceCount: Int
    /// Of `excludedCount`, the survivors the writer-side drawn-cell rule
    /// dropped after the filter (`TextLayerReconstructor.validateSurvivors`):
    /// glyphs the filter kept on their source box but the band layout would
    /// have drawn centred inside a redaction region. 0 for a digest taken
    /// before the rule ran, or by a caller that pre-dates it.
    public let drawnCellRuleExcludedCount: Int

    public init(pageIndex: Int, extractedCount: Int, excludedCount: Int,
                survivingCount: Int, boundaryCharacters: [BoundaryCharacterInfo],
                lineageHash: Data = Data(),
                survivingNonWhitespaceCount: Int? = nil,
                drawnCellRuleExcludedCount: Int = 0) {
        self.pageIndex = pageIndex
        self.extractedCount = extractedCount
        self.excludedCount = excludedCount
        self.survivingCount = survivingCount
        self.boundaryCharacters = boundaryCharacters
        self.lineageHash = lineageHash
        self.survivingNonWhitespaceCount = survivingNonWhitespaceCount ?? survivingCount
        self.drawnCellRuleExcludedCount = drawnCellRuleExcludedCount
    }
}

/// Boundary character marker for Layer 7 verification. Only the COUNT of
/// near-a-redaction-edge survivors is load-bearing (`VerificationEngine`
/// sums `.boundaryCharacters.count` across pages); the per-character
/// identity/bounds/distance payload this type used to carry was never read
/// anywhere, so the type carries no fields — its presence in the array is
/// the signal.
public struct BoundaryCharacterInfo: Sendable {
    public init() {}
}
