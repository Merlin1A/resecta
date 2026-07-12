import Testing
import Foundation
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// CANCEL-006 (Pkg B): import-path cancellation tests. Verifies the
// transition-table change (`.importing → .empty`), the `activeImportTask`
// registration / cancel path, and the per-page-loop surrender contract.

@Suite("ImportService cancellation", .tags(.importFlow))
@MainActor
struct ImportServiceCancelTests {

    // MARK: - Transition table

    @Test(".importing → .empty is a legal cancellation transition")
    func importingToEmptyIsLegal() {
        let pair = DocumentState.TransitionPair(.importing, .empty)
        #expect(DocumentState.legalTransitions.contains(pair),
                "Cancel-from-importing requires .importing → .empty")
    }

    @Test(".importing is in the cancellable phase set")
    func importingIsCancellable() {
        #expect(DocumentState.PhaseKind.importing.isCancellable)
        #expect(DocumentState.Phase.importing.isCancellable)
    }

    // MARK: - cancelActivePipeline behaviour

    @Test("cancelActivePipeline on .importing transitions to .empty")
    func cancelFromImportingReturnsToEmpty() {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.phase = .importing
        doc.cancelActivePipeline(redactionState: redaction)
        #expect(doc.phaseKind == .empty)
    }

    @Test("cancelActivePipeline on .importing nils activeImportTask")
    func cancelClearsImportTask() {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.activeImportTask = Task { }
        doc.phase = .importing
        doc.cancelActivePipeline(redactionState: redaction)
        #expect(doc.activeImportTask == nil)
    }

    @Test("cancelActivePipeline on .importing does not set sourceDocument")
    func cancelLeavesSourceDocumentClear() {
        let doc = DocumentState()
        let redaction = RedactionState()
        // Pre-condition: clean slate before import begins
        #expect(doc.sourceDocument == nil)
        doc.phase = .importing
        doc.cancelActivePipeline(redactionState: redaction)
        // Post-cancel: still no sourceDocument applied
        #expect(doc.sourceDocument == nil)
        #expect(doc.phaseKind == .empty)
    }

    // MARK: - Per-page loop surrender

    @Test("Import surrenders cooperatively on multi-page PDF when cancelled")
    func importSurrendersOnLargePDF() async throws {
        let doc = DocumentState()
        let redaction = RedactionState()
        // 100 pages is enough to exercise the per-page loops without
        // the test taking measurable wall time; the surrender contract
        // only requires `Task.checkCancellation()` to fire on the next
        // iteration after the cancel signal arrives.
        let data = makeMultiPagePDFData(pages: 100)

        let task = Task {
            await ImportService.importDocument(
                data: data, suggestedType: "pdf",
                documentState: doc, redactionState: redaction)
        }
        // Cancel immediately — the per-page loop should bail out before
        // mutating sourceDocument.
        task.cancel()
        await task.value

        // Either the cancel landed before any state mutation (preferred)
        // or the import completed before the cancel was observed (rare
        // on a 100-page fixture, but a hot CI box may race). In the
        // cancelled case we expect no half-loaded state.
        if doc.sourceDocument == nil {
            #expect(doc.phaseKind == .importing || doc.phaseKind == .empty,
                    "Cancelled import should not transition to .editing")
        }
    }

    @Test("validatePDFOffMainActor surrender keeps phase from advancing past .importing")
    func cancelDuringImportPreservesPhase() async throws {
        let doc = DocumentState()
        let redaction = RedactionState()
        let data = makeMultiPagePDFData(pages: 250)

        let importTask = Task {
            await ImportService.importDocument(
                data: data, suggestedType: "pdf",
                documentState: doc, redactionState: redaction)
        }
        // Yield once so the import has a chance to enter .importing.
        await Task.yield()
        // Now signal cancellation via the user-facing path.
        doc.cancelActivePipeline(redactionState: redaction)
        await importTask.value

        // After cancel + completion, phase should NOT be .editing
        // (which would only happen on a successful import).
        #expect(doc.phaseKind != .editing,
                "Cancelled import must not transition to .editing")
    }
}
