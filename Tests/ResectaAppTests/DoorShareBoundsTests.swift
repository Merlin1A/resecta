import Testing
import Foundation
import CoreGraphics
import UIKit
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// Every editor entry stores a share on the page, to the slack (1e-12): a
// draw, a resize, a move, a group move, the keyboard's nudge and the
// duplicate, each read back from the state after it, on placed canvases in a
// real `FitFlooredPDFView`, where the page's rectangle on the canvas is
// PDFKit's own and not the canvas's rounded bounds. Bands are seeded; a third
// reach an edge of the bounds or of the page, or past one. Then the cases the
// property does not reach: the whole-page mark and a found box padded to a
// full side, dragged to every edge; a group whose union lies past the page;
// a found box past the edge through the apply, a move, Undo, a delete and the
// nudge's accept, none of which traps; and an overlay with no geometry, on
// which a touch begins nothing.

/// A touch at a point in the overlay's own points.
final class DoorTouch: UITouch {
    var point: CGPoint
    private let target: UIView
    init(at point: CGPoint, on target: UIView) { self.point = point; self.target = target; super.init() }
    override func location(in view: UIView?) -> CGPoint { (view ?? target).convert(point, from: target) }
    override func previousLocation(in view: UIView?) -> CGPoint { location(in: view) }
    override var view: UIView? { target }
    override var window: UIWindow? { target.window }
}

/// A window whose gestures' Undo steps go to one manager the test holds.
final class UndoWindow: UIWindow {
    let undo: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()
    override var undoManager: UndoManager? { undo }
}

@Suite("Every editor entry stores a share on the page, to the slack", .serialized)
@MainActor
struct DoorShareBoundsTests {

    static let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
    /// Letter; A4; ISO B5; the 540 × 684 crop at (36, 54); 500.3 × 700.7;
    /// the 401.123 × 577.777 crop at (12.345, 67.891).
    static let shapes: [(media: CGRect, crop: CGRect?)] = [
        (letter, nil),
        (CGRect(x: 0, y: 0, width: 595.276, height: 841.89), nil),
        (CGRect(x: 0, y: 0, width: 498.898, height: 708.661), nil),
        (letter, CGRect(x: 36, y: 54, width: 540, height: 684)),
        (CGRect(x: 0, y: 0, width: 500.3, height: 700.7), nil),
        (letter, CGRect(x: 12.345, y: 67.891, width: 401.123, height: 577.777)),
    ]
    static let turns = [0, 90, 180, 270]
    /// Page `shape × 4 + turn index`.
    nonisolated static let pageIndices = Array(0..<24)
    static func pageIndex(shape: Int, turn: Int) -> Int { shape * 4 + turns.firstIndex(of: turn)! }

    static func document() throws -> PDFDocument {
        let data = UIGraphicsPDFRenderer(bounds: letter).pdfData { ctx in
            for shape in shapes { for _ in turns { ctx.beginPage(withBounds: shape.media, pageInfo: [:]) } }
        }
        let document = try #require(PDFDocument(data: data))
        for (s, shape) in shapes.enumerated() {
            for turn in turns {
                let page = document.page(at: pageIndex(shape: s, turn: turn))
                page?.rotation = turn
                if let crop = shape.crop { page?.setBounds(crop, for: .cropBox) }
            }
        }
        return document
    }

    struct Canvas {
        let window: UndoWindow
        let view: FitFlooredPDFView
        let coordinator: PDFViewCoordinator
        let state: RedactionState
        let page: PDFPage
        let overlay: RedactionOverlayView
        var index: Int { overlay.pageIndex }
        var regions: [RedactionRegion] { state.regions[index] ?? [] }
    }

    private static func overlays(in view: UIView) -> [RedactionOverlayView] {
        view.subviews.flatMap { ($0 as? RedactionOverlayView).map { [$0] } ?? overlays(in: $0) }
    }

    static func canvas(_ index: Int) throws -> Canvas {
        let document = try document()
        let state = RedactionState()
        let coordinator = PDFViewCoordinator()
        coordinator.redactionState = state
        let window = UndoWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let view = FitFlooredPDFView(frame: window.bounds)
        view.displayMode = .singlePage
        view.pageOverlayViewProvider = coordinator
        view.document = document
        window.addSubview(view)
        window.isHidden = false
        let page = try #require(document.page(at: index))
        view.go(to: page)
        view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let overlay = try #require(overlays(in: view).first { $0.pageIndex == index })
        try #require(overlay.boxPlaceProbeGap() != nil, "page \(index) is placed")
        return Canvas(window: window, view: view, coordinator: coordinator, state: state, page: page, overlay: overlay)
    }

    /// A finger from `start` to `end`, in the overlay's points, in four steps.
    static func gesture(_ c: Canvas, from start: CGPoint, to end: CGPoint) {
        let touch = DoorTouch(at: start, on: c.overlay)
        c.overlay.touchesBegan([touch], with: nil)
        for step in 1...4 {
            let t = CGFloat(step) / 4
            touch.point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            c.overlay.touchesMoved([touch], with: nil)
        }
        c.overlay.touchesEnded([touch], with: nil)
    }

    static func select(_ c: Canvas, _ ids: Set<UUID>) {
        c.state.selectedRegionIDs = ids
        c.overlay.configure(with: c.regions, selectedIDs: ids)
    }

    static func centre(_ c: Canvas, _ id: UUID) throws -> CGPoint {
        let r = c.overlay.pdfNormalizedToOverlay(try #require(c.regions.first { $0.id == id }?.normalizedRect))
        return CGPoint(x: r.midX, y: r.midY)
    }

    /// Whether a share lies on the unit square, each edge within the slack
    /// plus `extra`.
    static func onThePage(_ r: CGRect, extra: CGFloat = 0) -> Bool {
        let e = RedactionState.shareSlack + extra
        return r.minX >= -e && r.minY >= -e && r.maxX <= 1 + e && r.maxY <= 1 + e
    }

    static func expectAllOnThePage(_ c: Canvas, _ what: String) -> Int {
        for region in c.regions {
            #expect(onThePage(region.normalizedRect), "page \(c.index) after \(what): \(region.normalizedRect)")
        }
        return c.regions.count
    }

    /// A seeded generator (SplitMix64).
    struct Seeded {
        var state: UInt64
        mutating func next() -> CGFloat {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return CGFloat(Double((z ^ (z >> 31)) >> 11) / Double(1 << 53))
        }
    }

    /// A point for a band's end: inside the page's rectangle on the canvas,
    /// or, one time in three, on an edge of the page or of the bounds, or
    /// past one.
    static func point(_ random: inout Seeded, page p: CGRect, bounds b: CGRect) -> CGPoint {
        var x = p.minX + random.next() * p.width, y = p.minY + random.next() * p.height
        if random.next() < 1.0 / 3 {
            let xs = [p.minX, p.maxX, b.minX, b.maxX, p.minX - 40, p.maxX + 40]
            let ys = [p.minY, p.maxY, b.minY, b.maxY, p.minY - 40, p.maxY + 40]
            if random.next() < 0.5 { x = xs[Int(random.next() * 6) % 6] } else { y = ys[Int(random.next() * 6) % 6] }
        }
        return CGPoint(x: x, y: y)
    }

    @Test("Seeded bands through every editor entry, at each turn, on six page shapes: each stored share lies on the page",
          arguments: pageIndices)
    func everyEntryStoresOnThePage(index: Int) throws {
        let c = try Self.canvas(index)
        let p = c.overlay.pageRectOnCanvas, b = c.overlay.bounds
        var random = Seeded(state: 0xD00A_0000 &+ UInt64(index))
        var checked = 0
        for band in 0..<6 {
            c.state.regions[index] = []
            Self.select(c, [])
            // Draw: a band of at least 30 points each way.
            var start = Self.point(&random, page: p, bounds: b), end = Self.point(&random, page: p, bounds: b)
            if abs(end.x - start.x) < 30 { end.x = start.x + (start.x < p.midX ? 60 : -60) }
            if abs(end.y - start.y) < 30 { end.y = start.y + (start.y < p.midY ? 60 : -60) }
            c.overlay.isDrawingMode = true
            c.overlay.activeShapeTool = .rectangle
            Self.gesture(c, from: start, to: end)
            checked += Self.expectAllOnThePage(c, "band \(band)'s draw")
            guard let a = c.regions.last?.id else { continue }
            // A second and a third box for the group.
            for _ in 0..<2 {
                start = Self.point(&random, page: p, bounds: b)
                end = CGPoint(x: start.x + (start.x < p.midX ? 50 : -50), y: start.y + (start.y < p.midY ? 50 : -50))
                Self.gesture(c, from: start, to: end)
            }
            c.overlay.isDrawingMode = false
            checked += Self.expectAllOnThePage(c, "band \(band)'s other draws")
            // Resize the first box by its bottom-right handle, if a touch lands on it.
            Self.select(c, [a])
            let box = c.overlay.pdfNormalizedToOverlay(try #require(c.regions.first { $0.id == a }?.normalizedRect))
            let corner = RedactionOverlayView.handlePoint(.bottomRight, in: box)
            if c.overlay.hitTestResizeHandle(at: corner) != nil {
                Self.gesture(c, from: corner, to: Self.point(&random, page: p, bounds: b))
                checked += Self.expectAllOnThePage(c, "band \(band)'s resize")
            }
            // Move the first box, by a seeded step or far past an edge.
            Self.select(c, [a])
            var at = try Self.centre(c, a)
            let far: CGFloat = random.next() < 1.0 / 3 ? 2000 : 0
            Self.gesture(c, from: at, to: CGPoint(x: at.x + (random.next() - 0.5) * 300 + far, y: at.y + (random.next() - 0.5) * 300 - far))
            checked += Self.expectAllOnThePage(c, "band \(band)'s move")
            // Move the group of all three, by the first box.
            Self.select(c, Set(c.regions.map(\.id)))
            at = try Self.centre(c, a)
            Self.gesture(c, from: at, to: CGPoint(x: at.x - (random.next() - 0.5) * 300 - far, y: at.y + far))
            checked += Self.expectAllOnThePage(c, "band \(band)'s group move")
            // The keyboard's nudge, as its handler steps and stores, each way.
            let step = DocumentEditorView.nudgeStep(page: c.page)
            for (dx, dy) in [(step.dx, 0.0), (-step.dx, 0.0), (0.0, step.dy), (0.0, -step.dy)] {
                let r = try #require(c.regions.first { $0.id == a }?.normalizedRect)
                let nudged = DocumentEditorView.nudgedRect(r, dx: dx, dy: dy)
                #expect(Self.onThePage(nudged), "page \(index): the nudge's \(nudged)")
                _ = c.state.moveRegion(a, page: index, newRect: nudged, undoManager: nil)
            }
            checked += Self.expectAllOnThePage(c, "band \(band)'s nudges")
            // The duplicate.
            c.state.duplicateRegion(a, page: index, undoManager: nil)
            checked += Self.expectAllOnThePage(c, "band \(band)'s duplicate")
        }
        #expect(checked >= 6 * 5, "page \(index): \(checked) stored shares read back")
        withExtendedLifetime((c.coordinator, c.window)) {}
    }

    /// The deltas that push a box to each edge, in the overlay's points.
    static let toEachEdge: [(CGFloat, CGFloat)] = [(2000, 0), (-2000, 0), (0, 2000), (0, -2000)]

    @Test("The whole-page mark and a found box padded to a full side, dragged to every edge at 270° on the 401.123 crop, alone and with another box, stay on the page; the bar and the menu still read it as the mark")
    func fullSideBoxesStayOnThePage() throws {
        let index = Self.pageIndex(shape: 5, turn: 270)
        for withAnother in [false, true] {
            for padded in [false, true] {
                let c = try Self.canvas(index)
                let p = c.overlay.pageRectOnCanvas
                let box = padded
                    ? RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0, y: 0.4, width: 1, height: 0.03),
                                      source: .searchMatch(term: "line"))
                    : PageNavigationBar.wholePageRegion()
                c.state.addRegion(box, page: index, undoManager: nil)
                var ids: Set<UUID> = [box.id]
                if withAnother {
                    c.overlay.isDrawingMode = true
                    Self.gesture(c, from: CGPoint(x: p.midX - 40, y: p.midY - 40), to: CGPoint(x: p.midX + 20, y: p.midY + 20))
                    c.overlay.isDrawingMode = false
                    ids.formUnion(c.regions.map(\.id))
                    try #require(ids.count == 2, "the second box was drawn")
                }
                for (dx, dy) in Self.toEachEdge {
                    let before = try #require(c.regions.first { $0.id == box.id }?.normalizedRect)
                    Self.select(c, ids)
                    let at = padded ? try Self.centre(c, box.id) : CGPoint(x: p.minX + 8, y: p.minY + 8)
                    Self.gesture(c, from: at, to: CGPoint(x: at.x + dx, y: at.y + dy))
                    let after = try #require(c.regions.first { $0.id == box.id }?.normalizedRect)
                    let what = "\(padded ? "the padded box" : "the mark")\(withAnother ? " with another" : "") pushed (\(dx), \(dy))"
                    _ = Self.expectAllOnThePage(c, what)
                    // A full side stays a full side, within the slack.
                    #expect(abs(after.width - before.width) <= RedactionState.shareSlack
                                && abs(after.height - before.height) <= RedactionState.shareSlack, "\(what): \(before) → \(after)")
                    if !padded {
                        #expect(RedactionState.isWholePage(after), "\(what): \(after)")
                        #expect(PageNavigationBar.isWholePageMarked(page: index, in: c.state), "\(what): the bar lost the mark")
                        let region = try #require(c.regions.first { $0.id == box.id })
                        let rows = RedactionOverlayView.contextMenuRows(
                            for: region, selectedIDs: [box.id], infoTitle: nil, canSelectAllOnPage: true, showsRationale: false)
                        #expect(!rows.contains(.duplicate), "\(what): the menu offers Duplicate on the mark")
                    }
                }
                withExtendedLifetime((c.coordinator, c.window)) {}
            }
        }
    }

    @Test("A group whose union lies past the page keeps that excess and no more: a found box 1.9 pt past the right edge moved with a box at the left edge",
          arguments: [0, 5])
    func wideGroupKeepsItsExcess(shape: Int) throws {
        let index = Self.pageIndex(shape: shape, turn: shape == 0 ? 0 : 270)
        let c = try Self.canvas(index)
        let geometry = c.overlay.geometry
        let past = 1.9 / geometry.displayedSize.width
        let found = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.7, y: 0.5, width: 0.3 + past, height: 0.03),
                                    source: .searchMatch(term: "found"))
        c.state.addRegion(found, page: index, undoManager: nil)
        // A band over the whole page and past it stores a box at every edge.
        let p = c.overlay.pageRectOnCanvas
        c.overlay.isDrawingMode = true
        Self.gesture(c, from: CGPoint(x: p.minX - 40, y: p.minY - 40), to: CGPoint(x: p.maxX + 40, y: p.maxY + 40))
        c.overlay.isDrawingMode = false
        try #require(c.regions.count == 2, "the band was drawn")
        let union = c.regions.map(\.normalizedRect).reduce(CGRect.null) { $0.union($1) }
        let e = RedactionState.excessPastThePage(union)
        #expect(abs(e - past) < 1e-9)
        for (dx, dy) in Self.toEachEdge {
            Self.select(c, Set(c.regions.map(\.id)))
            let at = try Self.centre(c, found.id)
            Self.gesture(c, from: at, to: CGPoint(x: at.x + dx, y: at.y + dy))
            for region in c.regions {
                #expect(Self.onThePage(region.normalizedRect, extra: e), "pushed (\(dx), \(dy)): \(region.normalizedRect)")
            }
        }
        withExtendedLifetime((c.coordinator, c.window)) {}
    }

    @Test("A found box past the edge, applied, moved and undone, deleted and undone, and accepted as a nudge, is stored as found and never traps")
    func foundBoxPastTheEdgeThroughTheDoors() throws {
        let index = Self.pageIndex(shape: 0, turn: 0)
        let c = try Self.canvas(index)
        let past = 2 / c.overlay.geometry.displayedSize.width
        let rect = CGRect(x: 0.75, y: 0.3, width: 0.25 + past, height: 0.025)
        let found = RedactionRegion(id: UUID(), normalizedRect: rect, source: .searchMatch(term: "found"))
        let undo = c.window.undo
        undo.beginUndoGrouping()
        c.state.commitApply(createdRegions: [index: [found]], createdMetadata: [:], createdAudit: [:],
                            actionName: "Apply", runDeselectionParts: [], undoManager: undo)
        undo.endUndoGrouping()
        #expect(c.regions.first { $0.id == found.id }?.normalizedRect == rect, "stored as found")
        // Moved by a gesture, then undone.
        Self.select(c, [found.id])
        let at = try Self.centre(c, found.id)
        undo.beginUndoGrouping()
        Self.gesture(c, from: at, to: CGPoint(x: at.x - 30, y: at.y + 20))
        undo.endUndoGrouping()
        let moved = try #require(c.regions.first { $0.id == found.id }?.normalizedRect)
        #expect(Self.onThePage(moved), "the move stores on the page: \(moved)")
        undo.undo()
        #expect(c.regions.first { $0.id == found.id }?.normalizedRect == rect, "Undo puts it back as found")
        // Deleted, then undone.
        undo.beginUndoGrouping()
        c.state.removeRegion(found.id, page: index, undoManager: undo)
        undo.endUndoGrouping()
        #expect(c.regions.first { $0.id == found.id } == nil)
        undo.undo()
        #expect(c.regions.first { $0.id == found.id }?.normalizedRect == rect, "Undo of the delete puts it back as found")
        // Accepted as a nudge on a fresh document.
        let fresh = RedactionState()
        let nudge = SearchResult(pageIndex: 0, normalizedRect: rect, matchedText: "found", contextSnippet: "found",
                                 source: .ocr(confidence: 0.8), term: "found")
        let accepted = try #require(fresh.acceptManualDrawNudge(nudge, undoManager: nil))
        #expect(fresh.regions[0]?.first { $0.id == accepted.id }?.normalizedRect == rect, "the nudge's accept stores it as found")
        withExtendedLifetime((c.coordinator, c.window)) {}
    }

    @Test("An overlay with no page geometry begins no gesture: a touch on it is refused once, and a draw stores nothing")
    func defaultOverlayBeginsNothing() {
        let state = RedactionState()
        let coordinator = PDFViewCoordinator()
        coordinator.redactionState = state
        let window = UIWindow(frame: Self.letter)
        let overlay = RedactionOverlayView(frame: Self.letter)
        window.addSubview(overlay)
        overlay.coordinator = coordinator
        overlay.isDrawingMode = true
        overlay.activeShapeTool = .rectangle
        var refused = 0
        let saved = RedactionOverlayView.noGeometry
        RedactionOverlayView.noGeometry = { refused += 1 }
        defer { RedactionOverlayView.noGeometry = saved }
        let touch = DoorTouch(at: CGPoint(x: 100, y: 100), on: overlay)
        overlay.touchesBegan([touch], with: nil)
        #expect(refused == 1)
        touch.point = CGPoint(x: 300, y: 400)
        overlay.touchesMoved([touch], with: nil)
        overlay.touchesEnded([touch], with: nil)
        let storedNothing = state.regions.values.allSatisfy { $0.isEmpty }
        #expect(storedNothing)
        withExtendedLifetime((coordinator, window)) {}
    }
}
