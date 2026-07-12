import Testing
import UIKit
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// DRAW-1 — Polygon + freeform drawing gesture tests.
//
// The polygon tool collects vertices on each tap; once `count >= 3`,
// a tap inside `polygonCloseRadius` of the first vertex closes the
// loop and commits a `RedactionRegion` with non-nil `vertices`. A tap
// within `polygonVertexDeduplicationDistance / zoomScale` of the
// previous vertex is silently rejected. The freeform tool accumulates
// touch points during a drag; on touch-up, Douglas-Peucker simplifies
// the raw stream to ≤ 32 vertices (tolerance 2 pt × 1/zoomScale).
// Both routes commit through `coordinator?.addRegion(_:page:undoManager:)`
// — the same path the rectangle tool uses — so undo + observers are
// uniform across shapes.
//
// SECURITY: regions committed via polygon/freeform must always carry
// the `vertices` array. The engine consults `vertices` to choose
// polygon-vs-rect fill / verify; a polygon that lands with
// `vertices == nil` would silently fall back to bounding-box redaction
// — a quiet under-redaction. The "tapSequenceBuildsVertices" test
// pins the vertex count; the freeform tests pin the simplification.

@Suite("Polygon + Freeform Drawing (DRAW-1)")
@MainActor
struct PolygonDrawingTests {

    // MARK: - Douglas-Peucker simplification

    @Test("Long touch stream simplifies to ≤ 32 vertices")
    func testFreeformSimplifiesTo32Vertices() {
        // Synthesize a 300-point touch stream tracing a circle. At
        // tolerance 2 pt the simplifier should collapse this to a
        // small handful of vertices; at any reasonable tolerance the
        // count must be ≤ 32.
        var stream: [CGPoint] = []
        let count = 300
        let cx: CGFloat = 200
        let cy: CGFloat = 200
        let r: CGFloat = 100
        for i in 0..<count {
            let theta = (CGFloat(i) / CGFloat(count)) * 2 * .pi
            stream.append(CGPoint(
                x: cx + r * cos(theta),
                y: cy + r * sin(theta)
            ))
        }
        let simplified = RedactionOverlayView.simplifyDouglasPeucker(
            stream, epsilon: 2.0
        )
        #expect(simplified.count <= RedactionOverlayView.maxPolygonVertices,
                "simplified=\(simplified.count) must be ≤ \(RedactionOverlayView.maxPolygonVertices)")
        #expect(simplified.count >= 3,
                "simplified=\(simplified.count) must be at least 3 to form a polygon")
    }

    @Test("Tolerance at 1× is 2 pt; at 0.5× zoom is 4 pt; at 2× zoom is 1 pt")
    func testFreeformToleranceScalesWithZoom() {
        // The active tolerance is `baseline / zoomScale`. Pin the math
        // at three locked scales.
        let baseline = RedactionOverlayView.freeformDouglasPeuckerToleranceAtUnitZoom
        #expect(baseline == 2.0)
        let halfZoom: CGFloat = 0.5
        let doubleZoom: CGFloat = 2.0
        let oneZoom: CGFloat = 1.0
        #expect(baseline / oneZoom == 2.0)
        #expect(baseline / halfZoom == 4.0)
        #expect(baseline / doubleZoom == 1.0)
    }

    @Test("Simplifying a near-straight zig-zag drops mid points")
    func testDouglasPeuckerDropsMidPoints() {
        // Three collinear points: simplification with tolerance > 0
        // must keep only the endpoints.
        let line = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 50, y: 0),
            CGPoint(x: 100, y: 0),
        ]
        let simplified = RedactionOverlayView.simplifyDouglasPeucker(
            line, epsilon: 1.0
        )
        #expect(simplified.count == 2)
    }

    @Test("Simplifying a sharp triangle keeps the apex")
    func testDouglasPeuckerKeepsSharpFeatures() {
        // Two endpoints + a tall apex that exceeds the tolerance must
        // survive simplification.
        let triangle = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 50, y: 100),  // 100 pt off the baseline
            CGPoint(x: 100, y: 0),
        ]
        let simplified = RedactionOverlayView.simplifyDouglasPeucker(
            triangle, epsilon: 2.0
        )
        #expect(simplified.count == 3)
    }

    // MARK: - Shape tool mapping

    @Test("DrawingTool maps to ShapeTool correctly")
    func testDrawingToolMapping() {
        #expect(DocumentEditorView.shapeTool(for: nil) == .rectangle)
        #expect(DocumentEditorView.shapeTool(for: .rectangle) == .rectangle)
        #expect(DocumentEditorView.shapeTool(for: .polygon) == .polygon)
        #expect(DocumentEditorView.shapeTool(for: .freeform) == .freeform)
    }

    // MARK: - DRAW-1 polygon caption (pure function)

    @Test("polygonCaption returns nil when polygon tool is not active")
    func testPolygonCaptionReturnsNilForOtherTools() {
        // The caption is polygon-tool-only; the rectangle caption is
        // routed by `activeDrawingCaption`, and a nil active tool means
        // the hint capsule should be hidden entirely. Either way the
        // polygon helper itself returns nil.
        #expect(DocumentEditorView.polygonCaption(
            activeTool: .rectangle, vertexCount: 0) == nil)
        #expect(DocumentEditorView.polygonCaption(
            activeTool: .rectangle, vertexCount: 3) == nil)
        #expect(DocumentEditorView.polygonCaption(
            activeTool: nil, vertexCount: 0) == nil)
        #expect(DocumentEditorView.polygonCaption(
            activeTool: .freeform, vertexCount: 5) == nil)
    }

    @Test("polygonCaption at count 0 invites the first vertex")
    func testPolygonCaptionAtZero() {
        #expect(DocumentEditorView.polygonCaption(
            activeTool: .polygon, vertexCount: 0) == "Tap to add vertices.")
    }

    @Test("polygonCaption at count 1 and 2 names the 3-vertex close floor")
    func testPolygonCaptionBelowCloseFloor() {
        let expected = "Tap to add vertices. Need 3 to close."
        #expect(DocumentEditorView.polygonCaption(
            activeTool: .polygon, vertexCount: 1) == expected)
        #expect(DocumentEditorView.polygonCaption(
            activeTool: .polygon, vertexCount: 2) == expected)
    }

    @Test("polygonCaption at count 3 and above names the tap-on-first-vertex close")
    func testPolygonCaptionAtOrAboveCloseFloor() {
        let expected = "Tap the first vertex to close."
        #expect(DocumentEditorView.polygonCaption(
            activeTool: .polygon, vertexCount: 3) == expected)
        #expect(DocumentEditorView.polygonCaption(
            activeTool: .polygon, vertexCount: 4) == expected)
        #expect(DocumentEditorView.polygonCaption(
            activeTool: .polygon, vertexCount: 32) == expected)
    }

    // MARK: - Tap sequence builds vertices via the coordinator path

    /// Test-only coordinator: records `addRegion` calls so the polygon
    /// commit path can be asserted without mounting a full PDFView.
    /// `testOverlays` mirrors the base class's private `activeOverlays`
    /// dictionary so the tool-switch discard path can be exercised
    /// without the PDFKit delegate callback that normally populates it
    /// (the locator-driven `activeOverlays` path is covered in manual
    /// verification during Session 2/3).
    private final class RecordingCoordinator: PDFViewCoordinator {
        var addedRegions: [RedactionRegion] = []
        var testOverlays: [RedactionOverlayView] = []
        override func addRegion(
            _ region: RedactionRegion,
            page: Int,
            undoManager: UndoManager?
        ) {
            addedRegions.append(region)
        }
        override func updateActiveShapeTool(
            _ tool: RedactionOverlayView.ShapeTool
        ) {
            let changed = activeShapeTool != tool
            activeShapeTool = tool
            for overlay in testOverlays {
                overlay.activeShapeTool = tool
                if changed { overlay.discardInProgressPolygon() }
            }
        }
    }

    // MARK: - Polygon test helper

    /// Build a polygon overlay wired to a `RecordingCoordinator` with a
    /// fresh `RedactionState`. Returns all three so tests can drive the
    /// overlay AND assert on the state observer field.
    private func makePolygonHarness(
        size: CGSize = CGSize(width: 400, height: 400)
    ) -> (overlay: RedactionOverlayView,
          coordinator: RecordingCoordinator,
          state: RedactionState) {
        let overlay = RedactionOverlayView(
            frame: CGRect(origin: .zero, size: size)
        )
        overlay.isDrawingMode = true
        overlay.activeShapeTool = .polygon
        let coordinator = RecordingCoordinator()
        // Sync the coordinator's tool to the overlay so a later
        // `updateActiveShapeTool(.rectangle)` is observed as a change
        // (and fires `discardInProgressPolygon`). PDFViewCoordinator
        // defaults to `.rectangle`; without this sync the
        // tool-switch-zeros test would silently no-op.
        coordinator.activeShapeTool = .polygon
        let state = RedactionState()
        coordinator.redactionState = state
        overlay.coordinator = coordinator
        return (overlay, coordinator, state)
    }

    private func tap(_ overlay: RedactionOverlayView, at point: CGPoint) {
        let touch = StubTouch(location: point, view: overlay)
        overlay.touchesBegan([touch], with: nil)
        overlay.touchesEnded([touch], with: nil)
    }

    @Test("Polygon tool: 4 distant taps then tap on first vertex closes loop with 4 vertices")
    func testTapSequenceBuildsVertices() {
        let h = makePolygonHarness()

        // Four taps at well-separated points (> polygonCloseRadius and
        // > dedup tolerance apart) so neither the close branch nor the
        // dedup branch fires while vertices accumulate.
        let points: [CGPoint] = [
            CGPoint(x: 50, y: 50),
            CGPoint(x: 350, y: 50),
            CGPoint(x: 350, y: 350),
            CGPoint(x: 50, y: 350),
        ]

        for pt in points { tap(h.overlay, at: pt) }
        // No region has been committed yet — each tap was far from the
        // first vertex, so the close branch never fired.
        #expect(h.coordinator.addedRegions.isEmpty,
                "vertex-laying taps must not commit until close-on-first-vertex")

        // Close-loop via a single tap inside `polygonCloseRadius` of
        // `points[0]` (the first vertex). Count is already 4 (≥ 3) so
        // the close branch commits without appending a 5th vertex.
        tap(h.overlay, at: points[0])

        #expect(h.coordinator.addedRegions.count == 1,
                "tap-on-first-vertex must commit exactly one polygon region")
        guard let region = h.coordinator.addedRegions.first else { return }
        #expect(region.vertices != nil)
        #expect(region.vertices?.count == 4,
                "committed polygon has \(region.vertices?.count ?? -1) vertices, expected 4")
        #expect(region.source == .manual)
    }

    @Test("Polygon tool: close-on-first-vertex requires ≥ 3 vertices")
    func testTapOnFirstVertexClosesLoop_requiresMinimumThreeVertices() {
        // Two distant taps + a close-radius tap at the first vertex.
        // The close branch requires count >= 3, so the third tap at
        // `pts[0]` appends as vertex 3 instead of closing. A second
        // close-radius tap at `pts[0]` observes count == 3 and commits.
        // This pins the floor: any future change that allows close with
        // < 3 vertices regresses to a degenerate polygon and surfaces
        // here.
        let h = makePolygonHarness()

        let pts = [CGPoint(x: 50, y: 50), CGPoint(x: 350, y: 350)]
        for p in pts { tap(h.overlay, at: p) }

        // First close attempt at pts[0] while count == 2 — appends as
        // vertex 3. (Close branch is gated off below the floor; dedup
        // compares against the previous vertex pts[1], which is far,
        // so dedup does not fire either.)
        tap(h.overlay, at: pts[0])
        #expect(h.coordinator.addedRegions.isEmpty,
                "no commit yet — first close tap had count==2 < 3")
        #expect(h.state.inProgressPolygonVertexCount == 3,
                "third tap appends as vertex 3 below the close floor")

        // Second close at pts[0] — count is 3, close branch commits.
        tap(h.overlay, at: pts[0])
        #expect(h.coordinator.addedRegions.count == 1)
        #expect(h.coordinator.addedRegions.first?.vertices?.count == 3,
                "polygon closes at minimum 3 vertices")
        #expect(h.state.inProgressPolygonVertexCount == 0,
                "commit zeros the observer count")
    }

    @Test("Polygon tool: close-radius tap with count == 3 commits")
    func testCloseRadiusTapWithCountThreeCommits() {
        let h = makePolygonHarness()
        let pts = [
            CGPoint(x: 50, y: 50),
            CGPoint(x: 350, y: 50),
            CGPoint(x: 200, y: 350),
        ]
        for p in pts { tap(h.overlay, at: p) }
        // Tap inside polygonCloseRadius (= 18 pt) of pts[0] — 8 pt
        // away keeps the touch within the close ring without sitting
        // exactly on the first vertex.
        let closingPoint = CGPoint(x: pts[0].x + 8, y: pts[0].y + 8)
        tap(h.overlay, at: closingPoint)
        #expect(h.coordinator.addedRegions.count == 1)
        #expect(h.coordinator.addedRegions.first?.vertices?.count == 3)
    }

    @Test("Polygon tool: tap outside close radius appends")
    func testTapOutsideCloseRadiusAppends() {
        let h = makePolygonHarness()
        let pts = [
            CGPoint(x: 50, y: 50),
            CGPoint(x: 350, y: 50),
            CGPoint(x: 200, y: 350),
        ]
        for p in pts { tap(h.overlay, at: p) }
        // Tap 100 pt from pts[0] — well outside both polygonCloseRadius
        // (18 pt) and the dedup tolerance around pts[2].
        let appendPoint = CGPoint(x: pts[0].x + 100, y: pts[0].y + 100)
        tap(h.overlay, at: appendPoint)
        #expect(h.coordinator.addedRegions.isEmpty,
                "no commit — tap was outside close radius of first vertex")
        #expect(h.state.inProgressPolygonVertexCount == 4,
                "appended as vertex 4")
    }

    @Test("Polygon tool: dedup tap within tolerance of previous vertex is silently rejected")
    func testDedupTapIsSilentlyRejected() {
        let h = makePolygonHarness()
        let first = CGPoint(x: 100, y: 100)
        tap(h.overlay, at: first)
        #expect(h.state.inProgressPolygonVertexCount == 1)
        #expect(h.coordinator.addedRegions.isEmpty)

        // Tap exactly on top of the previous vertex — well inside the
        // dedup tolerance (2 pt / 1× zoom = 2 pt at the test surface,
        // since the overlay has no PDFView ancestor and zoom defaults
        // to 1.0). The append must be silently dropped: count stays
        // at 1 and no commit fires. The append branch is the only one
        // that posts a "Polygon vertex N" announcement, so an unchanged
        // count is also an implicit assertion that no announcement
        // fired for this tap.
        tap(h.overlay, at: first)
        #expect(h.state.inProgressPolygonVertexCount == 1,
                "dedup tap must not bump the vertex count")
        #expect(h.coordinator.addedRegions.isEmpty,
                "dedup tap must not commit a region")
    }

    @Test("Polygon dedup tolerance scales with zoom: 2 pt at 1×, 4 pt at 0.5×, 1 pt at 2×")
    func testPolygonDedupToleranceScalesWithZoom() {
        // Mirror `testFreeformToleranceScalesWithZoom`: active tolerance
        // is `baseline / zoomScale`. Pin the math at three locked
        // scales so a future refactor of the baseline constant has to
        // own the regression.
        let baseline = RedactionOverlayView
            .polygonVertexDeduplicationDistance
        #expect(baseline == 2.0)
        #expect(baseline / 1.0 == 2.0)
        #expect(baseline / 0.5 == 4.0)
        #expect(baseline / 2.0 == 1.0)
    }

    @Test("commitInProgressPolygon with count < 3 is a no-op")
    func testCommitInProgressPolygonBelowFloorIsNoop() {
        let h = makePolygonHarness()
        tap(h.overlay, at: CGPoint(x: 50, y: 50))
        tap(h.overlay, at: CGPoint(x: 350, y: 350))
        #expect(h.state.inProgressPolygonVertexCount == 2)
        h.overlay.commitInProgressPolygon()
        #expect(h.coordinator.addedRegions.isEmpty,
                "below-floor commit must not produce a region")
        #expect(h.state.inProgressPolygonVertexCount == 2,
                "below-floor commit must not mutate the count")
    }

    @Test("commitInProgressPolygon with count >= 3 commits with matching vertex count")
    func testCommitInProgressPolygonAtFloorCommits() {
        let h = makePolygonHarness()
        let pts = [
            CGPoint(x: 50, y: 50),
            CGPoint(x: 350, y: 50),
            CGPoint(x: 200, y: 350),
        ]
        for p in pts { tap(h.overlay, at: p) }
        h.overlay.commitInProgressPolygon()
        #expect(h.coordinator.addedRegions.count == 1)
        #expect(h.coordinator.addedRegions.first?.vertices?.count == 3)
        #expect(h.state.inProgressPolygonVertexCount == 0,
                "commit zeros the observer count")
    }

    @Test("discardInProgressPolygon clears vertices and zeros observer count")
    func testDiscardInProgressPolygonClearsState() {
        let h = makePolygonHarness()
        tap(h.overlay, at: CGPoint(x: 50, y: 50))
        tap(h.overlay, at: CGPoint(x: 350, y: 350))
        #expect(h.state.inProgressPolygonVertexCount == 2)
        h.overlay.discardInProgressPolygon()
        #expect(h.state.inProgressPolygonVertexCount == 0)
        // A subsequent tap restarts vertex 1 — pins that the polygon
        // vertex list was actually cleared (not just the count).
        tap(h.overlay, at: CGPoint(x: 100, y: 100))
        #expect(h.state.inProgressPolygonVertexCount == 1)
    }

    @Test("Tool switch via updateActiveShapeTool zeros polygon vertex count")
    func testToolSwitchZerosPolygonVertexCount() {
        let h = makePolygonHarness()
        h.coordinator.testOverlays = [h.overlay]
        tap(h.overlay, at: CGPoint(x: 50, y: 50))
        tap(h.overlay, at: CGPoint(x: 350, y: 350))
        #expect(h.state.inProgressPolygonVertexCount == 2)
        h.coordinator.updateActiveShapeTool(.rectangle)
        #expect(h.state.inProgressPolygonVertexCount == 0,
                "switching tool fires discardInProgressPolygon on every overlay")
    }

    @Test("Each appended polygon vertex bumps observer count by one")
    func testEachAppendedVertexBumpsCount() {
        let h = makePolygonHarness()
        let pts = [
            CGPoint(x: 50, y: 50),
            CGPoint(x: 350, y: 50),
            CGPoint(x: 200, y: 350),
        ]
        var expected = 0
        for p in pts {
            tap(h.overlay, at: p)
            expected += 1
            #expect(h.state.inProgressPolygonVertexCount == expected)
        }
    }

    @Test("removeFromSuperview zeros polygon vertex count")
    func testRemoveFromSuperviewZerosPolygonVertexCount() {
        let h = makePolygonHarness()
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        parent.addSubview(h.overlay)
        tap(h.overlay, at: CGPoint(x: 50, y: 50))
        tap(h.overlay, at: CGPoint(x: 350, y: 350))
        #expect(h.state.inProgressPolygonVertexCount == 2)
        h.overlay.removeFromSuperview()
        #expect(h.state.inProgressPolygonVertexCount == 0,
                "overlay removal must clear the cross-view count")
    }
}

// MARK: - Test helpers

/// Minimal UITouch stub for synthesising touch sequences in tests.
private final class StubTouch: UITouch {
    private let _location: CGPoint
    private let _view: UIView

    init(location: CGPoint, view: UIView) {
        self._location = location
        self._view = view
        super.init()
    }

    override func location(in view: UIView?) -> CGPoint {
        return _location
    }
    override var view: UIView? { _view }
}
