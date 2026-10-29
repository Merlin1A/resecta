import Testing
import Foundation
@testable import ResectaApp

// One Stop control for the whole run. Processing and verification showed
// two different buttons, so the toolbar swapped one for the other at the
// hand-off and a tap in flight reached neither. The control is now one
// button whose title comes from one static: the words stay, the button
// keeps its place.

@Suite("One Stop control for the run")
@MainActor
struct StopControlTests {

    @Test("Stop reads Processing while pages are processed and Verification while they are checked")
    func titlesPerPhase() {
        #expect(DocumentEditorToolbar.stopLabel(for: .detecting) == "Stop Processing")
        #expect(DocumentEditorToolbar.stopLabel(for: .redacting) == "Stop Processing")
        #expect(DocumentEditorToolbar.stopLabel(for: .verifying) == "Stop Verification")
        for kind in [DocumentState.PhaseKind.empty, .importing, .editing, .verified, .exporting, .failed] {
            #expect(DocumentEditorToolbar.stopLabel(for: kind) == nil, "\(kind) offers no Stop")
        }
    }

    @Test("A pending run offers Stop from the Redact tap", .timeLimit(.minutes(1)))
    func pendingRunOffersStop() async {
        let doc = DocumentState()
        doc.phase = .editing
        #expect(DocumentEditorToolbar.stopLabel(for: doc.runChromePhaseKind) == nil)
        let task = Task<Void, Never> { while !Task.isCancelled { await Task.yield() } }
        doc.activePipelineTask = task
        #expect(DocumentEditorToolbar.stopLabel(for: doc.runChromePhaseKind) == "Stop Processing")
        task.cancel()
        doc.activePipelineTask = nil
        _ = await task.value
    }
}
