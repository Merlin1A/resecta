import Testing
import UIKit
import CoreGraphics
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// DRAW-7 — Snap-to-text-box assist tests.
//
// While the user drags a rectangle in drawing mode, in-progress edges
// within `snapToTextToleranceAtUnitZoom / zoomScale` overlay-space
// points of an OCR text-block edge are nudged onto the text edge. The
// assist is designed to align edges to recognized text rows; it does
// not promise alignment for every drag (mechanism-description
// language, I6).
//
// DRAW-7 contract:
//   - Tolerance baseline: 8 pt at 1× zoom; scales by `1/zoomScale`.
//   - Default on; opt-out via `SettingsState.snapToTextEnabled`.
//   - Hook into `touchesMoved`, NOT `touchesEnded`.
//   - Persistence: `isInitializing` + `didSet` (NOT `@AppStorage` —
//     banned inside `@Observable`).
//
// The overlay coordinate transform flips Y between normalized PDF
// space (bottom-left origin) and overlay space (top-left origin). The
// fixtures below are sized so the snap math works in overlay space:
// a 400×400 overlay, an OCR bbox at normalized
// (0.10, 0.10, 0.30, 0.05), and a candidate drag rect within 8 pt of
// each edge in overlay coords.

@Suite("Snap-to-Text-Box Assist (DRAW-7)")
@MainActor
struct SnapToTextBoxTests {

    // Shared fixture: 400×400 overlay, single OCR bbox.
    // PDF normalized (0.10, 0.10, 0.30, 0.05) → overlay space rect
    // (40, 340, 120, 20):
    //   - minX = 0.10 * 400 = 40
    //   - minY = (1 - 0.10 - 0.05) * 400 = 340
    //   - width = 0.30 * 400 = 120
    //   - height = 0.05 * 400 = 20
    private static let overlayWidth: CGFloat = 400
    private static let overlayHeight: CGFloat = 400
    private static let ocrBboxNormalized = CGRect(
        x: 0.10, y: 0.10, width: 0.30, height: 0.05
    )

    private func makeOverlay(
        snapEnabled: Bool = true,
        zoomOverride: CGFloat? = nil
    ) -> RedactionOverlayView {
        let overlay = RedactionOverlayView(
            frame: CGRect(
                x: 0, y: 0,
                width: Self.overlayWidth, height: Self.overlayHeight
            )
        )
        overlay.isDrawingMode = true
        overlay.activeShapeTool = .rectangle
        overlay.snapToTextEnabled = snapEnabled
        overlay.ocrTextBlockNormalizedRects = [Self.ocrBboxNormalized]
        overlay.snapZoomScaleOverride = zoomOverride
        return overlay
    }

    /// Drive a rectangle drag that ends at `endNormalized` (PDF coords).
    /// Returns the committed normalized rect via the recording
    /// coordinator. The drag uses the overlay's own normalize-to-overlay
    /// transform so the math stays consistent with production.
    private func runDrag(
        on overlay: RedactionOverlayView,
        endNormalized: CGRect
    ) -> CGRect? {
        let recorder = RecordingCoordinator()
        overlay.coordinator = recorder

        // Convert end-normalized to overlay coords for the touch points.
        let endOverlay = overlay.pdfNormalizedToOverlay(endNormalized)
        let beginPoint = CGPoint(x: endOverlay.minX, y: endOverlay.minY)
        let movePoint = CGPoint(x: endOverlay.maxX, y: endOverlay.maxY)

        let beganTouch = StubTouch(location: beginPoint, view: overlay)
        overlay.touchesBegan([beganTouch], with: nil)
        let movedTouch = StubTouch(location: movePoint, view: overlay)
        overlay.touchesMoved([movedTouch], with: nil)
        let endedTouch = StubTouch(location: movePoint, view: overlay)
        overlay.touchesEnded([endedTouch], with: nil)

        return recorder.addedRegions.first?.normalizedRect
    }

    // MARK: - Tests

    @Test("Edges within 8pt tolerance snap onto the OCR text-block edges")
    func testSnapsWithinTolerance() {
        let overlay = makeOverlay()

        // Per dispatch: end-normalized (0.105, 0.11, 0.295, 0.06) is
        // within tolerance of the OCR bbox at the test render size.
        // Each edge differs by at most ~8 pt in overlay coords, so all
        // four edges should snap.
        let endNormalized = CGRect(
            x: 0.105, y: 0.11, width: 0.295, height: 0.06
        )
        let committed = runDrag(on: overlay, endNormalized: endNormalized)
        #expect(committed != nil)
        guard let committed else { return }

        // After snap the committed rect must equal the OCR bbox
        // (within floating-point tolerance). Using ~1e-6 — the snap
        // math is integer-pt accurate, but the round-trip through
        // overlay coords + normalize introduces FP noise.
        #expect(abs(committed.minX - Self.ocrBboxNormalized.minX) < 1e-5,
                "minX=\(committed.minX), expected ~\(Self.ocrBboxNormalized.minX)")
        #expect(abs(committed.minY - Self.ocrBboxNormalized.minY) < 1e-5,
                "minY=\(committed.minY), expected ~\(Self.ocrBboxNormalized.minY)")
        #expect(abs(committed.width - Self.ocrBboxNormalized.width) < 1e-5,
                "width=\(committed.width), expected ~\(Self.ocrBboxNormalized.width)")
        #expect(abs(committed.height - Self.ocrBboxNormalized.height) < 1e-5,
                "height=\(committed.height), expected ~\(Self.ocrBboxNormalized.height)")
    }

    @Test("Edges 12pt off (beyond 8pt tolerance) do not snap")
    func testNoSnapBeyondTolerance() {
        let overlay = makeOverlay()

        // 12 pt off in overlay space → 0.03 in normalized 400-pt
        // overlay. Build a rect whose left/right edges sit 12 pt
        // outside the OCR bbox so the snap path can't reach them.
        let twelvePtNormalized: CGFloat = 12.0 / Self.overlayWidth
        let endNormalized = CGRect(
            x: Self.ocrBboxNormalized.minX - twelvePtNormalized,
            y: Self.ocrBboxNormalized.minY - twelvePtNormalized,
            width: Self.ocrBboxNormalized.width + 2 * twelvePtNormalized,
            height: Self.ocrBboxNormalized.height + 2 * twelvePtNormalized
        )
        let committed = runDrag(on: overlay, endNormalized: endNormalized)
        #expect(committed != nil)
        guard let committed else { return }

        // With no snap, the committed rect equals the drag end rect.
        // Any divergence would mean the snap fired beyond tolerance.
        #expect(abs(committed.minX - endNormalized.minX) < 1e-5)
        #expect(abs(committed.minY - endNormalized.minY) < 1e-5)
        #expect(abs(committed.width - endNormalized.width) < 1e-5)
        #expect(abs(committed.height - endNormalized.height) < 1e-5)
    }

    @Test("Tolerance scales with zoom — 5pt offset at 2× zoom does not snap")
    func testToleranceScalesWithZoom() {
        // At 1× the tolerance is 8 pt; at 2× it halves to 4 pt. A
        // 5 pt offset at 2× is beyond tolerance, so the snap must
        // not fire. This pins the `1/zoomScale` math from the contract
        // DRAW-7.
        let overlay = makeOverlay(zoomOverride: 2.0)

        // 5 pt offset in overlay space → 5/400 in normalized space.
        let fivePtNormalized: CGFloat = 5.0 / Self.overlayWidth
        let endNormalized = CGRect(
            x: Self.ocrBboxNormalized.minX - fivePtNormalized,
            y: Self.ocrBboxNormalized.minY - fivePtNormalized,
            width: Self.ocrBboxNormalized.width + 2 * fivePtNormalized,
            height: Self.ocrBboxNormalized.height + 2 * fivePtNormalized
        )
        let committed = runDrag(on: overlay, endNormalized: endNormalized)
        #expect(committed != nil)
        guard let committed else { return }

        // With tolerance 4 pt at 2× zoom, the 5 pt offset must NOT
        // snap. Committed rect equals input.
        #expect(abs(committed.minX - endNormalized.minX) < 1e-5)
        #expect(abs(committed.width - endNormalized.width) < 1e-5)
    }

    @Test("Opt-out toggle prevents snap when set to false")
    func testOptOutPreventsSnap() {
        let overlay = makeOverlay(snapEnabled: false)

        // Same drag as `testSnapsWithinTolerance` — within tolerance —
        // but with snap disabled. Committed rect must remain at the
        // raw drag end (no snap).
        let endNormalized = CGRect(
            x: 0.105, y: 0.11, width: 0.295, height: 0.06
        )
        let committed = runDrag(on: overlay, endNormalized: endNormalized)
        #expect(committed != nil)
        guard let committed else { return }

        #expect(abs(committed.minX - endNormalized.minX) < 1e-5,
                "snap-disabled drag should not snap minX")
        #expect(abs(committed.width - endNormalized.width) < 1e-5,
                "snap-disabled drag should not snap width")
    }

    @Test("Setting snapToTextEnabled false persists across SettingsState init")
    func testSettingPersists() {
        // Clean the key first so the test is hermetic.
        UserDefaults.standard.removeObject(forKey: "snapToTextEnabled")

        let state = SettingsState()
        #expect(state.snapToTextEnabled == true,
                "default value must be true")

        state.snapToTextEnabled = false
        #expect(UserDefaults.standard.bool(forKey: "snapToTextEnabled") == false,
                "didSet must write to UserDefaults immediately")

        // Re-init reads from UserDefaults — the stored false survives.
        let reloaded = SettingsState()
        #expect(reloaded.snapToTextEnabled == false,
                "reload must observe the persisted false value")

        // Clean up so other tests start with a fresh default.
        UserDefaults.standard.removeObject(forKey: "snapToTextEnabled")
    }
}

// MARK: - Test helpers

/// Test-only coordinator that records `addRegion` calls. Used by the
/// drag-end commit path to capture the committed region's normalized
/// rect without mounting a real PDFView.
private final class RecordingCoordinator: PDFViewCoordinator {
    var addedRegions: [RedactionRegion] = []
    override func addRegion(
        _ region: RedactionRegion,
        page: Int,
        undoManager: UndoManager?
    ) {
        addedRegions.append(region)
    }
}

/// Minimal `UITouch` stub for synthesising touch sequences in tests.
/// Mirrors the helper in `PolygonDrawingTests` — kept private here so
/// each test file owns its own surface.
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
