import CoreGraphics
import Foundation

// The box-place check at run entry. A box is stored as a share of the page as
// shown; the run paints it through the engine's own page frame. Three
// witnesses, each from outside the canvas's two maps, must agree with that
// frame, or the run refuses the page by name and exports nothing:
//
// 1. the canvas probe: two shares, chosen so no symmetry of the page fixes
//    them, sent through the canvas's drawing map and back through UIKit's and
//    PDFKit's own conversions, must come back to the frame's page point (the
//    app runs it; the result reaches here as `canvasFailures`);
// 2. each hand-drawn box's page rectangle, read by PDFKit at the gesture's
//    end, must equal its stored share mapped by the frame;
// 3. the page's crop box and rotation when its boxes were stored must equal
//    the ones the run reads.
//
// The read-back is always this file's `PageGeometry`, which is `PageFrame`
// plus the crop box's origin: the frame the painter uses. It never calls the
// canvas's turn.

extension RunRecord {
    /// The largest difference, in points, allowed between a witness and the
    /// run's frame, on each side of a rectangle and each axis of a point. Both
    /// sides are floating-point functions of the same value, so an honest
    /// difference is rounding, far under this; a wrong turn or a wrong size
    /// moves a box by much more.
    public static let boxPlaceTolerance: CGFloat = 0.01

    /// The canvas probe's two shares of the page as shown, chosen so no
    /// symmetry of the unit square fixes either: each of the seven turns and
    /// flips moves one of them by at least 0.2 of a side.
    public static let boxPlaceProbeShares = [CGPoint(x: 0.2, y: 0.6), CGPoint(x: 0.9, y: 0.15)]

    /// A page's crop box (in page space, its origin included) and its
    /// rotation, normalized to 0, 90, 180 or 270.
    public struct PageGeometry: Equatable, Sendable {
        public let cropBox: CGRect
        public let rotation: Int

        public init(cropBox: CGRect, rotation: Int) {
            self.cropBox = cropBox
            self.rotation = ((rotation % 360) + 360) % 360
        }

        /// The engine's frame for this page: the displayed size is the crop
        /// box's, its sides swapped on a quarter turn.
        var frame: PageFrame {
            let turned = rotation == 90 || rotation == 270
            return PageFrame(
                rotation: rotation,
                displayedSize: turned
                    ? CGSize(width: cropBox.height, height: cropBox.width) : cropBox.size)
        }

        /// A point in page space (unrotated, the crop box's origin included)
        /// as a share of the page as shown (0 to 1, origin bottom-left).
        public func displayedShare(ofPagePoint point: CGPoint) -> CGPoint {
            let frame = frame
            let shown = frame.displayedPoint(CGPoint(x: point.x - cropBox.minX, y: point.y - cropBox.minY))
            return CGPoint(x: shown.x / frame.displayedSize.width, y: shown.y / frame.displayedSize.height)
        }

        /// A share of the page as shown, as a point in page space.
        public func pagePoint(ofDisplayedShare share: CGPoint) -> CGPoint {
            let frame = frame
            let source = frame.sourcePoint(
                CGPoint(x: share.x * frame.displayedSize.width, y: share.y * frame.displayedSize.height))
            return CGPoint(x: source.x + cropBox.minX, y: source.y + cropBox.minY)
        }

        /// A rectangle given as shares of the page as shown, as a rectangle
        /// in page space: where the run paints it.
        public func pageRect(ofDisplayedShare share: CGRect) -> CGRect {
            let frame = frame
            let w = frame.displayedSize.width, h = frame.displayedSize.height
            let shown = CGRect(x: share.minX * w, y: share.minY * h, width: share.width * w, height: share.height * h)
            return frame.sourceRect(shown).offsetBy(dx: cropBox.minX, dy: cropBox.minY)
        }

        /// A rectangle in page space as shares of the page as shown: the
        /// inverse of `pageRect(ofDisplayedShare:)`.
        public func displayedShare(ofPageRect rect: CGRect) -> CGRect {
            let frame = frame
            let w = frame.displayedSize.width, h = frame.displayedSize.height
            let shown = frame.displayedRect(rect.offsetBy(dx: -cropBox.minX, dy: -cropBox.minY))
            return CGRect(x: shown.minX / w, y: shown.minY / h, width: shown.width / w, height: shown.height / h)
        }
    }

    /// The largest difference between two rectangles' matching sides.
    public static func sideGap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.maxX - b.maxX), abs(a.maxY - b.maxY))
    }

    /// The largest difference between two points' matching axes.
    public static func axisGap(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        max(abs(a.x - b.x), abs(a.y - b.y))
    }
}

extension RunRecord.Page {
    /// A point in page space as a share of the page as shown, by the run's
    /// own frame for this page; nil when the run could not read the page's
    /// geometry.
    public func displayedShare(ofPagePoint point: CGPoint) -> CGPoint? {
        geometry?.displayedShare(ofPagePoint: point)
    }

    /// Whether every box on this page is confirmed where it was drawn. A page
    /// with no region is. Otherwise: the canvas probe passed for it, the run
    /// read its geometry, the geometry noted when its boxes were stored is the
    /// same, and each box with a page rectangle from PDFKit lies, mapped by
    /// the run's frame, within the tolerance of it on every side.
    public func boxPlacesConfirmed(canvasFailed: Bool) -> Bool {
        guard !regions.isEmpty else { return true }
        guard !canvasFailed, let geometry, geometryAtStore == geometry else { return false }
        return regions.allSatisfy { region in
            guard let drawn = region.drawnPageRect else { return true }
            return RunRecord.sideGap(geometry.pageRect(ofDisplayedShare: region.normalizedRect), drawn)
                <= RunRecord.boxPlaceTolerance
        }
    }
}

extension RunRecord.Confirmed {
    /// The first page, in page order, whose boxes are not all confirmed where
    /// they were drawn (`RunRecord.Page.boxPlacesConfirmed`); nil when every
    /// page's are. `canvasFailures` holds the pages whose canvas probe failed.
    public func firstPageWithUnconfirmedBoxPlace(canvasFailures: Set<Int>) -> Int? {
        pages.first { !$0.boxPlacesConfirmed(canvasFailed: canvasFailures.contains($0.pageIndex)) }?.pageIndex
    }
}
