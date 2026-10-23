import SwiftUI

// The KI-4 scene-phase lifecycle, moved out of `DocumentEditorView.swift`
// (the hub) along its `// MARK: - KI-4 Scene-phase observer` seam: the
// purge re-run toast's copy and gate, the re-run's state preamble, and the
// one handler that observes `\.scenePhase`. The statics stay on
// `DocumentEditorView` (ContentView and the tests read them there); the
// handler is a modifier the hub's `body` mounts, reading the same
// environment the hub does. See `KNOWN_ISSUES.md` KI-4.

extension DocumentEditorView {

    /// Toast copy for the KI-4 proactive purge re-run prompt. Mechanism-
    /// description: names what
    /// iOS did (reclaimed the temp file) and what the user can do (Re-run).
    static let purgeRerunToastMessage =
        "Pipeline output was reclaimed by iOS while the app was in the background. Tap Re-run to regenerate."

    /// Pure gate predicate for the KI-4 purge re-run toast. Returns `true`
    /// only when (a) the transition is `.background → .active`, (b) the
    /// editor is on `.verified(report)`, and (c) the output file is missing.
    /// Other transitions (`.inactive → .active` from the app switcher,
    /// `.background → .inactive` mid-resume, transitions into any non-
    /// verified phase) all return false. Static so the gate is testable
    /// without a SwiftUI host.
    static func shouldShowPurgeRerunToast(
        oldPhase: ScenePhase,
        newPhase: ScenePhase,
        documentPhase: DocumentState.Phase,
        outputFileExists: Bool
    ) -> Bool {
        guard oldPhase == .background, newPhase == .active else { return false }
        guard case .verified = documentPhase else { return false }
        return !outputFileExists
    }

    /// State preamble for the purge re-run action, extracted as a
    /// static so the transition is testable without a SwiftUI host (mirrors
    /// `shouldShowPurgeRerunToast`). The purge toast fires only from `.verified`,
    /// but `runFullPipeline` guards `canStartPipeline` which requires
    /// `.editing` — without this round-trip the "Re-run" button silently no-ops
    /// and strands the user (the output is gone and Share is disabled). The
    /// `verified -> editing` transition is legal.
    /// activeSearch is torn down first: the Search & Redact
    /// sheet mutates `redactionState.regions` and is incompatible with the
    /// `.redacting` / `.verifying` phases the re-run enters.
    @MainActor
    static func prepareForPurgeRerun(
        documentState: DocumentState,
        redactionState: RedactionState
    ) {
        redactionState.dismissActiveSearch()
        documentState.transition(to: .editing)
    }
}

/// The editor's scene-phase observer. Mounted once by
/// `DocumentEditorView.body`; owns the `.onChange(of: scenePhase)` that
/// fires the KI-4 purge re-run toast.
struct DocumentEditorScenePhaseHandler: ViewModifier {
    @Environment(DocumentState.self) private var documentState
    @Environment(RedactionState.self) private var redactionState
    @Environment(PipelineCoordinator.self) private var coordinator
    @Environment(ToastQueueManager.self) private var toastManager
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(old: oldPhase, new: newPhase)
        }
    }

    /// Fire the KI-4 purge re-run toast when the user returns to the
    /// foreground after iOS reclaimed the pipeline's temp output PDF.
    /// Defense-in-depth: the `canExport` Share-button disable + the
    /// `FailedStateView` Re-open Document Tier-2 surface remain in place.
    private func handleScenePhaseChange(old: ScenePhase, new: ScenePhase) {
        let outputPath = redactionState.outputURL?.path ?? ""
        let exists = FileManager.default.fileExists(atPath: outputPath)
        guard DocumentEditorView.shouldShowPurgeRerunToast(
            oldPhase: old,
            newPhase: new,
            documentPhase: documentState.phase,
            outputFileExists: exists
        ) else { return }
        let override = documentState.documentOverride
        toastManager.enqueue(
            DocumentEditorView.purgeRerunToastMessage,
            severity: .warning,
            actionLabel: "Re-run",
            actionHandler: {
                // Deferral pattern: ToastView's button
                // action calls this actionHandler() and then
                // `toastManager.dismiss(item)` — whose `withAnimation {
                // activeToasts.removeAll }` — synchronously in the same tap.
                // Mutating published state (the activeSearch teardown's
                // two-property didSet, the phase transition) inside that
                // animation transaction is the same re-entrancy class. Defer the
                // state preamble + pipeline kick-off one runloop turn so they
                // land after the dismiss animation; both are MainActor-isolated.
                Task { @MainActor in
                    // Tear down the search sheet and
                    // round-trip `verified -> editing` so runFullPipeline's
                    // canStartPipeline guard passes — the toast fires only from
                    // `.verified`, where the guard would otherwise reject and
                    // strand the user (gone output, disabled Share).
                    DocumentEditorView.prepareForPurgeRerun(
                        documentState: documentState,
                        redactionState: redactionState
                    )
                    coordinator.runFullPipeline(documentOverride: override)
                }
            }
        )
    }
}
