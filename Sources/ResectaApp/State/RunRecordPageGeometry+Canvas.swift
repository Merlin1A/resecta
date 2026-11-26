import CoreGraphics
import PDFKit
import RedactionEngine

// The canvas's maps on the engine's page geometry: the one value, made from
// a page's crop box (in the page's own space, with its origin) and its
// rotation, that the overlay, the scroll target and its framing, and the
// keyboard's nudge take a page's turn, sides and origin from. Only what no
// public engine member gives is here. The quarter turn is `CanvasTurn`'s.
//
// A crop box with a side of 0 or less gives no page: its displayed size is
// zero, its rectangles are `.zero` (the crop's origin not added), its page
// point is the origin, and its step is the fallback.

nonisolated extension RunRecord.PageGeometry {

    /// The page's geometry as PDFKit shows it in `box`, through the engine's
    /// own initialiser (which normalises the rotation).
    init(page: PDFPage, box: PDFDisplayBox) {
        self.init(cropBox: page.bounds(for: box), rotation: page.rotation)
    }

    /// The step when there is no page to read one from.
    static var fallbackStep: CGFloat { 0.0025 }

    private var hasSides: Bool { cropBox.width > 0 && cropBox.height > 0 }

    /// The page's size as shown: the crop box's, its sides swapped on a
    /// quarter turn.
    var displayedSize: CGSize {
        guard hasSides else { return .zero }
        switch rotation {
        case 90, 270: return CGSize(width: cropBox.height, height: cropBox.width)
        default: return cropBox.size
        }
    }

    /// A share of the page as shown, in displayed points (origin
    /// bottom-left), clamped to the page first. No turn enters: the share is
    /// already of the page as shown.
    func displayedRect(share: CGRect) -> CGRect {
        guard hasSides else { return .zero }
        let size = displayedSize, k = share.clampedToNormalized()
        return CGRect(x: k.minX * size.width, y: k.minY * size.height,
                      width: k.width * size.width, height: k.height * size.height)
    }

    /// A share of the page as shown, in the page's own space, for PDFKit:
    /// turned back to the stored page, then clamped and scaled by the crop
    /// box with its origin. The scroll target's map.
    func pageRect(share: CGRect) -> CGRect {
        guard hasSides else { return .zero }
        return normalizedToPDFPageCoordinates(
            CanvasTurn.stored(fromShown: share, rotation: rotation), pageRect: cropBox)
    }

    /// A point of the page as shown (displayed points, origin bottom-left)
    /// in the page's own space, through the engine's map.
    func pagePoint(displayed p: CGPoint) -> CGPoint {
        guard hasSides else { return .zero }
        let size = displayedSize
        return pagePoint(ofDisplayedShare: CGPoint(x: p.x / size.width, y: p.y / size.height))
    }

    /// One displayed point as a share of the page as shown.
    var pointStep: CGSize {
        guard hasSides else { return CGSize(width: Self.fallbackStep, height: Self.fallbackStep) }
        let size = displayedSize
        return CGSize(width: 1 / size.width, height: 1 / size.height)
    }
}
