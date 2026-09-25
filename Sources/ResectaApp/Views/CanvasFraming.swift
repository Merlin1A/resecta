import SwiftUI
import PDFKit

// The canvas framing math for the result walk — pure, host-free, pinned
// by `ReadabilityZoomPolicyTests`, `CanvasScrollTargetTests` and
// `CanvasCenteringMathTests`. The readability scale rule and its zoom
// gate moved here verbatim from `PDFDocumentView.swift`; the centring
// point is the walk's addition: WHERE the framed match lands (the
// centre of the visible canvas) while the SCALE rule stays as it was.

extension PDFDocumentView {

    /// Rect-level scroll fires only when the view is zoomed meaningfully
    /// past fit — at (or under) fit scale the whole page is on screen
    /// and the page write alone suffices. The 1% epsilon absorbs
    /// autoScales float noise.
    nonisolated static func shouldRectScroll(
        scaleFactor: CGFloat, fitScaleFactor: CGFloat
    ) -> Bool {
        scaleFactor > fitScaleFactor * 1.01
    }

    /// The readability formula. The navigation scale that renders
    /// `rectInPage` (page points) at `ReadabilityZoom.textHeightTarget`
    /// on screen, width-guarded so the whole rect stays visible, clamped
    /// to [fit … min(navZoomCap × fit, maxScale)]. A page-wide rect's
    /// width fit lands at-or-below fit ⇒ clamps to fit = no zoom (no
    /// special-casing); a taller united multi-line rect zooms LESS.
    /// `nil` = leave the scale alone (degenerate rect or geometry).
    /// The cap is a navigation target only — never written to
    /// `maxScaleFactor` (the pinch ceiling stays PDFKit's).
    nonisolated static func readabilityTargetScale(
        rectInPage: CGRect,
        viewportSize: CGSize,
        fitScale: CGFloat,
        maxScale: CGFloat
    ) -> CGFloat? {
        guard rectInPage.width > 0.001, rectInPage.height > 0.001,
              fitScale > 0, viewportSize.width > 0, viewportSize.height > 0
        else { return nil }
        let heightRule = ReadabilityZoom.textHeightTarget / rectInPage.height
        let widthFit = (viewportSize.width - 2 * ReadabilityZoom.horizontalMargin)
            / rectInPage.width
        let ceiling = min(ReadabilityZoom.navZoomCap * fitScale, maxScale)
        let target = min(heightRule, widthFit)
        return min(max(target, fitScale), max(ceiling, fitScale))
    }

    /// The point that centres `rectInPage` in the visible canvas — the
    /// top-left corner of the visible area in page space (PDFKit's
    /// destination semantics: the `/XYZ` point lands at the view's
    /// top-left; page space is y-up). `visibleSizeInPage` is the view's
    /// bounds divided by the scale the framing just wrote. Clamped to
    /// the page on each axis so the view never shows off-page space;
    /// on an axis where the page is smaller than the viewport the
    /// page's own edge is returned and PDFKit centres the page itself.
    nonisolated static func centeringDestinationPoint(
        rectInPage: CGRect,
        visibleSizeInPage: CGSize,
        pageBounds: CGRect
    ) -> CGPoint {
        let x: CGFloat
        if visibleSizeInPage.width >= pageBounds.width {
            x = pageBounds.minX
        } else {
            let wanted = rectInPage.midX - visibleSizeInPage.width / 2
            x = min(max(wanted, pageBounds.minX), pageBounds.maxX - visibleSizeInPage.width)
        }
        let y: CGFloat
        if visibleSizeInPage.height >= pageBounds.height {
            y = pageBounds.maxY
        } else {
            let wanted = rectInPage.midY + visibleSizeInPage.height / 2
            y = min(max(wanted, pageBounds.minY + visibleSizeInPage.height), pageBounds.maxY)
        }
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Readability zoom constants

/// The tuning surface — the one home for the readability formula's
/// numbers (`PDFDocumentView.readabilityTargetScale`). The shape is
/// fixed; the exact values are tuned on-sim and during a device pass.
/// `navZoomCap` is a navigation target only — it never touches
/// `maxScaleFactor` (the pinch ceiling stays PDFKit's).
nonisolated enum ReadabilityZoom {
    /// On-screen height (points) the matched text is framed to.
    static let textHeightTarget: CGFloat = 20
    /// Horizontal breathing room (points, each side) in the width guard.
    static let horizontalMargin: CGFloat = 16
    /// Ceiling as a multiple of the fit scale.
    static let navZoomCap: CGFloat = 3.5
    /// Relative dead band (× fit) below which the scale is left alone.
    static let scaleEpsilon: CGFloat = 0.01
}
