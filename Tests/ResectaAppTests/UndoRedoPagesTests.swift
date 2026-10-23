import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// The undo helper records the pages an Undo or Redo step touched, so the
// editor can show and name the page the step changed.
@Suite("Undo and Redo report their pages", .tags(.overlay))
@MainActor
struct UndoRedoPagesTests {

    private static func region(y: Double = 0.2) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: y, width: 0.3, height: 0.05), source: .manual)
    }

    @Test("Undo of an add on page 3 reports page 3")
    func undoReportsThePageItTouched() {
        let state = RedactionState()
        let mgr = makeUndoManager()
        withUndoGroup(mgr) {
            state.addRegion(Self.region(), page: 3, undoManager: mgr)
        }
        mgr.undo()
        #expect(state.lastUndoRedoPages == [3])
    }

    @Test("Undo of a delete that spans two pages reports both pages")
    func undoOfATwoPageDeleteReportsBothPages() {
        let state = RedactionState()
        let first = Self.region(y: 0.10)
        let second = Self.region(y: 0.30)
        let third = Self.region(y: 0.50)
        state.addRegion(first, page: 0, undoManager: nil)
        state.addRegion(second, page: 0, undoManager: nil)
        state.addRegion(third, page: 2, undoManager: nil)
        state.selectedRegionIDs = [first.id, second.id, third.id]
        let mgr = makeUndoManager()
        withUndoGroup(mgr) {
            _ = state.deleteSelected(undoManager: mgr)
        }
        mgr.undo()
        #expect(state.regions[0]?.count == 2)
        #expect(state.regions[2]?.count == 1)
        #expect(state.lastUndoRedoPages == [0, 2])
    }
}
