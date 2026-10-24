import SwiftUI
import RedactionEngine

// The editing-phase background-resume banner, moved out of
// `DocumentEditorView.swift` (the hub) along its `// InlineWarningBanner
// for background resume` seam: the overlay content.
// The editor's top-banner slot (`+TopBanner`) mounts `resumeBannerOverlay`
// when a paused run wins it; the hub's `@State dismissBannerTask` stays
// stored on the hub (an extension adds no storage) and `documentOverride`
// forwards to the document's state (`+ModeOverride`); both are read from
// here.

extension DocumentEditorView {

    // MARK: - Background-resume banner

    /// The banner the editor shows after a run was paused by a
    /// backgrounding (cancel-from-redacting): offers the pipeline and
    /// auto-dismisses after 8 s. Mounted by the top-banner slot, which
    /// shows it only while editing.
    @ViewBuilder
    var resumeBannerOverlay: some View {
        InlineWarningBanner(
            message: "Processing was paused. Your drawn regions are preserved.",
            primaryAction: (
                label: "Restart",
                action: {
                    dismissBannerTask?.cancel()
                    Self.clearBackgroundPause(documentState)
                    coordinator.runFullPipeline(documentOverride: documentOverride)
                }
            ),
            onDismiss: {
                dismissBannerTask?.cancel()
                documentState.wasPausedByBackground = false
                documentState.pausedFromPhase = nil
            }
        )
        // Routed through the resolver so Reduce
        // Motion swaps the slide for an opacity-only
        // crossfade.
        .transition(ResectaTokens.Anim.resolvedTransition(
            standard: .move(edge: .top).combined(with: .opacity),
            reduceMotion: reduceMotion))
        .padding(.top, ResectaTokens.Spacing.toolbarClearance)
        .onAppear {
            dismissBannerTask?.cancel()
            dismissBannerTask = Task { [weak documentState] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                withAnimation(ResectaTokens.Anim.overlayDismiss) {
                    documentState?.wasPausedByBackground = false
                    documentState?.pausedFromPhase = nil
                }
            }
        }
    }

    /// What the banner's primary action clears before it launches the run
    /// it offers: the pause flag and the phase it was paused from — the
    /// same pair the dismiss path and the Run Verification card clear
    /// (`handleRunVerificationTap`). Left set, the banner mounted again
    /// when the resumed run returned to `.editing`. Static so the pin is testable
    /// without a SwiftUI host.
    static func clearBackgroundPause(_ documentState: DocumentState) {
        documentState.wasPausedByBackground = false
        documentState.pausedFromPhase = nil
    }
}
