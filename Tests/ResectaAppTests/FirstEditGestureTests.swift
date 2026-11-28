import CoreGraphics
import CryptoKit
import Foundation
import Testing
import UIKit
@testable import RedactionEngine
@testable import ResectaApp

// The first move or resize of a box placed from the page's text starts from
// the box's start, the rectangle the page's plan paints it with, and not
// from the word's own extent: only the edges the finger moves change. Driven
// through the real overlay, coordinator and state, with each box's start
// given through `overlay.startReader`. The rows are the case table
// Cases/first-edit-gesture.json, in sixty-fourths of a point of a Letter
// page; every place is compared in sixty-fourths (`FirstEdit.sixtyFourths`).
//
// The zoom is high (64 times the page) so the canvas's finger tolerances,
// which shrink with the zoom (the start slop, the handles' touch boxes, the
// size floor), stay far below a row's sizes, and a row's gesture is what
// moves its edges.

private final class FirstEditCasesBundle: NSObject {}

@Suite("First edit gesture")
@MainActor
struct FirstEditGestureTests {

    // MARK: - The table

    struct Rect64: Decodable, Equatable, CustomStringConvertible {
        let minX: Int, minY: Int, maxX: Int, maxY: Int
        var edges: [Int] { [minX, minY, maxX, maxY] }
        var description: String { "\(minX)..\(maxX) x \(minY)..\(maxY)" }
    }
    struct TableBox: Decodable { let rect: Rect64; let anchored: Bool }
    struct Gesture: Decodable {
        let type: String
        let dx: Int?, dy: Int?
        let dMinX: Int?, dMaxX: Int?, dMinY: Int?, dMaxY: Int?
    }
    struct TableUndo: Decodable { let rect: Rect64; let anchored: Bool }
    struct TableStart: Decodable { let rect: Rect64; let clause: Int }
    struct TablePlan: Decodable { let version: Int; let starts: [String: TableStart] }
    struct TableRead: Decodable { let kept: TablePlan; let version: Int; let id: String; let atRead: TablePlan }
    struct Inputs: Decodable {
        let box: TableBox?
        let gesture: Gesture?
        let group: Bool?
        let then: String?
        let read: TableRead?
        /// The page the row's words come from: `synthetic` or `sample-p1`.
        let text: String?
    }
    struct Expected: Decodable {
        let written: Bool?
        let rect: Rect64
        let anchored: Bool?
        let undo: TableUndo?
        let start: Rect64?
        let clause: Int?
        let replanned: Bool?
    }
    struct Row: Decodable { let id: String; let inputs: Inputs; let expected: Expected }
    struct Table: Decodable { let rule: String; let cases: [Row] }

    static let tableSHA256 = "7e331de37921fed68ae36c2c9030a1b4e4067cdb7f22929b78058162f993f818"
    static let rowCount = 181

    static func tableData() throws -> Data {
        let url = try #require(Bundle(for: FirstEditCasesBundle.self).url(
            forResource: "first-edit-gesture", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    static func table() throws -> Table {
        try JSONDecoder().decode(Table.self, from: tableData())
    }

    @Test func theTableIsTheOneOfRecord() throws {
        let data = try Self.tableData()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == Self.tableSHA256)
        let table = try Self.table()
        #expect(table.rule == "first-edit")
        #expect(table.cases.count == Self.rowCount)
        #expect(Set(table.cases.map(\.id)).count == Self.rowCount, "every id once")
        let gestures = table.cases.filter { $0.inputs.gesture != nil }
        #expect(gestures.count == 179)
        #expect(table.cases.filter { $0.inputs.read != nil }.map(\.id).sorted()
                == ["J-read-current", "J-read-holder-deleted"])
        #expect(gestures.filter { $0.inputs.box?.anchored == true }.allSatisfy { $0.expected.start != nil },
                "every anchored box's row gives its start")
    }

    // MARK: - The canvas

    /// A Letter page, 612 by 792 points: 39168 by 50688 sixty-fourths.
    static let pageSize = CGSize(width: 612, height: 792)
    static let zoom: CGFloat = 64

    static func share(_ r: Rect64) -> CGRect {
        let w = Double(pageSize.width * 64), h = Double(pageSize.height * 64)
        return CGRect(x: Double(r.minX) / w, y: Double(r.minY) / h,
                      width: Double(r.maxX - r.minX) / w, height: Double(r.maxY - r.minY) / h)
    }

    static func sixtyFourths(_ share: CGRect) -> [Int] {
        FirstEdit.sixtyFourths(share, displayedSize: pageSize)
    }

    struct Canvas {
        let overlay: RedactionOverlayView
        let coordinator: PDFViewCoordinator
        let state: RedactionState
        let window: UIWindow
        let undo: UndoManager

        func stored(_ id: UUID) -> RedactionRegion? { state.regions[0]?.first { $0.id == id } }
        func copy(_ id: UUID) -> RedactionRegion? { overlay.regions.first { $0.id == id } }
    }

    /// The regions stored on page 0, `selected` selected, the overlay at the
    /// zoom, each box's start in `starts` given through its reader; on
    /// `coordinator` when one is given (one that holds a document).
    func mount(_ regions: [RedactionRegion], selected: Set<UUID>, starts: [UUID: CGRect],
               coordinator given: PDFViewCoordinator? = nil) throws -> Canvas {
        let state = RedactionState()
        for r in regions { state.addRegion(r, page: 0, undoManager: nil) }
        state.selectedRegionIDs = selected
        let coordinator = given ?? PDFViewCoordinator()
        coordinator.redactionState = state
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.pageSize))
        let overlay = RedactionOverlayView(frame: window.bounds)
        overlay.geometry = .testUnturned
        overlay.pageIndex = 0
        overlay.snapZoomScaleOverride = Self.zoom
        overlay.coordinator = coordinator
        overlay.startReader = { id in starts[id].map { DrawnPlan.FirstEditStart(share: $0, clause: 1) } }
        overlay.configure(with: state.regions[0] ?? [], selectedIDs: selected)
        window.addSubview(overlay)
        window.isHidden = false
        let undo = try #require(window.undoManager)
        undo.removeAllActions()
        return Canvas(overlay: overlay, coordinator: coordinator, state: state, window: window, undo: undo)
    }

    static func found(_ share: CGRect) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: share, source: .searchMatch(term: "found"), textAnchored: true)
    }

    static func hand(_ share: CGRect) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: share, source: .manual)
    }

    /// What the touch went down as.
    enum Grab: Equatable { case move, groupMove, resize(RedactionOverlayView.ResizeHandle) }

    /// One touch identity pressed at `start`, moved through `points`, then
    /// lifted, or cancelled when `cancel`. `grab` is what the press must
    /// have begun.
    func drag(_ c: Canvas, from start: CGPoint, through points: [CGPoint], grab: Grab, cancel: Bool = false,
              sourceLocation: SourceLocation = #_sourceLocation) {
        let touch = StubTouch(location: start, view: c.overlay)
        c.overlay.touchesBegan([touch], with: nil)
        switch grab {
        case .move: #expect(c.overlay.isDraggingExistingRegion, "a move began", sourceLocation: sourceLocation)
        case .groupMove: #expect(c.overlay.isGroupMoving, "a group move began", sourceLocation: sourceLocation)
        case .resize(let h): #expect(c.overlay.activeResizeHandle == h, "the \(h) handle was grabbed",
                                     sourceLocation: sourceLocation)
        }
        for p in points {
            touch.move(to: p)
            c.overlay.touchesMoved([touch], with: nil)
        }
        if cancel { c.overlay.touchesCancelled([touch], with: nil) } else { c.overlay.touchesEnded([touch], with: nil) }
    }

    /// A handle's point on `rect`, held a hair inside the canvas: a handle's
    /// touch box is kept on the canvas, so a point on the canvas's far edge
    /// is in none. The resize reads the finger's travel, not where it went
    /// down.
    static func grabPoint(_ handle: RedactionOverlayView.ResizeHandle, in rect: CGRect, canvas: CGRect) -> CGPoint {
        let p = RedactionOverlayView.handlePoint(handle, in: rect), e: CGFloat = 1.0 / 128
        return CGPoint(x: min(max(p.x, canvas.minX), canvas.maxX - e), y: min(max(p.y, canvas.minY), canvas.maxY - e))
    }

    /// Where a touch takes `handle` of the selected box: its grab point, or,
    /// where another box's rectangle also holds that point (a box inside a
    /// wider one, on their shared edge), the first point outward from it, in
    /// steps of a sixteenth of the smallest handle touch box, that the
    /// overlay gives to the handle: a touch just past the edge. The resize
    /// reads the finger's travel, so where in the handle it goes down does
    /// not move the result.
    static func grabbable(_ handle: RedactionOverlayView.ResizeHandle, in rect: CGRect,
                          overlay: RedactionOverlayView) -> CGPoint {
        let p = grabPoint(handle, in: rect, canvas: overlay.bounds)
        let out = CGVector(dx: p.x > rect.midX ? 1 : p.x < rect.midX ? -1 : 0,
                           dy: p.y > rect.midY ? 1 : p.y < rect.midY ? -1 : 0)
        let step = 22 * overlay.fingerScale / 16
        for i in 0...8 {
            let q = CGPoint(x: p.x + out.dx * step * CGFloat(i), y: p.y + out.dy * step * CGFloat(i))
            if overlay.hitTestResizeHandle(at: q) == handle { return q }
        }
        return p
    }

    /// A point on a box's body, clear of its handles' touch boxes.
    static func body(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.minX + rect.width / 4, y: rect.midY) }

    /// A point on the box `id`'s body that the overlay gives to that box:
    /// `body(rect)`, or, where a smaller box inside it holds that point (a
    /// word placed inside a wider result), the first point along its middle
    /// line, in eighths of its width, that the box takes itself.
    static func bodyPoint(of id: UUID, in rect: CGRect, overlay: RedactionOverlayView) -> CGPoint {
        let first = body(rect)
        if overlay.hitTarget(at: first, handles: true) == .region(id) { return first }
        for i in 1..<8 {
            let p = CGPoint(x: rect.minX + rect.width * CGFloat(i) / 8, y: rect.midY)
            if overlay.hitTarget(at: p, handles: true) == .region(id) { return p }
        }
        return first
    }

    /// A table resize as handle drags: each drag moves at most one edge on
    /// each axis, the first edit's first. In the canvas's points (y down):
    /// the page's top is the canvas's top edge.
    static func handleDrags(_ g: Gesture) -> [(handle: RedactionOverlayView.ResizeHandle, travel: CGVector)] {
        var xs: [(left: Bool, d: CGFloat)] = [], ys: [(top: Bool, d: CGFloat)] = []
        if let d = g.dMinX { xs.append((left: true, d: CGFloat(d) / 64)) }
        if let d = g.dMaxX { xs.append((left: false, d: CGFloat(d) / 64)) }
        if let d = g.dMaxY { ys.append((top: true, d: -CGFloat(d) / 64)) }
        if let d = g.dMinY { ys.append((top: false, d: -CGFloat(d) / 64)) }
        var drags: [(handle: RedactionOverlayView.ResizeHandle, travel: CGVector)] = []
        for i in 0..<max(xs.count, ys.count) {
            let x = i < xs.count ? xs[i] : nil, y = i < ys.count ? ys[i] : nil
            let handle: RedactionOverlayView.ResizeHandle
            switch (x?.left, y?.top) {
            case (true?, true?): handle = .topLeft
            case (false?, true?): handle = .topRight
            case (true?, false?): handle = .bottomLeft
            case (false?, false?): handle = .bottomRight
            case (nil, true?): handle = .topCenter
            case (nil, false?): handle = .bottomCenter
            case (true?, nil): handle = .leftCenter
            default: handle = .rightCenter
            }
            drags.append((handle: handle, travel: CGVector(dx: x?.d ?? 0, dy: y?.d ?? 0)))
        }
        return drags
    }

    /// Past the start slop, then to `travel` from where the touch went down.
    static func path(from down: CGPoint, travel: CGVector) -> [CGPoint] {
        let end = CGPoint(x: down.x + travel.dx, y: down.y + travel.dy)
        return [CGPoint(x: end.x + 0.5, y: end.y + 0.5), end]
    }

    // MARK: - Every gesture row, from its start

    /// A box away from `own`, drawn by hand: the other member of a row's group.
    static func partner(clearOf own: CGRect) -> CGRect {
        let a = share(Rect64(minX: 19000, minY: 24000, maxX: 20000, maxY: 24600))
        let b = share(Rect64(minX: 1000, minY: 1000, maxX: 2000, maxY: 1600))
        return a.intersects(own.insetBy(dx: -0.05, dy: -0.05)) ? b : a
    }

    /// Runs a row's gesture; returns the row's region id and the canvas.
    func runGesture(_ row: Row) throws -> (UUID, Canvas) {
        let box = try #require(row.inputs.box), gesture = try #require(row.inputs.gesture)
        let own = Self.share(box.rect)
        let region = box.anchored ? Self.found(own) : Self.hand(own)
        var regions = [region]
        if row.inputs.group == true { regions.append(Self.hand(Self.partner(clearOf: own))) }
        var starts: [UUID: CGRect] = [:]
        if box.anchored, let start = row.expected.start { starts[region.id] = Self.share(start) }
        let c = try mount(regions, selected: Set(regions.map(\.id)), starts: starts)
        try perform(gesture, on: region.id, in: c, group: regions.count > 1, cancel: row.inputs.then == "cancel")
        return (region.id, c)
    }

    /// A row's gesture on the box `id` as the canvas shows it now: a move
    /// from a touch on its body (the selection's group move when `group`),
    /// or a resize as at most two handle drags; cancelled, not lifted, when
    /// `cancel`.
    func perform(_ gesture: Gesture, on id: UUID, in c: Canvas, group: Bool, cancel: Bool) throws {
        if gesture.type == "move" {
            let down = Self.bodyPoint(of: id, in: c.overlay.pdfNormalizedToOverlay(try #require(c.copy(id)).normalizedRect),
                                      overlay: c.overlay)
            let travel = CGVector(dx: CGFloat(gesture.dx ?? 0) / 64, dy: -CGFloat(gesture.dy ?? 0) / 64)
            drag(c, from: down, through: Self.path(from: down, travel: travel), grab: group ? .groupMove : .move,
                 cancel: cancel)
        } else {
            for (handle, travel) in Self.handleDrags(gesture) {
                let drawn = c.overlay.pdfNormalizedToOverlay(try #require(c.copy(id)).normalizedRect)
                let down = Self.grabbable(handle, in: drawn, overlay: c.overlay)
                drag(c, from: down, through: Self.path(from: down, travel: travel), grab: .resize(handle),
                     cancel: cancel)
                if cancel { break }
            }
        }
    }

    /// The rows whose box the table moves past the page's edge. The canvas
    /// keeps every box on the page, as it always has: a move stops at the
    /// edge with its size, a resize is cut there. These rows' boxes are
    /// held to the table's rectangle so kept.
    static let pastThePage = ["seeded-680", "seeded-800", "seeded-1260", "seeded-1400", "seeded-1520", "seeded-1900"]

    static func onThePage(_ r: Rect64, move: Bool) -> Rect64 {
        let w = Int(pageSize.width * 64), h = Int(pageSize.height * 64)
        if move {
            let x = min(max(r.minX, 0), w - (r.maxX - r.minX)), y = min(max(r.minY, 0), h - (r.maxY - r.minY))
            return Rect64(minX: x, minY: y, maxX: x + r.maxX - r.minX, maxY: y + r.maxY - r.minY)
        }
        return Rect64(minX: max(r.minX, 0), minY: max(r.minY, 0), maxX: min(r.maxX, w), maxY: min(r.maxY, h))
    }

    @Test("Every gesture row's box ends where the row says, from its start, with its anchoring, step and undo")
    func everyGestureRowFromItsStart() throws {
        let rows = try Self.table().cases.filter { $0.inputs.gesture != nil }
        let page = Rect64(minX: 0, minY: 0, maxX: Int(Self.pageSize.width * 64), maxY: Int(Self.pageSize.height * 64))
        let past = rows.filter {
            let r = $0.expected.rect
            return r.minX < page.minX || r.minY < page.minY || r.maxX > page.maxX || r.maxY > page.maxY
        }
        #expect(past.map(\.id) == Self.pastThePage, "the rows past the page")
        for row in rows {
            let expectedRect = Self.pastThePage.contains(row.id)
                ? Self.onThePage(row.expected.rect, move: row.inputs.gesture?.type == "move") : row.expected.rect
            let (id, c) = try runGesture(row)
            // After the lift the canvas shows the stored box: no configure
            // follows a drag that wrote nothing.
            let lifted = try #require(c.stored(id)), copy = try #require(c.copy(id))
            #expect(Self.sixtyFourths(copy.normalizedRect) == Self.sixtyFourths(lifted.normalizedRect),
                    "\(row.id): the canvas's copy is where the stored box is")
            #expect(copy.textAnchored == lifted.textAnchored, "\(row.id): the copy's anchoring is the stored one")
            if row.inputs.then == "undo" { c.undo.undo() }
            let now = try #require(c.stored(id))
            #expect(Self.sixtyFourths(now.normalizedRect) == expectedRect.edges,
                    "\(row.id): the stored box is \(Self.sixtyFourths(now.normalizedRect)), not \(expectedRect)")
            if let anchored = row.expected.anchored {
                #expect(now.textAnchored == anchored, "\(row.id): anchored \(now.textAnchored)")
            }
            if let written = row.expected.written {
                #expect(c.undo.canUndo == written, "\(row.id): a step recorded \(c.undo.canUndo)")
            }
            if let undo = row.expected.undo, row.inputs.then == nil {
                while c.undo.canUndo { c.undo.undo() }
                let back = try #require(c.stored(id))
                #expect(Self.sixtyFourths(back.normalizedRect) == undo.rect.edges, "\(row.id): undo gives \(undo.rect)")
                #expect(back.textAnchored == undo.anchored, "\(row.id): undo gives anchored \(undo.anchored)")
            }
            withExtendedLifetime(c) {}
        }
    }

    // MARK: - The reader reads a plan of the page as it is

    @Test("A start is read from the kept plan only at the page's current version, else from a plan made at the read")
    func theReaderReadsOnlyACurrentPlan() throws {
        let rows = try Self.table().cases.filter { $0.inputs.read != nil }
        #expect(rows.count == 2)
        func plan(version: Int) -> DrawnPlan {
            DrawnPlan(pageIndex: 0, regions: [], cropBox: Self.pageSize, rotation: 0, switchOn: true,
                      exportDPI: 150, fillColor: .black).stamped(pageVersion: version, fromStoredRegions: true)
        }
        for row in rows {
            let read = try #require(row.inputs.read)
            var madeAtRead = false
            let chosen = FirstEdit.currentPlan(kept: plan(version: read.kept.version), pageVersion: read.version) {
                madeAtRead = true
                return plan(version: read.atRead.version)
            }
            #expect(chosen != nil)
            let start = try #require((madeAtRead ? read.atRead : read.kept).starts[read.id])
            #expect(start.rect == row.expected.rect, "\(row.id): the start read is \(start.rect)")
            #expect(start.clause == row.expected.clause, "\(row.id): clause \(start.clause)")
            #expect(madeAtRead == (row.expected.replanned ?? false), "\(row.id): made at the read \(madeAtRead)")
        }
        // A kept plan made from a working copy (a drag in flight) is not the
        // page as stored, at any version.
        let fromCopy = plan(version: 3).stamped(pageVersion: 3, fromStoredRegions: false)
        var madeAtRead = false
        _ = FirstEdit.currentPlan(kept: fromCopy, pageVersion: 3) { madeAtRead = true; return nil }
        #expect(madeAtRead)
        // Nor is a plan kept before the page's read is held, made without it.
        let beforeRead = DrawnPlan.beforeRead(pageIndex: 0, regions: [], cropBox: Self.pageSize, rotation: 0,
                                              switchOn: true, exportDPI: 150, fillColor: .black)
            .stamped(pageVersion: 3, fromStoredRegions: true)
        madeAtRead = false
        _ = FirstEdit.currentPlan(kept: beforeRead, pageVersion: 3) { madeAtRead = true; return nil }
        #expect(madeAtRead, "a plan kept before the page's read is passed over")
    }

    // MARK: - The gesture's own cases

    /// A found box on one line with its start wider than it on every side,
    /// as a joined box's paint is, clear of the page's edges.
    static let ownBox = Rect64(minX: 3456, minY: 41437, maxX: 8627, maxY: 42252)
    static let startBox = Rect64(minX: 3374, minY: 41386, maxX: 8831, maxY: 42422)

    @Test("A group with a box the slop gave a start, dragged past the slop and back, writes nothing and keeps the selection")
    func groupWithAStartBackIsNoTap() throws {
        let found = Self.found(Self.share(Self.ownBox))
        let hand = Self.hand(Self.share(Rect64(minX: 19000, minY: 24000, maxX: 20000, maxY: 24600)))
        let both: Set<UUID> = [found.id, hand.id]
        let c = try mount([found, hand], selected: both, starts: [found.id: Self.share(Self.startBox)])
        let down = Self.body(c.overlay.pdfNormalizedToOverlay(found.normalizedRect))
        drag(c, from: down, through: [CGPoint(x: down.x + 3, y: down.y), down], grab: .groupMove)
        #expect(c.undo.canUndo == false, "nothing written")
        #expect(c.state.selectedRegionIDs == both, "the selection is kept: not a tap")
        for r in [found, hand] {
            let copy = try #require(c.copy(r.id)), stored = try #require(c.stored(r.id))
            #expect(Self.sixtyFourths(copy.normalizedRect) == Self.sixtyFourths(r.normalizedRect), "the copy is back")
            #expect(copy.textAnchored == r.textAnchored && stored.textAnchored == r.textAnchored, "the anchoring is kept")
        }
        withExtendedLifetime(c) {}
    }

    @Test("A group of boxes drawn by hand, dragged past the slop and back, is a tap on the touched box, as before")
    func handGroupBackIsATap() throws {
        let a = Self.hand(Self.share(Self.ownBox))
        let b = Self.hand(Self.share(Rect64(minX: 19000, minY: 24000, maxX: 20000, maxY: 24600)))
        let c = try mount([a, b], selected: [a.id, b.id], starts: [:])
        let down = Self.body(c.overlay.pdfNormalizedToOverlay(a.normalizedRect))
        drag(c, from: down, through: [CGPoint(x: down.x + 3, y: down.y), down], grab: .groupMove)
        #expect(c.undo.canUndo == false, "nothing written")
        #expect(c.state.selectedRegionIDs == [a.id], "the touched box alone is selected")
        withExtendedLifetime(c) {}
    }

    @Test("Sent to the background after the slop, a first edit puts back the stored box, anchored, and writes nothing")
    func backgroundAfterTheSlopRestores() throws {
        let found = Self.found(Self.share(Self.ownBox))
        let c = try mount([found], selected: [found.id], starts: [found.id: Self.share(Self.startBox)])
        let drawn = c.overlay.pdfNormalizedToOverlay(found.normalizedRect)
        let down = RedactionOverlayView.handlePoint(.rightCenter, in: drawn)
        let touch = StubTouch(location: down, view: c.overlay)
        c.overlay.touchesBegan([touch], with: nil)
        touch.move(to: CGPoint(x: down.x + 5, y: down.y))
        c.overlay.touchesMoved([touch], with: nil)
        #expect(c.copy(found.id)?.textAnchored == false, "past the slop the copy is not anchored")
        c.overlay.cancelHeldGestureForBackground()
        let copy = try #require(c.copy(found.id))
        #expect(Self.sixtyFourths(copy.normalizedRect) == Self.ownBox.edges, "the copy is the stored box, not the start")
        #expect(copy.textAnchored, "anchored again")
        #expect(c.undo.canUndo == false, "nothing written")
        withExtendedLifetime(c) {}
    }

    @Test("The start is read once, at the slop's crossing, and kept through the drag")
    func theStartIsKeptFromTheCrossing() throws {
        let found = Self.found(Self.share(Self.ownBox))
        let c = try mount([found], selected: [found.id], starts: [found.id: Self.share(Self.startBox)])
        let drawn = c.overlay.pdfNormalizedToOverlay(found.normalizedRect)
        let down = RedactionOverlayView.handlePoint(.rightCenter, in: drawn)
        let touch = StubTouch(location: down, view: c.overlay)
        c.overlay.touchesBegan([touch], with: nil)
        touch.move(to: CGPoint(x: down.x + 1, y: down.y))
        c.overlay.touchesMoved([touch], with: nil)
        // After the crossing the page's plan holds the box as edited, which
        // has no start: a reader asked now answers none.
        c.overlay.startReader = { _ in nil }
        c.overlay.layer.displayIfNeeded()
        touch.move(to: CGPoint(x: down.x + 5, y: down.y))
        c.overlay.touchesMoved([touch], with: nil)
        c.overlay.touchesEnded([touch], with: nil)
        let stored = try #require(c.stored(found.id))
        let expected = Rect64(minX: Self.startBox.minX, minY: Self.startBox.minY,
                              maxX: Self.startBox.maxX + 320, maxY: Self.startBox.maxY)
        #expect(Self.sixtyFourths(stored.normalizedRect) == expected.edges,
                "the start read at the crossing, its right edge 5 points out")
        withExtendedLifetime(c) {}
    }

    @Test("Between the slop and the lift the copy is not anchored; at the lift the stored box is written so")
    func unanchoredFromTheSlop() throws {
        let found = Self.found(Self.share(Self.ownBox))
        let c = try mount([found], selected: [found.id], starts: [found.id: Self.share(Self.startBox)])
        let down = Self.body(c.overlay.pdfNormalizedToOverlay(found.normalizedRect))
        let touch = StubTouch(location: down, view: c.overlay)
        c.overlay.touchesBegan([touch], with: nil)
        #expect(c.copy(found.id)?.textAnchored == true, "before the slop the copy is anchored")
        touch.move(to: CGPoint(x: down.x + 4, y: down.y))
        c.overlay.touchesMoved([touch], with: nil)
        #expect(c.copy(found.id)?.textAnchored == false, "past the slop it is not")
        #expect(c.stored(found.id)?.textAnchored == true, "the stored box is unchanged until the lift")
        c.overlay.touchesEnded([touch], with: nil)
        #expect(c.stored(found.id)?.textAnchored == false, "written not anchored")
        withExtendedLifetime(c) {}
    }

    @Test("With no start for an anchored box, its first edit starts from its own rectangle and un-anchors it")
    func noStartEditsFromTheOwnRectangle() throws {
        let found = Self.found(Self.share(Self.ownBox))
        let c = try mount([found], selected: [found.id], starts: [:])
        let drawn = c.overlay.pdfNormalizedToOverlay(found.normalizedRect)
        let down = RedactionOverlayView.handlePoint(.rightCenter, in: drawn)
        drag(c, from: down, through: Self.path(from: down, travel: CGVector(dx: 5, dy: 0)), grab: .resize(.rightCenter))
        let stored = try #require(c.stored(found.id))
        let expected = Rect64(minX: Self.ownBox.minX, minY: Self.ownBox.minY,
                              maxX: Self.ownBox.maxX + 320, maxY: Self.ownBox.maxY)
        #expect(Self.sixtyFourths(stored.normalizedRect) == expected.edges, "the own rectangle, its right edge 5 out")
        #expect(stored.textAnchored == false)
        withExtendedLifetime(c) {}
    }

    @Test("A box drawn by hand edits from its own rectangle and asks no start")
    func aHandBoxAsksNoStart() throws {
        let hand = Self.hand(Self.share(Self.ownBox))
        var asked = 0
        let c = try mount([hand], selected: [hand.id], starts: [:])
        c.overlay.startReader = { _ in asked += 1; return DrawnPlan.FirstEditStart(share: Self.share(Self.startBox), clause: 1) }
        let down = Self.body(c.overlay.pdfNormalizedToOverlay(hand.normalizedRect))
        drag(c, from: down, through: Self.path(from: down, travel: CGVector(dx: 10, dy: 0)), grab: .move)
        let stored = try #require(c.stored(hand.id))
        let expected = Rect64(minX: Self.ownBox.minX + 640, minY: Self.ownBox.minY,
                              maxX: Self.ownBox.maxX + 640, maxY: Self.ownBox.maxY)
        #expect(Self.sixtyFourths(stored.normalizedRect) == expected.edges)
        #expect(asked == 0, "no start is read for a box drawn by hand")
        withExtendedLifetime(c) {}
    }

    // MARK: - A page stored turned

    /// The overlay of a page stored turned a quarter: its points are the
    /// stored page's (612 by 792), the page as shown is 792 by 612, and a
    /// region's share is of the page as shown.
    func mountTurned(_ regions: [RedactionRegion], selected: Set<UUID>, starts: [UUID: CGRect]) throws -> Canvas {
        let c = try mount(regions, selected: selected, starts: starts)
        c.overlay.geometry = RunRecord.PageGeometry(cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 90)
        c.overlay.configure(with: c.state.regions[0] ?? [], selectedIDs: selected)
        return c
    }

    static let turnedSides = CGSize(width: 792, height: 612)

    /// A share of the page as shown, from sixty-fourths of its 792 by 612 points.
    static func turnedShare(_ r: Rect64) -> CGRect {
        let w = Double(turnedSides.width * 64), h = Double(turnedSides.height * 64)
        return CGRect(x: Double(r.minX) / w, y: Double(r.minY) / h,
                      width: Double(r.maxX - r.minX) / w, height: Double(r.maxY - r.minY) / h)
    }

    @Test("On a page stored turned, a first move moves the start by the finger, and the page under the finger stays under it")
    func turnedMoveMovesTheStart() throws {
        let own = Rect64(minX: 6400, minY: 20000, maxX: 12800, maxY: 20800)
        let start = Rect64(minX: 6300, minY: 19900, maxX: 13100, maxY: 21000)
        let found = Self.found(Self.turnedShare(own))
        let c = try mountTurned([found], selected: [found.id], starts: [found.id: Self.turnedShare(start)])
        let drawn = c.overlay.pdfNormalizedToOverlay(found.normalizedRect)
        let down = CGPoint(x: drawn.midX, y: drawn.minY + drawn.height / 4)
        let travel = CGVector(dx: 0, dy: -10)   // up the canvas: right on the page as shown
        drag(c, from: down, through: Self.path(from: down, travel: travel), grab: .move)
        let stored = try #require(c.stored(found.id))
        let moved = Rect64(minX: start.minX + 640, minY: start.minY, maxX: start.maxX + 640, maxY: start.maxY)
        #expect(FirstEdit.sixtyFourths(stored.normalizedRect, displayedSize: Self.turnedSides) == moved.edges,
                "the start moved 10 points right as shown, its size kept")
        withExtendedLifetime(c) {}
    }

    @Test("On a page stored turned, a first resize moves only the dragged edge of the start, as shown")
    func turnedResizeMovesOneEdge() throws {
        let own = Rect64(minX: 6400, minY: 20000, maxX: 12800, maxY: 20800)
        let start = Rect64(minX: 6300, minY: 19900, maxX: 13100, maxY: 21000)
        let found = Self.found(Self.turnedShare(own))
        let c = try mountTurned([found], selected: [found.id], starts: [found.id: Self.turnedShare(start)])
        let drawn = c.overlay.pdfNormalizedToOverlay(found.normalizedRect)
        // The shown right edge is the stored top: the canvas's top edge.
        let down = RedactionOverlayView.handlePoint(.topCenter, in: drawn)
        drag(c, from: down, through: Self.path(from: down, travel: CGVector(dx: 0, dy: -5)), grab: .resize(.topCenter))
        let stored = try #require(c.stored(found.id))
        let out = Rect64(minX: start.minX, minY: start.minY, maxX: start.maxX + 320, maxY: start.maxY)
        #expect(FirstEdit.sixtyFourths(stored.normalizedRect, displayedSize: Self.turnedSides) == out.edges,
                "the right edge 5 points out as shown; the other three on the start")
        withExtendedLifetime(c) {}
    }

    // MARK: - Undo

    @Test("A first edit's Undo puts back the whole region, and the page's plan is the plan before the edit")
    func undoPutsBackTheWholeRegion() throws {
        var found = Self.found(Self.share(Self.ownBox))
        // A field beside the rect and the anchoring that the edit changes:
        // where PDFKit put the box (none is read here, with no PDF view).
        found.drawnPageRect = CGRect(x: 54, y: 647, width: 81, height: 13)
        let c = try mount([found], selected: [found.id], starts: [found.id: Self.share(Self.startBox)])
        let before = try #require(c.stored(found.id))
        func plan() -> DrawnPlan {
            DrawnPlan(pageIndex: 0, regions: c.state.regions[0] ?? [], cropBox: Self.pageSize, rotation: 0,
                      switchOn: true, exportDPI: 150, fillColor: .black)
        }
        let planBefore = plan()
        let drawn = c.overlay.pdfNormalizedToOverlay(found.normalizedRect)
        let down = RedactionOverlayView.handlePoint(.rightCenter, in: drawn)
        drag(c, from: down, through: Self.path(from: down, travel: CGVector(dx: 5, dy: 0)), grab: .resize(.rightCenter))
        #expect(c.stored(found.id)?.textAnchored == false)
        #expect(c.stored(found.id)?.drawnPageRect == nil, "the edit wrote the place PDFKit gave, none")
        c.undo.undo()
        let after = try #require(c.stored(found.id))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(after) == encoder.encode(before), "the region's encoded value is the one before")
        #expect(after == before)
        #expect(plan() == planBefore, "the page's plan box for box")
        withExtendedLifetime(c) {}
    }

    @Test("An edit's Undo changes the page's version, so the next first edit reads a plan of the page as undone")
    func undoBumpsThePageVersion() throws {
        let found = Self.found(Self.share(Self.ownBox))
        let c = try mount([found], selected: [found.id], starts: [found.id: Self.share(Self.startBox)])
        let drawn = c.overlay.pdfNormalizedToOverlay(found.normalizedRect)
        let down = RedactionOverlayView.handlePoint(.rightCenter, in: drawn)
        drag(c, from: down, through: Self.path(from: down, travel: CGVector(dx: 5, dy: 0)), grab: .resize(.rightCenter))
        let edited = c.state.pageVersion(0)
        let kept = DrawnPlan(pageIndex: 0, regions: c.state.regions[0] ?? [], cropBox: Self.pageSize, rotation: 0,
                             switchOn: true, exportDPI: 150, fillColor: .black)
            .stamped(pageVersion: edited, fromStoredRegions: true)
        c.undo.undo()
        #expect(c.state.pageVersion(0) != edited, "the Undo bumped the page's version")
        var madeAtRead = false
        _ = FirstEdit.currentPlan(kept: kept, pageVersion: c.state.pageVersion(0)) { madeAtRead = true; return nil }
        #expect(madeAtRead, "the plan kept at the edit is not read after its Undo")
        withExtendedLifetime(c) {}
    }

    // MARK: - The limit on the sides a gesture does not move

    /// A start's share that reads back to its sixty-fourths exactly through
    /// the plan's floor and ceiling, as the plan carries one: each axis by
    /// the edge steps (the min edge one double up, the max edge one or two
    /// toward its sixty-fourth).
    static func exactShare(_ k0: Int, _ k1: Int, side: Int) -> (origin: Double, length: Double) {
        let s = Double(side)
        var x = Double(k0) / s
        if Int((x * s).rounded(.down)) != k0 { x = x.nextUp }
        var m = Double(k1) / s
        if Int((m * s).rounded(.up)) != k1 { m = (m * s) > Double(k1) ? m.nextDown : m.nextUp }
        var w = m - x
        let sum = (x + w) * s
        if Int(sum.rounded(.up)) != k1 { m = sum > Double(k1) ? m.nextDown : m.nextUp; w = m - x }
        return (x, w)
    }

    /// A share's edges as the plan holds them: floor of the min edges and
    /// ceiling of the max edges, in sixty-fourths of sides `w` by `h`.
    static func planned(_ r: CGRect, w: Int, h: Int) -> [Int] {
        [Int((r.minX * Double(w)).rounded(.down)), Int((r.minY * Double(h)).rounded(.down)),
         Int((r.maxX * Double(w)).rounded(.up)), Int((r.maxY * Double(h)).rounded(.up))]
    }

    @Test("On an A4 page, at 0 and turned, a side no drag moved stays on its start's sixty-fourth or one outward",
          arguments: [0, 90])
    func unmovedSidesStayOnTheStart(rotation: Int) throws {
        // A4: 595.276 by 841.89 points, 38098 by 53881 sixty-fourths.
        let crop = CGRect(x: 0, y: 0, width: 595.276, height: 841.89)
        let turned = rotation == 90
        let shown = turned ? CGSize(width: crop.height, height: crop.width) : crop.size
        let sw = Int((shown.width * 64).rounded()), sh = Int((shown.height * 64).rounded())
        let start = (k0x: 3101, k1x: 9877, k0y: 20017, k1y: 20991)
        let x = Self.exactShare(start.k0x, start.k1x, side: sw), y = Self.exactShare(start.k0y, start.k1y, side: sh)
        let startShare = CGRect(x: x.origin, y: y.origin, width: x.length, height: y.length)
        #expect(Self.planned(startShare, w: sw, h: sh) == [start.k0x, start.k0y, start.k1x, start.k1y],
                "the start reads back to its sixty-fourths")
        let own = startShare.insetBy(dx: 0.002, dy: 0.0002)
        let found = Self.found(own)
        let c = try mount([found], selected: [found.id], starts: [found.id: startShare])
        c.overlay.frame = CGRect(origin: .zero, size: crop.size)
        c.overlay.geometry = RunRecord.PageGeometry(cropBox: crop, rotation: rotation)
        c.overlay.configure(with: c.state.regions[0] ?? [], selectedIDs: [found.id])
        func dragHandle(_ handle: RedactionOverlayView.ResizeHandle, _ travel: CGVector) throws {
            let drawn = c.overlay.pdfNormalizedToOverlay(try #require(c.copy(found.id)).normalizedRect)
            let down = RedactionOverlayView.handlePoint(handle, in: drawn)
            drag(c, from: down, through: Self.path(from: down, travel: travel), grab: .resize(handle))
        }
        // An edge, then a corner, then the corner ten times more.
        try dragHandle(.rightCenter, CGVector(dx: 3, dy: 0))
        try dragHandle(.bottomRight, CGVector(dx: 2, dy: 1))
        for _ in 0..<10 { try dragHandle(.bottomRight, CGVector(dx: 0.37, dy: 0.21)) }
        let now = Self.planned(try #require(c.stored(found.id)).normalizedRect, w: sw, h: sh)
        // The canvas's right and bottom edges moved; its left and top did not.
        // Unturned those are the page's left and top. Turned a quarter, the
        // canvas's left is the shown top and its top the shown right.
        let unmoved: [(index: Int, start: Int, outward: Int)] = turned
            ? [(2, start.k1x, 1), (3, start.k1y, 1)]
            : [(0, start.k0x, -1), (3, start.k1y, 1)]
        for side in unmoved {
            let d = (now[side.index] - side.start) * side.outward
            #expect(d == 0 || d == 1, "side \(side.index) stands \(d) sixty-fourths outward of its start (\(now))")
        }
        withExtendedLifetime(c) {}
    }
}
