import UIKit
import PDFKit
import RedactionEngine

// The canvas's half of the run's box-place check (`RunRecord+BoxPlace.swift`
// in the engine). Every place here is read through UIKit's and PDFKit's own
// conversions (`UIView.convert`, `PDFView.convert(_:to:)`) and compared with
// the engine's frame for the page (`RunRecord.PageGeometry`): never with the
// canvas's turn, which is what is being checked.

extension RedactionOverlayView {

    /// The PDF view this canvas is shown in, found up its superviews; nil
    /// before PDFKit has placed it.
    var hostPDFView: PDFView? {
        sequence(first: superview, next: { $0?.superview }).lazy.compactMap { $0 as? PDFView }.first
    }

    /// A rect in this canvas's points as a rect in page space (unrotated, the
    /// crop box's origin included), by UIKit's view transforms and PDFKit's
    /// page map; nil before PDFKit has placed the canvas.
    func pageRectByPDFKit(_ rect: CGRect) -> CGRect? {
        guard let view = hostPDFView, let page = view.document?.page(at: pageIndex) else { return nil }
        return view.convert(convert(rect, to: view), to: page)
    }

    /// Stores a box placed by the gesture in progress from its rect in this
    /// canvas's points, and keeps the rect for the commit.
    func storeFromGesture(_ index: Int, overlayRect: CGRect) {
        regions[index].normalizedRect = overlayToPDFNormalized(overlayRect)
        gestureOverlayRects[regions[index].id] = overlayRect
    }

    /// The page rectangles PDFKit gives the rects the gesture in progress
    /// placed, for the boxes named.
    func drawnPageRects(for ids: [UUID]) -> [UUID: CGRect] {
        var rects: [UUID: CGRect] = [:]
        for id in ids {
            if let rect = gestureOverlayRects[id], let page = pageRectByPDFKit(rect) { rects[id] = page }
        }
        return rects
    }

    // MARK: - The probe

    /// The probe, in points of page space: the largest gap, over the two
    /// shares and both of the canvas's maps, between the canvas and the
    /// engine's frame for the page. Each share goes
    /// - by the drawing map (`pdfNormalizedToOverlay`) to a canvas point, then
    ///   by UIKit and PDFKit to page space, against the frame's page point;
    /// - from the frame's page point by PDFKit and UIKit to a canvas point,
    ///   then by the gesture map (`overlayToPDFNormalized`) to a share, whose
    ///   page point by the frame is compared with the first.
    /// Nil before PDFKit has placed the canvas.
    func boxPlaceProbeGap() -> CGFloat? {
        guard bounds.width > 0, bounds.height > 0, let view = hostPDFView,
              let page = view.document?.page(at: pageIndex) else { return nil }
        let frame = RunRecord.PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        var gap: CGFloat = 0
        for share in RunRecord.boxPlaceProbeShares {
            let expected = frame.pagePoint(ofDisplayedShare: share)
            let drawn = pdfNormalizedToOverlay(CGRect(origin: share, size: .zero)).origin
            let drawnOnPage = view.convert(convert(drawn, to: view), to: page)
            gap = max(gap, RunRecord.axisGap(drawnOnPage, expected))
            let onCanvas = convert(view.convert(expected, from: page), from: view)
            let stored = overlayToPDFNormalized(CGRect(origin: onCanvas, size: .zero)).origin
            gap = max(gap, RunRecord.axisGap(frame.pagePoint(ofDisplayedShare: stored), expected))
        }
        return gap
    }

    /// Whether the probe passes now: nil before PDFKit has placed the canvas.
    func boxPlaceProbePasses() -> Bool? {
        boxPlaceProbeGap().map { $0 <= RunRecord.boxPlaceTolerance }
    }

    /// Runs the probe once, the first time the canvas is laid out inside its
    /// PDF view, and hands the answer to the coordinator.
    func reportBoxPlaceProbeOnce() {
        guard !boxPlaceProbed, window != nil, let passes = boxPlaceProbePasses() else { return }
        boxPlaceProbed = true
        coordinator?.recordBoxPlaceProbe(pageIndex: pageIndex, passes: passes)
    }
}
