import Testing
import Foundation
import CoreGraphics
import UIKit
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// A box on a page shown turned (its /Rotate 90, 180 or 270), drawn by a
// finger on the canvas or returned by Search, covers the word it was put
// over: on screen, and in the file when the document is burned or made
// searchable. Unturned pages are the control.
//
// The finger's points are given in the window, where a person touches the
// word they see, and reach the canvas through its touch handlers; asked
// for its location, the touch answers through each view's own coordinates
// as UIKit does. Nothing in this suite turns a point or a rectangle into
// the page's space itself. The output is read as the page is shown, under
// the word's rectangle there.

/// A touch at a point in the window. Its location in a view is that point
/// in the view's own coordinates, its transform included, as UIKit gives it.
private final class WindowPointTouch: UITouch {
    var point: CGPoint
    private let target: UIView

    init(at point: CGPoint, on target: UIView) {
        self.point = point
        self.target = target
        super.init()
    }

    override func location(in view: UIView?) -> CGPoint {
        (view ?? target).convert(point, from: nil)
    }
    override func previousLocation(in view: UIView?) -> CGPoint { location(in: view) }
    override var view: UIView? { target }
    override var window: UIWindow? { target.window }
}

@Suite("Boxes on a turned page")
@MainActor
struct TurnedPageBoxBurnTests {

    static let word = "Marigold"
    nonisolated static let turns = [0, 90, 180, 270]
    // Secure Rasterization only: Searchable Redaction is not offered, and the
    // app's run is Secure Rasterization for every input.
    nonisolated static let modes: [PipelineMode] = [.secureRasterization]

    /// One Letter page holding the word in bold 40, shown turned by `rotation`.
    static func document(rotation: Int) throws -> PDFDocument {
        let size = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: size).pdfData { ctx in
            ctx.beginPage(withBounds: size, pageInfo: [:])
            (word as NSString).draw(at: CGPoint(x: 80, y: 120),
                                    withAttributes: [.font: UIFont.boldSystemFont(ofSize: 40), .foregroundColor: UIColor.black])
        }
        let document = try #require(PDFDocument(data: data))
        document.page(at: 0)?.rotation = rotation
        return document
    }

    /// The editor's canvas on that page: a fit-floored PDF view in a window,
    /// with the coordinator's overlay installed by PDFKit.
    struct Canvas {
        let window: UIWindow
        let view: FitFlooredPDFView
        let coordinator: PDFViewCoordinator
        let state: RedactionState
        let document: PDFDocument
        let page: PDFPage
        let overlay: RedactionOverlayView

        /// The word's rectangle on screen, in the window.
        var wordOnScreen: CGRect {
            let range = (page.string! as NSString).range(of: TurnedPageBoxBurnTests.word)
            let inPage = page.selection(for: range)!.bounds(for: page)
            return view.convert(view.convert(inPage, from: page), to: nil)
        }

        /// The word's rectangle as a share of the page as shown, top-left origin.
        var wordShown: CGRect {
            let pageOnScreen = view.convert(view.convert(page.bounds(for: .cropBox), from: page), to: nil)
            let word = wordOnScreen
            return CGRect(x: (word.minX - pageOnScreen.minX) / pageOnScreen.width,
                          y: (word.minY - pageOnScreen.minY) / pageOnScreen.height,
                          width: word.width / pageOnScreen.width, height: word.height / pageOnScreen.height)
        }
    }

    static func canvas(rotation: Int) throws -> Canvas {
        let document = try document(rotation: rotation)
        let state = RedactionState()
        let coordinator = PDFViewCoordinator()
        coordinator.redactionState = state
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let view = FitFlooredPDFView(frame: window.bounds)
        view.displayMode = .singlePage
        view.pageOverlayViewProvider = coordinator
        view.document = document
        window.addSubview(view)
        window.isHidden = false
        let page = try #require(document.page(at: 0))
        view.go(to: page)
        view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let overlay = try #require(overlays(in: view).first { $0.pageIndex == 0 }, "PDFKit installed the overlay")
        return Canvas(window: window, view: view, coordinator: coordinator, state: state,
                      document: document, page: page, overlay: overlay)
    }

    private static func overlays(in view: UIView) -> [RedactionOverlayView] {
        view.subviews.flatMap { ($0 as? RedactionOverlayView).map { [$0] } ?? overlays(in: $0) }
    }

    /// A finger drags the rectangle tool from 8 points above and before the
    /// word's corner to 8 points past its far corner, as a person would over
    /// the word they see. Returns the region the canvas committed.
    static func drawOverWord(_ canvas: Canvas) throws -> RedactionRegion {
        canvas.overlay.isDrawingMode = true
        canvas.overlay.activeShapeTool = .rectangle
        let word = canvas.wordOnScreen
        let start = CGPoint(x: word.minX - 8, y: word.minY - 8)
        let end = CGPoint(x: word.maxX + 8, y: word.maxY + 8)
        let touch = WindowPointTouch(at: start, on: canvas.overlay)
        canvas.overlay.touchesBegan([touch], with: nil)
        for step in 1...4 {
            let t = CGFloat(step) / 4
            touch.point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            canvas.overlay.touchesMoved([touch], with: nil)
        }
        canvas.overlay.touchesEnded([touch], with: nil)
        let regions = canvas.state.regions[0] ?? []
        #expect(regions.count == 1, "the drag committed one box")
        return try #require(regions.first)
    }

    /// The box Search returns for the word on that page.
    static func searchBox(_ canvas: Canvas) throws -> RedactionRegion {
        let range = (canvas.page.string! as NSString).range(of: word)
        let rect = try #require(DocumentSearcher().boundingRect(for: range, page: canvas.page))
        return RedactionRegion(id: UUID(), normalizedRect: rect, source: .searchMatch(term: word))
    }

    /// Luminance 0...255 at 15 points across `rect` (shares of the page as
    /// shown, top-left origin) of `page` rendered as it is shown.
    static func lumas(_ page: PDFPage, _ rect: CGRect) -> [Int] {
        let image = page.thumbnail(of: CGSize(width: 1200, height: 1200), for: .cropBox)
        guard let cg = image.cgImage else { return [] }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out: [Int] = []
        for i in 0..<5 {
            for j in 0..<3 {
                let fx = rect.minX + rect.width * (0.1 + 0.2 * Double(i))
                let fy = rect.minY + rect.height * (0.2 + 0.3 * Double(j))
                let x = min(w - 1, Int(fx * Double(w))), y = min(h - 1, Int(fy * Double(h)))
                let o = (y * w + x) * 4
                out.append((Int(px[o]) * 299 + Int(px[o + 1]) * 587 + Int(px[o + 2]) * 114) / 1000)
            }
        }
        return out
    }

    /// Runs the pipeline in `mode` with `region` on the page and returns the
    /// output document.
    static func burn(_ canvas: Canvas, _ region: RedactionRegion, mode: PipelineMode) async throws -> PDFDocument {
        let coord = makeLoadedCoordinator(document: canvas.document)
        coord.redactionState.addRegion(region, page: 0, undoManager: nil)
        coord.runFullPipeline(documentOverride: mode)
        let task = try #require(coord.documentState.activePipelineTask, "the run started")
        await task.value
        let url = try #require(coord.redactionState.outputURL, "the run wrote an output")
        return try #require(PDFDocument(url: url))
    }

    static func expectWordCovered(_ output: PDFDocument, _ canvas: Canvas, mode: PipelineMode,
                                  _ what: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let page = try #require(output.page(at: 0), sourceLocation: sourceLocation)
        let under = lumas(page, canvas.wordShown)
        #expect(under.count == 15, sourceLocation: sourceLocation)
        #expect(under.allSatisfy { $0 < 40 },
                "\(what), \(mode) at \(canvas.page.rotation)°: the word is not covered in the output, lumas \(under)",
                sourceLocation: sourceLocation)
        if mode == .searchableRedaction {
            #expect(!(page.string ?? "").contains(word),
                    "\(what), searchable at \(canvas.page.rotation)°: the word's text is still in the output",
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: - In the file

    @Test("A box drawn over a word on a turned page covers that word in the output",
          .timeLimit(.minutes(3)), arguments: turns, modes)
    func drawnBoxCoversItsWord(rotation: Int, mode: PipelineMode) async throws {
        let canvas = try Self.canvas(rotation: rotation)
        let region = try Self.drawOverWord(canvas)
        let output = try await Self.burn(canvas, region, mode: mode)
        try Self.expectWordCovered(output, canvas, mode: mode, "a drawn box")
        withExtendedLifetime(canvas) {}
    }

    @Test("A box Search returns on a turned page covers its word in the output",
          .timeLimit(.minutes(3)), arguments: turns, modes)
    func searchBoxCoversItsWord(rotation: Int, mode: PipelineMode) async throws {
        let canvas = try Self.canvas(rotation: rotation)
        let output = try await Self.burn(canvas, try Self.searchBox(canvas), mode: mode)
        try Self.expectWordCovered(output, canvas, mode: mode, "a Search box")
        withExtendedLifetime(canvas) {}
    }

    // MARK: - Moved, resized, nudged

    /// A finger drag of one touch through `from` to `to`, window points.
    static func fingerDrag(_ canvas: Canvas, from: CGPoint, to: CGPoint) {
        let touch = WindowPointTouch(at: from, on: canvas.overlay)
        canvas.overlay.touchesBegan([touch], with: nil)
        for step in 1...6 {
            let t = CGFloat(step) / 6
            touch.point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            canvas.overlay.touchesMoved([touch], with: nil)
        }
        canvas.overlay.touchesEnded([touch], with: nil)
    }

    /// The rectangle tool drawn by a finger from `from` to `to`, window
    /// points; the box is then selected, with the tool off.
    static func drawAndSelect(_ canvas: Canvas, from: CGPoint, to: CGPoint) throws -> UUID {
        canvas.overlay.isDrawingMode = true
        canvas.overlay.activeShapeTool = .rectangle
        fingerDrag(canvas, from: from, to: to)
        canvas.overlay.isDrawingMode = false
        let region = try #require(canvas.state.regions[0]?.first, "the drag committed a box")
        canvas.state.selectedRegionIDs = [region.id]
        canvas.overlay.configure(with: canvas.state.regions[0] ?? [], selectedIDs: [region.id])
        return region.id
    }

    static func onlyRegion(_ canvas: Canvas) throws -> RedactionRegion {
        let regions = canvas.state.regions[0] ?? []
        #expect(regions.count == 1)
        return try #require(regions.first)
    }

    @Test("A box moved by a finger onto a word on a turned page covers that word in the output",
          .timeLimit(.minutes(3)), arguments: turns)
    func movedBoxCoversItsWord(rotation: Int) async throws {
        let canvas = try Self.canvas(rotation: rotation)
        let word = canvas.wordOnScreen.insetBy(dx: -8, dy: -8)
        // Drawn the word's size, beside it on screen, then dragged onto it.
        let away = word.width > word.height
            ? CGPoint(x: 0, y: word.height + 30)
            : CGPoint(x: word.width + 40 < word.minX ? -(word.width + 30) : word.width + 30, y: 0)
        let drawn = word.offsetBy(dx: away.x, dy: away.y)
        _ = try Self.drawAndSelect(canvas, from: CGPoint(x: drawn.minX, y: drawn.minY),
                                   to: CGPoint(x: drawn.maxX, y: drawn.maxY))
        Self.fingerDrag(canvas, from: CGPoint(x: drawn.midX, y: drawn.midY), to: CGPoint(x: word.midX, y: word.midY))
        let output = try await Self.burn(canvas, try Self.onlyRegion(canvas), mode: .secureRasterization)
        try Self.expectWordCovered(output, canvas, mode: .secureRasterization, "a moved box")
        withExtendedLifetime(canvas) {}
    }

    @Test("A box resized by a finger over a word on a turned page covers that word in the output",
          .timeLimit(.minutes(3)), arguments: turns)
    func resizedBoxCoversItsWord(rotation: Int) async throws {
        let canvas = try Self.canvas(rotation: rotation)
        let word = canvas.wordOnScreen.insetBy(dx: -8, dy: -8)
        // Drawn over the word's first half on screen, then its far corner
        // dragged past the word's far corner.
        _ = try Self.drawAndSelect(canvas, from: CGPoint(x: word.minX, y: word.minY),
                                   to: CGPoint(x: word.midX, y: word.midY))
        Self.fingerDrag(canvas, from: CGPoint(x: word.midX, y: word.midY), to: CGPoint(x: word.maxX, y: word.maxY))
        let output = try await Self.burn(canvas, try Self.onlyRegion(canvas), mode: .secureRasterization)
        try Self.expectWordCovered(output, canvas, mode: .secureRasterization, "a resized box")
        withExtendedLifetime(canvas) {}
    }

    /// The arrow keys reach the editor through its SwiftUI key handler,
    /// which a hosted test cannot press; this applies that handler's own
    /// step and move (`nudgeStep`, `nudgedRect`) with its signs for the
    /// right and down arrows, then reads where the canvas draws the box.
    @Test("The right and down arrows move a box right and down on screen on a turned page", arguments: turns)
    func arrowsMoveTheBoxAsShown(rotation: Int) throws {
        let canvas = try Self.canvas(rotation: rotation)
        let word = canvas.wordOnScreen.insetBy(dx: -8, dy: -8)
        let id = try Self.drawAndSelect(canvas, from: CGPoint(x: word.minX, y: word.minY),
                                        to: CGPoint(x: word.maxX, y: word.maxY))
        canvas.overlay.configure(with: canvas.state.regions[0] ?? [], selectedIDs: [])
        let before = try #require(Self.paintedOnScreen(canvas.overlay))
        let step = DocumentEditorView.nudgeStep(page: canvas.page)
        for (dx, dy) in [(step.dx, 0.0), (step.dx, 0.0), (0.0, step.dy), (0.0, step.dy)] + Array(repeating: (step.dx, 0.0), count: 18) + Array(repeating: (0.0, step.dy), count: 18) {
            let region = try Self.onlyRegion(canvas)
            _ = canvas.state.moveRegion(id, page: 0, newRect: DocumentEditorView.nudgedRect(region.normalizedRect, dx: dx, dy: dy),
                                        undoManager: nil)
        }
        canvas.overlay.configure(with: canvas.state.regions[0] ?? [], selectedIDs: [])
        let after = try #require(Self.paintedOnScreen(canvas.overlay))
        let right = after.midX - before.midX, down = after.midY - before.midY
        #expect(right > 4 && down > 4,
                "at \(rotation)°, 20 right and 20 down presses moved the box \(right) right and \(down) down on screen")
        withExtendedLifetime(canvas) {}
    }

    // MARK: - On screen

    /// The box of what the overlay paints, in its own space, carried to the
    /// window by the overlay's own transform as the screen shows it. The
    /// boxes are layers that the boxes' pass makes when their container is
    /// laid out, which rendering the layer does not do: the pass runs first.
    static func paintedOnScreen(_ overlay: RedactionOverlayView) -> CGRect? {
        overlay.boxLayers.root.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: overlay.bounds, format: format).image { ctx in
            overlay.layer.render(in: ctx.cgContext)
        }
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where px[(y * w + x) * 4 + 3] > 20 {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let sx = overlay.bounds.width / Double(w), sy = overlay.bounds.height / Double(h)
        let painted = CGRect(x: overlay.bounds.minX + Double(minX) * sx, y: overlay.bounds.minY + Double(minY) * sy,
                             width: Double(maxX - minX + 1) * sx, height: Double(maxY - minY + 1) * sy)
        return overlay.convert(painted, to: nil)
    }

    static func shareOfWord(_ painted: CGRect?, _ word: CGRect) -> Double {
        guard let painted else { return 0 }
        let overlap = painted.intersection(word)
        return overlap.isNull ? 0 : (overlap.width * overlap.height) / (word.width * word.height)
    }

    @Test("A box Search returns on a turned page is drawn over its word on screen", arguments: turns)
    func searchBoxDrawnOverItsWord(rotation: Int) throws {
        let canvas = try Self.canvas(rotation: rotation)
        canvas.overlay.configure(with: [try Self.searchBox(canvas)], selectedIDs: [])
        let painted = Self.paintedOnScreen(canvas.overlay)
        let share = Self.shareOfWord(painted, canvas.wordOnScreen)
        #expect(share > 0.9, "at \(rotation)°, the Search box is drawn at \(String(describing: painted)), \(share) of the word \(canvas.wordOnScreen)")
        withExtendedLifetime(canvas) {}
    }

    @Test("A box drawn over a word on a turned page stays over it on screen", arguments: turns)
    func drawnBoxStaysOverItsWord(rotation: Int) throws {
        let canvas = try Self.canvas(rotation: rotation)
        let region = try Self.drawOverWord(canvas)
        canvas.overlay.isDrawingMode = false
        canvas.overlay.configure(with: [region], selectedIDs: [])
        let painted = Self.paintedOnScreen(canvas.overlay)
        let share = Self.shareOfWord(painted, canvas.wordOnScreen)
        #expect(share > 0.9, "at \(rotation)°, the drawn box is drawn at \(String(describing: painted)), \(share) of the word \(canvas.wordOnScreen)")
        withExtendedLifetime(canvas) {}
    }
}
