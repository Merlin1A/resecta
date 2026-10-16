import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// The coordinator's commit seams. A move or resize commit records a step
// only when the rect changed: a tap on an already-selected region ends
// its "drag" at the start point, and that commit must leave no Move or
// Resize undo step and no `regionVersion` bump behind.

@Suite("Coordinator commit guard")
@MainActor
struct CoordinatorCommitGuardTests {

    private func seeded() -> (coordinator: PDFViewCoordinator, state: RedactionState, region: RedactionRegion) {
        let state = RedactionState()
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.10, y: 0.10, width: 0.30, height: 0.05),
            source: .manual
        )
        state.addRegion(region, page: 0, undoManager: nil)
        let coordinator = PDFViewCoordinator()
        coordinator.redactionState = state
        return (coordinator, state, region)
    }

    @Test("A move commit at the stored rect records no step")
    func moveAtTheStoredRectIsANoOp() {
        let (coordinator, state, region) = seeded()
        let undoManager = UndoManager()
        let version = state.regionVersion
        coordinator.commitMove(region.id, page: 0, newRect: region.normalizedRect, undoManager: undoManager)
        #expect(undoManager.canUndo == false)
        #expect(state.regionVersion == version)
    }

    @Test("A resize commit at the stored rect records no step")
    func resizeAtTheStoredRectIsANoOp() {
        let (coordinator, state, region) = seeded()
        let undoManager = UndoManager()
        let version = state.regionVersion
        coordinator.commitResize(region.id, page: 0, newRect: region.normalizedRect, undoManager: undoManager)
        #expect(undoManager.canUndo == false)
        #expect(state.regionVersion == version)
    }

    @Test("A real move still records one undoable step")
    func aRealMoveRecords() {
        let (coordinator, state, region) = seeded()
        let undoManager = UndoManager()
        let moved = region.normalizedRect.offsetBy(dx: 0.05, dy: 0)
        coordinator.commitMove(region.id, page: 0, newRect: moved, undoManager: undoManager)
        #expect(undoManager.canUndo)
        #expect(state.regions[0]?.first?.normalizedRect == moved)
    }
}
