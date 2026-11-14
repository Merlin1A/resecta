import UIKit

extension RedactionOverlayView {
    // MARK: - Coordinate Transforms

    /// Convert overlay-view rect to normalized PDF coordinates (0–1, bottom-left origin).
    func overlayToPDFNormalized(_ rect: CGRect) -> CGRect {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return .zero }
        return CGRect(
            x: rect.minX / w,
            y: 1.0 - (rect.maxY / h),   // Flip Y: UIKit top-left -> PDF bottom-left
            width: rect.width / w,
            height: rect.height / h
        )
    }

    /// Convert normalized PDF coordinates back to overlay-view rect.
    func pdfNormalizedToOverlay(_ normalized: CGRect) -> CGRect {
        let w = bounds.width
        let h = bounds.height
        return CGRect(
            x: normalized.minX * w,
            y: (1.0 - normalized.minY - normalized.height) * h,  // Flip Y back
            width: normalized.width * w,
            height: normalized.height * h
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
