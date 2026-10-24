import Testing
import Foundation
import CoreGraphics
import UIKit
import RedactionEngine
@testable import ResectaApp

// Which region or handle a touch picks. One-line boxes sit a few points
// apart at the fit zoom, and every box answers within a halo of 8 screen
// points, so a touch on one line also lands in its neighbour's halo; a
// whole-page box covers every box inside it. The touch picks, in order: the
// selected box's handle when the point is in no other box's body; else the
// smallest box whose body holds the point; else the box whose edge is
// nearest within the halo. Read here through the real overlay, coordinator
// and state at the fit scale (0.64, so the halo is 12.5 page points).

@Suite("Canvas hit target")
@MainActor
struct CanvasHitTargetTests {

    /// The overlay is page-sized in page points; the view shows it at 0.64.
    private static let pageSize = CGSize(width: 612, height: 792)
    private static let fitScale: CGFloat = 0.64

    /// A box in overlay points (top-left origin) as the region's normalized
    /// rect (bottom-left origin, as the page stores it).
    private static func region(_ rect: CGRect) -> RedactionRegion {
        RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: rect.minX / pageSize.width, y: 1 - rect.maxY / pageSize.height,
                                   width: rect.width / pageSize.width, height: rect.height / pageSize.height),
            source: .manual)
    }

    /// Three one-line boxes, 10 points tall at a 13-point pitch, appended
    /// top-down like applied search lines.
    private static func threeLines() -> [RedactionRegion] {
        (0..<3).map { i in region(CGRect(x: 100, y: 200 + CGFloat(i) * 13, width: 200, height: 10)) }
    }

    private static let wholePage = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1), source: .manual)

    private func mounted(
        _ regions: [RedactionRegion], selectedIDs: Set<UUID> = []
    ) -> (overlay: RedactionOverlayView, coordinator: PDFViewCoordinator, state: RedactionState, window: UIWindow) {
        let state = RedactionState()
        for r in regions { state.addRegion(r, page: 0, undoManager: nil) }
        state.selectedRegionIDs = selectedIDs
        let coordinator = PDFViewCoordinator()
        coordinator.redactionState = state
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.pageSize))
        let overlay = RedactionOverlayView(frame: window.bounds)
        overlay.snapZoomScaleOverride = Self.fitScale
        overlay.coordinator = coordinator
        overlay.configure(with: regions, selectedIDs: selectedIDs)
        window.addSubview(overlay)
        window.isHidden = false
        return (overlay, coordinator, state, window)
    }

    // MARK: - The region a touch picks

    @Test("A point on line 1's body picks line 1, not the line below whose halo reaches it")
    func lineUnderTheFingerWins() {
        let lines = Self.threeLines()
        let m = mounted(lines)
        // Line 1 spans y 200–210; line 2's halo starts at 213 − 12.5.
        #expect(m.overlay.hitTestRegion(at: CGPoint(x: 200, y: 207))?.id == lines[0].id)
        #expect(m.overlay.hitTestRegion(at: CGPoint(x: 200, y: 220))?.id == lines[1].id)
        withExtendedLifetime(m) {}
    }

    @Test("A small box inside a whole-page box picks the small box; the page elsewhere picks the page box")
    func smallBoxUnderAWholePageBox() {
        let small = Self.region(CGRect(x: 100, y: 300, width: 80, height: 20))
        let m = mounted([small, Self.wholePage])
        #expect(m.overlay.hitTestRegion(at: CGPoint(x: 140, y: 310))?.id == small.id)
        #expect(m.overlay.hitTestRegion(at: CGPoint(x: 400, y: 600))?.id == Self.wholePage.id)
        withExtendedLifetime(m) {}
    }

    @Test("A point in the gap 4 points below the last line picks the line whose edge is nearest")
    func gapPicksTheNearestEdge() {
        let lines = Self.threeLines()
        let m = mounted(lines)
        // The last line ends at 236; 240 is 4 below it and 17 below line 2.
        #expect(m.overlay.hitTestRegion(at: CGPoint(x: 200, y: 240))?.id == lines[2].id)
        // Between line 1 (ends 210) and line 2 (starts 213), 211 is nearer line 1.
        #expect(m.overlay.hitTestRegion(at: CGPoint(x: 200, y: 211))?.id == lines[0].id)
        withExtendedLifetime(m) {}
    }

    @Test("A selected box's handle box over another box's body picks that other box, never the handle")
    func handleNeverTakesAnotherBoxsBody() {
        let selected = Self.region(CGRect(x: 100, y: 300, width: 200, height: 100))
        // A small box sitting on the selected box's bottom-right corner.
        let other = Self.region(CGRect(x: 290, y: 395, width: 60, height: 20))
        let m = mounted([selected, other], selectedIDs: [selected.id])
        let point = CGPoint(x: 305, y: 405)
        #expect(m.overlay.hitTestResizeHandle(at: point) == nil)
        #expect(m.overlay.hitTestRegion(at: point)?.id == other.id)
        // Off the other box, the corner is still the selected box's handle.
        #expect(m.overlay.hitTestResizeHandle(at: CGPoint(x: 296, y: 388)) == .bottomRight)
        withExtendedLifetime(m) {}
    }

    // MARK: - Through the touch and the menu

    @Test("A tap on line 1 selects line 1")
    func tapSelectsTheLineUnderTheFinger() {
        let lines = Self.threeLines()
        let m = mounted(lines)
        let touch = StubTouch(location: CGPoint(x: 200, y: 207), view: m.overlay)
        m.overlay.touchesBegan([touch], with: nil)
        m.overlay.touchesEnded([touch], with: nil)
        #expect(m.state.selectedRegionIDs == [lines[0].id])
        withExtendedLifetime(m) {}
    }

    @Test("The long-press menu at line 1 is line 1's menu")
    func menuIsForTheLineUnderTheFinger() throws {
        let lines = Self.threeLines()
        let m = mounted(lines)
        let interaction = UIContextMenuInteraction(delegate: m.overlay)
        let config = try #require(m.overlay.contextMenuInteraction(interaction, configurationForMenuAtLocation: CGPoint(x: 200, y: 207)))
        #expect((config.identifier as? NSUUID).map { $0 as UUID } == lines[0].id)
        withExtendedLifetime(m) {}
    }

    @Test("A touch on a small box under a whole-page box is the overlay's, and selects the small box")
    func touchOnSmallBoxUnderPageBox() {
        let small = Self.region(CGRect(x: 100, y: 300, width: 80, height: 20))
        let m = mounted([small, Self.wholePage])
        #expect(m.overlay.hitTest(CGPoint(x: 140, y: 310), with: nil) === m.overlay)
        let touch = StubTouch(location: CGPoint(x: 140, y: 310), view: m.overlay)
        m.overlay.touchesBegan([touch], with: nil)
        m.overlay.touchesEnded([touch], with: nil)
        #expect(m.state.selectedRegionIDs == [small.id])
        withExtendedLifetime(m) {}
    }

    // MARK: - The rule itself

    private static let halo: CGFloat = 12.5

    private func resolve(_ point: CGPoint, _ boxes: [(UUID, CGRect)], selected: (UUID, CGRect)? = nil) -> RedactionOverlayView.CanvasHitTarget? {
        RedactionOverlayView.resolveHitTarget(
            at: point, regions: boxes.map { (id: $0.0, rect: $0.1) },
            selected: selected.map { (id: $0.0, rect: $0.1) }, halo: Self.halo,
            handleSize: 44 / Self.fitScale, minimumHandleSize: 22 / Self.fitScale,
            containerBounds: CGRect(origin: .zero, size: Self.pageSize))
    }

    @Test("The rule: the body before the halo, the smallest body, the nearest edge, the later box on a tie")
    func theRuleInOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        let big = CGRect(x: 0, y: 0, width: 300, height: 300), small = CGRect(x: 100, y: 100, width: 20, height: 20)
        #expect(resolve(CGPoint(x: 110, y: 110), [(a, small), (b, big)]) == .region(a), "the smallest body, whatever the order")
        #expect(resolve(CGPoint(x: 110, y: 110), [(b, big), (a, small)]) == .region(a))
        let same = CGRect(x: 0, y: 0, width: 50, height: 50)
        #expect(resolve(CGPoint(x: 10, y: 10), [(a, same), (b, same)]) == .region(b), "equal areas: the later one")
        let upper = CGRect(x: 0, y: 0, width: 100, height: 10), lower = CGRect(x: 0, y: 30, width: 100, height: 10)
        #expect(resolve(CGPoint(x: 50, y: 14), [(a, upper), (b, lower)]) == .region(a), "the nearer edge in the halo")
        #expect(resolve(CGPoint(x: 50, y: 26), [(a, upper), (b, lower)]) == .region(b))
        #expect(resolve(CGPoint(x: 50, y: 60), [(a, upper), (b, lower), (c, CGRect(x: 0, y: 200, width: 10, height: 10))]) == nil, "outside every halo")
    }

    @Test("The rule: the selected box's handle only off every other box's body")
    func handleOffOtherBodies() {
        let sel = UUID(), other = UUID()
        let selRect = CGRect(x: 100, y: 300, width: 200, height: 100)
        let otherRect = CGRect(x: 290, y: 395, width: 60, height: 20)
        #expect(resolve(CGPoint(x: 296, y: 388), [(sel, selRect), (other, otherRect)], selected: (sel, selRect)) == .handle(.bottomRight))
        #expect(resolve(CGPoint(x: 305, y: 405), [(sel, selRect), (other, otherRect)], selected: (sel, selRect)) == .region(other))
        #expect(resolve(CGPoint(x: 200, y: 350), [(sel, selRect), (other, otherRect)], selected: (sel, selRect)) == .region(sel), "the selected box's own body is the body")
    }
}
