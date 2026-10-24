import SwiftUI
import RedactionEngine

// The editing-phase background-resume banner, moved out of
// `DocumentEditorView.swift` (the hub) along its `// InlineWarningBanner
// for background resume` seam: the overlay content.
// The editor's top-banner slot (`+TopBanner`) mounts `resumeBannerOverlay`
// when a paused run wins it; `documentOverride` forwards to the
// document's state (`+ModeOverride`) and is read from here.

extension DocumentEditorView {

    // MARK: - Background-resume banner

    /// The banner the editor shows after a run was paused by a
    /// backgrounding (cancel-from-redacting): offers the pipeline again.
    /// It is a record of a run that did not finish, so no timer ends it —
    /// it stays until it is dismissed, Restart is tapped, or another run
    /// starts (the banner leaves the screen with the editing phase, and
    /// the pause it reported is over). Mounted by the top-banner slot,
    /// which shows it only while editing.
    @ViewBuilder
    var resumeBannerOverlay: some View {
        InlineWarningBanner(
            message: "Processing was paused. Your drawn regions are preserved.",
            primaryAction: (
                label: "Restart",
                action: {
                    Self.clearBackgroundPause(documentState)
                    coordinator.runFullPipeline(documentOverride: documentOverride)
                }
            ),
            onDismiss: {
                Self.clearBackgroundPause(documentState)
            }
        )
        // Routed through the resolver so Reduce
        // Motion swaps the slide for an opacity-only
        // crossfade.
        .transition(ResectaTokens.Anim.resolvedTransition(
            standard: .move(edge: .top).combined(with: .opacity),
            reduceMotion: reduceMotion))
        .padding(.top, ResectaTokens.Spacing.toolbarClearance)
        // Leaving the screen ends the pause: a run started from the
        // toolbar instead of Restart supersedes the paused one, and a
        // closed document resets the pair anyway.
        .onDisappear {
            Self.clearBackgroundPause(documentState)
        }
    }

    /// What the banner's primary action clears before it launches the run
    /// it offers: the pause flag and the phase it was paused from — the
    /// same pair the dismiss path and the banner's leaving clear. Left
    /// set, the banner mounted again
    /// when the resumed run returned to `.editing`. Static so the pin is testable
    /// without a SwiftUI host.
    static func clearBackgroundPause(_ documentState: DocumentState) {
        documentState.wasPausedByBackground = false
        documentState.pausedFromPhase = nil
    }
}
