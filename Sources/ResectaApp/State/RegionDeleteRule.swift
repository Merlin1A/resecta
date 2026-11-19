import Foundation

// What deleting the selection does, at every door — the … menu's Delete,
// ⌘⌫, and the canvas's long-press Delete N Regions. One responsibility.
// The selected regions go at once, as one undo step. When more than one
// went, a "Deleted N regions." notice offers Undo, which undoes that step
// only while the regions are as the delete left them (a later change makes
// the old notice's Undo do nothing). A delete ends Add to Selection: the
// outcome says so, and the editor's doors turn the mode off through its one
// reset.

enum RegionDeleteRule {

    struct Outcome: Equatable {
        let deletedCount: Int
        /// The pages the delete changed, for the canvas to redraw.
        let pages: Set<Int>
        /// Add to Selection ends after a delete.
        var endsAddToSelection: Bool { deletedCount > 0 }
    }

    static func deletedMessage(count: Int) -> String {
        "Deleted \(count) regions."
    }

    @MainActor
    @discardableResult
    static func deleteSelection(
        redactionState: RedactionState, undoManager: UndoManager?, toastManager: ToastQueueManager?
    ) -> Outcome {
        let count = redactionState.selectedRegionIDs.count
        guard count > 0 else { return Outcome(deletedCount: 0, pages: []) }
        let pages = redactionState.deleteSelected(undoManager: undoManager)
        if count > 1, let toastManager {
            let versionAfterDelete = redactionState.regionVersion
            // The guard: the regions are as the delete left them and the
            // step is still there to undo. A tap runs the Undo only while it
            // holds, and the queue ends the notice once it does not.
            toastManager.post(
                .deletedBoxes(count: count),
                action: { [weak undoManager] in undoManager?.undo() },
                stillValid: { [weak redactionState, weak undoManager] in
                    guard let redactionState, let undoManager else { return false }
                    return undoManager.canUndo && redactionState.regionVersion == versionAfterDelete
                })
        }
        return Outcome(deletedCount: count, pages: pages)
    }
}
