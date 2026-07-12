import Foundation

// Phase 0: Encapsulates per-document state for the Redact workspace.
// Owns DocumentState, RedactionState, and PipelineCoordinator.
// ARCH §4.2: These were previously app-level; now workspace-scoped.
// MainActor by SE-0466 default.

@Observable
final class RedactWorkspace {
    let documentState: DocumentState
    let redactionState: RedactionState
    let coordinator: PipelineCoordinator

    init(settingsState: SettingsState) {
        let doc = DocumentState()
        let red = RedactionState()
        // Hydrate the persisted triage priors at
        // workspace creation (document open). Hydration lives here — not
        // in RedactionState.init — so bare instances stay inert and
        // test isolation holds; tearDown() → clearAll() is the matching
        // save point.
        red.priors = RedactionState.loadPriors()
        self.documentState = doc
        self.redactionState = red
        self.coordinator = PipelineCoordinator(
            documentState: doc, redactionState: red, settingsState: settingsState
        )
    }

    // GAP §2.2 F2-11: tearDown ordering is critical.
    func tearDown() {
        // 1. Cancel pipeline FIRST (stop in-flight work)
        documentState.cancelActivePipeline(redactionState: redactionState)
        // 2. THEN clearAll (wipe PII; internally calls clearOutput first per F2-11)
        redactionState.clearAll()
        // 3. SEC-2: remove the per-session temp subdir AFTER clearOutput has
        //    deleted the redacted file (clearAll → clearOutput chain). The
        //    subdir removal sweeps any straggler files (intermediate recon_
        //    artifacts, mid-pipeline writes) in one shot.
        coordinator.tearDownTempDirectory()
    }
}
