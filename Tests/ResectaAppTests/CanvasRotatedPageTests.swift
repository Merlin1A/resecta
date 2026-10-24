import Testing
import Foundation
import CoreGraphics
import UIKit
import PDFKit
import RedactionEngine
@testable import ResectaApp

// The canvas on a rotated page and on a cropped one. PDFKit sizes each
// page's overlay to the page as it is shown: a portrait page turned 90°
// shows landscape, and a page with an offset crop box shows only the
// crop. Read on a three-page document (portrait · portrait turned 90° ·
// landscape with an offset crop box) in a real `FitFlooredPDFView` with the
// coordinator as its overlay provider: the overlay's aspect is the shown
// aspect, its bounds are the unit rect, a drawn rect comes back where it
// was drawn, and the hit test at a box's centre picks that box.

@Suite("Canvas on rotated and cropped pages")
@MainActor
struct CanvasRotatedPageTests {

    private static func document() throws -> PDFDocument {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { ctx in
            ctx.beginPage(withBounds: CGRect(x: 0, y: 0, width: 612, height: 792), pageInfo: [:])
            ctx.beginPage(withBounds: CGRect(x: 0, y: 0, width: 612, height: 792), pageInfo: [:])
            ctx.beginPage(withBounds: CGRect(x: 0, y: 0, width: 792, height: 612), pageInfo: [:])
        }
        let document = try #require(PDFDocument(data: data))
        try #require(document.pageCount == 3)
        document.page(at: 1)?.rotation = 90
        document.page(at: 2)?.setBounds(CGRect(x: 72, y: 54, width: 648, height: 504), for: .cropBox)
        return document
    }

    /// The page's size as shown: the crop box, its sides swapped at 90°/270°.
    private static func shownSize(_ page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox).size
        return page.rotation % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
    }

    private static func overlays(in view: UIView) -> [RedactionOverlayView] {
        view.subviews.flatMap { ($0 as? RedactionOverlayView).map { [$0] } ?? overlays(in: $0) }
    }

    @Test("Each page's overlay has the shown aspect, the unit rect, a round-tripping rect and the hit test", arguments: [0, 1, 2])
    func overlayMatchesTheShownPage(pageIndex: Int) throws {
        let state = RedactionState()
        let coordinator = PDFViewCoordinator()
        coordinator.redactionState = state
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let view = FitFlooredPDFView(frame: window.bounds)
        view.displayMode = .singlePage
        view.pageOverlayViewProvider = coordinator
        view.document = try Self.document()
        window.addSubview(view)
        window.isHidden = false
        let page = try #require(view.document?.page(at: pageIndex))
        view.go(to: page)
        view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let overlay = try #require(Self.overlays(in: view).first { $0.pageIndex == pageIndex },
                                   "PDFKit installed the coordinator's overlay for page \(pageIndex)")
        // The overlay draws in page space (its bounds); PDFKit turns it with
        // the page, so its frame, the extent it covers on screen, has the
        // shown aspect.
        let shown = Self.shownSize(page)
        let bounds = overlay.bounds
        let frame = overlay.frame
        #expect(abs(frame.width / frame.height - shown.width / shown.height) < 0.01,
                "page \(pageIndex): overlay frame \(frame.size) (bounds \(bounds.size), transform \(overlay.transform)) vs shown \(shown)")

        let unit = overlay.overlayToPDFNormalized(bounds)
        #expect(abs(unit.minX) < 0.001 && abs(unit.minY) < 0.001 && abs(unit.width - 1) < 0.001 && abs(unit.height - 1) < 0.001)

        let drawn = CGRect(x: bounds.width * 0.3, y: bounds.height * 0.4, width: bounds.width * 0.2, height: bounds.height * 0.1)
        let back = overlay.pdfNormalizedToOverlay(overlay.overlayToPDFNormalized(drawn))
        #expect(abs(back.minX - drawn.minX) < 0.01 && abs(back.minY - drawn.minY) < 0.01
                && abs(back.width - drawn.width) < 0.01 && abs(back.height - drawn.height) < 0.01)

        let region = RedactionRegion(id: UUID(), normalizedRect: overlay.overlayToPDFNormalized(drawn), source: .manual)
        overlay.configure(with: [region], selectedIDs: [])
        #expect(overlay.hitTestRegion(at: CGPoint(x: drawn.midX, y: drawn.midY))?.id == region.id)
        withExtendedLifetime((coordinator, window)) {}
    }
}
