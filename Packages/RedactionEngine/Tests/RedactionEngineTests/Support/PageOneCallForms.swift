import CoreGraphics
import PDFKit
@testable import RedactionEngine

// The one-call forms of a page's render and pre-flight, for tests. The
// product has neither: `PageRasterizer.rasterize` validates a page through
// `validatePageGeometry` and `validatePageMemory` (PageMemoryPolicy.swift)
// separately, and renders it through `renderPageFromCGPage`
// (PageRasterizer.swift) over the page's pre-extracted Core Graphics page.
// Each body below is the product's former one-call form, unchanged.

extension PageRasterizer {
    /// Render a PDF page to a CGImage using CGPDFPage, never PDFKit's page-level draw.
    /// Handles cropBox origin, /Rotate, DPI scaling, and anti-aliasing defense.
    /// Never render through PDFKit's page `draw(with:to:)` here.
    @concurrent
    func renderPage(
        _ page: PDFPage, pageIndex: Int,
        box: PDFDisplayBox = .cropBox,
        dpi: CGFloat = 300
    ) async throws -> CGImage {
        try Task.checkCancellation()

        guard let cgPage = page.pageRef else {
            throw PipelineError.redactionError(.bitmapCreationFailed(pageIndex: pageIndex))
        }

        // The box and rotation as PDFKit reads them, handed to the one render
        // body; it never reads the live `PDFPage` itself.
        return try await renderPageFromCGPage(
            cgPage, bounds: page.bounds(for: box), rotation: page.rotation,
            pageIndex: pageIndex, dpi: dpi, box: box
        )
    }
}

/// Validate a page before rendering: the geometry half
/// (`validatePageGeometry`) and the memory half (`validatePageMemory`)
/// together, the combined verdict.
func validatePage(_ page: PDFPage, effectiveDPI: Int = 300) -> Bool {
    validatePageGeometry(page) && validatePageMemory(page, effectiveDPI: effectiveDPI)
}
