import SwiftUI
#if DEBUG
import RedactionEngine // the forced name-model failure below
#endif

// Workspace router and app-level concerns.
// Owns: toast manager, pipeline-cancel scene-phase handler.
// Delegates workspace-specific UI to HomeView and RedactWorkspaceView.
// Scene phase handling reaches into active workspace for pipeline cancellation.
// ToastQueueManager injected above the workspace switch for all workspaces.
//
// App-switcher snapshot obfuscation is owned by `ResectaApp` (the
// `WindowGroup` root) — see `SnapshotPrivacyOverlay.swift`. Lifting it out
// of `ContentView` is intended to cover the full window on iPad Stage
// Manager and split-view, where ContentView's layout would not span the
// whole scene. ContentView retains only the `.background`-triggered
// pipeline-cancel hook.

struct ContentView: View {
    @Environment(AppCoordinator.self) private var appCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Toast queue manager — injected into environment for child views
    @State private var toastManager = ToastQueueManager()

    var body: some View {
        Group {
            switch appCoordinator.activeWorkspace {
            case .home:
                HomeView()
            case .redact(let ws):
                RedactWorkspaceView(workspace: ws)
            }
        }
        // Cross-dissolve on workspace switch.
        // Folded the hand-rolled reduceMotion ternary
        // into `Anim.resolved` — the one canonical seam every
        // other animation site already routes through.
        .animation(
            ResectaTokens.Anim.resolved(.easeInOut(duration: 0.25), reduceMotion: reduceMotion),
            value: appCoordinator.activeWorkspace.kind
        )
        .environment(toastManager) // inject toast manager
        #if DEBUG
        // Sim-verification hook: `--showToast` posts a two-sentence
        // warning toast once the workspace is up, so the toast's line cap
        // can be photographed at accessibility sizes. `--showToast=<name>`
        // posts the message of that name in the message table instead
        // (`ResectaApp.toastHook(for:)`); a row with an action shows its
        // button, which does nothing here.
        .task {
            switch ResectaApp.toastHook(for: CommandLine.arguments) {
            case .absent:
                return
            case .stop(let reason):
                preconditionFailure(reason)
            case .bare:
                try? await Task.sleep(for: .seconds(2))
                toastManager.post(.outputReclaimed)
            case .named(let name):
                try? await Task.sleep(for: .seconds(2))
                toastManager.post(MessageID.example(named: name), action: {})
            }
        }
        // `--forceDetectionDegrade`: once the test document is in the
        // editor, the session records a scan kickoff whose name model
        // failed, through the function a real kickoff calls, and posts
        // the toast it returns; the Scan banner is then the app's own.
        // The flag is cleared only for a new document, so it holds for
        // the session.
        .task {
            guard CommandLine.arguments.contains("--forceDetectionDegrade") else { return }
            for _ in 0..<120 {
                if case .redact(let ws) = appCoordinator.activeWorkspace,
                   ws.documentState.phaseKind == .editing {
                    let diagnostics = GazetteerLoadDiagnostics(failedGazetteers: [
                        GazetteerLoadDiagnostics.Gazetteer.nerNameModel.rawValue,
                    ])
                    if ws.redactionState.noteScanKickoffDiagnostics(diagnostics) != nil {
                        toastManager.post(.detectionDegraded(failedGazetteers: diagnostics.failedGazetteers))
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            preconditionFailure("--forceDetectionDegrade: no document reached the editor; pass --loadTestDocument")
        }
        #endif
        // Brief messages at the workspace's root (Home, the editor, a run,
        // the results), at the place `MessagePlacement` gives; a presented
        // sheet draws its own. The editor's capture cover is inside this
        // host, so the editor's receipt stays drawn over it.
        .messageHost(toastManager, place: .root)
        .messageLayer(toastManager, role: .root)
        // Cancel pipeline on .background.
        // wasPausedByBackground stays true — user dismisses via InlineWarningBanner.
        // The .inactive/.active obscure-and-reveal flip lives at the
        // WindowGroup root (see ResectaApp.swift). This handler only owns
        // the cancellation side effect.
        .onChange(of: scenePhase) { _, newPhase in
            // Reach into active workspace for pipeline cancellation
            if newPhase == .background,
               case .redact(let ws) = appCoordinator.activeWorkspace {
                Self.cancelForBackground(documentState: ws.documentState, redactionState: ws.redactionState)
            }
            // Do NOT clear wasPausedByBackground on .active here.
            // The InlineWarningBanner in DocumentEditorView handles dismissal.
        }
        // Drain the toast queue on every workspace switch.
        // Workspace tear-down (AppCoordinator.tearDownCurrentWorkspace)
        // happens just before `activeWorkspace` flips, so by the time
        // this `.onChange` fires the old document context is gone — any
        // toasts still queued from the old workspace would carry stale
        // context into the new one (e.g., a Custom Terms cap toast
        // queued behind a long-running pipeline notice). `clearAll()`
        // cancels in-flight dismiss tasks and zeroes both queues plus
        // active toasts, so the new workspace starts with a clean slate.
        .onChange(of: appCoordinator.activeWorkspace.kind) { _, kind in
            toastManager.clearAll()
            // Home has no document phase; the editor's observer pushes the
            // phase again when a document opens.
            if kind == .home { toastManager.documentPhaseDidChange(to: nil) }
        }
    }

    /// The background rule: every cancellable phase is cancelled; only a
    /// run the editor can restart raises the paused banner, a cut Verify
    /// included (it returns to the editor rather than the skipped results).
    /// The phase is captured BEFORE the cancel transitions away, so the
    /// banner can offer the matching pipeline (detect-only vs. full redact).
    static func cancelForBackground(documentState: DocumentState, redactionState: RedactionState) {
        let kind = documentState.runChromePhaseKind
        guard kind.isCancellable else { return }
        if kind.raisesResumeBanner { documentState.pausedFromPhase = kind }
        documentState.cancelActivePipeline(redactionState: redactionState, cause: .background)
        if kind.raisesResumeBanner { documentState.wasPausedByBackground = true }
    }
}
