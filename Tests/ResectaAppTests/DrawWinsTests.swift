import Testing
import UIKit
import CoreGraphics
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// Rectangle draw tool — S2 of the 1.1.0 draw-tool program (D-109; RB-75, RB-77).
//
//   S2-a  DRAW WINS: with the Rectangle tool on, a touch-down ALWAYS starts a
//         draw — over a region body (DT-04), over a selected region's handle
//         box (DT-05), with the Add-to-Selection toggle left on (DT-07) — and
//         the context menu is suppressed. With the tool off, the old ladder
//         (handle → region → marquee) is unchanged (regression pins).
//   S2-b  SCREEN-POINT THRESHOLDS (DT-06): every finger tolerance is divided
//         by the live zoom (`fingerScale`), pinned through the
//         `snapZoomScaleOverride` seam.
//   S2-c  the inert "Snap to Text Boxes" Settings toggle is gone (DT-09);
//         the machinery stays (`SnapToTextBoxTests`).
//
// Geometry: a 400×400 overlay, so 1 overlay pt = 0.0025 normalized. The
// fixture region is the centred 200×200 square (overlay 100…300 × 100…300);
// its corners are ≥ 77 pt from the page-centre snap lines and the page
// margins so no snap alters the numbers below.

@Suite("Draw wins + screen-point thresholds (S2)")
@MainActor
struct DrawWinsTests {

    private static let overlaySize = CGSize(width: 400, height: 400)

    private static func centredRegion() -> RedactionRegion {
        RedactionRegion.mock(rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    }

    private func makeOverlay(
        drawing: Bool,
        regions: [RedactionRegion] = [],
        selectedIDs: Set<UUID> = [],
        zoom: CGFloat? = nil
    ) -> (overlay: RedactionOverlayView, coordinator: RecordingCoordinator) {
        let overlay = RedactionOverlayView(
            frame: CGRect(origin: .zero, size: Self.overlaySize)
        )
        overlay.isDrawingMode = drawing
        overlay.activeShapeTool = .rectangle
        overlay.snapToTextEnabled = false
        overlay.snapZoomScaleOverride = zoom
        let coordinator = RecordingCoordinator()
        overlay.coordinator = coordinator
        overlay.configure(with: regions, selectedIDs: selectedIDs)
        return (overlay, coordinator)
    }

    private func drag(
        _ overlay: RedactionOverlayView,
        from origin: CGPoint,
        through points: [CGPoint]
    ) {
        let touch = StubTouch(location: origin, view: overlay)
        overlay.touchesBegan([touch], with: nil)
        for point in points {
            touch.move(to: point)
            overlay.touchesMoved([touch], with: nil)
        }
        overlay.touchesEnded([touch], with: nil)
    }

    // MARK: - S2-a draw wins

    @Test("S2-a: draw mode + touch-down on a region body draws a NEW region; the old one is unmoved and unselected (DT-04)")
    func testDrawOverRegionBody() {
        let region = Self.centredRegion()
        let (overlay, coordinator) = makeOverlay(
            drawing: true, regions: [region], selectedIDs: [region.id]
        )
        drag(overlay, from: CGPoint(x: 200, y: 200), through: [CGPoint(x: 260, y: 250)])
        #expect(coordinator.addedRegions.count == 1, "a drag over a body draws")
        #expect(coordinator.movedRegions.isEmpty, "the body never moves in draw mode")
        #expect(coordinator.resizedRegions.isEmpty)
        #expect(coordinator.selections.first == .some(nil),
                "touch-down clears the selection before drawing")
        #expect(!coordinator.selections.contains(region.id),
                "the tapped body is never selected in draw mode")
    }

    @Test("S2-a: draw mode + touch-down inside the selected region's handle box draws, never resizes (DT-05)")
    func testDrawOverHandleBox() {
        let region = Self.centredRegion()
        let (overlay, coordinator) = makeOverlay(
            drawing: true, regions: [region], selectedIDs: [region.id]
        )
        // (100,100) is the top-left corner — dead centre of its 46-pt box.
        drag(overlay, from: CGPoint(x: 100, y: 100), through: [CGPoint(x: 60, y: 60)])
        #expect(coordinator.addedRegions.count == 1, "a drag from a handle box draws")
        #expect(coordinator.resizedRegions.isEmpty, "no resize in draw mode")
        #expect(coordinator.movedRegions.isEmpty)
    }

    @Test("S2-a: draw mode + Add to Selection on draws, no lasso commit (DT-07, S1-f carried)")
    func testDrawWithMultiSelectOn() {
        let region = Self.centredRegion()
        let (overlay, coordinator) = makeOverlay(drawing: true, regions: [region])
        overlay.isMultiSelectActive = true
        drag(overlay, from: CGPoint(x: 200, y: 200), through: [CGPoint(x: 260, y: 250)])
        #expect(coordinator.addedRegions.count == 1)
        #expect(coordinator.lassoCommits.isEmpty)
        #expect(!coordinator.selections.contains(region.id),
                "no toggle-select of the body underneath")
    }

    @Test("S2-a regression: tool OFF — body tap selects, handle-box drag resizes, marquee runs with the toggle on")
    func testToolOffLadderUnchanged() {
        let region = Self.centredRegion()

        let (tapOverlay, tapCoordinator) = makeOverlay(drawing: false, regions: [region])
        let tap = StubTouch(location: CGPoint(x: 200, y: 200), view: tapOverlay)
        tapOverlay.touchesBegan([tap], with: nil)
        tapOverlay.touchesEnded([tap], with: nil)
        #expect(tapCoordinator.selections == [region.id], "body tap selects")
        #expect(tapCoordinator.addedRegions.isEmpty)

        let (handleOverlay, handleCoordinator) = makeOverlay(
            drawing: false, regions: [region], selectedIDs: [region.id]
        )
        drag(handleOverlay, from: CGPoint(x: 100, y: 100), through: [CGPoint(x: 80, y: 80)])
        #expect(handleCoordinator.resizedRegions.count == 1, "handle-box drag resizes")
        #expect(handleCoordinator.addedRegions.isEmpty)

        let (marqueeOverlay, marqueeCoordinator) = makeOverlay(drawing: false, regions: [region])
        marqueeOverlay.isMultiSelectActive = true
        drag(marqueeOverlay, from: CGPoint(x: 20, y: 20), through: [CGPoint(x: 60, y: 60)])
        #expect(marqueeCoordinator.lassoCommits.count == 1, "marquee still runs")
        #expect(marqueeCoordinator.addedRegions.isEmpty)
    }

    @Test("S2-a: the context menu is suppressed in draw mode and served on a region with the tool off")
    func testContextMenuSuppressedInDrawMode() {
        let region = Self.centredRegion()
        let (drawOverlay, _) = makeOverlay(drawing: true, regions: [region])
        let drawInteraction = UIContextMenuInteraction(delegate: drawOverlay)
        #expect(drawOverlay.contextMenuInteraction(
            drawInteraction, configurationForMenuAtLocation: CGPoint(x: 200, y: 200)
        ) == nil, "no menu while the Rectangle tool is on")

        let (offOverlay, _) = makeOverlay(drawing: false, regions: [region])
        let offInteraction = UIContextMenuInteraction(delegate: offOverlay)
        #expect(offOverlay.contextMenuInteraction(
            offInteraction, configurationForMenuAtLocation: CGPoint(x: 200, y: 200)
        ) != nil, "tool off: the region menu is served")
    }

    // MARK: - S2-b screen-point thresholds

    @Test("S2-b: at zoom 2.0 a 12×12 overlay-pt drag (24 screen pt) commits; the start gate opens at 4 overlay pt")
    func testZoomedInThresholdsShrink() {
        let (overlay, coordinator) = makeOverlay(drawing: true, zoom: 2.0)
        let touch = StubTouch(location: CGPoint(x: 60, y: 60), view: overlay)
        overlay.touchesBegan([touch], with: nil)
        touch.move(to: CGPoint(x: 65, y: 65))
        overlay.touchesMoved([touch], with: nil)
        #expect(overlay.currentDragRect != nil,
                "5 overlay pt = 10 screen pt clears the 8-screen-pt start gate at 2.0×")
        touch.move(to: CGPoint(x: 72, y: 72))
        overlay.touchesMoved([touch], with: nil)
        overlay.touchesEnded([touch], with: nil)
        #expect(coordinator.addedRegions.count == 1,
                "12 overlay pt = 24 screen pt clears the 20-screen-pt floor at 2.0×")

        // Control: the same 5-pt move at 1.0× stays inside the 8-pt gate.
        let (unitOverlay, _) = makeOverlay(drawing: true, zoom: 1.0)
        let unitTouch = StubTouch(location: CGPoint(x: 60, y: 60), view: unitOverlay)
        unitOverlay.touchesBegan([unitTouch], with: nil)
        unitTouch.move(to: CGPoint(x: 65, y: 65))
        unitOverlay.touchesMoved([unitTouch], with: nil)
        #expect(unitOverlay.currentDragRect == nil, "5 pt at 1.0× is inside the 8-pt gate")
    }

    @Test("S2-b: at zoom 0.5 a 30×30 overlay-pt drag (15 screen pt) is rejected")
    func testZoomedOutFloorGrows() {
        let (overlay, coordinator) = makeOverlay(drawing: true, zoom: 0.5)
        drag(overlay, from: CGPoint(x: 60, y: 60), through: [CGPoint(x: 90, y: 90)])
        #expect(coordinator.addedRegions.isEmpty,
                "30 overlay pt = 15 screen pt is under the 20-screen-pt floor at 0.5×")

        let (unitOverlay, unitCoordinator) = makeOverlay(drawing: true, zoom: 1.0)
        drag(unitOverlay, from: CGPoint(x: 60, y: 60), through: [CGPoint(x: 90, y: 90)])
        #expect(unitCoordinator.addedRegions.count == 1, "the same drag commits at 1.0×")
    }

    @Test("S2-b: the handle box shrinks with zoom — 20 pt inside the corner resizes at 1.0× and moves at 2.0×; 40 pt resizes at 0.5×")
    func testHandleBoxScalesWithZoom() {
        let region = Self.centredRegion()

        // 1.0×: box = 46 overlay pt (half 23) → (120,120) is a handle.
        let (unit, unitCoordinator) = makeOverlay(
            drawing: false, regions: [region], selectedIDs: [region.id], zoom: 1.0
        )
        drag(unit, from: CGPoint(x: 120, y: 120), through: [CGPoint(x: 90, y: 90)])
        #expect(unitCoordinator.resizedRegions.count == 1)
        #expect(unitCoordinator.movedRegions.isEmpty)

        // 2.0×: box = 23 overlay pt (half 11.5) → (120,120) is body → move.
        let (zoomed, zoomedCoordinator) = makeOverlay(
            drawing: false, regions: [region], selectedIDs: [region.id], zoom: 2.0
        )
        drag(zoomed, from: CGPoint(x: 120, y: 120), through: [CGPoint(x: 90, y: 90)])
        #expect(zoomedCoordinator.resizedRegions.isEmpty)
        #expect(zoomedCoordinator.movedRegions.count == 1)

        // 0.5×: box = 92 overlay pt (half 46) → (140,140) is still a handle.
        let (wide, wideCoordinator) = makeOverlay(
            drawing: false, regions: [region], selectedIDs: [region.id], zoom: 0.5
        )
        drag(wide, from: CGPoint(x: 140, y: 140), through: [CGPoint(x: 90, y: 90)])
        #expect(wideCoordinator.resizedRegions.count == 1)
        #expect(wideCoordinator.movedRegions.isEmpty)
    }

    @Test("S2-b: the region hit inset scales — 12 pt outside the body selects at 0.5× and not at 1.0×")
    func testRegionHitInsetScalesWithZoom() {
        let region = Self.centredRegion()
        let (wide, wideCoordinator) = makeOverlay(drawing: false, regions: [region], zoom: 0.5)
        let wideTap = StubTouch(location: CGPoint(x: 88, y: 200), view: wide)
        wide.touchesBegan([wideTap], with: nil)
        wide.touchesEnded([wideTap], with: nil)
        #expect(wideCoordinator.selections == [region.id], "16-pt inset at 0.5×")

        let (unit, unitCoordinator) = makeOverlay(drawing: false, regions: [region], zoom: 1.0)
        let unitTap = StubTouch(location: CGPoint(x: 88, y: 200), view: unit)
        unit.touchesBegan([unitTap], with: nil)
        unit.touchesEnded([unitTap], with: nil)
        #expect(unitCoordinator.selections.isEmpty, "8-pt inset at 1.0×")
    }

    @Test("S2-b: resolveResizeHandle's minimumHandleSize parameter clamps the small-region floor")
    func testMinimumHandleSizeParameter() {
        // 30×30 region: half the short side = 15 → default floor 22 wins.
        let rect = CGRect(x: 100, y: 100, width: 30, height: 30)
        let point = CGPoint(x: 100 - 10.5, y: 100 - 10.5)   // 10.5 pt outside the corner
        #expect(RedactionOverlayView.resolveResizeHandle(at: point, regionRect: rect) == .topLeft,
                "default floor 22 → half 11 covers 10.5 pt")
        #expect(RedactionOverlayView.resolveResizeHandle(
            at: point, regionRect: rect,
            targetHandleSize: 23, minimumHandleSize: 11
        ) == nil, "zoom-2.0 floor 11 → half 5.5 misses 10.5 pt")
    }

    // MARK: - S2-a editor statics

    @Test("S2-a: drawToolEntryEffects — entering clears the selection and the toggle; exiting changes nothing else")
    func testDrawToolEntryEffects() {
        let entering = DocumentEditorView.drawToolEntryEffects(entering: true)
        #expect(entering.clearSelection && entering.disableMultiSelect)
        let exiting = DocumentEditorView.drawToolEntryEffects(entering: false)
        #expect(!exiting.clearSelection && !exiting.disableMultiSelect)
    }

    @Test("S2-d: nudgeDelta is one PDF point per axis (Letter → 1/612, 1/792); nil/degenerate → 0.0025")
    func testNudgeDelta() {
        let letter = DocumentEditorView.nudgeDelta(pageSize: CGSize(width: 612, height: 792))
        #expect(abs(letter.dx - 1 / 612) < 1e-12 && abs(letter.dy - 1 / 792) < 1e-12)
        let none = DocumentEditorView.nudgeDelta(pageSize: nil)
        #expect(none.dx == 0.0025 && none.dy == 0.0025)
        let zero = DocumentEditorView.nudgeDelta(pageSize: .zero)
        #expect(zero.dx == 0.0025 && zero.dy == 0.0025)
    }

    // MARK: - S2-c source contract

    @Test("S2-c: the inert Snap to Text Boxes toggle is gone from SettingsView (DT-09 / RB-77)")
    func testSnapToggleRemovedFromSettings() throws {
        let source = try loadRepoFile("Sources/ResectaApp/Views/SettingsView.swift")
        #expect(!source.contains("Snap to Text Boxes"), "the toggle title must not appear")
        #expect(!source.contains("settingsState.snapToTextEnabled"),
                "no Settings binding to the dark snap-to-text flag")
        #expect(source.contains("DRAW-7 UI removed 1.1.0"), "the revival note stays at the site")
    }

    @Test("S2-a: the editor's Add to Selection toggle exits the Rectangle tool and tool entry clears the toggle (source pin)")
    func testEditorMutualExclusionSourcePin() throws {
        let source = try loadRepoFile("Sources/ResectaApp/Views/DocumentEditorView.swift")
        #expect(source.contains("if isMultiSelectActive { activeTool = nil }"))
        #expect(source.contains("DocumentEditorView.drawToolEntryEffects(entering: entering)"))
    }

    // MARK: - S3 source contract (packet §7.7)

    @Test("S3 (§7.7): applyResizeSnapping posts the 'Aligned to guide' VoiceOver announcement like applySnapping — the draw path snaps through it since S1-b (source pin)")
    func testResizeSnapAnnouncesGuideAlignment() throws {
        let source = try loadRepoFile("Sources/ResectaApp/Overlay/RedactionOverlayView.swift")
        guard let start = source.range(of: "private func applyResizeSnapping("),
              let end = source.range(of: "// MARK: - Handle Animation",
                                     range: start.upperBound..<source.endIndex)
        else {
            Issue.record("Could not locate applyResizeSnapping")
            return
        }
        let body = source[start.upperBound..<end.lowerBound]
        #expect(body.contains("UIAccessibility.isVoiceOverRunning"),
                "the announcement must be gated on VoiceOver, as in applySnapping")
        #expect(body.contains("argument: \"Aligned to guide\""),
                "the resize/draw snap path must post the same announcement the move path posts")
    }

    private func loadRepoFile(_ relativePath: String, file: StaticString = #filePath) throws -> String {
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
