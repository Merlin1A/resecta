import Testing
import Foundation
import CoreGraphics
import UIKit
import RedactionEngine
@testable import ResectaApp

// What a touch on a selected region does to it, read where it lands: the
// stored rect and the window's undo manager, through the real overlay,
// coordinator and state at the fit scale (0.64). A tap that drifts a
// point is a tap: it moves nothing and records no step. A resize keeps
// the edge where it was grabbed, so a handle grabbed off its centre does
// not jump to the finger. A group of regions moves only once the finger
// travels, as one step. A cancel mid-move or mid-group restores the rects.
// (The resize anchor, the flip, the floor after the snap and the
// cancelled resize are pinned in `OverlayCancelAndHapticTests`.)

@Suite("Canvas resize outcome")
@MainActor
struct CanvasResizeOutcomeTests {

    private static let pageSize = CGSize(width: 612, height: 792)
    private static let fitScale: CGFloat = 0.64
    /// A box whose edges stay clear of every guide (the page's margins and
    /// centre lines) through a 12-point drag, so the drag alone moves them.
    private static let clearOfGuides = CGRect(x: 60, y: 420, width: 160, height: 160)

    /// A box in overlay points (top-left origin) as a stored region.
    private static func region(_ rect: CGRect) -> RedactionRegion {
        RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: rect.minX / pageSize.width, y: 1 - rect.maxY / pageSize.height,
                                   width: rect.width / pageSize.width, height: rect.height / pageSize.height),
            source: .manual)
    }

    private struct Canvas {
        let overlay: RedactionOverlayView
        let coordinator: PDFViewCoordinator
        let state: RedactionState
        let window: UIWindow
        let undo: UndoManager

        /// A stored region's rect in overlay points.
        func rect(_ id: UUID) -> CGRect? {
            state.regions[0]?.first { $0.id == id }.map { overlay.pdfNormalizedToOverlay($0.normalizedRect) }
        }
    }

    private func mount(_ regions: [RedactionRegion], selected: Set<UUID>) throws -> Canvas {
        let state = RedactionState()
        for r in regions { state.addRegion(r, page: 0, undoManager: nil) }
        state.selectedRegionIDs = selected
        let coordinator = PDFViewCoordinator()
        coordinator.redactionState = state
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.pageSize))
        let overlay = RedactionOverlayView(frame: window.bounds)
        overlay.pageIndex = 0
        overlay.snapZoomScaleOverride = Self.fitScale
        overlay.coordinator = coordinator
        overlay.configure(with: state.regions[0] ?? [], selectedIDs: selected)
        window.addSubview(overlay)
        window.isHidden = false
        let undo = try #require(window.undoManager)
        return Canvas(overlay: overlay, coordinator: coordinator, state: state, window: window, undo: undo)
    }

    /// One touch identity pressed at `start`, moved through `points`, then lifted.
    private func drag(_ overlay: RedactionOverlayView, from start: CGPoint, through points: [CGPoint], cancel: Bool = false) {
        let touch = StubTouch(location: start, view: overlay)
        overlay.touchesBegan([touch], with: nil)
        for p in points {
            touch.move(to: p)
            overlay.touchesMoved([touch], with: nil)
        }
        if cancel { overlay.touchesCancelled([touch], with: nil) } else { overlay.touchesEnded([touch], with: nil) }
    }

    private func expectClose(_ a: CGRect?, _ b: CGRect, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let a else { Issue.record("\(label): the region is gone", sourceLocation: sourceLocation); return }
        let close = abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01
            && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
        #expect(close, "\(label): \(a) vs \(b)", sourceLocation: sourceLocation)
    }

    // MARK: - A tap is a tap

    @Test("A tap with half a point of drift on a selected one-line box moves nothing and records no step")
    func driftTapIsATap() throws {
        let box = CGRect(x: 100, y: 300, width: 120, height: 8)
        let r = Self.region(box)
        let c = try mount([r], selected: [r.id])
        drag(c.overlay, from: CGPoint(x: box.midX, y: box.midY), through: [CGPoint(x: box.midX, y: box.midY + 0.5)])
        expectClose(c.rect(r.id), box, "the stored rect")
        #expect(c.undo.canUndo == false, "no step is recorded")
        withExtendedLifetime(c) {}
    }

    // MARK: - The grab offset

    @Test("A resize keeps the edge where it was grabbed: a handle grabbed 15 points inside the corner moves by the drag")
    func resizeKeepsTheGrabOffset() throws {
        let box = Self.clearOfGuides
        let r = Self.region(box)
        let c = try mount([r], selected: [r.id])
        let grab = CGPoint(x: box.maxX - 15, y: box.maxY - 15)
        drag(c.overlay, from: grab, through: [CGPoint(x: grab.x + 8, y: grab.y + 8), CGPoint(x: grab.x + 9, y: grab.y + 9)])
        expectClose(c.rect(r.id), CGRect(x: box.minX, y: box.minY, width: box.width + 9, height: box.height + 9),
                    "the corner moved by the drag, not to the finger")
        withExtendedLifetime(c) {}
    }

    @Test("Each of the eight handles moves only its own edges, by the drag", arguments: [
        RedactionOverlayView.ResizeHandle.topLeft, .topRight, .bottomLeft, .bottomRight,
        .topCenter, .bottomCenter, .leftCenter, .rightCenter,
    ])
    func eachHandleMovesItsEdges(handle: RedactionOverlayView.ResizeHandle) throws {
        let box = Self.clearOfGuides
        let r = Self.region(box)
        let c = try mount([r], selected: [r.id])
        let edges = RedactionOverlayView.movingEdges(handle)
        let x = edges.left ? box.minX : edges.right ? box.maxX : box.midX
        let y = edges.top ? box.minY : edges.bottom ? box.maxY : box.midY
        let d: CGFloat = 12
        drag(c.overlay, from: CGPoint(x: x, y: y), through: [CGPoint(x: x + d, y: y + d)])
        let expected = CGRect(
            x: box.minX + (edges.left ? d : 0), y: box.minY + (edges.top ? d : 0),
            width: box.width + (edges.right ? d : 0) - (edges.left ? d : 0),
            height: box.height + (edges.bottom ? d : 0) - (edges.top ? d : 0))
        expectClose(c.rect(r.id), expected, "\(handle)")
        withExtendedLifetime(c) {}
    }

    // MARK: - A group moves once the finger travels

    @Test("A group of three moved 2 points stays put; moved 20 it moves as one step that one Undo restores")
    func groupMovesOnlyPastTheSlop() throws {
        let boxes = [CGRect(x: 100, y: 200, width: 100, height: 40),
                     CGRect(x: 250, y: 200, width: 100, height: 40),
                     CGRect(x: 100, y: 300, width: 100, height: 40)]
        let rs = boxes.map(Self.region)
        let c = try mount(rs, selected: Set(rs.map(\.id)))
        let start = CGPoint(x: boxes[0].midX, y: boxes[0].midY)
        drag(c.overlay, from: start, through: [CGPoint(x: start.x + 2, y: start.y)])
        for (r, b) in zip(rs, boxes) { expectClose(c.rect(r.id), b, "after a 2-point drag") }
        #expect(c.undo.canUndo == false, "no step for a 2-point drag")

        c.overlay.configure(with: c.state.regions[0] ?? [], selectedIDs: Set(rs.map(\.id)))
        drag(c.overlay, from: start, through: [CGPoint(x: start.x + 10, y: start.y), CGPoint(x: start.x + 20, y: start.y)])
        for (r, b) in zip(rs, boxes) { expectClose(c.rect(r.id), b.offsetBy(dx: 20, dy: 0), "after a 20-point drag") }
        #expect(c.undo.canUndo)
        c.undo.undo()
        for (r, b) in zip(rs, boxes) { expectClose(c.rect(r.id), b, "after one Undo") }
        #expect(c.undo.canUndo == false, "the group move was one step")
        withExtendedLifetime(c) {}
    }

    // MARK: - A cancel restores

    @Test("A move or a group move cancelled mid-drag restores the rects and records nothing")
    func cancelRestoresMoveAndGroup() throws {
        let box = CGRect(x: 100, y: 300, width: 100, height: 40)
        let r = Self.region(box)
        let c = try mount([r], selected: [r.id])
        drag(c.overlay, from: CGPoint(x: box.midX, y: box.midY), through: [CGPoint(x: box.midX + 30, y: box.midY)], cancel: true)
        expectClose(c.rect(r.id), box, "a cancelled move")
        expectClose(c.overlay.regions.first.map { c.overlay.pdfNormalizedToOverlay($0.normalizedRect) }, box, "the drawn rect")

        let other = Self.region(CGRect(x: 300, y: 300, width: 100, height: 40))
        let g = try mount([r, other], selected: [r.id, other.id])
        drag(g.overlay, from: CGPoint(x: box.midX, y: box.midY), through: [CGPoint(x: box.midX + 30, y: box.midY)], cancel: true)
        expectClose(g.overlay.regions.first { $0.id == r.id }.map { g.overlay.pdfNormalizedToOverlay($0.normalizedRect) }, box, "a cancelled group move, drawn")
        #expect(g.undo.canUndo == false)
        withExtendedLifetime((c, g)) {}
    }

    // MARK: - On the page after a guide

    @Test("A region moved along the page's bottom edge stays on the page when it aligns to a neighbour's edge")
    func moveStaysOnThePageAfterTheSnap() throws {
        // The moving box sits on the bottom edge; a neighbour's top lies 3
        // points below the moving box's top, inside the guide's reach.
        let moving = CGRect(x: 100, y: Self.pageSize.height - 40, width: 100, height: 40)
        let neighbour = CGRect(x: 320, y: Self.pageSize.height - 37, width: 100, height: 30)
        let r = Self.region(moving), n = Self.region(neighbour)
        let c = try mount([r, n], selected: [r.id])
        let start = CGPoint(x: moving.midX, y: moving.midY)
        drag(c.overlay, from: start, through: [CGPoint(x: start.x + 10, y: start.y), CGPoint(x: start.x + 20, y: start.y)])
        let stored = try #require(c.state.regions[0]?.first { $0.id == r.id }?.normalizedRect)
        #expect(stored.minY >= 0 && stored.maxY <= 1 && stored.minX >= 0 && stored.maxX <= 1, "stored \(stored)")
        withExtendedLifetime(c) {}
    }

    // MARK: - The size floor: 20 along, 8 across

    /// Screen points at the fit scale, in overlay points.
    private static func overlay(_ screen: CGFloat) -> CGFloat { screen / fitScale }

    /// Draw a band from `origin` sized `screen` (on-screen points) with the
    /// Rectangle tool on; returns the regions added.
    private func drawBand(_ c: Canvas, from origin: CGPoint, screen: CGSize) -> [RedactionRegion] {
        c.overlay.isDrawingMode = true
        let before = Set((c.state.regions[0] ?? []).map(\.id))
        let end = CGPoint(x: origin.x + Self.overlay(screen.width), y: origin.y + Self.overlay(screen.height))
        drag(c.overlay, from: origin, through: [CGPoint(x: (origin.x + end.x) / 2, y: (origin.y + end.y) / 2), end])
        return (c.state.regions[0] ?? []).filter { !before.contains($0.id) }
    }

    @Test("At the fit zoom a 60 x 9 band commits as drawn and 19 x 60 commits; 60 x 7 and 7 x 60 are rejected")
    func floorIs20AlongAnd8Across() throws {
        let c = try mount([], selected: [])
        let added = drawBand(c, from: CGPoint(x: 60, y: 120), screen: CGSize(width: 60, height: 9))
        #expect(added.count == 1, "60 x 9 commits")
        if let r = added.first {
            let h = c.overlay.pdfNormalizedToOverlay(r.normalizedRect).height
            #expect(abs(h - Self.overlay(9)) < 0.01, "stored as drawn, never grown to the floor: \(h)")
        }
        #expect(drawBand(c, from: CGPoint(x: 60, y: 220), screen: CGSize(width: 60, height: 7)).isEmpty, "60 x 7 is under the 8-point floor")
        #expect(drawBand(c, from: CGPoint(x: 60, y: 320), screen: CGSize(width: 7, height: 60)).isEmpty, "7 x 60 is under the 8-point floor across")
        #expect(drawBand(c, from: CGPoint(x: 200, y: 320), screen: CGSize(width: 19, height: 60)).count == 1, "19 x 60: 60 along, 19 across")
        withExtendedLifetime(c) {}
    }

    @Test("A 60 x 7 band that a neighbour's edge 2 points out would lift to 9 is rejected: the floor judges the finger's band")
    func floorJudgesTheFingersBand() throws {
        let origin = CGPoint(x: 60, y: 200)
        let farEdge = origin.y + Self.overlay(7)
        let neighbour = Self.region(CGRect(x: 300, y: farEdge + Self.overlay(2), width: 100, height: 40))
        let c = try mount([neighbour], selected: [])
        #expect(drawBand(c, from: origin, screen: CGSize(width: 60, height: 7)).isEmpty)
        withExtendedLifetime(c) {}
    }

    @Test("A resize floors at 8 across a long side and at 20 along a short one")
    func resizeFloorsByAxis() throws {
        // A long box: its height floors at 8 when the bottom edge is dragged past the top.
        let long = CGRect(x: 60, y: 420, width: 160, height: 40)
        let r = Self.region(long)
        let c = try mount([r], selected: [r.id])
        let bottom = CGPoint(x: long.midX, y: long.maxY)
        drag(c.overlay, from: bottom, through: [CGPoint(x: bottom.x, y: bottom.y - 20), CGPoint(x: bottom.x, y: long.minY + 1)])
        #expect(abs((c.rect(r.id)?.height ?? 0) - Self.overlay(8)) < 0.01, "8 across a long box")

        // A one-line box 10 points tall: its width floors at 20 when the right edge is dragged to the left one.
        let thin = CGRect(x: 60, y: 600, width: 160, height: Self.overlay(10))
        let t = Self.region(thin)
        let d = try mount([t], selected: [t.id])
        let right = CGPoint(x: thin.maxX, y: thin.midY)
        drag(d.overlay, from: right, through: [CGPoint(x: right.x - 20, y: right.y), CGPoint(x: thin.minX + 1, y: right.y)])
        #expect(abs((d.rect(t.id)?.width ?? 0) - Self.overlay(20)) < 0.01, "20 along a one-line box")
        withExtendedLifetime((c, d)) {}
    }
}
