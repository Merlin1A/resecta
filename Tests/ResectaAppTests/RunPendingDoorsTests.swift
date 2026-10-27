import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// The run-entry window's doors. From the Redact tap the run holds its task
// while the phase still reads `.editing` (the run-entry capture, before
// `.redacting`). Every editor door reads one predicate for that window, so
// Search, Scan, the canvas, the iPhone bar and the keyboard lock from the
// tap, Stop is offered at once, and leaving the app pauses the run as it
// does once pages are processing.

@Suite("Run pending — the editor's doors", .tags(.coordination))
@MainActor
struct RunPendingDoorsTests {

    private static let otherPhases: [DocumentState.Phase] = [
        .empty,
        .importing,
        .detecting(progress: .init(currentPage: 0, totalPages: 1, currentStep: "s")),
        .redacting(progress: .init(currentPage: 0, totalPages: 1, currentStep: "s")),
        .verifying(progress: .init(currentLayer: 1, totalLayers: 1, layerName: "l", completedLayers: [])),
        .verified(report: .skipped),
        .exporting,
    ]

    /// The capture window, modelled as `RunEntryPendingRunGateTests` does:
    /// the run holds the task while the detached capture works.
    private func pendingRun(_ doc: DocumentState) {
        doc.phase = .editing
        doc.activeRunId = UUID()
        doc.activePipelineTask = Task<Void, Never> {
            while !Task.isCancelled { await Task.yield() }
        }
    }

    private func addRegion(to redaction: RedactionState) {
        redaction.addRegion(
            RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.05),
                            source: .manual),
            page: 0, undoManager: nil)
    }

    @Test("A run is pending only in `.editing` with a run task", .timeLimit(.minutes(1)))
    func pendingOnlyWhileEditingWithATask() async {
        let doc = DocumentState()
        doc.phase = .editing
        #expect(doc.isRunPending == false, "editing with no run")
        pendingRun(doc)
        #expect(doc.isRunPending == true, "editing with the run's task: the capture window")
        let task = doc.activePipelineTask
        for phase in Self.otherPhases {
            doc.phase = phase
            #expect(doc.isRunPending == false, "\(doc.phaseKind) is not the pending window")
        }
        task?.cancel()
        _ = await task?.value
    }

    @Test("The chrome shows the run from the tap, and region edits close", .timeLimit(.minutes(1)))
    func chromeAndEditsWhilePending() async {
        let doc = DocumentState()
        doc.phase = .editing
        #expect(doc.runChromePhaseKind == .editing)
        #expect(doc.regionEditsOpen == true)
        #expect(doc.canvasLocked == false)

        pendingRun(doc)
        #expect(doc.runChromePhaseKind == .redacting, "the pending run shows as processing")
        #expect(doc.regionEditsOpen == false, "the run owns the regions from the tap")
        #expect(doc.canvasLocked == true, "the canvas waits for the run")

        let task = doc.activePipelineTask
        for phase in Self.otherPhases {
            doc.phase = phase
            #expect(doc.runChromePhaseKind == doc.phaseKind, "outside the window the chrome reads the phase")
            #expect(doc.regionEditsOpen == doc.canMutateRegions)
        }
        task?.cancel()
        _ = await task?.value
    }

    @Test("Search and Scan are unavailable while a run is pending", .timeLimit(.minutes(1)))
    func searchEntriesWhilePending() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.phase = .editing
        #expect(DocumentEditorToolbar.searchEntriesDisabled(documentState: doc, redactionState: redaction) == false)

        redaction.activeSearch = SearchState()
        #expect(DocumentEditorToolbar.searchEntriesDisabled(documentState: doc, redactionState: redaction) == true,
                "one sheet at a time")
        redaction.activeSearch = nil

        pendingRun(doc)
        #expect(DocumentEditorToolbar.searchEntriesDisabled(documentState: doc, redactionState: redaction) == true,
                "a search opened in the capture window would edit regions the run is reading")
        doc.cancelActivePipeline(redactionState: redaction)
        #expect(DocumentEditorToolbar.searchEntriesDisabled(documentState: doc, redactionState: redaction) == false,
                "the doors reopen when the run ends")
    }

    @Test("Leaving the app while a run is pending pauses it and raises the paused banner", .timeLimit(.minutes(1)))
    func backgroundPausesAPendingRun() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        pendingRun(doc)
        let task = doc.activePipelineTask

        ContentView.cancelForBackground(documentState: doc, redactionState: redaction)

        #expect(doc.activePipelineTask == nil, "the run was cancelled")
        #expect(task?.isCancelled == true)
        #expect(doc.pausedFromPhase == .redacting, "the banner offers the full run again")
        #expect(doc.wasPausedByBackground == true)
        #expect(doc.phaseKind == .editing)
        task?.cancel()  // never left running when the pause did not cancel it
        _ = await task?.value
    }

    @Test("A real Redact tap: the doors lock at once, and leaving the app keeps the regions and pauses", .timeLimit(.minutes(1)))
    func realRunLocksFromTheTap() async throws {
        let coord = makeLoadedCoordinator()
        addRegion(to: coord.redactionState)
        let doc = coord.documentState

        coord.runFullPipeline(documentOverride: .secureRasterization)
        let task = try #require(doc.activePipelineTask, "the run started")
        // The launch holds the task synchronously; the run has not reached
        // `.redacting` yet.
        #expect(doc.phaseKind == .editing, "precondition: the run-entry window")
        #expect(doc.isRunPending)
        #expect(doc.runChromePhaseKind == .redacting)
        #expect(doc.canvasLocked)
        #expect(DocumentEditorToolbar.searchEntriesDisabled(
            documentState: doc, redactionState: coord.redactionState))

        ContentView.cancelForBackground(documentState: doc, redactionState: coord.redactionState)
        await task.value

        #expect(doc.pausedFromPhase == .redacting)
        #expect(doc.wasPausedByBackground)
        #expect(doc.phaseKind == .editing)
        #expect(coord.redactionState.outputURL == nil, "no copy was built")
        #expect(coord.redactionState.regions[0]?.count == 1, "the regions are untouched")
    }
}
