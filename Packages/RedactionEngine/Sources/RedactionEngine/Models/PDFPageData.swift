import PDFKit
import CoreGraphics

// See ARCH §2.3 for PDFPageData, SendablePDFDocument, and SendablePDFPage.

/// Wrapper providing the engine with all per-page data needed for processing.
/// Bridges the app target (which holds the PDFDocument) and the engine package
/// (which processes individual pages without knowing the document lifecycle).
///
/// SAFETY: pages are rasterized with bounded parallelism, so
/// each PDFPageData is consumed by one `@concurrent rasterize()` call while
/// several such calls run concurrently against pages of the same source
/// document. To keep that path off the shared PDFKit object graph, the page
/// geometry (`cropBoxBounds`), the Core Graphics page (`cgPage`), and `hasText`
/// are pre-extracted SERIALLY at build time (`PipelineCoordinator.buildPDFPageData`);
/// the concurrent render path is then CG-only (`renderPageFromCGPage`). The live
/// `PDFPage` (`page`) is read inside a concurrent task only by the read-only
/// dimension pre-flight (`validatePage`) and searchable text extraction
/// (`extractCharacters`) — undocumented-but-empirically-validated paths covered
/// by `PDFKitConcurrencyStressTests`. `@unchecked Sendable`: `PDFPage` /
/// `CGPDFPage` are not Sendable; this struct asserts the access discipline above.
public struct PDFPageData: @unchecked Sendable {
    public let page: PDFPage
    public let pageIndex: Int
    public let regions: [RedactionRegion]
    public let fillColor: FillColor
    public let targetDPI: Int
    /// The pipeline mode for this page (may differ from global if per-page fallback triggered).
    public let pipelineMode: PipelineMode
    /// From page.rotation — for coordinate functions.
    public let rotation: Int
    /// Doc-level OCG hidden-layer presence, precomputed at import time
    /// against a CGPDFDocument built from the raw bytes. Required because
    /// `PDFDocument(data:)` leaves `documentURL == nil`, which prevented the
    /// engine from reaching the catalog at extraction time. See AD-2-1 /
    /// ENGINE §5B.1.
    public let hasHiddenOCG: Bool
    /// The page's cropBox bounds, pre-extracted serially at build time
    /// so the concurrent rasterize path never reads `page.bounds(for:)` off the
    /// shared document. The `.zero` default keeps existing test constructions
    /// compiling, but any PDFPageData that reaches `rasterize()` MUST carry the
    /// real value — `.zero` yields a zero-pixel raster.
    public let cropBoxBounds: CGRect
    /// The page's `CGPDFPage`, pre-extracted serially; the concurrent
    /// render path draws this directly (`renderPageFromCGPage`). The `nil`
    /// default keeps test constructions compiling — a PDFPageData that reaches
    /// `rasterize()` with `nil` throws `.bitmapCreationFailed`.
    public let cgPage: CGPDFPage?
    /// Whether the source page carried a non-empty text layer, computed
    /// serially for searchable pages only (`false` for secure-rasterization
    /// pages). Feeds the searchable-mode debug assertion without a concurrent
    /// `page.string` read.
    public let hasText: Bool
    /// PD-5: why this page's mode fell back to Secure Rasterization in a
    /// Searchable-mode run, recorded at build time where the pre-flight
    /// trigger check runs (`PipelineCoordinator.buildPDFPageData`). Nil for
    /// pages that kept searchable mode AND for every page of a
    /// secure-raster-mode run (rasterized by choice, not by fallback).
    public let fallbackReason: TextLayerDetector.FallbackReason?

    public init(page: PDFPage, pageIndex: Int, regions: [RedactionRegion],
                fillColor: FillColor, targetDPI: Int, pipelineMode: PipelineMode,
                rotation: Int, hasHiddenOCG: Bool = false,
                cropBoxBounds: CGRect = .zero, cgPage: CGPDFPage? = nil,
                hasText: Bool = false,
                fallbackReason: TextLayerDetector.FallbackReason? = nil) {
        self.page = page
        self.pageIndex = pageIndex
        self.regions = regions
        self.fillColor = fillColor
        self.targetDPI = targetDPI
        self.pipelineMode = pipelineMode
        self.rotation = rotation
        self.hasHiddenOCG = hasHiddenOCG
        self.cropBoxBounds = cropBoxBounds
        self.cgPage = cgPage
        self.hasText = hasText
        self.fallbackReason = fallbackReason
    }
}

/// Wrapper to pass PDFDocument across isolation boundaries.
/// Safety: each parallel verification layer receives its OWN
/// `PDFDocument` instance (`PipelineCoordinator.loadParallelLayerDocuments`);
/// never reuse one instance across concurrent tasks. The sequential layers
/// (3/4, sandwich 5–8) and the provisioning-failure fallback access a single
/// instance sequentially.
/// SEARCH (D10-F1): the off-main search consumers honor the same rule — the
/// background search and the live-preview text-walk EACH receive their own
/// copy (`DocumentState.makeSearchCopy`), so the wrapper is never constructed
/// against an instance another task (or the on-screen `PDFView`) is reading.
public struct SendablePDFDocument: @unchecked Sendable {
    public let document: PDFDocument
    public init(_ document: PDFDocument) { self.document = document }
}

/// Wrapper to pass PDFPage across isolation boundaries.
/// Safety: consumed by the `renderPageWithTimeout(PDFPage,…)`
/// test-seam overload only; the production rasterize path renders via
/// `PDFPageData.cgPage` (`renderPageFromCGPage`), not a live `PDFPage`.
public struct SendablePDFPage: @unchecked Sendable {
    public let page: PDFPage
    public init(_ page: PDFPage) { self.page = page }
}
