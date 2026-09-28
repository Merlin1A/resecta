import Testing
import Foundation
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// The run-entry window. A full run reads its region state — the burned
// `pages`, the sensitive-term set, the deselection snapshot and the
// re-check requests — while the phase is still `.editing` and the canvas
// live; the manual-term capture in that prefix suspends the run. The
// invariant pinned here: every one of those reads comes from ONE region
// state, with no suspension point between the read and the `.redacting`
// transition, so a region drawn while the capture is pending is burned
// (the capture re-runs once when the region version moved); a run whose
// burned version is not the live one leaves the stale flag standing; an
// import is refused and the Home/Done close cancels while a run is pending.

@Suite("Run entry — the pending-run gates", .tags(.coordination))
@MainActor
struct RunEntryPendingRunGateTests {

    @Test("An import is refused while a run is pending, in every phase that otherwise admits one")
    func importRefusedWhileRunPending() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.phase = .editing
        #expect(doc.canStartImport == true, "precondition: editing with no run admits an import")
        #expect(doc.canStartImport(with: redaction) == true)

        let pending = Task<Void, Never> { await Task.yield() }
        doc.activePipelineTask = pending
        #expect(doc.canStartImport == false,
                "a run pending in `.editing` (the capture window) must refuse the drop and the pickers")
        #expect(doc.canStartImport(with: redaction) == false)

        doc.activePipelineTask = nil
        #expect(doc.canStartImport == true, "the gate reopens when the run ends")
        _ = await pending.value
    }

    @Test("The phase-only refusal keeps its own answer: a pending run never widens the phase set that admits an import")
    func pendingRunNeverAdmitsABlockedPhase() async {
        let doc = DocumentState()
        let pending = Task<Void, Never> { await Task.yield() }
        for phase in [DocumentState.Phase.importing,
                      .redacting(progress: .init(currentPage: 0, totalPages: 1, currentStep: "s")),
                      .verifying(progress: .init(currentLayer: 1, totalLayers: 1, layerName: "l", completedLayers: [])),
                      .exporting] {
            doc.phase = phase
            doc.activePipelineTask = pending
            #expect(doc.canStartImport == false)
            doc.activePipelineTask = nil
            #expect(doc.canStartImport == false)
        }
        _ = await pending.value
    }

    @Test("Cancelling from `.editing` ends the pending run and leaves the session closable")
    func cancelFromEditingEndsThePendingRun() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.phase = .editing
        let started = UUID()
        doc.activeRunId = started
        doc.activePipelineTask = Task<Void, Never> {
            // The capture window: the run holds the task while the
            // detached capture works; nothing else moves.
            while !Task.isCancelled { await Task.yield() }
        }

        doc.cancelActivePipeline(redactionState: redaction)

        #expect(doc.activePipelineTask == nil)
        #expect(doc.phaseKind == .editing, "no phase to recover from — the run never left `.editing`")
        #expect(doc.transition(to: .empty), "the close that follows is a legal transition")
    }

    @Test("Source pin: the Done/Home teardown cancels a pending run before it clears the session")
    func doneCloseCancelsBeforeClearing() throws {
        let source = try loadRepoFile("Sources/ResectaApp/Views/DocumentEditorView+Home.swift")
        let body = try #require(source.range(of: "func performDoneCloseSession() {"))
        let tail = source[body.upperBound...]
        let cancel = tail.range(of: "documentState.cancelActivePipeline(redactionState: redactionState)")
        let clear = try #require(tail.range(of: "redactionState.clearAll()"))
        #expect(cancel != nil, "the teardown must cancel a run pending in the capture window")
        if let cancel {
            #expect(cancel.lowerBound < clear.lowerBound,
                    "cancel first, then clear — the order `RedactWorkspace.tearDown()` keeps")
        }
    }

    @Test("Source pin: the full run captures the term set before it snapshots the pages")
    func captureRunsBeforeThePagesSnapshot() throws {
        let source = try loadRepoFile("Sources/ResectaApp/State/PipelineRunner.swift")
        let entry = try #require(source.range(of: "private func runFull("))
        let run = source[entry.upperBound...]
        let capture = try #require(run.range(of: "collectSensitiveTermSet"))
        let pages = try #require(run.range(of: "buildPDFPageData("))
        #expect(capture.lowerBound < pages.lowerBound,
                "the awaited capture must precede the synchronous region snapshot")
    }
}

// MARK: - Repo file loader (the house source-pin helper)

@MainActor
private func loadRepoFile(
    _ relativePath: String, from file: StaticString = #filePath
) throws -> String {
    let repoRoot = URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent()   // Tests/ResectaAppTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // <repo root>
    return try String(
        contentsOf: repoRoot.appendingPathComponent(relativePath),
        encoding: .utf8)
}
