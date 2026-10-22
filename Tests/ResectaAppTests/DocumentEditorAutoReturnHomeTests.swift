import Testing
import Foundation
import PDFKit
@testable import ResectaApp

// Phase 1 redesign — pin the `.empty`-case auto-return-home gate so the
// HomeView.openSampleDocument race mitigation can't silently regress.
// `shouldAutoReturnHome` returns true only when the editor is genuinely
// idle on `.empty` with no source document; the `sourceDocument == nil`
// half defends against a future bootstrap that mounts a document before
// flipping phase.

@Suite("Document editor auto-return-home gate (Phase 1)")
@MainActor
struct DocumentEditorAutoReturnHomeTests {

    @Test(".empty + nil source → returnHome fires")
    func emptyIdleReturnsHome() {
        #expect(
            DocumentEditorView.shouldAutoReturnHome(
                phaseKind: .empty,
                sourceDocument: nil
            ) == true
        )
    }

    @Test(".empty + bootstrapped Document → returnHome suppressed")
    func emptyWithDocumentDoesNotReturnHome() {
        let doc = makeTestPDFDocument()
        #expect(
            DocumentEditorView.shouldAutoReturnHome(
                phaseKind: .empty,
                sourceDocument: doc
            ) == false
        )
    }

    @Test(".editing + nil source → returnHome suppressed")
    func editingIdleDoesNotReturnHome() {
        #expect(
            DocumentEditorView.shouldAutoReturnHome(
                phaseKind: .editing,
                sourceDocument: nil
            ) == false
        )
    }

    @Test(".editing + Document → returnHome suppressed")
    func editingWithDocumentDoesNotReturnHome() {
        let doc = makeTestPDFDocument()
        #expect(
            DocumentEditorView.shouldAutoReturnHome(
                phaseKind: .editing,
                sourceDocument: doc
            ) == false
        )
    }

    // MARK: - The return beat

    /// The `.empty` arm returns home after one yield — long enough to let
    /// a bootstrap's own `.importing` land first, short enough that no
    /// empty page shows on the way back.
    @Test("The auto-return awaits one yield, not a timed sleep")
    func autoReturnYieldsOnce() throws {
        let path = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ResectaApp/Views/DocumentEditorView.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        let arm = try #require(source.range(of: "case .empty:"))
        let gate = try #require(source.range(of: "shouldAutoReturnHome(", range: arm.upperBound..<source.endIndex))
        let body = String(source[arm.upperBound..<gate.lowerBound])
        #expect(body.contains("await Task.yield()"))
        #expect(!body.contains("milliseconds(150)"))
        #expect(!body.contains("Task.sleep"))
    }

    // MARK: - Window UndoManager cleared on editor close

    /// The per-window UndoManager outlives a closed document, so its stack must
    /// be emptied on close — otherwise the next document opened in the same
    /// window inherits stale Undo/Redo state and the prior RedactionState stays
    /// retained by the registration targets. The close path delegates to the
    /// `clearUndoStackOnClose` static; this pins that it empties a populated
    /// stack. groupsByEvent is disabled so the registration is observable
    /// without a run-loop tick.
    @Test("clearUndoStackOnClose empties a populated undo stack")
    func testOnDisappearClearsUndoStack() {
        final class UndoCanary { var tripped = false }
        let canary = UndoCanary()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: canary) { $0.tripped = true }
        undoManager.endUndoGrouping()
        #expect(undoManager.canUndo == true)   // precondition: a registration exists

        DocumentEditorView.clearUndoStackOnClose(undoManager)

        #expect(undoManager.canUndo == false)  // Stack emptied on close
        #expect(undoManager.canRedo == false)
    }
}
