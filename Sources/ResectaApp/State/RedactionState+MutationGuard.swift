import Foundation

// Whether a registered region step, an undo or a redo, may run now. The
// steps are registered by `registerUndo` and run when the system's undo
// machinery asks: the toolbar's Undo, ⌘Z, the three-finger gesture. While
// a run owns the regions (pending from the Redact tap, then detecting,
// redacting or verifying) a step that ran would change the regions under
// the run and delete its registered output.

extension RedactionState {
    /// A region step may run: no document is wired (a bare state) or the
    /// editor's region edits are open (`DocumentState.regionEditsOpen`).
    var mayRunRegionStep: Bool {
        mutationGate?.regionEditsOpen ?? true
    }

    /// A step that arrived while a run owns the regions; the regions are
    /// left as they are. An undo goes back on the undo stack once the undo
    /// machinery returns: a step registered while it is undoing would land
    /// on the redo stack. `UndoManager` offers no way to put a step back on
    /// the redo stack, so a redo is dropped.
    func holdRefusedRegionStep(
        _ undoManager: UndoManager, _ actionName: String,
        handler: @escaping @MainActor (RedactionState) -> Void
    ) {
        guard undoManager.isUndoing else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            undoManager.beginUndoGrouping()
            self.registerUndo(undoManager, actionName, handler: handler)
            undoManager.endUndoGrouping()
        }
    }
}
