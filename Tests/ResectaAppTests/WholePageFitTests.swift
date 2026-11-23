import Testing
import Foundation
import CoreGraphics
import UIKit
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// The editor's gestures keep a box on the page as PDFKit places it on the
// canvas (`pageRectOnCanvas`), the rectangle the maps divide by, not the
// canvas's bounds, which PDFKit rounds to the screen's pixels. On an A4
// page the bounds are 595.333 x 842 against the page's 595.276 x 841.89,
// so a box held in the bounds is stored up to 0.11 pt past the page. The
// whole-page mark is found by `RedactionState.isWholePage`, each edge
// within `shareSlack`, since the store map need not carry a full side
// through exactly when the page's corner is not the canvas's.
// The pages are BoxPlaceCheckTests' own: 5 is A4 at 0°, 6 A4 at 90°,
// 7 the 401.123 x 577.777 crop at 270°.

/// A touch at a point in the overlay's own points.
private final class CanvasTouch: UITouch {
    var point: CGPoint
    private let target: UIView
    init(at point: CGPoint, on target: UIView) { self.point = point; self.target = target; super.init() }
    override func location(in view: UIView?) -> CGPoint { (view ?? target).convert(point, from: target) }
    override func previousLocation(in view: UIView?) -> CGPoint { location(in: view) }
    override var view: UIView? { target }
    override var window: UIWindow? { target.window }
}

@Suite("The editor's gestures keep a box on the page as PDFKit places it")
@MainActor
struct WholePageFitTests {

    nonisolated static let pages = [5, 6, 7]
    typealias Canvas = BoxPlaceCheckTests.Canvas

    /// A finger from `start` to `end`, in the overlay's points, in four steps.
    static func gesture(_ c: Canvas, from start: CGPoint, to end: CGPoint) {
        let touch = CanvasTouch(at: start, on: c.overlay)
        c.overlay.touchesBegan([touch], with: nil)
        for step in 1...4 {
            let t = CGFloat(step) / 4
            touch.point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            c.overlay.touchesMoved([touch], with: nil)
        }
        c.overlay.touchesEnded([touch], with: nil)
    }

    static func select(_ c: Canvas, _ ids: Set<UUID>) {
        c.state.selectedRegionID = ids.count == 1 ? ids.first : nil
        c.overlay.configure(with: c.state.regions[c.overlay.pageIndex] ?? [], selectedIDs: ids)
    }

    /// Each stored share lies on the unit square, to `shareSlack`.
    static func onThePage(_ c: Canvas, _ what: String) {
        let e = RedactionState.shareSlack
        for region in c.state.regions[c.overlay.pageIndex] ?? [] {
            let r = region.normalizedRect
            #expect(r.minX >= -e && r.minY >= -e && r.maxX <= 1 + e && r.maxY <= 1 + e,
                    "\(BoxPlaceCheckTests.cases[c.overlay.pageIndex]) after \(what): \(r) lies past the page")
        }
    }

    @Test("A draw, a resize, a move and a group move pushed past each edge store their boxes on the page",
          arguments: pages)
    func doorsStoreOnThePage(pageIndex: Int) throws {
        let c = try BoxPlaceCheckTests.canvas(pageIndex)
        let p = c.overlay.pageRectOnCanvas
        let mid = CGPoint(x: p.midX, y: p.midY)
        // The draw, past the far corner, then past the near one.
        c.overlay.isDrawingMode = true
        c.overlay.activeShapeTool = .rectangle
        Self.gesture(c, from: mid, to: CGPoint(x: p.maxX + 60, y: p.maxY + 60))
        Self.onThePage(c, "a draw past the far corner")
        let far = c.overlay.pdfNormalizedToOverlay(try #require(c.state.regions[pageIndex]?.last?.normalizedRect))
        #expect(abs(far.maxX - p.maxX) < 1e-9 && abs(far.maxY - p.maxY) < 1e-9,
                "the band reached the page's far corner on the canvas: \(far) in \(p)")
        Self.gesture(c, from: mid, to: CGPoint(x: p.minX - 60, y: p.minY - 60))
        Self.onThePage(c, "a draw past the near corner")
        c.overlay.isDrawingMode = false
        let ids = try #require(c.state.regions[pageIndex]?.map(\.id))
        try #require(ids.count == 2, "both draws stored a box")
        // A move, held at the far edges, then at the near ones.
        func centre(_ id: UUID) throws -> CGPoint {
            let r = try #require(c.state.regions[pageIndex]?.first { $0.id == id }?.normalizedRect)
            let shown = c.overlay.pdfNormalizedToOverlay(r)
            return CGPoint(x: shown.midX, y: shown.midY)
        }
        Self.select(c, [ids[0]])
        var at = try centre(ids[0])
        Self.gesture(c, from: at, to: CGPoint(x: at.x + 2000, y: at.y + 2000))
        Self.onThePage(c, "a move past the far edges")
        at = try centre(ids[0])
        Self.gesture(c, from: at, to: CGPoint(x: at.x - 2000, y: at.y - 2000))
        Self.onThePage(c, "a move past the near edges")
        // A resize by its bottom-right handle, past the far edges.
        Self.select(c, [ids[1]])
        let box = c.overlay.pdfNormalizedToOverlay(
            try #require(c.state.regions[pageIndex]?.first { $0.id == ids[1] }?.normalizedRect))
        let corner = RedactionOverlayView.handlePoint(.bottomRight, in: box)
        try #require(c.overlay.hitTestResizeHandle(at: corner) != nil, "the touch lands on a handle")
        Self.gesture(c, from: corner, to: CGPoint(x: corner.x + 2000, y: corner.y + 2000))
        Self.onThePage(c, "a resize past the far edges")
        // A group move, past the far edges, then the near ones.
        Self.select(c, Set(ids))
        at = try centre(ids[0])
        Self.gesture(c, from: at, to: CGPoint(x: at.x + 2000, y: at.y + 2000))
        Self.onThePage(c, "a group move past the far edges")
        Self.select(c, Set(ids))
        at = try centre(ids[0])
        Self.gesture(c, from: at, to: CGPoint(x: at.x - 2000, y: at.y - 2000))
        Self.onThePage(c, "a group move past the near edges")
        withExtendedLifetime((c.coordinator, c.window)) {}
    }

    @Test("The whole-page mark, dragged both ways, is still the whole page: the bar reads it as marked and the menu offers no Duplicate",
          arguments: pages)
    func wholePageMarkKeptAfterADrag(pageIndex: Int) throws {
        let c = try BoxPlaceCheckTests.canvas(pageIndex)
        let mark = PageNavigationBar.wholePageRegion()
        c.state.addRegion(mark, page: pageIndex, undoManager: nil)
        let p = c.overlay.pageRectOnCanvas
        for (dx, dy): (CGFloat, CGFloat) in [(40, 30), (-80, -60), (25, -45)] {
            Self.select(c, [mark.id])
            let at = CGPoint(x: p.midX, y: p.midY)
            Self.gesture(c, from: at, to: CGPoint(x: at.x + dx, y: at.y + dy))
            let stored = try #require(c.state.regions[pageIndex]?.first { $0.id == mark.id })
            let what = "\(BoxPlaceCheckTests.cases[pageIndex]) after a drag by (\(dx), \(dy))"
            #expect(RedactionState.isWholePage(stored.normalizedRect), "\(what): \(stored.normalizedRect)")
            #expect(PageNavigationBar.isWholePageMarked(page: pageIndex, in: c.state), "\(what): the bar lost the mark")
            let rows = RedactionOverlayView.contextMenuRows(
                for: stored, selectedIDs: [mark.id], infoTitle: nil, canSelectAllOnPage: true, showsRationale: false)
            #expect(!rows.contains(.duplicate), "\(what): the menu offers Duplicate on the mark")
            Self.onThePage(c, what)
        }
        #expect(c.state.regions[pageIndex]?.count == 1)
        withExtendedLifetime((c.coordinator, c.window)) {}
    }

    @Test("The whole-page predicate: each edge within the slack of the unit square, and no further")
    func wholePagePredicate() {
        let e = RedactionState.shareSlack
        // Inside the slack by half of it: an edge set at the slack itself lands a
        // rounding step past it once 1 is added (1 + 1e-12 - 1 = 1.00009e-12).
        let h = e / 2
        #expect(RedactionState.isWholePage(CGRect(x: 0, y: 0, width: 1, height: 1)))
        #expect(RedactionState.isWholePage(CGRect(x: h, y: -h, width: 1, height: 1 + h)))
        #expect(RedactionState.isWholePage(CGRect(x: 9.5e-17, y: 0, width: 1 - 9.5e-17, height: 1)))
        #expect(!RedactionState.isWholePage(CGRect(x: 9.6e-5, y: -1.3e-4, width: 1, height: 1)))
        #expect(!RedactionState.isWholePage(CGRect(x: 0, y: 0, width: 1, height: 1 - 3 * e)))
        #expect(!RedactionState.isWholePage(CGRect(x: 0, y: 0, width: 0.5, height: 1)))
    }

    @Test("No exact comparison with the unit square is left in the app's sources")
    func noExactUnitSquareComparison() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        try #require(files.count > 100, "the app's sources were read (\(files.count) files)")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("== CGRect(x: 0, y: 0, width: 1, height: 1)"),
                    "\(file.lastPathComponent) compares a share with the unit square exactly")
        }
    }
}
