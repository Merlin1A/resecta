import Foundation
import RedactionEngine

// The one undo helper every region mutation registers through, moved out
// of `RedactionState.swift` along its `// MARK: - Undo Helper` seam, with the
// record of each Undo or Redo step (its pages and name). The record's two
// stored properties stay on the class (an extension adds no storage).

extension RedactionState {

    /// An Undo or Redo step as the editor shows it.
    struct UndoRedoStep: Equatable {
        var pages: Set<Int>
        let name: String
        let serial: Int
    }

    /// The pages the last Undo or Redo step changed.
    var lastUndoRedoPages: Set<Int> { lastUndoRedo?.pages ?? [] }

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
                    target.recordUndoRedo(before: before, name: actionName)
                }
            }
            undoManager.setActionName(actionName)
        }
    }

    /// Records the step `name` names: the pages whose regions it changed.
    func recordUndoRedo(before: [Int: [RedactionRegion]], name: String) {
        let touched = Set(before.keys).union(regions.keys).filter { before[$0] != regions[$0] }
        if undoRedoStepOpen, var step = lastUndoRedo {
            step.pages.formUnion(touched)
            lastUndoRedo = step
        } else {
            lastUndoRedo = UndoRedoStep(pages: touched, name: name, serial: (lastUndoRedo?.serial ?? 0) + 1)
            undoRedoStepOpen = true
            Task { @MainActor [weak self] in self?.undoRedoStepOpen = false }
        }
    }
}
