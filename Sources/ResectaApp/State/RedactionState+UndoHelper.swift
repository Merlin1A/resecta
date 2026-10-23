import Foundation
import RedactionEngine

// The one undo helper every region mutation registers through, moved out
// of `RedactionState.swift` along its `// MARK: - Undo Helper` seam, with the
// record of the pages each Undo or Redo step changed. The record's two
// stored properties stay on the class (an extension adds no storage).

extension RedactionState {

    /// Register an undoable action. Under the app target's SE-0466 MainActor
    /// default, `RedactionState` — and this method — are MainActor
    /// isolated, as is `UndoManager.registerUndo` on iOS 26. The `handler` is
    /// typed `@MainActor` because every handler body mutates MainActor region
    /// state and re-registers the inverse action; they already executed on
    /// MainActor via the `assumeIsolated` wrappers below, so the annotation
    /// makes the type system agree without changing runtime behavior. The inner
    /// `MainActor.assumeIsolated` still bridges the iOS-26
    /// `registerUndo(withTarget:)` callback (whose handler is not statically
    /// MainActor-typed).
    func registerUndo(
        _ undoManager: UndoManager?, _ actionName: String,
        handler: @escaping @MainActor (RedactionState) -> Void
    ) {
        guard let undoManager else { return }
        nonisolated(unsafe) let target = self
        MainActor.assumeIsolated {
            undoManager.registerUndo(withTarget: target) { target in
                MainActor.assumeIsolated {
                    let before = target.regions
                    handler(target)
                    target.recordUndoRedoPages(before: before)
                }
            }
            undoManager.setActionName(actionName)
        }
    }

    func recordUndoRedoPages(before: [Int: [RedactionRegion]]) {
        let touched = Set(before.keys).union(regions.keys).filter { before[$0] != regions[$0] }
        if undoRedoStepOpen {
            lastUndoRedoPages.formUnion(touched)
        } else {
            lastUndoRedoPages = touched
            undoRedoStepOpen = true
            Task { @MainActor [weak self] in self?.undoRedoStepOpen = false }
        }
    }
}
