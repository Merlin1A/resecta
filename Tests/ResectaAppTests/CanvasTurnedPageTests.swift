import Testing
import Foundation
import CoreGraphics
import UIKit
import PDFKit
import RedactionEngine
@testable import ResectaApp

// A box on a turned page is drawn, stored, moved, resized and scrolled to in
// the SHOWN frame, the frame the search places boxes in and the burn paints
// them in. PDFKit sizes a page's overlay to the STORED page and turns the
// view with the page, so the canvas turns every rect it writes or draws
// (`CanvasTurn`). Read on a five-page document (0° · 90° · 180° · 270° ·
// 90° over an offset crop box) in a real `FitFlooredPDFView` with the
// coordinator as its overlay provider. Each page carries one word's box in
// page space, off every axis of symmetry; its place on screen comes from
// PDFKit's and UIKit's own conversions, never from the canvas's map.

@Suite("Boxes on turned pages: the canvas in the shown frame")
@MainActor
struct CanvasTurnedPageTests {

    static let turns = [0, 90, 180, 270, 90]
    static let offsetCrop = CGRect(x: 36, y: 54, width: 540, height: 684)

    private static func document() throws -> PDFDocument {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let data = renderer.pdfData { ctx in
            for _ in turns { ctx.beginPage(withBounds: page, pageInfo: [:]) }
        }
        let document = try #require(PDFDocument(data: data))
        try #require(document.pageCount == turns.count)
        for (i, turn) in turns.enumerated() { document.page(at: i)?.rotation = turn }
        document.page(at: 4)?.setBounds(offsetCrop, for: .cropBox)
        return document
    }

    /// One word's box in page space (unrotated, the crop box's origin
    /// included), off both diagonals and both centre lines.
    private static func word(on page: PDFPage) -> CGRect {
        let c = page.bounds(for: .cropBox)
        return CGRect(x: c.minX + 0.18 * c.width, y: c.minY + 0.62 * c.height,
                      width: 0.22 * c.width, height: 0.03 * c.height)
    }

    /// The word as a region holds it: the search's transform.
    private static func shown(_ rect: CGRect, on page: PDFPage) throws -> CGRect {
        try #require(ConcealingAnnotations.displayNormalized(
            rect, crop: page.bounds(for: .cropBox), rotation: page.rotation))
    }

    private static func near(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }

    private static func overlays(in view: UIView) -> [RedactionOverlayView] {
        view.subviews.flatMap { ($0 as? RedactionOverlayView).map { [$0] } ?? overlays(in: $0) }
    }

    /// A shown page with its canvas, and the word's place on the canvas by
    /// PDFKit's page map and UIKit's view transform.
    private struct Canvas {
        let view: FitFlooredPDFView
        let window: UIWindow
        let coordinator: PDFViewCoordinator
        let page: PDFPage
        let overlay: RedactionOverlayView
        let word: CGRect
        /// The word's place in the canvas's own points.
        let wordOnCanvas: CGRect
        /// The word's place on screen, in the PDF view's points.
        let wordOnScreen: CGRect
    }

    private static func canvas(_ pageIndex: Int) throws -> Canvas {
        let state = RedactionState()
        let coordinator = PDFViewCoordinator()
        coordinator.redactionState = state
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let view = FitFlooredPDFView(frame: window.bounds)
        view.displayMode = .singlePage
        view.pageOverlayViewProvider = coordinator
        view.document = try document()
        window.addSubview(view)
        window.isHidden = false
        let page = try #require(view.document?.page(at: pageIndex))
        view.go(to: page)
        view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let overlay = try #require(overlays(in: view).first { $0.pageIndex == pageIndex },
                                   "PDFKit installed the coordinator's overlay for page \(pageIndex)")
        let word = word(on: page)
        let onScreen = view.convert(word, from: page)
        return Canvas(view: view, window: window, coordinator: coordinator, page: page, overlay: overlay,
                      word: word, wordOnCanvas: view.convert(onScreen, to: overlay), wordOnScreen: onScreen)
    }

    @Test("The turn is the search's transform on normalized rects, and its inverse undoes it",
          arguments: [0, 90, 180, 270, -90, 450])
    func turnMatchesTheSearch(rotation: Int) throws {
        for crop in [CGRect(x: 0, y: 0, width: 612, height: 792), Self.offsetCrop] {
            for rect in [CGRect(x: crop.minX + 40, y: crop.minY + 500, width: 130, height: 22),
                         CGRect(x: crop.minX + 300, y: crop.minY + 60, width: 18, height: 200)] {
                let stored = CGRect(x: (rect.minX - crop.minX) / crop.width, y: (rect.minY - crop.minY) / crop.height,
                                    width: rect.width / crop.width, height: rect.height / crop.height)
                let search = try #require(ConcealingAnnotations.displayNormalized(rect, crop: crop, rotation: rotation))
                let turned = CanvasTurn.shown(fromStored: stored, rotation: rotation)
                #expect(Self.near(turned, search, 1e-9), "rotation \(rotation): \(turned) vs the search's \(search)")
                #expect(Self.near(CanvasTurn.stored(fromShown: turned, rotation: rotation), stored, 1e-9))
            }
        }
    }

    @Test("A drag over the word's place on screen is stored where the search would place the word",
          arguments: 0..<5)
    func dragIsStoredInTheShownFrame(pageIndex: Int) throws {
        let c = try Self.canvas(pageIndex)
        let stored = c.overlay.overlayToPDFNormalized(c.wordOnCanvas)
        let expected = try Self.shown(c.word, on: c.page)
        #expect(Self.near(stored, expected, 0.002),
                "page \(pageIndex) (/Rotate \(c.page.rotation)): drag stored \(stored), the word is at \(expected)")
        withExtendedLifetime((c.coordinator, c.window)) {}
    }

    @Test("A found box is drawn over its word on screen, and a touch on the word picks it",
          arguments: 0..<5)
    func foundBoxIsDrawnOverItsWord(pageIndex: Int) throws {
        let c = try Self.canvas(pageIndex)
        let found = try Self.shown(c.word, on: c.page)
        let drawn = c.overlay.pdfNormalizedToOverlay(found)
        #expect(Self.near(drawn, c.wordOnCanvas, 1),
                "page \(pageIndex) (/Rotate \(c.page.rotation)): drawn at \(drawn), the word is at \(c.wordOnCanvas)")
        let region = RedactionRegion(id: UUID(), normalizedRect: found, source: .searchMatch(term: "word"))
        c.overlay.configure(with: [region], selectedIDs: [])
        #expect(c.overlay.hitTestRegion(at: CGPoint(x: c.wordOnCanvas.midX, y: c.wordOnCanvas.midY))?.id == region.id)
        withExtendedLifetime((c.coordinator, c.window)) {}
    }

    @Test("Move: an arrow key moves a box the way it points on screen", arguments: 0..<5)
    func arrowKeyMovesTheWayItPoints(pageIndex: Int) throws {
        let c = try Self.canvas(pageIndex)
        let start = try Self.shown(c.word, on: c.page)
        func onScreen(_ n: CGRect) -> CGRect { c.view.convert(c.overlay.pdfNormalizedToOverlay(n), from: c.overlay) }
        let before = onScreen(start)
        let right = onScreen(DocumentEditorView.nudgedRect(start, dx: 0.02, dy: 0))
        let up = onScreen(DocumentEditorView.nudgedRect(start, dx: 0, dy: -0.02))
        #expect(right.midX > before.midX + 1 && abs(right.midY - before.midY) < 0.5,
                "page \(pageIndex) (/Rotate \(c.page.rotation)): right arrow moved \(before) to \(right)")
        #expect(up.midY < before.midY - 1 && abs(up.midX - before.midX) < 0.5,
                "page \(pageIndex) (/Rotate \(c.page.rotation)): up arrow moved \(before) to \(up)")
        withExtendedLifetime((c.coordinator, c.window)) {}
    }

    @Test("Move: a box dragged on screen is stored where it was dropped", arguments: 0..<5)
    func dragMoveIsStoredWhereDropped(pageIndex: Int) throws {
        let c = try Self.canvas(pageIndex)
        let dropped = c.wordOnScreen.offsetBy(dx: 23, dy: -17)
        let stored = c.overlay.overlayToPDFNormalized(c.view.convert(dropped, to: c.overlay))
        let expected = try Self.shown(c.view.convert(dropped, to: c.page), on: c.page)
        #expect(Self.near(stored, expected, 0.002),
                "page \(pageIndex) (/Rotate \(c.page.rotation)): moved box stored \(stored), dropped at \(expected)")
        withExtendedLifetime((c.coordinator, c.window)) {}
    }

    @Test("Resize: the shown right edge moves right, and a widened box is stored as widened", arguments: 0..<5)
    func resizeFollowsTheShownEdge(pageIndex: Int) throws {
        let c = try Self.canvas(pageIndex)
        let box = try Self.shown(c.word, on: c.page)
        var wider = box
        wider.size.width += 0.05
        let before = c.view.convert(c.overlay.pdfNormalizedToOverlay(box), from: c.overlay)
        let after = c.view.convert(c.overlay.pdfNormalizedToOverlay(wider), from: c.overlay)
        #expect(abs(after.minX - before.minX) < 0.5 && after.maxX > before.maxX + 1
                    && abs(after.minY - before.minY) < 0.5 && abs(after.maxY - before.maxY) < 0.5,
                "page \(pageIndex) (/Rotate \(c.page.rotation)): widened \(before) to \(after)")
        let dragged = CGRect(x: c.wordOnScreen.minX, y: c.wordOnScreen.minY,
                             width: c.wordOnScreen.width + 30, height: c.wordOnScreen.height)
        let stored = c.overlay.overlayToPDFNormalized(c.view.convert(dragged, to: c.overlay))
        let expected = try Self.shown(c.view.convert(dragged, to: c.page), on: c.page)
        #expect(Self.near(stored, expected, 0.002))
        withExtendedLifetime((c.coordinator, c.window)) {}
    }

    @Test("Scroll: the scroll target for a box is the box's own place on the page", arguments: 0..<5)
    func scrollTargetIsTheBoxesPlace(pageIndex: Int) throws {
        let document = try Self.document()
        let page = try #require(document.page(at: pageIndex))
        let word = Self.word(on: page)
        let target = PDFDocumentView.pageRect(forShown: try Self.shown(word, on: page), on: page, box: .cropBox)
        #expect(Self.near(target, word, 0.5),
                "page \(pageIndex) (/Rotate \(page.rotation)): scroll target \(target), the word is at \(word)")
    }
}
