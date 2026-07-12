import SwiftUI
import RedactionEngine

// UI_UX §4.3, C6, R1, R2, R3: Progressive reveal during verification.
// §A4b: Full-screen view — verification is a distinct workflow phase (D6).
// §4.3a: Intermediate colors prevent premature confidence anchoring.
// §4.3b: "In Progress" banner with .thickMaterial persists until all layers complete.
// Cancel is in the toolbar (§A3), not in this view.

struct VerificationProgressView: View {
    @Environment(DocumentState.self) private var documentState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Reads pipelineProgress for all display data. Only pipelineProgress changes
    /// on verification layer ticks, so this view re-evaluates independently of the
    /// parent DocumentEditorView body.
    var body: some View {
        let progress = documentState.pipelineProgress
        let completedLayers = progress?.completedLayers ?? []
        let totalLayers = progress?.total ?? 0
        let currentLayer = progress?.current ?? 0
        let layerName = progress?.stepDescription ?? ""
        let animationKey: String = completedLayers.enumerated().map { idx, layer in
            let statusKey: String
            switch layer.status {
            case .pass: statusKey = "p"
            case .warn(let msg): statusKey = "w:\(msg)"
            case .info(let msg): statusKey = "i:\(msg)"
            case .attention(let msg): statusKey = "a:\(msg)"
            case .fail(let msg): statusKey = "f:\(msg)"
            case .skipped: statusKey = "s"
            }
            return "\(idx):\(statusKey)"
        }.joined(separator: "|")

        ScrollView {
            VStack(spacing: ResectaTokens.Spacing.xl) {
                shieldHero

                // §4.3b: Persistent "Verification In Progress" banner — C6: .thickMaterial
                VStack(spacing: ResectaTokens.Spacing.xxs) {
                    Text("Verification In Progress")
                        .font(.headline)
                    // R2: .contentTransition(.numericText()) for smooth digit transitions
                    Text("\(completedLayers.count) of \(totalLayers) checks completed")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: ResectaTokens.CornerRadius.toast))
                .accessibilityIdentifier("verificationBanner")
                .frame(maxWidth: columnMaxWidth)

                VStack(spacing: ResectaTokens.Spacing.md) {
                    // Completed layers — intermediate colors (§4.3a)
                    ForEach(Array(completedLayers.enumerated()), id: \.offset) { index, layer in
                        LayerResultRow(
                            layer: layer,
                            layerIndex: index + 1,
                            isExpanded: false,
                            onTap: {},
                            useIntermediateColors: true,
                            isExpandable: false
                        )
                        .transition(reduceMotion
                                    ? .opacity
                                    : .asymmetric(
                                        insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .opacity
                                    ))
                        .accessibilityIdentifier("layerResult_\(index)")
                        .frame(maxWidth: columnMaxWidth)
                    }

                    // Currently running layer — spinner
                    if currentLayer <= totalLayers {
                        HStack(spacing: ResectaTokens.Spacing.sm) {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                                Text("Layer \(currentLayer): \(layerName)")
                                    .font(.subheadline.weight(.medium))
                                Text("Checking\u{2026}")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }
                        .padding(ResectaTokens.Spacing.sm)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ResectaTokens.CornerRadius.toast))
                        .frame(maxWidth: columnMaxWidth)
                    }

                    // R1: Phase 3E — Animated shimmer placeholders for remaining layers.
                    // Reduced motion: static .quaternary fill (no animation).
                    let remainingStart = completedLayers.count + 1
                    if remainingStart < totalLayers {
                        ForEach(remainingStart..<totalLayers, id: \.self) { _ in
                            VerificationShimmerRow(reduceMotion: reduceMotion)
                                .frame(maxWidth: columnMaxWidth)
                        }
                    }

                    // Phase 4: trust strip below the shimmers — verification is
                    // the only multi-second wait in the app, so the privacy
                    // reassurance fits the moment. Mirrors HomeView's strip
                    // exactly; reuses TrustItem + FlowLayout.
                    trustStrip
                }
            }
            .padding()
            .animation(ResectaTokens.Anim.modeTransition, value: animationKey)
        }
        .accessibilityIdentifier("verificationProgress")
    }

    // MARK: - Subviews

    // R3: shield stays `.secondary` / gray (not green — premature confidence
    // anchoring). Phase 4 bumps size from 40pt → 56pt for parity with
    // HomeView masthead; R3 constrains color, not size, so the bump is
    // spec-neutral. `.hierarchical` rendering picks up the secondary tint.
    // VoiceOver: hidden — the banner ("Verification In Progress" + count)
    // and the running-layer label already convey the same state.
    private var shieldHero: some View {
        VStack(spacing: ResectaTokens.Spacing.xs) {
            Image(systemName: "shield.fill")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            // Reduce-motion fallback for the "stalled" read of a large static
            // shield. Non-reduced-motion users get the banner's
            // .contentTransition(.numericText()) count instead.
            if reduceMotion {
                Text("Verifying\u{2026}")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, ResectaTokens.Spacing.xl)
    }

    private var trustStrip: some View {
        FlowLayout(spacing: ResectaTokens.Spacing.sm, alignment: .center) {
            TrustItem(label: "On-device")
            Text("·").foregroundStyle(.tertiary).font(.caption)
            TrustItem(label: "No tracking")
            Text("·").foregroundStyle(.tertiary).font(.caption)
            TrustItem(label: "Open source")
        }
        .frame(maxWidth: columnMaxWidth)
    }

    // MARK: - Layout helpers

    /// Mirrors `HomeView.columnMaxWidth` (HomeView.swift:77-81) and
    /// `VerificationResultsView.columnMaxWidth`. Lifted to a static helper
    /// so the gate is testable without a SwiftUI host (mirrors Session 1's
    /// `shouldAutoReturnHome` and Session 2's `shouldAutoExpand`).
    private var columnMaxWidth: CGFloat {
        Self.columnMaxWidth(for: horizontalSizeClass)
    }

    static func columnMaxWidth(
        for horizontalSizeClass: UserInterfaceSizeClass?
    ) -> CGFloat {
        horizontalSizeClass == .regular
            ? ResectaTokens.BrandedSurface.panelMaxWidthRegular
            : ResectaTokens.BrandedSurface.panelMaxWidthCompact
    }
}

// MARK: - Shimmer Placeholder Row (Phase 3E)

/// Animated shimmer row for not-yet-started verification layers.
/// Reduced motion: static fill with no animation.
private struct VerificationShimmerRow: View {
    let reduceMotion: Bool
    @State private var shimmerPhase: CGFloat = -1

    var body: some View {
        HStack(spacing: ResectaTokens.Spacing.sm) {
            Circle()
                .fill(.quaternary)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                shimmerBar(maxWidth: .infinity, height: 14)
                shimmerBar(maxWidth: 100, height: 10)
            }
            Spacer()
        }
        .padding(ResectaTokens.Spacing.sm)
        .background(.regularMaterial, in: RoundedRectangle(
            cornerRadius: ResectaTokens.CornerRadius.toast))
        .accessibilityLabel("Verification check pending")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(
                .linear(duration: 1.5)
                .repeatForever(autoreverses: false)
            ) {
                shimmerPhase = 1
            }
        }
    }

    @ViewBuilder
    private func shimmerBar(maxWidth: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: ResectaTokens.CornerRadius.small)
            .fill(.quaternary)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(height: height)
            .overlay {
                if !reduceMotion {
                    // 04-ux-ui-audit.md §1.3.c: `.primary` resolves to
                    // near-black in light mode and near-white in dark mode,
                    // so the shimmer band reads against `.quaternary` in
                    // both schemes (the prior `.white.opacity(0.15)` was
                    // invisible on light-gray placeholders).
                    LinearGradient(
                        colors: [.clear, .primary.opacity(0.10), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .offset(x: shimmerPhase * 200)
                }
            }
            .clipped()
    }
}
