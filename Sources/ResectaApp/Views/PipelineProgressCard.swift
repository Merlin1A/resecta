import SwiftUI

// §A4.2: Floating progress card — replaces PipelineProgressOverlay (§5.3).
// Handles .detecting, .redacting, .exporting phases with scrim + dimensioned card.
// .verifying is NOT handled here — VerificationProgressView owns that phase.
// §4.2: Uses .regularMaterial (not .glassEffect) for consistency with verification surfaces.

struct PipelineProgressCard: View {
    @Environment(DocumentState.self) private var documentState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Scrim — blocks interaction with document during processing
            Color.black.opacity(ResectaTokens.Opacity.scrim)
                .ignoresSafeArea()
                .allowsHitTesting(true) // Prevent taps reaching document

            // Floating card
            VStack(spacing: ResectaTokens.Spacing.md) {
                processingContent
            }
            .padding(ResectaTokens.Spacing.lg)
            .containerRelativeFrame(.horizontal) { length, _ in
                // WP8: Adaptive width — wider on iPad landscape
                if length > 700 { min(length * 0.5, 480) }
                else { min(length * 0.85, 320) }
            }
            .background(.regularMaterial, in: RoundedRectangle(
                cornerRadius: ResectaTokens.CornerRadius.sheet, style: .continuous))
            // Research Area 5: Uses .sheet (24pt) — scrim-backed floating overlay.
            // §4.2: .regularMaterial for consistency with verification content surfaces.
        }
    }

    // MARK: - Processing Content

    /// Reads phaseKind for routing and pipelineProgress for display numbers.
    /// Only pipelineProgress changes on progress ticks (self-transitions),
    /// so this view re-evaluates without invalidating the parent body.
    @ViewBuilder
    private var processingContent: some View {
        let progress = documentState.pipelineProgress
        switch documentState.phaseKind {
        case .detecting:
            VStack(spacing: ResectaTokens.Spacing.sm) {
                Text("Detecting\u{2026}")
                    .font(.headline)
                // FLOW-3 (Pkg N): only render the page-progress Text once
                // `pipelineProgress` has been populated. The card briefly
                // mounts before the first transition syncs progress, and
                // the previous `progress?.current ?? 0 / progress?.total ?? 0`
                // fallback flashed "Page 0 of 0" for one frame. Gating
                // on `progress != nil` keeps the spinner-only chrome
                // visible during that handoff window.
                if let progress {
                    Text("Page \(progress.current) of \(progress.total)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())

                    ProgressView(value: Double(progress.current),
                                 total: Double(max(progress.total, 1)))
                } else {
                    ProgressView()
                }
            }

        case .redacting:
            VStack(spacing: ResectaTokens.Spacing.sm) {
                Text(progress?.stepDescription ?? "Processing\u{2026}")
                    .font(.headline)
                // FLOW-3 (Pkg N): same gating as the .detecting branch
                // above — suppress the "Page 0 of 0" flash before the
                // first progress tick lands.
                if let progress {
                    Text("Page \(progress.current) of \(progress.total)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())

                    ProgressView(value: Double(progress.current),
                                 total: Double(max(progress.total, 1)))
                } else {
                    ProgressView()
                }
            }

        // .verifying is NOT handled by this card — it uses VerificationProgressView
        // (§4.3) for layer-by-layer trust communication. See §A4.5.

        case .exporting:
            VStack(spacing: ResectaTokens.Spacing.sm) {
                ProgressView()
                    .controlSize(.large)
                Text("Preparing for sharing\u{2026}")
                    .font(.headline)
            }

        default:
            ProgressView("Processing\u{2026}")
        }
    }
}
