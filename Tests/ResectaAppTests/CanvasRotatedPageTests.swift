import Testing
import Foundation
import CoreGraphics
import UIKit
import PDFKit
import RedactionEngine
@testable import ResectaApp

// The canvas on a rotated page and on a cropped one. PDFKit sizes each
// page's overlay to the STORED page (its crop box, unturned) and turns the
// view with the page, so on a page turned 90° the overlay's bounds are
// portrait and its frame, the extent it covers on screen, is landscape; on
// a page whose sides are not whole thirds of a point the bounds are the
// page rounded to the screen, not the page's own size. Read on a
// three-page document (portrait · portrait turned 90° · landscape with an
// offset crop box) in a real `FitFlooredPDFView` with the coordinator as its
// overlay provider: the overlay's frame has the shown aspect, its bounds
// map to the unit rect, a drawn rect comes back where it was drawn, and the
// hit test at a box's centre picks that box. The round trip passes whatever
// the turn; `CanvasTurnedPageTests` holds the turn itself, with positions
// from PDFKit and UIKit. Then the page's geometry on the turned page: the
// readable zoom, its re-assert, the plain request's clear, the keyboard's
// step, and the source pins.

@Suite("Canvas on rotated and cropped pages", .serialized)
@MainActor
struct CanvasRotatedPageTests {

    // MARK: - The guard: the overlay's space, before anything maps through it

    /// The guard's own pages: Letter at 0, 90, 180 and 270, and at 90 over
    /// the crop (36, 54, 540, 684); A4 and 500.3 × 700.7, each at 0 and 90;
    /// and a crop of 401.123 × 577.777 at (12.345, 67.891), turned 270.
    static let guardPages: [(media: CGRect, crop: CGRect?, turn: Int)] = [
        (CGRect(x: 0, y: 0, width: 612, height: 792), nil, 0),
        (CGRect(x: 0, y: 0, width: 612, height: 792), nil, 90),
        (CGRect(x: 0, y: 0, width: 612, height: 792), nil, 180),
        (CGRect(x: 0, y: 0, width: 612, height: 792), nil, 270),
        (CGRect(x: 0, y: 0, width: 612, height: 792), CGRect(x: 36, y: 54, width: 540, height: 684), 90),
        (CGRect(x: 0, y: 0, width: 595.276, height: 841.89), nil, 0),
        (CGRect(x: 0, y: 0, width: 595.276, height: 841.89), nil, 90),
        (CGRect(x: 0, y: 0, width: 500.3, height: 700.7), nil, 0),
        (CGRect(x: 0, y: 0, width: 500.3, height: 700.7), nil, 90),
        (CGRect(x: 0, y: 0, width: 612, height: 792), CGRect(x: 12.345, y: 67.891, width: 401.123, height: 577.777), 270),
    ]

    private static func guardDocument() throws -> PDFDocument {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { ctx in
            for page in guardPages { ctx.beginPage(withBounds: page.media, pageInfo: [:]) }
        }
        let document = try #require(PDFDocument(data: data))
        try #require(document.pageCount == guardPages.count)
        for (i, page) in guardPages.enumerated() {
            document.page(at: i)?.rotation = page.turn
            if let crop = page.crop { document.page(at: i)?.setBounds(crop, for: .cropBox) }
        }
        return document
    }

    /// The quarter turn PDFKit gives an overlay for a page's rotation.
    private static func quarterTurn(_ rotation: Int) -> (a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat) {
        switch ((rotation % 360) + 360) % 360 {
        case 90: (0, 1, -1, 0)
        case 180: (-1, 0, 0, -1)
        case 270: (0, -1, 1, 0)
        default: (1, 0, 0, 1)
        }
    }

    @Test("The guard: on every page, once placed, the page's rectangle on the canvas is the crop's size, the bounds are within a third of a point of it, and the overlay is turned with the page")
    func overlaySpaceGuard() throws {
        let coordinator = PDFViewCoordinator()
        coordinator.redactionState = RedactionState()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let view = FitFlooredPDFView(frame: window.bounds)
        view.displayMode = .singlePage
        view.pageOverlayViewProvider = coordinator
        view.document = try Self.guardDocument()
        window.addSubview(view)
        window.isHidden = false
        for (index, spec) in Self.guardPages.enumerated() {
            let page = try #require(view.document?.page(at: index))
            view.go(to: page)
            view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let overlay = try #require(Self.overlays(in: view).first { $0.pageIndex == index },
                                       "PDFKit installed the coordinator's overlay for page \(index)")
            // Placed first: the probe answers only once PDFKit has placed the canvas.
            try #require(overlay.boxPlaceProbeGap() != nil, "page \(index) is not placed")
            let crop = page.bounds(for: .cropBox)
            let p = overlay.pageRectOnCanvas
            #expect(abs(p.width - crop.width) <= 0.01 && abs(p.height - crop.height) <= 0.01,
                    "page \(index) (\(spec.media.size) at \(spec.turn)): the page's rectangle on the canvas \(p.size), the crop \(crop.size)")
            #expect(abs(overlay.bounds.width - p.width) <= 0.34 && abs(overlay.bounds.height - p.height) <= 0.34,
                    "page \(index): bounds \(overlay.bounds.size) against the page's rectangle \(p.size)")
            let t = overlay.transform, q = Self.quarterTurn(spec.turn)
            #expect(abs(t.a - q.a) < 1e-9 && abs(t.b - q.b) < 1e-9 && abs(t.c - q.c) < 1e-9 && abs(t.d - q.d) < 1e-9,
                    "page \(index) at \(spec.turn): transform \(t)")
            #expect(overlay.geometry == RunRecord.PageGeometry(cropBox: crop, rotation: spec.turn))
        }
        withExtendedLifetime((coordinator, window)) {}
    }

    @Test("The guard: an overlay handed its page's size but no PDF view is not placed, though the size alone would pass")
    func unplacedOverlayFailsTheGuard() {
        let crop = CGRect(x: 0, y: 0, width: 595.276, height: 841.89)
        let overlay = RedactionOverlayView(frame: CGRect(x: 0, y: 0, width: 595.333, height: 842))
        overlay.geometry = RunRecord.PageGeometry(cropBox: crop, rotation: 0)
        overlay.pageSize = crop.size
        let p = overlay.pageRectOnCanvas
        #expect(abs(p.width - crop.width) <= 0.01 && abs(p.height - crop.height) <= 0.01)
        #expect(overlay.boxPlaceProbeGap() == nil)
    }

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

    // MARK: - The page's geometry on a turned page

    /// The share of cases 11 and 12 on page 1 (turned 90°): its displayed
    /// rectangle is 80.78 × 12.73, so the readable scale is 20 ÷ 12.73; its
    /// page rectangle is 12.73 × 80.78, whose scale would clamp to fit.
    static let s = CGRect(x: 0.45, y: 0.49, width: 0.102, height: 0.0208)
    static let readableScale: CGFloat = 20 / (0.0208 * 612)

    /// A real canvas in a 390 × 600 window, on this file's document.
    private static func canvas() throws -> (view: FitFlooredPDFView, window: UIWindow, coordinator: PDFViewCoordinator) {
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
        view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return (view, window, coordinator)
    }

    /// The canvas shown at page 1, laid out, so a framing on that page
    /// crosses no page. (Crossing one, PDFKit re-fits the new page when the
    /// floor moves, and only a later bounds change re-asserts the framing;
    /// these cases read the framing's own rule.)
    private static func onTurnedPage(_ c: (view: FitFlooredPDFView, window: UIWindow, coordinator: PDFViewCoordinator)) throws {
        let page = try #require(c.view.document?.page(at: 1))
        c.view.go(to: page)
        c.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try #require(c.view.currentPage == page, "the canvas shows page 1")
    }

    private static func target(page: Int, share: CGRect, zoom: DocumentState.CanvasZoomIntent,
                               anchor: DocumentState.CanvasScrollAnchor) -> DocumentState.CanvasScrollTarget {
        DocumentState.CanvasScrollTarget(pageIndex: page, normalizedRect: share, zoom: zoom, anchor: anchor, token: UUID())
    }

    @Test("Case 12: on a turned page the readable zoom is read from the box as shown, not from its page rectangle")
    func zoomReadsTheBoxAsShown() throws {
        let c = try Self.canvas()
        try Self.onTurnedPage(c)
        let fit = c.view.scaleFactorForSizeToFit
        _ = PDFDocumentView.consumeCanvasScrollTarget(
            Self.target(page: 1, share: Self.s, zoom: .readability, anchor: .center), in: c.view, lastHandledToken: nil)
        #expect(abs(c.view.scaleFactor - Self.readableScale) < 0.005,
                "scale \(c.view.scaleFactor), readable \(Self.readableScale), fit \(fit)")
        #expect(c.view.scaleFactor > fit * 1.5)
        withExtendedLifetime(c) {}
    }

    @Test("Case 11: the framing re-applied after the canvas changes size keeps the turned page's readable zoom and the box on screen")
    func reassertKeepsTheTurnedFraming() throws {
        let c = try Self.canvas()
        try Self.onTurnedPage(c)
        let page = try #require(c.view.document?.page(at: 1))
        _ = PDFDocumentView.consumeCanvasScrollTarget(
            Self.target(page: 1, share: Self.s, zoom: .readability, anchor: .center), in: c.view, lastHandledToken: nil)
        var frame = c.view.frame
        frame.size.height -= 100
        c.view.frame = frame
        c.view.layoutIfNeeded()
        #expect(abs(c.view.scaleFactor - Self.readableScale) < 0.005, "scale after the pass \(c.view.scaleFactor)")
        // S's page rectangle, worked out here (case 2's map), on screen.
        let pageRect = CGRect(x: (1 - Self.s.maxY) * 612, y: Self.s.minX * 792,
                              width: Self.s.height * 612, height: Self.s.width * 792)
        let onScreen = c.view.convert(pageRect, from: page)
        #expect(c.view.bounds.contains(onScreen), "the box \(onScreen) in the canvas \(c.view.bounds)")
        withExtendedLifetime(c) {}
    }

    @Test("Case 11b: a plain scroll request clears the armed framing, so a later layout pass does not re-apply it")
    func plainRequestClearsTheFraming() throws {
        let c = try Self.canvas()
        try Self.onTurnedPage(c)
        let first = try #require(c.view.document?.page(at: 0))
        let framed = PDFDocumentView.consumeCanvasScrollTarget(
            Self.target(page: 1, share: Self.s, zoom: .readability, anchor: .center), in: c.view, lastHandledToken: nil)
        let t = CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.03)
        _ = PDFDocumentView.consumeCanvasScrollTarget(
            Self.target(page: 0, share: t, zoom: .none, anchor: .visible), in: c.view, lastHandledToken: framed)
        #expect(c.view.currentPage == first, "the plain request went to its page")
        var frame = c.view.frame
        frame.size.height -= 100
        c.view.frame = frame
        c.view.layoutIfNeeded()
        #expect(c.view.currentPage == first, "after the pass the view is still on the plain request's page, not the framed one")
        withExtendedLifetime(c) {}
    }

    @Test("Case 13: one arrow-key press on a page turned 90° moves a box one point as the page is shown")
    func keyboardStepOnATurnedPage() throws {
        let page = try #require(try Self.document().page(at: 1))
        let step = DocumentEditorView.nudgeStep(page: page)
        #expect(step.dx == 1 / 792 && step.dy == 1 / 612)
    }

    // MARK: - Source pins

    private func loadRepoFile(_ relativePath: String, from file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("Source pin: the keyboard's step comes from the page's geometry, and the scroll path names no page bounds and no turn of its own")
    func stepAndScrollReadTheGeometry() throws {
        let keyboard = try loadRepoFile("Sources/ResectaApp/Views/DocumentEditorKeyboard.swift")
        #expect(keyboard.contains("nudgeStep(page:"))
        #expect(!keyboard.contains("bounds(for:"))
        let scroll = try loadRepoFile("Sources/ResectaApp/Views/PDFDocumentView.swift")
        #expect(!scroll.contains("bounds(for:"))
        #expect(!scroll.contains("CanvasTurn."))
    }

    @Test("Source pin: no file under Sources assigns the display box, so the canvas shows the crop box")
    func noDisplayBoxIsAssigned() throws {
        let root = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var read = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.contains("displayBox ="), "\(url.lastPathComponent) assigns the display box")
            read += 1
        }
        #expect(read > 100)
    }

    @Test("Source pin: the box-place probe names neither the turn nor any of the canvas's own geometry members")
    func probeStaysOnTheEnginesFrame() throws {
        let probe = try loadRepoFile("Sources/ResectaApp/Overlay/RedactionOverlayView+BoxPlace.swift")
        for name in ["CanvasTurn", "PageGeometry(page:", "displayedSize", "displayedRect(share:", "pageRect(share:",
                     "pagePoint(displayed:", "pointStep"] {
            #expect(!probe.contains(name), "the probe names \(name)")
        }
    }
}
