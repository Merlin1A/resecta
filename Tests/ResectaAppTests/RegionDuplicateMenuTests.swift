import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// WU-37 — Duplicate Region on the canvas context menu.
// The 0.02-offset clamp pre-existed in `RedactionState.duplicateRegion`;
// this WU promotes it to the long-press menu, retitles the action
// "Duplicate Region", and overrides the inner addRegion undo name to
// "Duplicate Redaction" so the iOS long-press Undo menu reads in the
// existing "<verb> Redaction" pattern (see WU-41).

@Suite("Region duplicate menu (WU-37)")
@MainActor
struct RegionDuplicateMenuTests {

    // MARK: - 0.02-offset clamp predicate

    @Test("Interior region duplicates with +0.02 in X and -0.02 in Y")
    func interiorRegionShiftsBothAxes() {
        let source = CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)
        let clamped = RedactionState.duplicateOffsetClamp(source: source)
        #expect(abs(clamped.minX - 0.52) < 1e-9)
        #expect(abs(clamped.minY - 0.48) < 1e-9)
        // Width / height are preserved across the copy.
        #expect(abs(clamped.width - 0.1) < 1e-9)
        #expect(abs(clamped.height - 0.1) < 1e-9)
    }

    @Test("Region touching the right edge clamps so the copy stays in-page")
    func rightEdgeClampsToOneMinusWidth() {
        // minX 0.95, width 0.05 — minX+offset would be 0.97, but
        // 1-width is 0.95. Clamp keeps the duplicate flush at 0.95.
        let source = CGRect(x: 0.95, y: 0.5, width: 0.05, height: 0.1)
        let clamped = RedactionState.duplicateOffsetClamp(source: source)
        #expect(abs(clamped.minX - 0.95) < 1e-9)
        #expect(clamped.maxX <= 1.0 + 1e-9)
    }

    @Test("Region touching the top edge clamps so the copy doesn't go below 0")
    func topEdgeClampsToZero() {
        // PDF normalized coords use bottom-left origin; minY 0.01,
        // offset -0.02 would yield -0.01; clamp keeps it at 0.
        let source = CGRect(x: 0.1, y: 0.01, width: 0.1, height: 0.05)
        let clamped = RedactionState.duplicateOffsetClamp(source: source)
        #expect(abs(clamped.minY - 0.0) < 1e-9)
    }

    @Test("Right-edge clamp output stays within the unit square")
    func clampOutputStaysInUnitSquare() {
        // Sweep a battery of rect shapes; for each, maxX must not
        // exceed 1.0 and minY must not drop below 0.
        let cases: [CGRect] = [
            CGRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5),
            CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
            CGRect(x: 0.95, y: 0.95, width: 0.04, height: 0.04),
            CGRect(x: 0.0, y: 1.0, width: 0.1, height: 0.0),
            CGRect(x: 0.0, y: 0.0, width: 0.99, height: 0.99),
        ]
        for source in cases {
            let clamped = RedactionState.duplicateOffsetClamp(source: source)
            #expect(clamped.minX >= 0.0)
            #expect(clamped.minY >= 0.0)
            #expect(clamped.maxX <= 1.0 + 1e-9, "maxX \(clamped.maxX) > 1 for \(source)")
        }
    }

    // MARK: - Undo action name override

    @Test("duplicateRegion overrides the inner addRegion undo name with Duplicate Redaction")
    func duplicateOverridesAddUndoName() {
        let state = RedactionState()
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.1),
            source: .manual
        )
        state.regions[0, default: []].append(region)
        let mgr = makeUndoManager()

        withUndoGroup(mgr) {
            state.duplicateRegion(region.id, page: 0, undoManager: mgr)
        }

        // The inner addRegion call sets the action name to "Add
        // Redaction"; duplicateRegion's trailing setActionName overrides
        // it. UndoManager.undoActionName reads the name of the next undo.
        #expect(mgr.undoActionName == "Duplicate Redaction")
    }

    @Test("Undo restores the page region count")
    func undoRestoresPriorCount() {
        let state = RedactionState()
        let original = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.2, y: 0.5, width: 0.1, height: 0.1),
            source: .manual
        )
        state.regions[0, default: []].append(original)
        let mgr = makeUndoManager()

        withUndoGroup(mgr) {
            state.duplicateRegion(original.id, page: 0, undoManager: mgr)
        }
        #expect(state.regions[0]?.count == 2)

        mgr.undo()
        #expect(state.regions[0]?.count == 1)
    }

    @Test("Duplicate of a detected region lands as manual-sourced")
    func duplicateIsManualSourced() {
        let state = RedactionState()
        let detected = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.2, y: 0.5, width: 0.1, height: 0.1),
            source: .detectedPII(kind: .ssn)
        )
        state.regions[0, default: []].append(detected)

        state.duplicateRegion(detected.id, page: 0, undoManager: nil)
        // Two regions on page 0 — the original detection and the
        // manual-sourced copy. The copy must NOT inherit the detection
        // source so the verification pipeline treats it as user-drawn.
        let manual = state.regions[0]?.filter { $0.source == .manual } ?? []
        #expect(manual.count == 1)
    }
}
