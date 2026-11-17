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
    /// backgrounding (cancel-from-redacting or -verifying): offers the
    /// pipeline again.
    /// It is a record of a run that did not finish, so neither a timer nor
    /// its leaving the screen ends it: the pause ends when the banner is
    /// closed, when a full run starts (`runFullPipeline`, after its refusal
    /// check), or when the document is closed or replaced. Mounted by the
    /// top-banner slot, which shows it only while editing.
    @ViewBuilder
    var resumeBannerOverlay: some View {
        InlineWarningBanner(
            message: "Processing was paused. Your drawn regions are preserved.",
            primaryAction: (
                label: "Restart",
                action: {
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
    }

    /// What the banner's close clears: the pause flag and the phase it was
    /// paused from, the same pair a full run's start clears. Left set, the
    /// banner shows again whenever the editor is in `.editing`. Static so
    /// the pin is testable without a SwiftUI host.
    static func clearBackgroundPause(_ documentState: DocumentState) {
        documentState.wasPausedByBackground = false
        documentState.pausedFromPhase = nil
    }
}
