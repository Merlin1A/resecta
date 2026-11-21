import UIKit

// The two transforms between the overlay's points and the page's normalized
// space, and the snap page, moved out of `RedactionOverlayView.swift` (the
// hub) from its `// MARK: - Coordinate Transforms` and `// MARK: - Snap Page`
// seams.

extension RedactionOverlayView {
    // MARK: - Coordinate Transforms

    /// Convert overlay-view rect to normalized PDF coordinates (0–1, bottom-left origin).
    func overlayToPDFNormalized(_ rect: CGRect) -> CGRect {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return .zero }
        // The bounds are the STORED page (PDFKit turns this view with the
        // page); a region lives in the SHOWN frame (`CanvasTurn`).
        let stored = CGRect(
            x: rect.minX / w,
            y: 1.0 - (rect.maxY / h),   // Flip Y: UIKit top-left -> PDF bottom-left
            width: rect.width / w,
            height: rect.height / h
        )
        return CanvasTurn.shown(fromStored: stored, rotation: pageRotation)
    }

    /// Convert normalized PDF coordinates back to overlay-view rect.
    func pdfNormalizedToOverlay(_ normalized: CGRect) -> CGRect {
        let w = bounds.width
        let h = bounds.height
        let stored = CanvasTurn.stored(fromShown: normalized, rotation: pageRotation)
        return CGRect(
            x: stored.minX * w,
            y: (1.0 - stored.minY - stored.height) * h,  // Flip Y back
            width: stored.width * w,
            height: stored.height * h
        )
    }

    // MARK: - Snap Page

    /// The page the snap engine reads on each call.
    var snapPage: SnapGuideEngine.Page {
        SnapGuideEngine.Page(
            regions: regions,
            bounds: bounds,
            fingerScale: fingerScale,
            toOverlay: pdfNormalizedToOverlay
        )
    }
}
