import SwiftUI
import RedactionEngine

// The detection-summary banner, moved out of `DocumentEditorView.swift`
// (the hub) along its `// MARK: - Detection Summary` seam: the overlay
// content, the run-record observer, the review re-entry path
// (`handleBannerReview` → `presentReviewInScanInterface`, which the hub's
// `pendingTriage` observer and the Home close path also call), the pure
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
                    // Review re-entry is additionally gated on the promotion
                    // flag: re-staging `detectionResults`
                    // after an apply would stage the already-promoted
                    // detections a second time.
                    showsReviewAction: banner.showsReview
                        && !redactionState.triagePromotionOccurred
                        && !redactionState.detectionResults.isEmpty,
                    onReview: handleBannerReview,
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
            // only fires for the DEBUG `--seedTriage` path, whose record
            // lands during launch — without it the seeded staged banner
            // never appears on the Simulator.
            if detectionBanner == nil, let record = redactionState.lastDetectionRun {
                handleDetectionRunChange(record)
            }
        }
    }

    /// Re-populate pendingTriage from stored detectionResults to
    /// re-open the review — now the search sheet's Scan interface, not
    /// the retired standalone triage sheet.
    private func handleBannerReview() {
        detectionBanner = nil
        // Block while a review is already pending (mirrors the
        // pipeline's own entry guard): re-staging would silently reset
        // the user's in-progress selections to the all-deselected
        // arrival default. The pending review is already on screen —
        // dismissing the banner is all this tap should do.
        guard redactionState.pendingTriage == nil else { return }
        guard !redactionState.triagePromotionOccurred,
              !redactionState.detectionResults.isEmpty else { return }
        redactionState.pendingTriage = redactionState.detectionResults
        // Review-first arrival: re-staged detections arrive
        // all-DESELECTED, like every arrival — an empty map, since the
        // one apply path reads an absent id as not accepted.
        redactionState.triageSelections = [:]
        // Deterministic presentation (the observer above also fires,
        // but a direct call doesn't depend on change delivery).
        presentReviewInScanInterface()
    }

    /// Open — or re-target — the one search sheet on its Scan
    /// interface so the staged detections render for review.
    func presentReviewInScanInterface() {
        // A review is a full-chrome activity: the sheet's detent
        // selection is sticky @State across sheet sessions, and a
        // stale compactFloat (~110 pt) would present the arrival with
        // the review list clipped out of sight. Never LOWER an
        // already-larger detent.
        if searchSheetDetent == .compactFloat {
            searchSheetDetent = .medium
        }
        if let state = redactionState.activeSearch {
            // Sheet already up: surface the review by re-targeting its
            // interface. This is a PROGRAMMATIC transition (no user
            // gesture), so it must not ride the user-transition path:
            // that path's undo toast offered to restore the cleared
            // session — and taking that restore during the pending
            // review buried the review behind the parked switcher (its
            // every entry point disables while detections are staged).
            // Instead the arrival owns the whole transition: cancel any
            // in-flight run (an orphaned task would keep streaming into
            // the review's interface and its completion tail would
            // record a false run outcome), clear the session state the
            // user-transition path would have cleared, and name the
            // drop with a plain notice — no restore affordance. The
            // touched tracker resets with it: the arriving review is a
            // fresh all-deselected selection context, and a Dismiss
            // confirmation about the just-cleared session's work would
            // reference selections the user can no longer see.
            if state.searchModeType != .piiScan {
                state.cancelSearchWithoutAwait()
                let dropped = SearchAndRedactSheet.unappliedMatchCount(in: state)
                if let message = Self.reviewArrivalClearedMessage(unappliedCount: dropped) {
                    toastManager.enqueue(message, severity: .info)
                }
                state.isProgrammaticModeChange = true
                state.searchModeType = .piiScan
                state.clearResults()
                state.piiCategoryFilter = nil
                state.sortOrder = .discoveryOrder
                state.userModifiedSelections = false
                // The arriving review is a fresh all-deselected
                // context; a stale unreviewed-preselect flag from the
                // cleared session must not carry into it.
                state.hasUnreviewedPreselection = false
            }
        } else {
            let state = SearchState()
            state.searchModeType = .piiScan
            // Deliberately NOT arming `pendingAutoRunScan`: a review
            // arrival presents staged detections; it never starts a run.
            redactionState.activeSearch = state
        }
    }

    /// Notice for the review-arrival re-target when the drop would
    /// otherwise be silent: the arriving review replaces a session that
    /// still held unapplied matches. Returns nil when nothing unapplied
    /// is lost so the common arrival stays toast-free. Deliberately
    /// carries no restore action — restoring the cleared session over a
    /// pending review would bury the review behind its parked entry
    /// points. Pinned by `InterfaceSwitchClearTests`.
    static func reviewArrivalClearedMessage(unappliedCount: Int) -> String? {
        guard unappliedCount > 0 else { return nil }
        let suffix = unappliedCount == 1 ? "" : "es"
        return "Detection review opened — \(unappliedCount) unapplied match\(suffix) cleared."
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
            pendingTriage: redactionState.pendingTriage,
            // Scan-interface runs disclose OCR skips through the
            // sheet's own per-page banner; the pipeline-side
            // skip count belongs to pipeline records only.
            ocrSkippedPageCount: record.scanSummary != nil
                ? 0 : redactionState.ocrPixelCapSkippedPages.count
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
        /// Whether this outcome supports Review re-entry at all. The view
        /// additionally gates the button on the live promotion flag and
        /// on `detectionResults` being present.
        let showsReview: Bool
        /// Success outcomes keep the 5 s auto-dismiss; zero/failed
        /// records persist until dismissed or the next run.
        let autoDismisses: Bool
        /// Warning icon for zero-with-skips / failed outcomes.
        let isWarning: Bool
    }

    /// Pure banner-model builder covering every `DetectionRunRecord`
    /// outcome, for both run origins. Pipeline-staged records derive
    /// their per-kind "Found …" summary from `pendingTriage`;
    /// Scan-interface records carry their counts in `scanSummary`
    /// (their results live in the sheet's list, not in triage). The
    /// former auto-applied case is retired with the auto-apply setting.
    static func detectionBannerModel(
        outcome: RedactionState.DetectionRunRecord.Outcome,
        scanSummary: RedactionState.DetectionRunRecord.ScanRunSummary?,
        pendingTriage: [Int: [DetectionResult]]?,
        ocrSkippedPageCount: Int
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
                    showsReview: false, autoDismisses: true, isWarning: false)
            }
            let pending = pendingTriage ?? [:]
            let flat = pending.values.flatMap { $0 }
            guard !flat.isEmpty else {
                // Staged record but triage already resolved by the time
                // the banner rebuilt (fast Apply) — generic re-entry copy.
                return DetectionBannerModel(
                    message: "Detection finished \u{2014} results were staged for review",
                    showsReview: true, autoDismisses: true, isWarning: false)
            }
            var counts: [String: Int] = [:]
            for det in flat {
                let label: String = switch det.kind {
                case .pii(let kind): kind.accessibilityName
                case .face: "face"
                case .searchMatch: "search match"
                }
                counts[label, default: 0] += 1
            }
            let pages = Set(pending.keys).count
            let parts = counts.sorted(by: { $0.value > $1.value })
                .prefix(3)
                .map { "\($0.value) \($0.key)\($0.value == 1 ? "" : "s")" }
            return DetectionBannerModel(
                message: "Found \(parts.joined(separator: ", ")) across \(pages) page\(pages == 1 ? "" : "s")",
                showsReview: true, autoDismisses: true, isWarning: false)

        case .nothingFound(let pageCount):
            var message = "Detection ran on \(pageCount) page\(pageCount == 1 ? "" : "s") and flagged no items."
            if ocrSkippedPageCount > 0 {
                // A zero-found run never opens the triage
                // sheet, so its OCR-skip banner can't carry this; the
                // coverage gap must be disclosed here instead.
                message += " \(ocrSkippedPageCount) page\(ocrSkippedPageCount == 1 ? " was" : "s were") too large to scan for text \u{2014} review \(ocrSkippedPageCount == 1 ? "it" : "them") manually."
            }
            return DetectionBannerModel(
                message: message,
                showsReview: false, autoDismisses: false,
                isWarning: ocrSkippedPageCount > 0)

        case .failed:
            return DetectionBannerModel(
                message: "Detection couldn't finish \u{2014} no regions were changed. Manual redaction tools remain available.",
                showsReview: false, autoDismisses: false, isWarning: true)
        }
    }
}

// MARK: - Detection Summary Banner

/// Inline banner recording how the last detection run ended:
/// found-and-staged, auto-applied, nothing found, or failed. The warning
/// variants swap the icon; layout and styling are shared.
private struct DetectionSummaryBanner: View {
    let model: DocumentEditorView.DetectionBannerModel
    let showsReviewAction: Bool
    let onReview: () -> Void
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
            // Review button re-opens triage sheet
            if showsReviewAction {
                Button("Review") {
                    onReview()
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.tint)
            }
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
