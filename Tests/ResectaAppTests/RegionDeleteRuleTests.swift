import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
import RedactionEngine

// One rule for deleting the selection, at every door: the selected regions
// go at once, as one undo step; when more than one went, a "Deleted N
// regions." notice offers Undo, which undoes that step only while nothing
// has changed the regions since; and a delete ends Add to Selection.

@MainActor
@Suite("Region delete rule")
struct RegionDeleteRuleTests {

    private static func state(selecting count: Int, of total: Int = 3) -> RedactionState {
        let state = RedactionState()
        var ids: [UUID] = []
        for i in 0..<total {
            let region = RedactionRegion(
                id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.1 + 0.1 * Double(i), width: 0.2, height: 0.04),
                source: .manual)
            state.addRegion(region, page: 0, undoManager: nil)
            ids.append(region.id)
        }
        state.selectedRegionIDs = Set(ids.prefix(count))
        return state
    }

    /// The delete as one event's undo group.
    private static func delete(
        _ state: RedactionState, _ undoManager: UndoManager, _ toasts: ToastQueueManager
    ) -> RegionDeleteRule.Outcome {
        undoManager.beginUndoGrouping()
        let outcome = RegionDeleteRule.deleteSelection(
            redactionState: state, undoManager: undoManager, toastManager: toasts)
        undoManager.endUndoGrouping()
        return outcome
    }

    private static func manager() -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return undoManager
    }

    @Test("Three selected go at once as one undo step, with one notice that offers Undo")
    func deletesWithANotice() throws {
        let state = Self.state(selecting: 3)
        let undoManager = Self.manager()
        let toasts = ToastQueueManager()
        let outcome = Self.delete(state, undoManager, toasts)
        #expect((state.regions[0] ?? []).isEmpty)
        #expect(undoManager.canUndo)
        #expect(outcome.deletedCount == 3)
        #expect(outcome.endsAddToSelection)
        let toast = try #require(toasts.activeToasts.first)
        #expect(toasts.activeToasts.count == 1)
        #expect(toast.message == "Deleted 3 regions.")
        #expect(toast.actionLabel == "Undo")
        #expect(toast.severity == .info)
        #expect(toast.editsRegions, "a run start drops the notice: the pipeline owns the regions")
        toast.actionHandler?()
        #expect(state.regions[0]?.count == 3, "the notice's Undo restores the three in one step")
    }

    @Test("A later change makes the old notice's Undo do nothing")
    func staleUndoDoesNothing() throws {
        let state = Self.state(selecting: 2)
        let undoManager = Self.manager()
        let toasts = ToastQueueManager()
        _ = Self.delete(state, undoManager, toasts)
        let toast = try #require(toasts.activeToasts.first)
        undoManager.beginUndoGrouping()
        state.addRegion(RedactionRegion(
            id: UUID(), normalizedRect: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1), source: .manual),
            page: 0, undoManager: undoManager)
        undoManager.endUndoGrouping()
        toast.actionHandler?()
        #expect(state.regions[0]?.count == 2, "the remaining region and the new one stay; nothing is undone")
    }

    @Test("One selected region is deleted with no notice; Add to Selection still ends")
    func oneRegionNoNotice() {
        let state = Self.state(selecting: 1)
        let toasts = ToastQueueManager()
        let outcome = Self.delete(state, Self.manager(), toasts)
        #expect(state.regions[0]?.count == 2)
        #expect(toasts.activeToasts.isEmpty)
        #expect(outcome.deletedCount == 1)
        #expect(outcome.endsAddToSelection)
    }

    @Test("Nothing selected: nothing happens")
    func nothingSelected() {
        let state = Self.state(selecting: 0)
        let toasts = ToastQueueManager()
        let outcome = Self.delete(state, Self.manager(), toasts)
        #expect(state.regions[0]?.count == 3)
        #expect(toasts.activeToasts.isEmpty)
        #expect(!outcome.endsAddToSelection)
    }
}
