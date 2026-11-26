import UIKit

// The two transforms between the overlay's points and the page's normalized
// space, and the snap page, moved out of `RedactionOverlayView.swift` (the
// hub) from its `// MARK: - Coordinate Transforms` and `// MARK: - Snap Page`
// seams.

extension RedactionOverlayView {
    // MARK: - Coordinate Transforms

    /// Convert overlay-view rect to normalized PDF coordinates (0–1, bottom-left origin).
    func overlayToPDFNormalized(_ rect: CGRect) -> CGRect {
        let page = pageRectOnCanvas
        let w = page.width
        let h = page.height
        guard w > 0, h > 0 else { return .zero }
        // The page's rectangle is the STORED page (PDFKit turns this view
        // with the page); a region lives in the SHOWN frame (`CanvasTurn`).
        let stored = CGRect(
            x: (rect.minX - page.minX) / w,
            y: 1.0 - ((rect.maxY - page.minY) / h),   // Flip Y: UIKit top-left -> PDF bottom-left
            width: rect.width / w,
            height: rect.height / h
        )
        return CanvasTurn.shown(fromStored: stored, rotation: pageRotation)
    }

    /// Convert normalized PDF coordinates back to overlay-view rect.
    func pdfNormalizedToOverlay(_ normalized: CGRect) -> CGRect {
        let page = pageRectOnCanvas
        let w = page.width
        let h = page.height
        let stored = CanvasTurn.stored(fromShown: normalized, rotation: pageRotation)
        return CGRect(
            x: page.minX + stored.minX * w,
            y: page.minY + (1.0 - stored.minY - stored.height) * h,  // Flip Y back
            width: stored.width * w,
            height: stored.height * h
        )
    }

    /// The page's rectangle in this canvas's points: where PDFKit puts the
    /// display box's top-left and bottom-right corners (before the turn,
    /// as the canvas turns with the page). Its size is the page's own, not
    /// the canvas's rounded bounds, and its corner is wherever PDFKit puts
    /// the page. Before PDFKit has placed the canvas, the page's size (or
    /// the bounds) from the canvas's corner.
    var pageRectOnCanvas: CGRect {
        if let cached = cachedPageRectOnCanvas { return cached }
        guard let view = hostPDFView, let page = view.document?.page(at: pageIndex) else {
            return CGRect(origin: .zero, size: pageSize ?? bounds.size)
        }
        let box = page.bounds(for: view.displayBox)
        let topLeft = convert(view.convert(CGPoint(x: box.minX, y: box.maxY), from: page), from: view)
        let bottomRight = convert(view.convert(CGPoint(x: box.maxX, y: box.minY), from: page), from: view)
        let rect = CGRect(x: topLeft.x, y: topLeft.y,
                          width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
        cachedPageRectOnCanvas = rect
        return rect
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
