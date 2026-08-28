import SwiftUI

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
        // Bottom toasts (info, success) — above page navigation bar
        // Container animation routed through `Anim.resolved` so
        // the slide-in spring crossfades to the opacity-only
        // fallback when Reduce Motion is on. Full enum path is spelled
        // out because `.toastIn` shorthand cannot infer through
        // `Anim.resolved`'s `Animation` parameter.
        .overlay(alignment: .bottom) {
            VStack(spacing: ResectaTokens.Spacing.sm) {
                ForEach(toastManager.activeBottomToasts) { item in
                    ToastView(item: item, toastManager: toastManager)
                        // Routed through the resolver so Reduce Motion
                        // swaps the slide for an opacity-only crossfade.
                        .transition(ResectaTokens.Anim.resolvedTransition(
                            standard: .asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ),
                            reduceMotion: reduceMotion))
                        .onTapGesture { toastManager.dismiss(item) }
                }
            }
            // Clear page nav bar — and the Search/Scan sheet parked at
            // the compact float (`bottomClearance`).
            .padding(.bottom, ResectaTokens.Spacing.xl + toastManager.bottomClearance)
            .animation(
                ResectaTokens.Anim.resolved(ResectaTokens.Anim.toastIn, reduceMotion: reduceMotion),
                value: toastManager.toastVersion
            )
        }
        // Top toasts (warning, error) — below the navigation bar
        // See bottom-overlay comment above; same Reduce-Motion
        // routing applies to the top toast stack.
        .overlay(alignment: .top) {
            VStack(spacing: ResectaTokens.Spacing.sm) {
                ForEach(toastManager.activeTopToasts) { item in
                    ToastView(item: item, toastManager: toastManager)
                        // Routed through the resolver so Reduce Motion
                        // swaps the slide for an opacity-only crossfade.
                        .transition(ResectaTokens.Anim.resolvedTransition(
                            standard: .asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            ),
                            reduceMotion: reduceMotion))
                        .onTapGesture { toastManager.dismiss(item) }
                }
            }
            .padding(.top, ResectaTokens.Spacing.xl) // Clear toolbar
            .animation(
                ResectaTokens.Anim.resolved(ResectaTokens.Anim.toastIn, reduceMotion: reduceMotion),
                value: toastManager.toastVersion
            )
        }
        // Cancel pipeline on .background.
        // wasPausedByBackground stays true — user dismisses via InlineWarningBanner.
        // The .inactive/.active obscure-and-reveal flip lives at the
        // WindowGroup root (see ResectaApp.swift). This handler only owns
        // the cancellation side effect.
        .onChange(of: scenePhase) { _, newPhase in
            // Reach into active workspace for pipeline cancellation
            if newPhase == .background,
               case .redact(let ws) = appCoordinator.activeWorkspace,
               ws.documentState.phaseKind.isCancellable {
                // Capture the phase being cancelled BEFORE
                // cancelActivePipeline transitions to .editing, so the
                // editing-phase resume banner can offer the matching pipeline
                // (detect-only vs. full redact).
                ws.documentState.pausedFromPhase = ws.documentState.phaseKind
                ws.documentState.cancelActivePipeline(redactionState: ws.redactionState)
                ws.documentState.wasPausedByBackground = true
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
        .onChange(of: appCoordinator.activeWorkspace.kind) { _, _ in
            toastManager.clearAll()
        }
    }
}
