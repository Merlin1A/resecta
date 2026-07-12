import CoreGraphics
import Foundation

// See ARCH §2.3 for PageOutput, RasterizeResult, PageFilterDigest,
// and BoundaryCharacterInfo definitions.

/// Per-page output from the redaction pipeline.
/// Canonical definition — also reproduced in ENGINE §5.1 for context.
public struct PageOutput: Sendable {
    public let image: CGImage            // CGImage is Sendable
    public let size: CGSize
    /// Surviving text entries for invisible layer (Searchable Redaction mode only).
    /// Nil for Secure Rasterization mode.
    public let textLayerEntries: [CharacterInfo]?
    /// Redaction rectangles in PDF-point-space (J-12): the text-layer line
    /// assembly never bridges a gap across one (ENGINE §5C.1). Empty for
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
    /// PD-5: the EFFECTIVE reason this page rasterized in a Searchable-mode
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
/// page's autoreleasepool exits. See ENGINE §5B.2.
public struct PageFilterDigest: Sendable {
    public let pageIndex: Int
    public let extractedCount: Int
    public let excludedCount: Int
    public let survivingCount: Int
    public let boundaryCharacters: [BoundaryCharacterInfo]
    /// SHA-256 over the surviving character sequence in filter iteration order.
    /// Layer 9 (Character Lineage) recomputes the same hash from output PDFKit
    /// composed-character iteration and reports mismatch. Empty Data() when the
    /// filter ran on a page with no surviving characters or when the digest was
    /// constructed by a caller that pre-dates the lineage field. See ENGINE §6.6
    /// SVT-2.
    public let lineageHash: Data
    /// Count of surviving characters whose text is NOT lineage-whitespace —
    /// the Layer 7 comparison domain (VH-1). PDFKit synthesizes inter-run
    /// whitespace on the output side and the extraction stream legitimately
    /// carries word-spacing entries, so only the non-whitespace count is
    /// comparable across the two views. Callers that omit it get
    /// `survivingCount` (correct wherever the surviving set carries no
    /// whitespace entries).
    public let survivingNonWhitespaceCount: Int

    public init(pageIndex: Int, extractedCount: Int, excludedCount: Int,
                survivingCount: Int, boundaryCharacters: [BoundaryCharacterInfo],
                lineageHash: Data = Data(),
                survivingNonWhitespaceCount: Int? = nil) {
        self.pageIndex = pageIndex
        self.extractedCount = extractedCount
        self.excludedCount = excludedCount
        self.survivingCount = survivingCount
        self.boundaryCharacters = boundaryCharacters
        self.lineageHash = lineageHash
        self.survivingNonWhitespaceCount = survivingNonWhitespaceCount ?? survivingCount
    }
}

/// Boundary character metadata for Layer 7 verification.
/// Lightweight alternative to full CharacterInfo (~64 bytes → ~24 bytes).
/// See ENGINE §5B.2.
public struct BoundaryCharacterInfo: Sendable {
    public let character: String
    public let bounds: CGRect
    public let distanceToEdge: CGFloat

    public init(character: String, bounds: CGRect, distanceToEdge: CGFloat) {
        self.character = character
        self.bounds = bounds
        self.distanceToEdge = distanceToEdge
    }
}
