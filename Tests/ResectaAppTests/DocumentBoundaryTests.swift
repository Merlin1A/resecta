import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import ResectaApp
import RedactionEngine

// The document boundary: a document dropped over an open one replaces it in
// the same window. The window's undo manager and toast queue outlive the
// document and the editor stays mounted, so the boundary clears both when
// the workspace sees the document swap (`RedactWorkspaceView.isDocumentSwap`
// → `PipelineCoordinator.documentDidChange()`), and the per-document mode
// override lives on the document's state, reset with it.

@Suite("Document boundary", .tags(.importFlow))
@MainActor
struct DocumentBoundaryTests {

    @Test("A document dropped over an open one starts with no undo history, no notices and the default mode")
    func dropOverAnOpenDocumentCrossesTheBoundary() async {
        let coord = makeLoadedCoordinator()
        let first = coord.documentState.sourceDocument
        let undo = UndoManager()
        undo.groupsByEvent = false
        coord.undoManager = undo
        let toasts = ToastQueueManager()
        coord.toastManager = toasts

        // A region added then deleted: Undo would bring it back into the
        // next document.
        let region = RedactionRegion(
            id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1), source: .manual)
        undo.beginUndoGrouping()
        coord.redactionState.addRegion(region, page: 0, undoManager: undo)
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        coord.redactionState.removeRegion(region.id, page: 0, undoManager: undo)
        undo.endUndoGrouping()
        #expect(undo.canUndo)
        toasts.enqueue("Region deleted", severity: .info, actionLabel: "Undo") { undo.undo() }
        toasts.enqueue("A notice about the first document", severity: .warning)
        #expect(!toasts.activeToasts.isEmpty)
        coord.documentState.documentOverride = .searchableRedaction

        let outcome = await ImportService.importDocument(
            data: makeMultiPagePDFData(pages: 2), door: .drop,
            documentState: coord.documentState, redactionState: coord.redactionState)
        guard outcome == .completed else {
            Issue.record("the drop import did not open: \(outcome)")
            return
        }
        let second = coord.documentState.sourceDocument
        #expect(second?.pageCount == 2)
        #expect(RedactWorkspaceView.isDocumentSwap(from: first, to: second))

        // What the workspace's document-swap observer runs.
        coord.documentDidChange()

        #expect(!undo.canUndo)
        #expect(toasts.activeToasts.isEmpty)
        let regionsLeft = coord.redactionState.regions.values.reduce(0) { $0 + $1.count }
        #expect(regionsLeft == 0)
        #expect(coord.documentState.documentOverride == nil)
        #expect(coord.documentState.phaseKind == .editing)
    }

    @Test("Start Over clears the mode override with the rest of the document")
    func startOverClearsTheModeOverride() {
        let coord = makeLoadedCoordinator()
        coord.documentState.documentOverride = .searchableRedaction
        coord.documentState.resetForStartOver(redactionState: coord.redactionState, coordinator: coord)
        #expect(coord.documentState.documentOverride == nil)
    }

    @Test("A drop on the results or error screen is refused with a notice")
    func dropOnResultsOrErrorIsRefusedWithANotice() {
        // The notice names the screen's own way back (its button's title).
        for (phase, wayBack): (DocumentState.Phase, String) in [
            (.verified(report: .skipped), "Keep Editing"),
            (.failed(error: .importError(.corrupt), returnPhase: .empty), "Choose Another File"),
        ] {
            let doc = DocumentState()
            doc.phase = phase
            #expect(doc.importRefusalMessage()
                    == "Cannot import from this screen. Tap \(wayBack) first.")
        }
        let editing = DocumentState()
        editing.phase = .editing
        #expect(editing.importRefusalMessage() == nil)
        editing.phase = .importing
        #expect(editing.importRefusalMessage() == DocumentState.importBlockedDuringPipelineMessage)
    }
}
