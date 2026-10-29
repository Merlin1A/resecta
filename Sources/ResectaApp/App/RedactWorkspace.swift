import Foundation

// Phase 0: Encapsulates per-document state for the Redact workspace.
// Owns DocumentState, RedactionState, and PipelineCoordinator.
// These were previously app-level; now workspace-scoped.
// MainActor by SE-0466 default.

@Observable
final class RedactWorkspace {
    let documentState: DocumentState
    let redactionState: RedactionState
    let coordinator: PipelineCoordinator

    /// A locked document the import is holding while the password sheet is
    /// presented; nil otherwise. Set by the two doors on
    /// `ImportOutcome.needsPassword`, cleared by the sheet's outcome.
    var lockedImport: LockedImportHold?

    init(settingsState: SettingsState, userTermsStore: UserTermsStore) {
        let doc = DocumentState()
        let red = RedactionState()
        red.mutationGate = doc
        self.documentState = doc
        self.redactionState = red
        self.coordinator = PipelineCoordinator(
            documentState: doc, redactionState: red, settingsState: settingsState,
            userTermsStore: userTermsStore
        )
    }

    // tearDown ordering is critical.
    func tearDown() {
        // 1. Cancel pipeline FIRST (stop in-flight work)
        documentState.cancelActivePipeline(redactionState: redactionState)
        // 2. THEN clearAll (wipe PII; internally calls clearOutput first)
        redactionState.clearAll()
        // 2a. The source's password and any held locked import go with the
        //     document.
        documentState.documentPassword.wipe()
        lockedImport = nil
        // 3. Remove the per-session temp subdir AFTER clearOutput has
        //    deleted the redacted file (clearAll → clearOutput chain). The
        //    subdir removal sweeps any straggler files (intermediate recon_
        //    artifacts, mid-pipeline writes) in one shot.
        coordinator.tearDownTempDirectory()
    }
}
