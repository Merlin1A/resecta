import Testing
import Foundation
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// Import-path cancellation tests. Verifies the
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
    }

    // MARK: - cancelActivePipeline behaviour

    @Test("cancelActivePipeline on .importing with no open document transitions to .empty")
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

    @Test("Cancel during a drop import over an open document returns to that document")
    func cancelOverAnOpenDocumentReturnsToTheEditor() async throws {
        let doc = DocumentState()
        let redaction = RedactionState()
        let open = makeTestPDFDocument()
        doc.sourceDocument = open
        doc.phase = .editing
        let region = RedactionRegion(
            id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1), source: .manual)
        redaction.addRegion(region, page: 0, undoManager: nil)
        let data = makeMultiPagePDFData(pages: 250)

        let importTask = Task {
            await ImportService.importDocument(
                data: data, suggestedType: "pdf", door: .drop,
                documentState: doc, redactionState: redaction)
        }
        for _ in 0..<500 where doc.phaseKind != .importing {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(doc.phaseKind == .importing, "the drop import never started")
        doc.cancelActivePipeline(redactionState: redaction)
        await importTask.value

        #expect(doc.phaseKind == .editing)
        #expect(doc.sourceDocument === open)
        #expect(redaction.regions[0]?.map(\.id) == [region.id])
    }

    @Test("Leaving the app during an import cancels it without the paused banner")
    func backgroundDuringImportRaisesNoPause() {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.sourceDocument = makeTestPDFDocument()
        doc.phase = .importing
        ContentView.cancelForBackground(documentState: doc, redactionState: redaction)
        #expect(doc.phaseKind == .editing)
        #expect(doc.wasPausedByBackground == false)
        #expect(doc.pausedFromPhase == nil)
    }

    @Test("Leaving the app during a run still raises the paused banner")
    func backgroundDuringARunRaisesThePause() {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.sourceDocument = makeTestPDFDocument()
        doc.phase = .redacting(progress: .init(currentPage: 1, totalPages: 1, currentStep: "Page 1…"))
        ContentView.cancelForBackground(documentState: doc, redactionState: redaction)
        #expect(doc.phaseKind == .editing)
        #expect(doc.wasPausedByBackground)
        #expect(doc.pausedFromPhase == .redacting)
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

        // The race falls one of two ways and each way has a contract.
        // Cancel observed first (the usual outcome): no half-loaded state —
        // the document never received a source and the phase never reached
        // .editing. Import completed first (rare on a 100-page fixture; a hot
        // machine may race): the document is fully loaded — the source is
        // set with every page present and the phase is .editing.
        if doc.sourceDocument == nil {
            #expect(doc.phaseKind == .importing || doc.phaseKind == .empty,
                    "Cancelled import should not transition to .editing")
        } else {
            #expect(doc.sourceDocument?.pageCount == 100,
                    "A completed import carries every page of the fixture")
            #expect(doc.phaseKind == .editing,
                    "A completed import lands on .editing")
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
