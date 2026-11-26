import Foundation
import PDFKit
import RedactionEngine

/// The run's inputs as pure functions of values. The coordinator snapshots
/// its state objects and forwards; nothing here reads one, so the bridge
/// from the open document to engine-ready page data can be driven by a
/// test with plain values.
enum RunInputs {

    /// The confirmed part of the run's record: the fill colour, the quality
    /// and every region as drawn, one entry per page. It reads the live
    /// regions, never the pages built from them: those hold the regions
    /// after the clamp and the size floor, and a region the run drops must
    /// still be in the record.
    ///
    /// `geometry` holds each page's crop box and rotation, read from the
    /// document at run entry; a page with it gets its plan of boxes, made
    /// once here under the run's plan source, and the run's frame for the
    /// box-place check. A page without it has neither. The switch is the
    /// run's snapshot of the Settings switch; under "as placed" the plan
    /// does not read it. `geometryAtStore` holds the geometry noted when
    /// each page's boxes were stored (`RedactionState`).
    static func confirmedRecord(
        pageCount: Int,
        geometry: [Int: PageGeometry],
        geometryAtStore: [Int: PageGeometry] = [:],
        regions: [Int: [RedactionRegion]],
        reads: [Int: RunRecord.PageRead],
        settings snapshot: PipelineCoordinator.RunSettings
    ) -> RunRecord.Confirmed {
        RunRecord.Confirmed(
            fillColor: snapshot.fillColor,
            exportDPI: snapshot.exportDPI,
            pages: (0..<pageCount).map { page in
                let drawn = (regions[page] ?? []).map {
                    RunRecord.DrawnRegion(region: $0)
                }
                guard let sides = geometry[page] else { return RunRecord.Page(pageIndex: page, regions: drawn) }
                return RunRecord.Page(pageIndex: page, regions: drawn,
                                      geometry: sides, geometryAtStore: geometryAtStore[page],
                                      switchOn: snapshot.boxesAcrossColumn, read: reads[page])
            })
    }

    /// A page's crop box and rotation, as the run's record reads them.
    typealias PageGeometry = RunRecord.PageGeometry

    /// Every page's crop box and rotation, read serially from `doc`.
    static func pageGeometry(of doc: PDFDocument) -> [Int: PageGeometry] {
        var geometry: [Int: PageGeometry] = [:]
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            geometry[i] = PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        }
        return geometry
    }

    /// Bridge the document and the applied regions into engine-ready
    /// `PDFPageData`, one per page, in page order.
    ///
    /// `textLayerStatus` is the import's per-page status and
    /// `sourceHasHiddenOCG` its hidden-layer fact; `settings` is the
    /// run-entry snapshot; `effectiveMode` is the mode the run was entered
    /// with. `inkPlans` holds, for a page whose text is a hidden layer over a
    /// picture of the page, the hidden words each region's ink covers
    /// (`DocumentSearcher.inkStripPlan`, read at run entry); each region
    /// strips them too.
    static func pageData(
        document doc: PDFDocument,
        regions: [Int: [RedactionRegion]],
        textLayerStatus: [Int: TextLayerStatus],
        sourceHasHiddenOCG: Bool,
        settings snapshot: PipelineCoordinator.RunSettings,
        effectiveMode: PipelineMode,
        inkPlans: [Int: InkStripPlan] = [:],
        record: RunRecord.Confirmed?
    ) -> [PDFPageData] {
        (0..<doc.pageCount).compactMap { i -> PDFPageData? in
            guard let page = doc.page(at: i) else { return nil }
            // Pre-extract page geometry and the CGPDFPage SERIALLY here
            // so the concurrent rasterize path is CG-only — it never reads
            // `page.bounds(for:)` / `page.pageRef` off the shared source document.
            let cropBoxBounds = page.bounds(for: .cropBox)
            let cgPage = page.pageRef
            // The ink plan applies only when it covers every region as it now
            // stands; otherwise the page is decided without it.
            let inkPlan = inkPlans[i].flatMap { $0.covers(regions[i] ?? []) ? $0 : nil }
            let pageRegions = regions[i]?.compactMap { region -> RedactionRegion? in
                var clamped = region
                clamped.normalizedRect = region.normalizedRect.clampedToNormalized()
                clamped.inkStripRects = inkPlan?.strips[region.id] ?? []
                // Minimum dimension threshold, read on the clamped box: a
                // box reaching past the page edge keeps only its on-page
                // part, and one wholly past the edge clamps to nothing. Read
                // before the clamp, a box of full size off the page passed
                // the floor and reached the pipeline with no area. The run's
                // record admits by the same test.
                guard RedactionRegion.isAdmitted(normalizedRect: region.normalizedRect) else { return nil }
                return clamped
            } ?? []

            // The pre-flight reason is recorded (not just nil-checked)
            // and threaded through the run so the verification report can say
            // why a page rasterized. Reasons exist only for Searchable-mode
            // runs — a secure-raster-mode run rasterizes every page by
            // choice, so its pages carry nil.
            let (pageMode, fallbackReason) = PageModeDecision.decide(
                effectiveMode: effectiveMode, textLayerStatus: textLayerStatus[i], page: page,
                pageRegions: pageRegions, inkPlanCovers: inkPlan != nil
            )

            // Compute hasText serially, searchable pages only. Secure-
            // rasterization pages short-circuit the searchable-mode assert's left
            // disjunct, so `false` is correct for them — and this avoids a
            // Release-only `page.string` scan that would otherwise feed only a
            // Debug-build assert. Searchable pages already paid for text scans
            // via textLayerStatus and the trigger check (`PageModeDecision.decide`).
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
                fallbackReason: fallbackReason,
                confirmedPage: record?.pages.first { $0.pageIndex == i }
            )
        }
    }
}
