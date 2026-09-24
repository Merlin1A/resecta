import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// The result walk's centring point — pure, host-free. The point is the
// visible area's top-left in page space (y-up, PDFKit's destination
// semantics) that puts `rectInPage` at the centre of the visible canvas,
// clamped to the page so the view never shows off-page space; where the
// page is smaller than the viewport on an axis, the page's own edge is
// returned and PDFKit centres the page itself. The scale rule is NOT
// re-pinned here (`ReadabilityZoomPolicyTests` owns it): centring
// changes only WHERE the match lands.

@Suite("Canvas centring math")
struct CanvasCenteringMathTests {

    private let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    private let visible = CGSize(width: 300, height: 400)

    private func point(_ rect: CGRect, visible: CGSize? = nil, page: CGRect? = nil) -> CGPoint {
        PDFDocumentView.centeringDestinationPoint(
            rectInPage: rect,
            visibleSizeInPage: visible ?? self.visible,
            pageBounds: page ?? self.page)
    }

    @Test("An interior rect lands at the centre of the visible area")
    func interiorRectCentres() {
        // The rect's centre (306, 396); the visible area's top-left is
        // half a viewport left and half a viewport UP (y-up) of it.
        let p = point(CGRect(x: 296, y: 391, width: 20, height: 10))
        #expect(p.x == CGFloat(306 - 150))
        #expect(p.y == CGFloat(396 + 200))
        // Reading it back: the visible area spans x 156…456, y 396…796
        // in page space, whose centre is the rect's centre.
        #expect((p.x + visible.width / 2) == CGFloat(306))
        #expect((p.y - visible.height / 2) == CGFloat(396))
    }

    @Test("Clamps at the page's left and right edges")
    func clampsHorizontally() {
        #expect(point(CGRect(x: 10, y: 391, width: 20, height: 10)).x == page.minX)
        #expect(point(CGRect(x: 590, y: 391, width: 20, height: 10)).x == page.maxX - visible.width)
    }

    @Test("Clamps at the page's top and bottom edges (y-up)")
    func clampsVertically() {
        // Near the top of the page: the visible top-left cannot exceed maxY.
        #expect(point(CGRect(x: 296, y: 770, width: 20, height: 10)).y == page.maxY)
        // Near the bottom: the visible area cannot extend below minY.
        #expect(point(CGRect(x: 296, y: 5, width: 20, height: 10)).y == page.minY + visible.height)
    }

    @Test("A page smaller than the viewport on an axis returns the page's edge — PDFKit centres the page")
    func smallPageYieldsThePageEdge() {
        let small = CGRect(x: 0, y: 0, width: 200, height: 300)
        let p = point(CGRect(x: 90, y: 140, width: 20, height: 10), visible: visible, page: small)
        #expect(p.x == small.minX)
        #expect(p.y == small.maxY)
        // Only one axis small: the other still centres.
        let wide = CGRect(x: 0, y: 0, width: 200, height: 800)
        let q = point(CGRect(x: 90, y: 395, width: 20, height: 10), visible: visible, page: wide)
        #expect(q.x == wide.minX)
        #expect(q.y == CGFloat(400 + 200))
    }

    @Test("A rotated (landscape) page with an offset crop box: the rect from the engine's canonical conversion centres inside that box")
    func rotatedPageRectThroughTheCanonicalConversion() {
        // A landscape crop box whose origin is not (0, 0) — the shape a
        // rotated page's `bounds(for:)` takes. The normalized rect goes
        // through the same conversion the consumer uses.
        let box = CGRect(x: 20, y: 30, width: 792, height: 612)
        let rect = normalizedToPDFPageCoordinates(
            CGRect(x: 0.5, y: 0.5, width: 0.05, height: 0.02), pageRect: box)
        let p = point(rect, visible: visible, page: box)
        // The visible area's centre is the rect's centre, inside the box.
        let cx = p.x + visible.width / 2
        let cy = p.y - visible.height / 2
        #expect(abs(cx - rect.midX) < 0.001)
        #expect(abs(cy - rect.midY) < 0.001)
        #expect(p.x >= box.minX && p.x + visible.width <= box.maxX)
        #expect(p.y <= box.maxY && p.y - visible.height >= box.minY)
    }

    @Test("The scroll request carries the anchor; every existing writer stays on .visible")
    @MainActor
    func anchorRidesTheRequest() {
        let doc = DocumentState()
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.02)
        doc.requestCanvasScroll(toPageIndex: 2, normalizedRect: rect, zoom: .readability)
        #expect(doc.pendingCanvasScrollTarget?.anchor == .visible)
        doc.requestCanvasScroll(toPageIndex: 2, normalizedRect: rect, zoom: .readability, anchor: .center)
        #expect(doc.pendingCanvasScrollTarget?.anchor == .center)
        #expect(doc.pendingCanvasScrollTarget?.zoom == .readability)
    }

    @Test("The re-assert store is bounded: a pass cap and a settle window")
    func reassertBounds() {
        #expect(FitFlooredPDFView.reassertPassCap >= 3)
        #expect(FitFlooredPDFView.reassertWindow > 0 && FitFlooredPDFView.reassertWindow <= 1.0)
    }
}
