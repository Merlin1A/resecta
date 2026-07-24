import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp

// SA-3 rider (D-70): rect-level scroll-to-match seams.
// `DocumentState.requestCanvasScroll` is the writer contract every
// result-navigation site shares; `PDFDocumentView.shouldRectScroll`
// is the consumer's zoom gate. The normalized→page-space conversion
// is deliberately NOT re-pinned here — the consumer reuses the
// engine's canonical `normalizedToPDFPageCoordinates` (ENGINE
// §5B.1a), which the engine suite owns.

@Suite("Canvas scroll-to-match target")
@MainActor
struct CanvasScrollTargetTests {

    @Test("requestCanvasScroll stores the page and rect")
    func requestStoresPageAndRect() {
        let doc = DocumentState()
        let rect = CGRect(x: 0.25, y: 0.5, width: 0.1, height: 0.05)
        doc.requestCanvasScroll(toPageIndex: 3, normalizedRect: rect)
        #expect(doc.pendingCanvasScrollTarget?.pageIndex == 3)
        #expect(doc.pendingCanvasScrollTarget?.normalizedRect == rect)
    }

    @Test("re-requesting the same rect mints a fresh token — every navigation is consumable once")
    func repeatRequestMintsFreshToken() {
        let doc = DocumentState()
        let rect = CGRect(x: 0.25, y: 0.5, width: 0.1, height: 0.05)
        doc.requestCanvasScroll(toPageIndex: 3, normalizedRect: rect)
        let first = doc.pendingCanvasScrollTarget
        doc.requestCanvasScroll(toPageIndex: 3, normalizedRect: rect)
        let second = doc.pendingCanvasScrollTarget
        #expect(first != nil && second != nil)
        #expect(first?.token != second?.token,
                "Re-navigating to the same match must be a fresh consumable request.")
        #expect(first?.pageIndex == second?.pageIndex)
        #expect(first?.normalizedRect == second?.normalizedRect)
    }

    @Test("zoom gate: rect-scroll only fires meaningfully past fit scale")
    func zoomGate() {
        // At fit (and below): the whole page is visible — page-granular
        // navigation suffices; go(to:on:) would zoom unexpectedly.
        #expect(!PDFDocumentView.shouldRectScroll(scaleFactor: 1.0, fitScaleFactor: 1.0))
        #expect(!PDFDocumentView.shouldRectScroll(scaleFactor: 0.8, fitScaleFactor: 1.0))
        // Inside the 1% autoScales float-noise epsilon: still page-only.
        #expect(!PDFDocumentView.shouldRectScroll(scaleFactor: 1.005, fitScaleFactor: 1.0))
        // Meaningfully zoomed: the match can be off-screen — rect-scroll.
        #expect(PDFDocumentView.shouldRectScroll(scaleFactor: 1.02, fitScaleFactor: 1.0))
        #expect(PDFDocumentView.shouldRectScroll(scaleFactor: 2.0, fitScaleFactor: 1.0))
    }
}
