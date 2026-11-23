import Testing
import Foundation
import CoreGraphics
import UIKit
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// A box pushed past a page edge covers that edge. PDFKit sizes the canvas
// to the screen's pixels, so where it rounds a side of the page down (the
// 401.123 x 577.777 crop), a gesture held at the canvas's bounds stops
// short of the page's edge by the rounding, and the strip between is never
// covered. The gestures hold a box at the page's own rectangle on the
// canvas (`pageRectOnCanvas`) instead. The pages are BoxPlaceCheckTests'
// own: 5 is A4 at 0°, 6 A4 at 90°, 7 the 401.123 x 577.777 crop at 270°.

@Suite("A box pushed past a page edge covers that edge")
@MainActor
struct PageEdgeCoverTests {

    nonisolated static let pages = [5, 6, 7]
    typealias Canvas = BoxPlaceCheckTests.Canvas
    /// How near, in the canvas's points, a pushed side must come to the page's edge.
    static let reach: CGFloat = 1e-6

    static func onWindow(_ c: Canvas, _ point: CGPoint) -> CGPoint { c.overlay.convert(point, to: nil) }

    /// A finger put down at `point` and pushed `dx, dy` in the CANVAS's
    /// points. On a turned page the canvas can be flipped against the window
    /// along one side, so the push is named on the canvas and both ends are
    /// taken to the window.
    static func push(_ c: Canvas, at point: CGPoint, by dx: CGFloat, _ dy: CGFloat) {
        let start = onWindow(c, point), end = onWindow(c, CGPoint(x: point.x + dx, y: point.y + dy))
        BoxPlaceCheckTests.move(c, at: start, by: end.x - start.x, end.y - start.y)
    }

    static func select(_ c: Canvas, _ id: UUID) {
        c.state.selectedRegionID = id
        c.overlay.configure(with: c.state.regions[c.overlay.pageIndex] ?? [], selectedIDs: [id])
    }

    /// The box `id` as the canvas shows it.
    static func shown(_ c: Canvas, _ id: UUID) throws -> CGRect {
        c.overlay.pdfNormalizedToOverlay(
            try #require(c.state.regions[c.overlay.pageIndex]?.first { $0.id == id }?.normalizedRect))
    }

    /// The box reaches the page's far edges (right and bottom on the canvas), or its near ones.
    static func reaches(_ c: Canvas, _ box: CGRect, far: Bool, _ what: String) {
        let p = c.overlay.pageRectOnCanvas
        let page = BoxPlaceCheckTests.cases[c.overlay.pageIndex]
        if far {
            #expect(box.maxX >= p.maxX - reach && box.maxY >= p.maxY - reach,
                    "\(page) after \(what): the box ends at (\(box.maxX), \(box.maxY)), the page at (\(p.maxX), \(p.maxY)); canvas \(c.overlay.bounds.size)")
        } else {
            #expect(box.minX <= p.minX + reach && box.minY <= p.minY + reach,
                    "\(page) after \(what): the box starts at (\(box.minX), \(box.minY)), the page at (\(p.minX), \(p.minY)); canvas \(c.overlay.bounds.size)")
        }
    }

    /// Runs `body` on a canvas of its own, so each gesture meets one box
    /// alone: where two boxes overlap, a touch can land on the other one.
    static func onFreshCanvas(_ pageIndex: Int, _ body: (Canvas, CGRect) throws -> Void) throws {
        let c = try BoxPlaceCheckTests.canvas(pageIndex)
        try body(c, c.overlay.pageRectOnCanvas)
        withExtendedLifetime((c.coordinator, c.window)) {}
    }

    /// The one box on the canvas's page.
    static func onlyBox(_ c: Canvas) throws -> UUID {
        let ids = try #require(c.state.regions[c.overlay.pageIndex]?.map(\.id))
        try #require(ids.count == 1, "one box on the page, not \(ids.count)")
        return ids[0]
    }

    /// A box an eighth of the page each way from its middle, drawn and selected.
    static func middleBox(_ c: Canvas, _ p: CGRect) throws -> UUID {
        let dx = p.width / 8, dy = p.height / 8
        BoxPlaceCheckTests.drag(c, from: onWindow(c, CGPoint(x: p.midX - dx, y: p.midY - dy)),
                                to: onWindow(c, CGPoint(x: p.midX + dx, y: p.midY + dy)))
        c.overlay.isDrawingMode = false
        let id = try onlyBox(c)
        select(c, id)
        return id
    }

    @Test("A draw, a move and a resize pushed past the page's corners reach its edges, on pages whose sides PDFKit rounds",
          arguments: pages)
    func pushedBoxCoversTheEdge(pageIndex: Int) throws {
        try Self.onFreshCanvas(pageIndex) { c, p in
            let o = Self.onWindow(c, .zero), step = Self.onWindow(c, CGPoint(x: 1, y: 1))
            print("PAGE-EDGE \(BoxPlaceCheckTests.cases[pageIndex]): canvas \(c.overlay.bounds) page on the canvas \(p); "
                  + "a canvas step of (1, 1) is (\(step.x - o.x), \(step.y - o.y)) on the window")
        }
        // A draw from the middle past the far corner, and one past the near corner.
        for far in [true, false] {
            try Self.onFreshCanvas(pageIndex) { c, p in
                let corner = far ? CGPoint(x: p.maxX + 60, y: p.maxY + 60) : CGPoint(x: p.minX - 60, y: p.minY - 60)
                BoxPlaceCheckTests.drag(c, from: Self.onWindow(c, CGPoint(x: p.midX, y: p.midY)), to: Self.onWindow(c, corner))
                c.overlay.isDrawingMode = false
                let id = try Self.onlyBox(c)
                Self.reaches(c, try Self.shown(c, id), far: far, far ? "a draw past the far corner" : "a draw past the near corner")
            }
        }
        // A move of a middle box past the near corner, then past the far one.
        try Self.onFreshCanvas(pageIndex) { c, p in
            let id = try Self.middleBox(c, p)
            var box = try Self.shown(c, id)
            Self.push(c, at: CGPoint(x: box.midX, y: box.midY), by: -2000, -2000)
            Self.reaches(c, try Self.shown(c, id), far: false, "a move past the near corner")
            box = try Self.shown(c, id)
            Self.push(c, at: CGPoint(x: box.midX, y: box.midY), by: 2000, 2000)
            Self.reaches(c, try Self.shown(c, id), far: true, "a move past the far corner")
        }
        // A resize of a middle box by its far handle, then by its near one.
        try Self.onFreshCanvas(pageIndex) { c, p in
            let id = try Self.middleBox(c, p)
            var handle = RedactionOverlayView.handlePoint(.bottomRight, in: try Self.shown(c, id))
            try #require(c.overlay.hitTestResizeHandle(at: handle) != nil, "the touch lands on the far handle")
            Self.push(c, at: handle, by: 2000, 2000)
            Self.reaches(c, try Self.shown(c, id), far: true, "a resize past the far corner")
            Self.select(c, id)
            handle = RedactionOverlayView.handlePoint(.topLeft, in: try Self.shown(c, id))
            try #require(c.overlay.hitTestResizeHandle(at: handle) != nil, "the touch lands on the near handle")
            Self.push(c, at: handle, by: -2000, -2000)
            Self.reaches(c, try Self.shown(c, id), far: false, "a resize past the near corner")
        }
    }
}
