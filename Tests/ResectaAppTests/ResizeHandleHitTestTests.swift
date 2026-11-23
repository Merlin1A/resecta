import Testing
import CoreGraphics
@testable import ResectaApp

// Pure-geometry coverage for
// `RedactionOverlayView.resolveResizeHandle(at:regionRect:targetHandleSize:)`,
// the resolver extracted from `hitTestResizeHandle` so the hit-test
// math is host-free. Mechanism recap (see the doc comment on the
// resolver itself): this geometry is consulted at the single
// touch-down instant, with zero recognizer slop — a touch starting
// outside every box below falls straight through to PDFView's own
// pan recognizer for that touch's whole lifetime. The drawn handle
// dot is cosmetic and plays no part in this test.

@Suite("Resize handle hit-test resolver", .tags(.overlay, .critical))
@MainActor
struct ResizeHandleHitTestTests {

    // MARK: - Large region: each handle independent, no cross-talk

    @Test("Large region (200×200): every handle center resolves to itself")
    func largeRegionEachHandleResolvesIndependently() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
        let expectations: [(CGPoint, RedactionOverlayView.ResizeHandle)] = [
            (CGPoint(x: 0, y: 0), .topLeft),
            (CGPoint(x: 200, y: 0), .topRight),
            (CGPoint(x: 0, y: 200), .bottomLeft),
            (CGPoint(x: 200, y: 200), .bottomRight),
            (CGPoint(x: 100, y: 0), .topCenter),
            (CGPoint(x: 100, y: 200), .bottomCenter),
            (CGPoint(x: 0, y: 100), .leftCenter),
            (CGPoint(x: 200, y: 100), .rightCenter),
        ]
        for (point, expected) in expectations {
            #expect(
                RedactionOverlayView.resolveResizeHandle(at: point, regionRect: rect) == expected,
                "point \(point) should resolve to \(expected)"
            )
        }
    }

    @Test("Large region: a point near a corner but off-center still resolves to that corner")
    func largeRegionNearCornerResolves() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
        // The 46pt floor applies in full here (min dimension 200 ≥
        // 92), so a point 10pt inside the 23pt half-width box still hits.
        #expect(
            RedactionOverlayView.resolveResizeHandle(
                at: CGPoint(x: 10, y: 10), regionRect: rect
            ) == .topLeft
        )
    }

    @Test("Large region: the region's own center is on no handle")
    func largeRegionCenterIsNoHandle() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
        #expect(
            RedactionOverlayView.resolveResizeHandle(
                at: CGPoint(x: 100, y: 100), regionRect: rect
            ) == nil
        )
    }

    // MARK: - Clamp formula: min(46, max(22, min(w,h)/2))

    @Test("Region at exactly the 92pt min-dimension: clamp reaches the full 46pt floor")
    func clampReachesFullFloorAt92() {
        // The target is now 46. min(width,height) = 92 -> 92/2 = 46
        // -> max(22,46) = 46 -> min(46,46) = 46 (half-width 23).
        let rect = CGRect(x: 0, y: 0, width: 92, height: 92)
        // 22 units out on the top edge from topLeft still hits topLeft.
        #expect(
            RedactionOverlayView.resolveResizeHandle(
                at: CGPoint(x: 22, y: 0), regionRect: rect
            ) == .topLeft
        )
        // 24 units out has crossed into topCenter's box (center at x=46,
        // half-width 23 -> box starts at x=23) instead of falling in a gap.
        #expect(
            RedactionOverlayView.resolveResizeHandle(
                at: CGPoint(x: 24, y: 0), regionRect: rect
            ) == .topCenter
        )
    }

    @Test("60pt region: clamp keeps a 30pt move band (half-width 15), not the full 46pt")
    func clampKeeps30ptBandAt60() {
        // min(width,height) = 60 -> 60/2 = 30 -> max(22,30) = 30 -> min(46,30) = 30 (half-width 15).
        // Unaffected by the 44->46 target bump: 30 < both 44 and 46,
        // so the clamp still bottoms out on the region's own half-side.
        let rect = CGRect(x: 0, y: 0, width: 60, height: 60)
        #expect(
            RedactionOverlayView.resolveResizeHandle(
                at: CGPoint(x: 14, y: 14), regionRect: rect
            ) == .topLeft
        )
        // 16pt out on both axes clears topLeft's 15pt half-width AND
        // falls short of topCenter/leftCenter's boxes -> no handle.
        // This is the clamp actually shrinking the zone versus the
        // pre-fix flat 22pt (which would have caught this point).
        #expect(
            RedactionOverlayView.resolveResizeHandle(
                at: CGPoint(x: 16, y: 16), regionRect: rect
            ) == nil
        )
    }

    @Test("A 10×10 region: clamp never regresses below the pre-fix 22pt")
    func clampFloorsAt22ForTinyRegions() {
        // min(width,height) = 10 -> 10/2 = 5 -> max(22,5) = 22 -> min(46,22) = 22 (half-width 11).
        // Unaffected by the 44->46 target bump — 22 wins either way.
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        // A side of 10 is short of 60, so the region has only its four
        // corner handles, and both axes are short of 22, so each corner
        // steps 6 out: bottomRight sits at (16, 16), its 22pt box spans
        // 5…27. A point just inside the region's own corner is in that box
        // and in no other corner's, and past the body's reach.
        #expect(
            RedactionOverlayView.resolveResizeHandle(
                at: CGPoint(x: 9, y: 9), regionRect: rect
            ) == .bottomRight
        )
    }

    // MARK: - Nearest-center tie-break (deterministic, not array order)

    @Test("Overlapping boxes on a thin region resolve to the NEAREST center, not array order")
    func tieBreakIsNearestCenterNotArrayOrder() {
        // 120×5 region: min(w,h)/2 = 2.5 -> clamp floors at 22
        // (half-width 11). Its height is short of 22, so its corners
        // step min(6.5, 8.5) = 6.5 out: topLeft at (0,-6.5), bottomLeft
        // at (0,11.5), 18 apart, so their boxes overlap from y 0.5 to
        // 4.5. Both claim (0,3): 9.5 from topLeft, 8.5 from bottomLeft.
        // `.topLeft` is declared FIRST in the resolver's handles array,
        // so a first-match policy (the pre-fix behavior class) would
        // return `.topLeft` here; nearest-center must return `.bottomLeft`.
        let rect = CGRect(x: 0, y: 0, width: 120, height: 5)
        #expect(
            RedactionOverlayView.resolveResizeHandle(
                at: CGPoint(x: 0, y: 3), regionRect: rect
            ) == .bottomLeft
        )
        // Symmetric check: closer to topLeft (8.5) than to bottomLeft (9.5).
        #expect(
            RedactionOverlayView.resolveResizeHandle(
                at: CGPoint(x: 0, y: 2), regionRect: rect
            ) == .topLeft
        )
    }

    // MARK: - Default parameter wiring

    @Test("Omitting targetHandleSize defaults to ResectaTokens.TouchTarget.minimum")
    func defaultTargetHandleSizeIsTheTouchTargetFloor() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
        let withDefault = RedactionOverlayView.resolveResizeHandle(
            at: CGPoint(x: 10, y: 10), regionRect: rect
        )
        let withExplicitFloor = RedactionOverlayView.resolveResizeHandle(
            at: CGPoint(x: 10, y: 10), regionRect: rect,
            targetHandleSize: ResectaTokens.TouchTarget.minimum
        )
        #expect(withDefault == withExplicitFloor)
        #expect(withDefault == .topLeft)
    }

    @Test("A point far from every handle on a mid-size region resolves to nil")
    func farPointResolvesToNil() {
        let rect = CGRect(x: 0, y: 0, width: 60, height: 60)
        #expect(
            RedactionOverlayView.resolveResizeHandle(
                at: CGPoint(x: 30, y: 30), regionRect: rect
            ) == nil
        )
    }

    // MARK: - Thin regions and page edges

    @Test("A thin region's centre is its body, not a handle")
    func thinRegionCentreIsTheBody() {
        let rect = CGRect(x: 0, y: 0, width: 120, height: 8)
        #expect(RedactionOverlayView.resolveResizeHandle(
            at: CGPoint(x: 60, y: 4), regionRect: rect) == nil)
    }

    @Test("A region at the page edge keeps a whole handle box inside the page")
    func edgeHandleBoxShiftsInward() {
        // A 200-pt region against the left edge: its left-centre box would
        // straddle x = 0, half off the page; inside the page it spans 0…46.
        let rect = CGRect(x: 0, y: 100, width: 200, height: 200)
        let page = CGRect(x: 0, y: 0, width: 400, height: 400)
        #expect(RedactionOverlayView.resolveResizeHandle(
            at: CGPoint(x: 30, y: 200), regionRect: rect, containerBounds: page) == .leftCenter)
    }
}
