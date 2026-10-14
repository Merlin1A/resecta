import Foundation
import PDFKit
import RedactionEngine

/// The run's inputs as pure functions of values. The coordinator snapshots
/// its state objects and forwards; nothing here reads one, so the bridge
/// from the open document to engine-ready page data can be driven by a
/// test with plain values.
enum RunInputs {

    /// Bridge the document and the applied regions into engine-ready
    /// `PDFPageData`, one per page, in page order.
    ///
    /// `textLayerStatus` is the import's per-page status and
    /// `sourceHasHiddenOCG` its hidden-layer fact; `settings` is the
    /// run-entry snapshot; `effectiveMode` is the mode the run was entered
    /// with.
    static func pageData(
        document doc: PDFDocument,
        regions: [Int: [RedactionRegion]],
        textLayerStatus: [Int: TextLayerStatus],
        sourceHasHiddenOCG: Bool,
        settings snapshot: PipelineCoordinator.RunSettings,
        effectiveMode: PipelineMode
    ) -> [PDFPageData] {
        (0..<doc.pageCount).compactMap { i -> PDFPageData? in
            guard let page = doc.page(at: i) else { return nil }
            // Pre-extract page geometry and the CGPDFPage SERIALLY here
            // so the concurrent rasterize path is CG-only — it never reads
            // `page.bounds(for:)` / `page.pageRef` off the shared source document.
            let cropBoxBounds = page.bounds(for: .cropBox)
            let cgPage = page.pageRef
            let pageRegions = regions[i]?.compactMap { region -> RedactionRegion? in
                // Minimum dimension threshold.
                guard region.normalizedRect.width > 0.001,
                      region.normalizedRect.height > 0.001 else { return nil }
                var clamped = region
                clamped.normalizedRect = region.normalizedRect.clampedToNormalized()
                return clamped
            } ?? []

            let pageMode: PipelineMode
            // The pre-flight reason is recorded (not just nil-checked)
            // and threaded through the run so the verification report can say
            // why a page rasterized. Reasons exist only for Searchable-mode
            // runs — a secure-raster-mode run rasterizes every page by
            // choice, so its pages carry nil.
            var fallbackReason: TextLayerDetector.FallbackReason?
            // Rotated pages now take
            // searchable mode. The canonical coordinate contract is complete —
            // `extractCharacters` applies T_rot so `CharacterInfo.bounds` are
            // zero-origin, rotation-applied (displayed) coordinates, matching the
            // rasterizer's `effectiveSize` region basis; the filter and the
            // verifier compare in one frame. Proven end-to-end by the
            // `RotatedPageCoordinateTests` matrix (4 rotations × {zero,offset}
            // CropBox origin, Layers 6–10 + tamper). The former `page.rotation == 0`
            // stopgap is removed.
            if effectiveMode == .searchableRedaction,
               textLayerStatus[i] == .rich {
                // Check per-page triggers BEFORE committing to
                // searchable mode (RTL/vertical/encoding-broken pages have
                // unreliable PDFKit bounds; fall back per-page). Rotated pages
                // now reach this gate for the first time — a real RTL/vertical
                // misclassification surfaces here as a per-page SR fallback (the
                // checkFallbackTriggers heuristics are geometry-agnostic).
                if let trigger = TextLayerDetector.checkFallbackTriggers(page) {
                    pageMode = .secureRasterization
                    fallbackReason = trigger
                } else {
                    pageMode = .searchableRedaction
                }
            } else {
                pageMode = .secureRasterization
                // A sparse/no-text page in a Searchable-mode run is also a
                // per-page fallback the report should explain; the trigger
                // check never ran, but the reason is the same fact the
                // sparse/none classification records.
                if effectiveMode == .searchableRedaction {
                    fallbackReason = .noExtractableText
                }
            }

            // Compute hasText serially, searchable pages only. Secure-
            // rasterization pages short-circuit the searchable-mode assert's left
            // disjunct, so `false` is correct for them — and this avoids a
            // Release-only `page.string` scan that would otherwise feed only a
            // Debug-build assert. Searchable pages already paid for text scans
            // via textLayerStatus / checkFallbackTriggers above.
            let hasText = pageMode == .searchableRedaction
                ? (page.string?.isEmpty == false) : false

            return PDFPageData(
                page: page, pageIndex: i, regions: pageRegions,
                fillColor: snapshot.fillColor,
                targetDPI: snapshot.exportDPI,
                pipelineMode: pageMode,
                rotation: page.rotation,
                hasHiddenOCG: sourceHasHiddenOCG,
                cropBoxBounds: cropBoxBounds,
                cgPage: cgPage,
                hasText: hasText,
                fallbackReason: fallbackReason
            )
        }
    }
}
