import SwiftUI
import RedactionEngine

// The detection-summary banner, moved out of `DocumentEditorView.swift`
// (the hub) along its `// MARK: - Detection Summary` seam: the overlay
// content, the run-record observer, the pure
// banner model + its builder, and the private banner view. The hub's
// `@State detectionBanner` / `dismissSummaryTask` / `searchSheetDetent`
// stay stored on the hub (an extension adds no storage) and are read
// from here.

extension DocumentEditorView {
    // MARK: - Detection Summary

    /// Banner overlay, extracted from `body` (the inline closure
    /// pushed the type-checker past its budget). The record observer
    /// lives on the always-installed `Group` — driven by the run record,
    /// not the .detecting → .editing phase edge, because a page-0
    /// bootstrap failure degrades without ever leaving .editing, so a
    /// phase-edge trigger missed the failed outcome entirely. `run`
    /// increments per record, so consecutive identical outcomes still
    /// fire the observer.
    var detectionBannerOverlay: some View {
        Group {
            if let banner = detectionBanner,
               documentState.phaseKind == .editing {
                DetectionSummaryBanner(
                    model: banner,
                    onDismiss: {
                        withAnimation { detectionBanner = nil }
                    }
                )
                // Routed
                // through the resolver so Reduce Motion swaps the slide
                // for an opacity-only crossfade.
                .transition(ResectaTokens.Anim.resolvedTransition(
                    standard: .move(edge: .top).combined(with: .opacity),
                    reduceMotion: reduceMotion))
                .padding(.top, ResectaTokens.Spacing.toolbarClearance)
            }
        }
        .onChange(of: redactionState.lastDetectionRun) { _, record in
            handleDetectionRunChange(record)
        }
        .onAppear {
            // Hydrate from a record written before this view mounted. In
            // production the editor is installed whenever a run finishes
            // (records are per-document and cleared on close), so this
            // only fires for a record written during launch.
            if detectionBanner == nil, let record = redactionState.lastDetectionRun {
                handleDetectionRunChange(record)
            }
        }
    }

    /// Rebuild the banner when a detection run records its
    /// outcome. Success outcomes keep the pre-existing 5 s auto-dismiss;
    /// zero/failed records stay until dismissed or the next run replaces
    /// them — a failure notice that vanishes on a timer is no record at all.
    private func handleDetectionRunChange(
        _ record: RedactionState.DetectionRunRecord?
    ) {
        dismissSummaryTask?.cancel()
        guard let record else {
            // Document closed / replaced — drop the stale banner.
            detectionBanner = nil
            return
        }
        let model = Self.detectionBannerModel(
            outcome: record.outcome,
            scanSummary: record.scanSummary,
        )
        withAnimation { detectionBanner = model }
        if model.autoDismisses {
            dismissSummaryTask = Task {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                withAnimation(ResectaTokens.Anim.overlayDismiss) {
                    detectionBanner = nil
                }
            }
        }
    }

    /// View model for the detection summary banner. One value per
    /// run outcome; pure data so `detectionBannerModel` is unit-testable
    /// without a SwiftUI host (`DetectionBannerModelTests`).
    struct DetectionBannerModel: Equatable {
        let message: String
        /// Success outcomes keep the 5 s auto-dismiss; zero/failed
        /// records persist until dismissed or the next run.
        let autoDismisses: Bool
        /// Warning icon for zero-with-skips / failed outcomes.
        let isWarning: Bool
    }

    /// Pure banner-model builder covering every `DetectionRunRecord`
    /// outcome. Scan-interface records carry their counts in
    /// `scanSummary` (their results live in the sheet's list).
    static func detectionBannerModel(
        outcome: RedactionState.DetectionRunRecord.Outcome,
        scanSummary: RedactionState.DetectionRunRecord.ScanRunSummary?
    ) -> DetectionBannerModel {
        switch outcome {
        case .staged:
            // Scan-interface run: counts come from the record itself.
            // No Review action — the results are (or were) on screen in
            // the sheet, and a dismissed sheet's results are cleared by
            // design (re-running the scan restores them).
            if let scanSummary {
                let n = scanSummary.foundCount
                let p = scanSummary.pageCount
                return DetectionBannerModel(
                    message: "Scan found \(n) item\(n == 1 ? "" : "s") across \(p) page\(p == 1 ? "" : "s")",
                    autoDismisses: true, isWarning: false)
            }
            return DetectionBannerModel(
                message: "Detection finished \u{2014} results were staged for review",
                autoDismisses: true, isWarning: false)

        case .nothingFound(let pageCount):
            return DetectionBannerModel(
                message: "Detection ran on \(pageCount) page\(pageCount == 1 ? "" : "s") and flagged no items.",
                autoDismisses: false, isWarning: false)

        case .failed:
            return DetectionBannerModel(
                message: "Detection couldn't finish \u{2014} no regions were changed. Manual redaction tools remain available.",
                autoDismisses: false, isWarning: true)
        }
    }
}

// MARK: - Detection Summary Banner

/// Inline banner recording how the last detection run ended:
/// found-and-staged, auto-applied, nothing found, or failed. The warning
/// variants swap the icon; layout and styling are shared.
private struct DetectionSummaryBanner: View {
    let model: DocumentEditorView.DetectionBannerModel
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: ResectaTokens.Spacing.sm) {
            // Non-warning icon follows the Scan entry point's glyph —
            // the banner is the run-outcome surface for detection runs
            // from either origin; the former sparkle glyph retired with
            // the Auto-Detect menu.
            Image(systemName: model.isWarning
                ? "exclamationmark.triangle.fill"
                : "doc.viewfinder")
                // The glyph tint now gates on the same
                // `isWarning` flag the symbol itself switches on: neutral
                // for routine outcomes (an unearned-alarm budget), warn
                // tint only when there is actually something to flag.
                .foregroundStyle(model.isWarning
                    ? ResectaTokens.SemanticColor.warningTint
                    : Color.secondary)
                .accessibilityHidden(true)
            Text(model.message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss", systemImage: "xmark") {
                onDismiss()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.sm)
        .background(.regularMaterial, in: RoundedRectangle(
            cornerRadius: ResectaTokens.CornerRadius.toast, style: .continuous))
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .accessibilityIdentifier("detectionSummaryBanner")
    }
}
