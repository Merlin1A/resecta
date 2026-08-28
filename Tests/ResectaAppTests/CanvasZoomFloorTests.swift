import Testing
import UIKit
import PDFKit
@testable import ResectaApp

// The document view's zoom floor. `FitFlooredPDFView`
// pins `minScaleFactor` to `scaleFactorForSizeToFit` after every layout
// and page change, so a pinch out stops at the page's fit size; zoom-in
// keeps PDFKit's default ceiling. Views are hosted in a window so PDFKit
// lays the page out the way the editor does; the numbers below are the
// iPhone 17 editor canvas (402 pt wide) with the Letter sample, where
// fit is width-bound (≈ 0.64).

@Suite("Canvas zoom floor", .serialized)
@MainActor
struct CanvasZoomFloorTests {

    private static let canvas = CGSize(width: 402, height: 684)
    private static let letter = CGSize(width: 612, height: 792)
    private static let landscapeLetter = CGSize(width: 792, height: 612)

    private func near(_ a: CGFloat, _ b: CGFloat, rel: CGFloat = 0.01) -> Bool {
        abs(a - b) <= max(abs(b) * rel, 1e-6)
    }

    private func makeDocument(pageSizes: [CGSize]) -> PDFDocument {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSizes[0]))
        let data = renderer.pdfData { ctx in
            for size in pageSizes {
                ctx.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                UIColor.black.setFill()
                ctx.fill(CGRect(x: 36, y: 36, width: 100, height: 12))
            }
        }
        return PDFDocument(data: data)!
    }

    /// A floored view configured like the app's hosts, in a window of
    /// `size`, laid out once. The window is returned so it outlives the
    /// assertions.
    private func makeView(
        pageSizes: [CGSize] = [CanvasZoomFloorTests.letter],
        displayMode: PDFDisplayMode = .singlePage,
        size: CGSize = CanvasZoomFloorTests.canvas
    ) -> (view: FitFlooredPDFView, window: UIWindow) {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        let view = FitFlooredPDFView(frame: window.bounds)
        view.autoScales = true
        view.displayMode = displayMode
        view.document = makeDocument(pageSizes: pageSizes)
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        return (view, window)
    }

    private func settle(_ view: UIView) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        view.layoutIfNeeded()
    }

    @Test("after the first layout the floor, the fit and the scale agree")
    func floorMatchesFitAfterFirstLayout() {
        let (view, _) = makeView()
        let fit = view.scaleFactorForSizeToFit
        #expect(fit > 0.3 && fit < 1.0, "Letter on a 402-pt canvas fits below 1× (read \(fit))")
        #expect(near(view.minScaleFactor, fit), "floor \(view.minScaleFactor) vs fit \(fit)")
        #expect(near(view.scaleFactor, fit), "scale \(view.scaleFactor) vs fit \(fit)")
        #expect(view.autoScales, "PDFKit's resize re-fit stays on beside the floor")
    }

    @Test("a scale below fit clamps to fit — the pinch-out floor")
    func scaleBelowFitClampsToFit() {
        let (view, _) = makeView()
        let fit = view.scaleFactorForSizeToFit
        view.scaleFactor = fit * 0.3
        #expect(near(view.scaleFactor, fit), "scale \(view.scaleFactor) after a 0.3× request vs fit \(fit)")
        // The gesture path: PDFKit's scroll view sits at its own minimum
        // when the page is at fit.
        if let scroll = view.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
            #expect(scroll.minimumZoomScale > 0)
            #expect(near(scroll.zoomScale, scroll.minimumZoomScale),
                    "scroll zoom \(scroll.zoomScale) vs its minimum \(scroll.minimumZoomScale) at fit")
        }
    }

    @Test("zoom-in is untouched: 2× fit holds and PDFKit's ceiling stays")
    func zoomInKeepsTheDefaultCeiling() {
        let (view, _) = makeView()
        let fit = view.scaleFactorForSizeToFit
        view.scaleFactor = fit * 2
        #expect(near(view.scaleFactor, fit * 2), "2× fit must hold (read \(view.scaleFactor))")
        #expect(view.maxScaleFactor >= fit * 4, "ceiling \(view.maxScaleFactor) must clear the 4× the draw-tool battery zooms to")
    }

    @Test("the floor follows a canvas resize both ways")
    func floorTracksACanvasResize() {
        let (view, window) = makeView()
        let fit = view.scaleFactorForSizeToFit
        // Narrower canvas: fit drops; a view sitting at the floor re-fits.
        window.frame.size.width = 300
        view.frame = window.bounds
        settle(view)
        let narrowFit = view.scaleFactorForSizeToFit
        #expect(narrowFit < fit * 0.9, "a 300-pt canvas must fit smaller (read \(narrowFit) vs \(fit))")
        #expect(near(view.minScaleFactor, narrowFit), "floor \(view.minScaleFactor) vs narrow fit \(narrowFit)")
        #expect(near(view.scaleFactor, narrowFit), "scale \(view.scaleFactor) must re-fit to \(narrowFit)")
        // Back to the full width: the floor rises with the fit and the
        // page re-fits again.
        window.frame.size.width = Self.canvas.width
        view.frame = window.bounds
        settle(view)
        #expect(near(view.minScaleFactor, view.scaleFactorForSizeToFit))
        #expect(near(view.scaleFactor, view.scaleFactorForSizeToFit))
        // A zoomed-in view re-fits on a resize — PDFKit's `autoScales`
        // behaviour, unchanged by the floor (measured on iOS 26.4: the
        // scale lands on the new fit, below the old floor, so the floor
        // must have followed the fit down first).
        view.scaleFactor = view.scaleFactorForSizeToFit * 2
        window.frame.size.width = 300
        view.frame = window.bounds
        settle(view)
        #expect(near(view.scaleFactor, narrowFit), "a resize re-fits the page (read \(view.scaleFactor) vs \(narrowFit))")
        #expect(near(view.minScaleFactor, narrowFit), "floor \(view.minScaleFactor) vs narrow fit \(narrowFit)")
    }

    @Test("the floor follows the current page's size in single-page mode")
    func floorTracksThePageSize() {
        let (view, _) = makeView(pageSizes: [Self.letter, Self.landscapeLetter])
        let portraitFit = view.scaleFactorForSizeToFit
        guard let landscape = view.document?.page(at: 1) else {
            Issue.record("the two-page fixture lost its second page")
            return
        }
        view.go(to: landscape)
        settle(view)
        let landscapeFit = view.scaleFactorForSizeToFit
        #expect(landscapeFit < portraitFit * 0.9, "a landscape page fits smaller on a portrait canvas (read \(landscapeFit) vs \(portraitFit))")
        #expect(near(view.minScaleFactor, landscapeFit), "floor \(view.minScaleFactor) vs landscape fit \(landscapeFit)")
        #expect(near(view.scaleFactor, landscapeFit), "scale \(view.scaleFactor) vs landscape fit \(landscapeFit)")
        view.scaleFactor = landscapeFit * 0.5
        #expect(near(view.scaleFactor, landscapeFit))
    }

    @Test("continuous mode (the redacted preview) floors at fit width")
    func continuousModeFloorsAtFitWidth() {
        let (view, _) = makeView(displayMode: .singlePageContinuous)
        let fit = view.scaleFactorForSizeToFit
        #expect(fit > 0.3 && fit < 1.0)
        #expect(near(view.minScaleFactor, fit), "floor \(view.minScaleFactor) vs fit width \(fit)")
        view.scaleFactor = fit * 0.5
        #expect(near(view.scaleFactor, fit), "scale \(view.scaleFactor) after a 0.5× request vs fit width \(fit)")
    }
}
