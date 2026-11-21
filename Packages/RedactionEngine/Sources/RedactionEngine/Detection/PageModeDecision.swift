import CoreGraphics
import PDFKit

// The per-page mode decision of a run, in one place. The app's run inputs
// (`RunInputs.pageData`) and the verification corpus's runner both call it,
// so the two write a page in the same mode for the same reason.

/// Which mode one page of a run is written in, and the reason a page of a
/// Searchable run is written as an image.
public enum PageModeDecision {

    /// The mode and reason for one page. `effectiveMode` is the mode the run
    /// was entered with; `textLayerStatus` is the import's status for the
    /// page; `pageRegions` are the page's regions after the size floor;
    /// `inkPlanCovers` says whether an ink plan covers every one of them.
    /// Every Searchable page with rich text that no trigger takes is read
    /// for text shown in an invisible render mode (`InvisibleTextReading`):
    /// a page that shows some, or whose content could not be read, is
    /// written as an image only. The page's other content facts are read
    /// (`PageContentFacts.read`) only when some region was not placed from
    /// the page's own text and does not cover the whole page; by then the
    /// page is known to show no invisible text, so its content is not walked
    /// for that again.
    public static func decide(
        effectiveMode: PipelineMode,
        textLayerStatus: TextLayerStatus?,
        page: PDFPage,
        pageRegions: [RedactionRegion],
        inkPlanCovers: Bool
    ) -> (mode: PipelineMode, fallbackReason: TextLayerDetector.FallbackReason?) {
        // `showsInvisibleText: false` holds because the invisible-text arm
        // runs before the box rule: a page the box rule reads shows none.
        // PageModeDecisionTests pins that order.
        decide(effectiveMode: effectiveMode, textLayerStatus: textLayerStatus, page: page,
               pageRegions: pageRegions, inkPlanCovers: inkPlanCovers,
               readFacts: { PageContentFacts.read($0, showsInvisibleText: false) })
    }

    /// The decision with the readers of the page's facts given, so a test can
    /// count their reads. Internal: outside the package the facts are always
    /// read from the page.
    static func decide(
        effectiveMode: PipelineMode,
        textLayerStatus: TextLayerStatus?,
        page: PDFPage,
        pageRegions: [RedactionRegion],
        inkPlanCovers: Bool,
        readFacts: (CGPDFPage?) -> PageContentFacts,
        readInvisibleText: (CGPDFPage?) -> InvisibleTextReading = InvisibleTextReading.read
    ) -> (mode: PipelineMode, fallbackReason: TextLayerDetector.FallbackReason?) {
        let pageMode: PipelineMode
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
           textLayerStatus == .rich {
            // Check per-page triggers BEFORE committing to
            // searchable mode (RTL/vertical/encoding-broken pages have
            // unreliable PDFKit bounds; fall back per-page). Rotated pages
            // now reach this gate for the first time — a real RTL/vertical
            // misclassification surfaces here as a per-page SR fallback (the
            // checkFallbackTriggers heuristics are geometry-agnostic).
            if let trigger = TextLayerDetector.checkFallbackTriggers(page) {
                pageMode = .secureRasterization
                fallbackReason = trigger
            } else if let reason = Self.invisibleTextReason(readInvisibleText(page.pageRef)) {
                // The page shows text in an invisible render mode (a hidden
                // layer over a picture of the page, or a word drawn without
                // ink), or its content could not be read: it is written as
                // an image only, with the reason.
                pageMode = .secureRasterization
                fallbackReason = reason
            } else if !inkPlanCovers, !PageContentFacts.keepsTextLayer(
                regions: pageRegions, facts: { readFacts(page.pageRef) }
            ) {
                // A box not placed from this page's own text (drawn,
                // duplicated, read from the picture, moved or resized)
                // on a page whose text layer need not sit on its print,
                // with no ink plan that covers it: the covered words'
                // text may lie outside the box, so the page is written as
                // an image only.
                pageMode = .secureRasterization
                fallbackReason = .unanchoredRegion
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
        return (pageMode, fallbackReason)
    }

    /// The page's reason from its invisible-text reading: text shown in an
    /// invisible mode is its own reason; content that could not be read is
    /// a fault's (`extractionFailed`), never the invisible-text reason;
    /// content that shows none gives no reason here.
    static func invisibleTextReason(_ reading: InvisibleTextReading) -> TextLayerDetector.FallbackReason? {
        switch reading {
        case .shows: .invisibleText
        case .unreadable: .extractionFailed
        case .showsNone: nil
        }
    }
}
