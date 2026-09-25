import SwiftUI
import RedactionEngine

// The editing-phase background-resume banner, moved out of
// `DocumentEditorView.swift` (the hub) along its `// InlineWarningBanner
// for background resume` seam: the overlay content and the pure
// resume-route pair (`ResumeAction` · `resumeAction(forPausedFrom:)`).
// The hub's `body` mounts `resumeBannerOverlay` in the same overlay slot
// it always held; the hub's `@State dismissBannerTask` and
// `documentOverride` stay stored on the hub (an extension adds no
// storage) and are read from here.

extension DocumentEditorView {

    // MARK: - Background-resume banner

    /// The banner the editor shows after a run was paused by a
    /// backgrounding (cancel-from-detecting / cancel-from-redacting):
    /// offers the pipeline matching the phase the user paused from and
    /// auto-dismisses after 8 s. Rendered only while editing.
    @ViewBuilder
    var resumeBannerOverlay: some View {
        if documentState.wasPausedByBackground,
           documentState.phaseKind == .editing {
            // Offer the pipeline matching the
            // phase the user paused from. A detect-pause resumes
            // detection at the recorded recognition level
            // (fallback .accurate); any other origin re-runs the
            // full pipeline (unchanged behavior).
            let resume = DocumentEditorView.resumeAction(
                forPausedFrom: documentState.pausedFromPhase)
            InlineWarningBanner(
                message: resume == .detect
                    ? "Detection was paused."
                    : "Processing was paused. Your drawn regions are preserved.",
                primaryAction: (
                    label: resume == .detect ? "Resume Detection" : "Restart",
                    action: {
                        dismissBannerTask?.cancel()
                        switch resume {
                        case .detect:
                            coordinator.runDetectionPipeline(
                                recognitionLevel: documentState.lastUsedRecognitionLevel ?? .accurate)
                        case .fullPipeline:
                            coordinator.runFullPipeline(documentOverride: documentOverride)
                        }
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
    }

    /// Which resume pipeline the editing-phase background-
    /// resume banner offers, derived from the phase the user paused from. A
    /// detect-pause resumes detection (partial detection results were discarded
    /// on cancel); any other origin (redact-pause, or unknown) re-runs the full
    /// redact pipeline. Static so the selection is testable without a SwiftUI host.
    enum ResumeAction: Equatable { case detect, fullPipeline }

    static func resumeAction(forPausedFrom phase: DocumentState.PhaseKind?) -> ResumeAction {
        phase == .detecting ? .detect : .fullPipeline
    }
}
