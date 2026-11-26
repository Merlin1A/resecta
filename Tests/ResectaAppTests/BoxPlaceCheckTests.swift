import Testing
import Foundation
import CoreGraphics
import UIKit
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// The run's box-place check, on a real canvas: a `FitFlooredPDFView` in a
// window with the coordinator as its overlay provider. The canvas is probed
// against the engine's frame for each page (`RunRecord.PageGeometry`); a
// finger's box carries the rectangle PDFKit gives it on the page; a page's
// geometry is noted when its boxes are stored. Every expected place here
// comes from UIKit's and PDFKit's conversions or the engine's frame, never
// from the canvas's own maps.

/// A touch at a point in the window, as `TurnedPageBoxBurnTests` makes it.
private final class WindowTouch: UITouch {
    var point: CGPoint
    private let target: UIView
    init(at point: CGPoint, on target: UIView) { self.point = point; self.target = target; super.init() }
    override func location(in view: UIView?) -> CGPoint { (view ?? target).convert(point, from: nil) }
    override func previousLocation(in view: UIView?) -> CGPoint { location(in: view) }
    override var view: UIView? { target }
    override var window: UIWindow? { target.window }
}

@Suite("The run's box-place check on the canvas")
@MainActor
struct BoxPlaceCheckTests {

    /// Each page: its media box, its rotation and its crop box (nil: the media box).
    struct PageCase: Sendable, CustomStringConvertible {
        let media: CGRect
        let rotation: Int
        let crop: CGRect?
        var description: String {
            "\(Int(media.width))x\(Int(media.height)) at \(rotation)°\(crop.map { " crop \($0)" } ?? "")"
        }
    }

    nonisolated static let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
    nonisolated static let a4 = CGRect(x: 0, y: 0, width: 595.276, height: 841.89)
    nonisolated static let cases: [PageCase] = [
        PageCase(media: letter, rotation: 0, crop: nil),
        PageCase(media: letter, rotation: 90, crop: nil),
        PageCase(media: letter, rotation: 180, crop: nil),
        PageCase(media: letter, rotation: 270, crop: nil),
        PageCase(media: letter, rotation: 90, crop: CGRect(x: 36, y: 54, width: 540, height: 684)),
        PageCase(media: a4, rotation: 0, crop: nil),
        PageCase(media: a4, rotation: 90, crop: nil),
        PageCase(media: letter, rotation: 270, crop: CGRect(x: 12.345, y: 67.891, width: 401.123, height: 577.777)),
        PageCase(media: CGRect(x: 0, y: 0, width: 5000, height: 3000), rotation: 0, crop: nil),
        PageCase(media: letter, rotation: 180, crop: CGRect(x: 12.345, y: 67.891, width: 401.123, height: 577.777)),
    ]

    static func document() throws -> PDFDocument {
        let data = UIGraphicsPDFRenderer(bounds: letter).pdfData { ctx in
            for c in cases {
                ctx.beginPage(withBounds: c.media, pageInfo: [:])
                ("Marigold" as NSString).draw(at: CGPoint(x: 80, y: 120),
                                              withAttributes: [.font: UIFont.boldSystemFont(ofSize: 40)])
            }
        }
        let document = try #require(PDFDocument(data: data))
        try #require(document.pageCount == cases.count)
        for (i, c) in cases.enumerated() {
            document.page(at: i)?.rotation = c.rotation
            if let crop = c.crop { document.page(at: i)?.setBounds(crop, for: .cropBox) }
        }
        return document
    }

    struct Canvas {
        let window: UIWindow
        let view: FitFlooredPDFView
        let coordinator: PDFViewCoordinator
        let state: RedactionState
        let document: PDFDocument
        let page: PDFPage
        let overlay: RedactionOverlayView
        var geometry: RunRecord.PageGeometry {
            RunRecord.PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        }
        /// A rect in the window as a rect on the page, by UIKit and PDFKit.
        func onPage(windowRect: CGRect) -> CGRect { view.convert(view.convert(windowRect, from: nil), to: page) }
    }

    private static func overlays(in view: UIView) -> [RedactionOverlayView] {
        view.subviews.flatMap { ($0 as? RedactionOverlayView).map { [$0] } ?? overlays(in: $0) }
    }

    static func canvas(_ pageIndex: Int, document: PDFDocument? = nil) throws -> Canvas {
        let document = try document ?? Self.document()
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
        let page = try #require(document.page(at: pageIndex))
        view.go(to: page)
        view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let overlay = try #require(overlays(in: view).first { $0.pageIndex == pageIndex },
                                   "PDFKit installed the coordinator's overlay for page \(pageIndex)")
        return Canvas(window: window, view: view, coordinator: coordinator, state: state,
                      document: document, page: page, overlay: overlay)
    }

    /// A finger drags the rectangle tool across `from`...`to` (window points).
    static func drag(_ c: Canvas, from start: CGPoint, to end: CGPoint) {
        c.overlay.isDrawingMode = true
        c.overlay.activeShapeTool = .rectangle
        let touch = WindowTouch(at: start, on: c.overlay)
        c.overlay.touchesBegan([touch], with: nil)
        for step in 1...4 {
            let t = CGFloat(step) / 4
            touch.point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            c.overlay.touchesMoved([touch], with: nil)
        }
        c.overlay.touchesEnded([touch], with: nil)
    }

    /// A finger presses a selected box at `at` and moves it by (dx, dy).
    static func move(_ c: Canvas, at start: CGPoint, by dx: CGFloat, _ dy: CGFloat) {
        c.overlay.isDrawingMode = false
        let touch = WindowTouch(at: start, on: c.overlay)
        c.overlay.touchesBegan([touch], with: nil)
        for step in 1...4 {
            let t = CGFloat(step) / 4
            touch.point = CGPoint(x: start.x + dx * t, y: start.y + dy * t)
            c.overlay.touchesMoved([touch], with: nil)
        }
        c.overlay.touchesEnded([touch], with: nil)
    }

    /// A band in the window over the middle of the page as shown.
    static func band(_ c: Canvas) -> (CGPoint, CGPoint) {
        let shown = c.view.convert(c.view.convert(c.page.bounds(for: .cropBox), from: c.page), to: nil)
        return (CGPoint(x: shown.minX + 0.21 * shown.width, y: shown.minY + 0.33 * shown.height),
                CGPoint(x: shown.minX + 0.47 * shown.width, y: shown.minY + 0.41 * shown.height))
    }

    static func record(_ state: RedactionState, _ document: PDFDocument) -> RunRecord.Confirmed {
        RunInputs.confirmedRecord(
            pageCount: document.pageCount, geometry: RunInputs.pageGeometry(of: document),
            geometryAtStore: state.geometryAtStore, regions: state.regions, reads: [:],
            settings: .init(pipelineMode: .secureRasterization, autoVerify: false, paranoidMode: false,
                            fillColor: .black, exportDPI: 150))
    }

    static func noteGeometry(_ c: Canvas) {
        let doc = c.document
        c.state.pageGeometryReader = { doc.page(at: $0).map {
            RunRecord.PageGeometry(cropBox: $0.bounds(for: .cropBox), rotation: $0.rotation) } }
    }

    // MARK: - The probe: the honest gap, measured

    @Test("The canvas probe passes on every page case at the fit floor, 1 and 5, and PDFKit's handover recorded no failure",
          arguments: 0..<9)
    func probePassesEverywhere(pageIndex: Int) throws {
        let c = try Self.canvas(pageIndex)
        #expect(c.state.canvasProbeFailures.isEmpty,
                "\(Self.cases[pageIndex]): the canvas failed the probe when PDFKit placed it")
        var largest: CGFloat = 0
        for zoom in [CGFloat(0), 1, 5] {
            c.view.autoScales = false
            c.view.maxScaleFactor = 5
            if zoom > 0 { c.view.scaleFactor = max(zoom, c.view.minScaleFactor) } else {
                c.view.scaleFactor = c.view.minScaleFactor }
            c.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            let gap = try #require(c.overlay.boxPlaceProbeGap(), "the canvas is placed")
            largest = max(largest, gap)
            let crop = c.page.bounds(for: .cropBox)
            print("BOXPLACE-GAP case=\(pageIndex) [\(Self.cases[pageIndex])] scale=\(c.view.scaleFactor) gap=\(gap) "
                  + "overlay=\(c.overlay.bounds.size) crop=\(crop.size)")
            #expect(gap <= RunRecord.boxPlaceTolerance,
                    "\(Self.cases[pageIndex]) at scale \(c.view.scaleFactor): probe gap \(gap) pt")
        }
        print("BOXPLACE-GAP-MAX case=\(pageIndex) gap=\(largest)")
        #expect(c.coordinator.boxPlaceProbeFailures().isEmpty)
        withExtendedLifetime((c.coordinator, c.window)) {}
    }

    // MARK: - A finger's box carries PDFKit's place

    @Test("A drawn box carries the page rectangle PDFKit gives the finger's band, and the run confirms it",
          arguments: 0..<9)
    func drawnBoxCarriesItsPage(pageIndex: Int) throws {
        let c = try Self.canvas(pageIndex)
        Self.noteGeometry(c)
        let (start, end) = Self.band(c)
        Self.drag(c, from: start, to: end)
        let region = try #require(c.state.regions[pageIndex]?.first, "the drag committed a box")
        let drawn = try #require(region.drawnPageRect, "a finger's box carries its page rectangle")
        let finger = c.onPage(windowRect: CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y))
        #expect(RunRecord.sideGap(drawn, finger) <= RunRecord.boxPlaceTolerance,
                "\(Self.cases[pageIndex]): drawn \(drawn), the finger's band on the page \(finger)")
        let record = Self.record(c.state, c.document)
        #expect(record.firstPageWithUnconfirmedBoxPlace(canvasFailures: c.state.canvasProbeFailuresAtRunEntry()) == nil)
        withExtendedLifetime((c.coordinator, c.window)) {}
    }

    @Test("Move, resize by drag, Undo and Redo keep each box's page rectangle with its share; the run confirms each step",
          arguments: [0, 1, 4, 6, 7])
    func gestureStepsAndUndo(pageIndex: Int) throws {
        let c = try Self.canvas(pageIndex)
        Self.noteGeometry(c)
        let (start, end) = Self.band(c)
        Self.drag(c, from: start, to: end)
        let id = try #require(c.state.regions[pageIndex]?.first?.id)
        c.state.selectedRegionID = id
        c.overlay.configure(with: c.state.regions[pageIndex] ?? [], selectedIDs: [id])
        func confirmed(_ what: String) {
            let region = c.state.regions[pageIndex]?.first { $0.id == id }
            #expect(region != nil)
            #expect(Self.record(c.state, c.document).firstPageWithUnconfirmedBoxPlace(canvasFailures: []) == nil,
                    "\(Self.cases[pageIndex]) after \(what): refused")
        }
        confirmed("the drag")
        let before = c.state.regions[pageIndex]?.first?.drawnPageRect
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        Self.move(c, at: mid, by: 31, -19)
        let moved = try #require(c.state.regions[pageIndex]?.first)
        #expect(moved.drawnPageRect != nil && moved.drawnPageRect != before, "the move carried its new page rectangle")
        confirmed("the move")
        // A move committed with an undo manager: Undo puts the share and its
        // page rectangle back together, and Redo puts the new pair back.
        let undo = UndoManager()
        let pre = try #require(c.state.regions[pageIndex]?.first)
        c.overlay.configure(with: c.state.regions[pageIndex] ?? [], selectedIDs: [id])
        let index = try #require(c.overlay.regions.firstIndex { $0.id == id })
        let band = c.overlay.pdfNormalizedToOverlay(pre.normalizedRect).offsetBy(dx: -40, dy: 25)
        c.overlay.storeFromGesture(index, overlayRect: band)
        c.coordinator.commitMove(id, page: pageIndex, newRect: c.overlay.regions[index].normalizedRect,
                                 drawnPageRect: c.overlay.drawnPageRects(for: [id])[id], undoManager: undo)
        let post = try #require(c.state.regions[pageIndex]?.first)
        #expect(post.drawnPageRect != nil && post.drawnPageRect != pre.drawnPageRect)
        confirmed("a committed move")
        undo.undo()
        #expect(c.state.regions[pageIndex]?.first?.normalizedRect == pre.normalizedRect)
        #expect(c.state.regions[pageIndex]?.first?.drawnPageRect == pre.drawnPageRect)
        confirmed("Undo")
        undo.redo()
        #expect(c.state.regions[pageIndex]?.first?.drawnPageRect == post.drawnPageRect)
        confirmed("Redo")
        withExtendedLifetime((c.coordinator, c.window)) {}
    }

    @Test("Undo of a resize, a move and a group move puts each whole region back, and Redo the edited one")
    func undoRestoresWholeRegions() throws {
        let state = RedactionState()
        let undo = UndoManager()
        undo.groupsByEvent = false
        var a = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05),
                                source: .searchMatch(term: "Marigold"), textAnchored: true)
        a.drawnPageRect = CGRect(x: 61, y: 79, width: 122, height: 40)
        var b = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.05),
                                source: .manual)
        b.drawnPageRect = CGRect(x: 306, y: 396, width: 61, height: 40)
        state.regions[0] = [a, b]
        func step(_ edit: () -> Void) throws -> ([RedactionRegion], [RedactionRegion]) {
            let before = state.regions[0] ?? []
            undo.beginUndoGrouping(); edit(); undo.endUndoGrouping()
            let after = state.regions[0] ?? []
            #expect(after != before, "the edit changed the page")
            undo.undo()
            #expect(state.regions[0] == before, "Undo puts every field of every region back")
            undo.redo()
            #expect(state.regions[0] == after, "Redo puts the edited regions back")
            undo.undo()
            return (before, after)
        }
        _ = try step { state.resizeRegion(a.id, page: 0, newRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05),
                                          undoManager: undo, drawnPageRect: CGRect(x: 61, y: 79, width: 183, height: 40)) }
        _ = try step { state.moveRegion(a.id, page: 0, newRect: CGRect(x: 0.2, y: 0.1, width: 0.2, height: 0.05),
                                        undoManager: undo) }
        _ = try step { state.moveRegions([(a.id, CGRect(x: 0.15, y: 0.1, width: 0.2, height: 0.05)),
                                          (b.id, CGRect(x: 0.55, y: 0.5, width: 0.1, height: 0.05))],
                                         page: 0, undoManager: undo) }
        #expect(state.regions[0] == [a, b])
    }

    @Test("Boxes no finger placed carry no page rectangle and are confirmed: found, duplicated, arrow-stepped, whole page",
          arguments: [1, 4, 6])
    func boxesNoGesturePlaced(pageIndex: Int) throws {
        let c = try Self.canvas(pageIndex)
        Self.noteGeometry(c)
        let (start, end) = Self.band(c)
        Self.drag(c, from: start, to: end)
        let drawnID = try #require(c.state.regions[pageIndex]?.first?.id)
        // An arrow step: a move with no gesture clears the page rectangle.
        let stepped = DocumentEditorView.nudgedRect(c.state.regions[pageIndex]![0].normalizedRect, dx: 0.02, dy: 0)
        c.state.moveRegion(drawnID, page: pageIndex, newRect: stepped, undoManager: nil)
        #expect(c.state.regions[pageIndex]?.first { $0.id == drawnID }?.drawnPageRect == nil)
        c.state.duplicateRegion(drawnID, page: pageIndex, undoManager: nil)
        let found = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.6, y: 0.7, width: 0.2, height: 0.04),
                                    source: .searchMatch(term: "Marigold"))
        c.state.addRegion(found, page: pageIndex, undoManager: nil)
        c.state.addRegion(RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                          source: .manual), page: pageIndex, undoManager: nil)
        let regions = c.state.regions[pageIndex] ?? []
        #expect(regions.count == 4)
        #expect(regions.allSatisfy { $0.drawnPageRect == nil })
        #expect(Self.record(c.state, c.document).firstPageWithUnconfirmedBoxPlace(
            canvasFailures: c.state.canvasProbeFailuresAtRunEntry()) == nil)
        // A page that holds only found boxes.
        c.state.regions[pageIndex] = [found]
        #expect(Self.record(c.state, c.document).firstPageWithUnconfirmedBoxPlace(canvasFailures: []) == nil)
        withExtendedLifetime((c.coordinator, c.window)) {}
    }

    @Test("The page rectangle is read from the gesture's own rect, not rebuilt from the stored share")
    func witnessFromTheGestureRect() throws {
        let c = try Self.canvas(1)
        c.overlay.configure(with: [RedactionRegion(id: UUID(), normalizedRect: .zero, source: .manual)], selectedIDs: [])
        let band = CGRect(x: 40, y: 60, width: 120, height: 30)
        c.overlay.storeFromGesture(0, overlayRect: band)
        let id = c.overlay.regions[0].id
        // A store map gone wrong: the share is planted in the page's stored frame.
        c.overlay.regions[0].normalizedRect = CanvasTurn.stored(fromShown: c.overlay.regions[0].normalizedRect, rotation: 90)
        let drawn = try #require(c.overlay.drawnPageRects(for: [id])[id])
        let expected = c.view.convert(c.overlay.convert(band, to: c.view), to: c.page)
        #expect(RunRecord.sideGap(drawn, expected) <= RunRecord.boxPlaceTolerance)
        var region = c.overlay.regions[0]
        region.drawnPageRect = drawn
        let page = RunRecord.Page(pageIndex: 1, regions: [RunRecord.DrawnRegion(region: region)],
            geometry: c.geometry, geometryAtStore: c.geometry, switchOn: false)
        #expect(!page.boxPlacesConfirmed(canvasFailed: false), "the stored share is off the drawn place")
        withExtendedLifetime((c.coordinator, c.window)) {}
    }

    // MARK: - Pages with no live canvas, and geometry

    @Test("A canvas that failed the probe at handover keeps its page refused after it leaves the screen")
    func handoverFailureIsKept() throws {
        let c = try Self.canvas(1)
        Self.noteGeometry(c)
        c.coordinator.recordBoxPlaceProbe(pageIndex: 1, passes: false)
        c.coordinator.pdfView(c.view, willEndDisplayingOverlayView: c.overlay, for: c.page)
        c.state.addRegion(RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05),
                                          source: .searchMatch(term: "Marigold")), page: 1, undoManager: nil)
        #expect(c.state.canvasProbeFailuresAtRunEntry().contains(1))
        #expect(Self.record(c.state, c.document).firstPageWithUnconfirmedBoxPlace(
            canvasFailures: c.state.canvasProbeFailuresAtRunEntry()) == 1)
        c.state.clearAll()
        #expect(c.state.canvasProbeFailures.isEmpty, "the document's close drops it")
        withExtendedLifetime((c.coordinator, c.window)) {}
    }

    @Test("A page whose rotation or crop box changed after its boxes were stored is refused; its note goes with its boxes")
    func geometryNotedAtStore() throws {
        let document = try Self.document()
        let state = RedactionState()
        state.pageGeometryReader = { document.page(at: $0).map {
            RunRecord.PageGeometry(cropBox: $0.bounds(for: .cropBox), rotation: $0.rotation) } }
        let region = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05),
                                     source: .manual)
        state.addRegion(region, page: 1, undoManager: nil)
        #expect(state.geometryAtStore[1] == RunRecord.PageGeometry(cropBox: Self.letter, rotation: 90))
        func refused() -> Int? {
            RunInputs.confirmedRecord(pageCount: document.pageCount, geometry: RunInputs.pageGeometry(of: document),
                                      geometryAtStore: state.geometryAtStore, regions: state.regions, reads: [:],
                                      settings: .init(pipelineMode: .secureRasterization, autoVerify: false,
                                                      paranoidMode: false, fillColor: .black, exportDPI: 150))
                .firstPageWithUnconfirmedBoxPlace(canvasFailures: [])
        }
        #expect(refused() == nil)
        document.page(at: 1)?.rotation = 180
        #expect(refused() == 1, "turned after its boxes were stored")
        document.page(at: 1)?.rotation = 90
        document.page(at: 1)?.setBounds(CGRect(x: 10, y: 0, width: 602, height: 792), for: .cropBox)
        #expect(refused() == 1, "cropped after its boxes were stored")
        state.removeRegion(region.id, page: 1, undoManager: nil)
        #expect(state.geometryAtStore[1] == nil, "a page with no box keeps no note")
        state.addRegion(region, page: 1, undoManager: nil)
        #expect(refused() == nil, "a box stored under the new crop is noted with it")
    }

    // MARK: - The run

    @Test("A run with a box stored off its drawn place is refused by name before anything is exported",
          .timeLimit(.minutes(2)))
    func runRefusesByName() async throws {
        let document = try Self.document()
        let coord = makeLoadedCoordinator(document: document)
        let page = try #require(document.page(at: 1))
        let geometry = RunRecord.PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        let shown = CGRect(x: 0.18, y: 0.62, width: 0.22, height: 0.05)
        // Drawn over `shown`, stored in the page's stored frame: the turn dropped.
        var region = RedactionRegion(id: UUID(), normalizedRect: CanvasTurn.stored(fromShown: shown, rotation: 90),
                                     source: .manual)
        region.drawnPageRect = geometry.pageRect(ofDisplayedShare: shown)
        coord.redactionState.addRegion(region, page: 1, undoManager: nil)
        coord.runFullPipeline(documentOverride: .secureRasterization)
        let task = try #require(coord.documentState.activePipelineTask, "the run started")
        await task.value
        guard case .failed(let error, _) = coord.documentState.phase,
              case .redactionError(.boxPlaceUnconfirmed(pageIndex: 1)) = error else {
            Issue.record("expected the box-place refusal on page 2, got \(coord.documentState.phase)")
            return
        }
        #expect(coord.redactionState.outputURL == nil, "nothing was exported")
        // Put where it was drawn, the same box runs.
        coord.redactionState.regions[1] = []
        region.normalizedRect = shown
        coord.redactionState.addRegion(region, page: 1, undoManager: nil)
        coord.documentState.phase = .editing
        coord.runFullPipeline(documentOverride: .secureRasterization)
        let second = try #require(coord.documentState.activePipelineTask)
        await second.value
        #expect(coord.redactionState.outputURL != nil, "the box confirmed where it was drawn is exported")
    }

    @Test("The refusal's title and message")
    func refusalCopy() {
        let error = PipelineError.redactionError(.boxPlaceUnconfirmed(pageIndex: 1))
        #expect(error.localizedTitle == "Redaction Verification Failed")
        #expect(error.localizedRecovery
            == "A box on page 2 could not be confirmed where it was drawn. Redaction stopped before any file was written.")
    }

    // MARK: - The hand box's terms

    @Test("A finger's box is read for its words where PDFKit put it, not where its share is stored")
    func termsReadFromTheDrawnPlace() throws {
        let document = try Self.document()
        let page = try #require(document.page(at: 1))
        let range = (try #require(page.string) as NSString).range(of: "Marigold")
        let word = try #require(page.selection(for: range)).bounds(for: page)
        let geometry = RunRecord.PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        // Stored somewhere empty, drawn over the word.
        var region = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.7, y: 0.05, width: 0.2, height: 0.04),
                                     source: .manual)
        region.drawnPageRect = word.insetBy(dx: -2, dy: -2)
        #expect(!geometry.pageRect(ofDisplayedShare: region.normalizedRect).intersects(word))
        let set = PipelineCoordinator.sensitiveTermSet(
            applied: [], manualRegions: [1: [region]], in: document, textLayerStatus: [1: .rich])
        #expect(set.terms.map(\.text).contains("Marigold"), "terms \(set.terms.map(\.text))")
    }
}
