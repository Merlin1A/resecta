import SwiftUI
import RedactionEngine

// The verification results page, grouped: the system grouped background
// inside the results view's own NavigationStack (the nav bar stays the
// editor's), the masthead said once (the count ring, the row-word title,
// one sentence), the actions (Share as a capsule, the action rows, the
// undo footnote), the check sections with their counts, the headerless run
// section, the passed checks, the completion line and the legal text as
// the last section's footer, the trust line. A page link pushes the Preview
// at that page on this same stack. Action-bar and export dialogs are still
// mounted by DocumentEditorView.

struct VerificationResultsView: View {
    let report: VerificationReport
    /// Defense-in-depth gate, computed once on `DocumentEditorView`
    /// (Phase 3) and threaded into both the bar and this card so they share
    /// one source of truth.
    let canExport: Bool
    /// The two facts behind `canExport`, threaded separately so a disabled
    /// Share card can say WHY (`shareDisabledReason`). `canExport` itself
    /// stays a single boolean — its derivation is pinned on
    /// `DocumentEditorView.canExport(report:)`.
    let outputExists: Bool
    let isVerificationStale: Bool
    /// Preview is offered whenever a redacted output exists on disk, independent
    /// of pass/warn/info/fail and of userOverrodeFailure (decoupled from the
    /// former isFailPreOverride gate). Computed once on DocumentEditorView and
    /// threaded in like `canExport`, since this view does not inject RedactionState.
    let previewAvailable: Bool
    /// Tap handler for the Share capsule. Mirrors the bar's
    /// `onExport` so ⌘E reaches `handleExportTap(report:)` from either
    /// surface.
    var onExport: () -> Void
    /// Tap handler for the Run Verification card shown on skipped reports.
    /// The routing decision — verify-only against the
    /// existing output vs. a full re-run — lives on `DocumentEditorView`
    /// (`handleRunVerificationTap`), which owns the coordinator and
    /// `RedactionState`; this view stays decoupled like `onExport`.
    var onRunVerification: () -> Void
    /// Deselection facts captured at run entry
    /// (`RedactionState.LastRunInputs.deselection`), threaded in like
    /// `previewAvailable` since this view does not inject RedactionState.
    /// Nil (also the default, so fixture call sites stay source-compatible)
    /// or zero deselections renders no row.
    var deselectionSnapshot: RedactionState.DeselectionSnapshot? = nil
    /// Pre-derived run facts for the run-facts strip.
    /// This view injects no RedactionState (mirrors
    /// `deselectionSnapshot`/`previewAvailable`); `DocumentEditorView`
    /// builds this via the pure `RunFacts.derive(...)` static func.
    /// Defaults to the empty/false value, so the strip renders nothing
    /// when unthreaded (keeps any future fixture call site
    /// source-compatible).
    var runFacts: RunFacts = RunFacts()

    @Environment(DocumentState.self) private var documentState
    @Environment(RedactionState.self) private var redactionState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var previewPage: PreviewPage?
    /// The findings the checks cannot see (`ResultsFindings`), derived when
    /// the screen appears and again when the boxes change.
    @State private var findings: [ResultsFinding] = []

    /// A page the Preview opens at (0-based), pushed on this view's stack.
    struct PreviewPage: Hashable, Identifiable {
        let index: Int
        var id: Int { index }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        VerificationMasthead(report: report, outputExists: outputExists,
                                             mode: runFacts.runMode, findingCount: findings.count)
                        VerificationResultsActions(
                            report: report, canExport: canExport, outputExists: outputExists,
                            isVerificationStale: isVerificationStale, previewAvailable: previewAvailable,
                            onExport: onExport, onRunVerification: onRunVerification)
                            .padding(.top, ResectaTokens.Results.blockGap)
                        ResultsFindingsSection(
                            findings: findings, pagesOnChips: previewAvailable, onOpenPage: openPreview(at:))
                        VerificationDetailsSection(
                            report: report, deselectionSnapshot: deselectionSnapshot,
                            runFactsLines: runFactsLines, previewAvailable: previewAvailable,
                            onOpenPage: openPreview(at:))
                        footerBlock
                        trustStrip
                            .padding(.top, ResectaTokens.Spacing.xl)
                    }
                    .padding(.horizontal, ResectaTokens.Spacing.md)
                    .padding(.top, ResectaTokens.Spacing.lg)
                    .padding(.bottom, dynamicTypeSize.isAccessibilitySize
                        ? ResectaTokens.Spacing.lg : ResectaTokens.Spacing.xxl)
                    .frame(maxWidth: columnMaxWidth)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier("verificationResults")
            }
            .navigationDestination(item: $previewPage) { page in
                RedactedPreviewView(verdict: report.overallStatus, page: page.index)
            }
        }
        .task(id: redactionState.regionVersion) {
            findings = ResultsFindings.derive(documentState: documentState, redactionState: redactionState)
        }
        // VerificationActionBar is placed by the phase router in
        // DocumentEditorView as .safeAreaInset, not embedded here. Export
        // dialogs are also mounted on DocumentEditorView.
    }

    /// A page link: push the Preview at that page. A page past the
    /// document's end (a seeded report's pages on a short sample) is
    /// dropped; no phase changes.
    private func openPreview(at page: Int) {
        guard previewAvailable, Self.isPageInDocument(page, pageCount: documentState.pageCount) else { return }
        previewPage = PreviewPage(index: page)
    }

    /// Whether a 0-based page exists in a document of `pageCount` pages; an
    /// unknown count (0) admits every page.
    static func isPageInDocument(_ page: Int, pageCount: Int) -> Bool {
        page >= 0 && (pageCount == 0 || page < pageCount)
    }

    // MARK: - Layout helpers

    /// Mirrors `HomeView.columnMaxWidth` (HomeView.swift:77-81).
    private var columnMaxWidth: CGFloat {
        horizontalSizeClass == .regular
            ? ResectaTokens.BrandedSurface.panelMaxWidthRegular
            : ResectaTokens.BrandedSurface.panelMaxWidthCompact
    }

    /// The page's run breakdown — the check sections and the completion
    /// line — describes a run's layer results. On the skipped sentinel
    /// (`layers.isEmpty`) there is no run to describe. One gate for both.
    /// Static so it's unit-testable without a SwiftUI host.
    static func shouldShowRunBreakdown(report: VerificationReport) -> Bool {
        !report.layers.isEmpty
    }

    // MARK: - Run facts strip
    //
    // 0-2 conditional lines stating what this run's detection did not
    // cover, the first rows of the headerless run section, on every
    // verdict — a routine PASS with nothing to state renders none. Every line
    // is a pinned static builder so the rendered text is unit-testable
    // without a SwiftUI host. Whether the detectors ran on the output is
    // no longer stated here in prose: the verification ledger measures it.

    /// Pure facts input for the strip. `derive` is the single production
    /// source (called from `DocumentEditorView`); the plain-value
    /// default keeps every field off.
    struct RunFacts: Equatable {
        /// 0-indexed pages whose raster exceeded the OCR pixel
        /// caps during the run behind this output.
        var ocrSkippedPages: Set<Int> = []
        /// The degrade-failure list at the run behind this output's
        /// entry; nil when that run was not degraded.
        var degradeFailures: [String]? = nil
        /// The run's mode, for the SKIPPED sentences.
        var runMode: RunMode = .searchableOrUnknown

        /// Pure derivation from the run's own retained inputs — the two
        /// facts are read at run entry and recorded with the output, so
        /// a later scan not followed by another Redact cannot move what
        /// this strip says about the on-screen report.
        static func derive(inputs: RedactionState.LastRunInputs?) -> RunFacts {
            RunFacts(
                ocrSkippedPages: inputs?.ocrSkippedPages ?? [],
                degradeFailures: inputs?.degradeFailures,
                runMode: RunMode.of(perPageModes: inputs?.perPageModes ?? [],
                                    fallbackReasons: inputs?.perPageFallbackReasons ?? [])
            )
        }
    }

    /// Pinned line builders + line-order assembly.
    enum RunFactsStrip {
        /// 0-indexed input; 1-based page
        /// numbers via `SearchResultsSection.formatPageList`.
        static func ocrSkipLine(pages: [Int]) -> String {
            let oneBased = pages.sorted().map { $0 + 1 }
            let list = SearchResultsSection.formatPageList(oneBased)
            if oneBased.count == 1 {
                return "Page \(list) was too large to scan for text, so its image content was not examined by detection. Review that page manually before sharing."
            }
            return "Pages \(list) were too large to scan for text, so image content there was not examined by detection. Review those pages manually before sharing."
        }

        /// Reuses `DetectionDegradeCopy.banner` verbatim; no new
        /// degrade string.
        static func degradeLine(failedGazetteers: [String]) -> String {
            DetectionDegradeCopy.banner(failedGazetteers: failedGazetteers)
        }

        /// Ordered lines for the given facts: the OCR-skip line, then
        /// the degrade line.
        static func lines(for facts: RunFacts) -> [String] {
            var result: [String] = []
            if !facts.ocrSkippedPages.isEmpty {
                result.append(ocrSkipLine(pages: Array(facts.ocrSkippedPages)))
            }
            if let degradeFailures = facts.degradeFailures {
                result.append(degradeLine(failedGazetteers: degradeFailures))
            }
            return result
        }
    }

    private var runFactsLines: [String] { RunFactsStrip.lines(for: runFacts) }

    // MARK: - The actions' rules and words (the view is VerificationResultsActions)

    /// Card visibility — skipped reports only. Static so the mount condition
    /// is unit-testable without a SwiftUI host (mirrors `shouldShowRunBreakdown`).
    static func shouldShowRunVerificationCard(report: VerificationReport) -> Bool {
        report.overallStatus.isSkipped
    }

    /// Body copy for the Run Verification card — one body for every skip
    /// reason; the masthead sentence carries the reason.
    static let runVerificationCardBodyText =
        "Run the checks on the redacted PDF before you share it."

    /// VoiceOver label for the Share card. Promoted to a `static` constant
    /// so the rebuild can't silently alter the spoken string and so it's
    /// unit-testable without rendering (mirrors the accessibility label
    /// contract in `AccessibilityLabelTests`).
    static let shareCardAccessibilityLabel =
        "Share Document. Save the redacted PDF or share it from this device."

    /// VoiceOver label for the Preview card.
    static let previewCardAccessibilityLabel =
        "Preview Redacted Document. \(previewCardBodyText)"

    /// Body copy for the Preview card.
    static let previewCardBodyText = "Open the redacted PDF in a read-only viewer."

    /// Defense-in-depth gate for the Share card: Share is enabled
    /// exactly when a fresh, valid output exists (`canExport`). Lifted to a
    /// `static` helper so the gate is a single source of truth and is
    /// unit-testable without a SwiftUI host (mirrors `shouldShowRunBreakdown`).
    /// Simplified to a single `canExport` input — the WARN confirmation and
    /// FAIL override gates were removed. Do not invert or inline.
    static func shareDisabled(canExport: Bool) -> Bool { !canExport }

    /// Explanation for a disabled Share card — nil exactly when Share is
    /// enabled. Takes the same two facts `DocumentEditorView.canExport(report:)`
    /// derives its boolean from, so the caption and the gate cannot disagree.
    /// A missing output file wins over staleness: the stale copy presumes an
    /// output exists to be stale against. Static so the (exists, stale) →
    /// copy mapping is unit-testable without a SwiftUI host.
    static func shareDisabledReason(outputExists: Bool, isStale: Bool) -> String? {
        // The second sentence holds together, so a line breaks between
        // the two sentences.
        let step = "Run\u{00A0}Redact\u{00A0}again\u{00A0}to\u{00A0}share."
        if !outputExists {
            return "The redacted PDF is no longer available. \(step)"
        }
        if isStale {
            return "Regions changed after this PDF was made. \(step)"
        }
        return nil
    }

    /// The undo footnote under the actions, on every run.
    static let undoFootnote = "Redact cleared undo; use Delete\u{00A0}Region instead."

    /// Red-tints the Share tile on ANY verification FAIL verdict. Keyed on the
    /// status verdict ALONE — independent of userOverrodeFailure — so the tint
    /// does NOT flip as a side effect of the "Share Anyway" override / share
    /// round-trip (DocumentEditorView.swift:1408-1411). Static so it is a single
    /// source of truth and unit-testable without a SwiftUI host.
    static func shouldTintShareRed(report: VerificationReport) -> Bool {
        report.overallStatus.isFail
    }

    /// The Share-card caption for a source that was encrypted. Static so the
    /// copy is pinned without a SwiftUI host.
    static func notProtectedCaption(hadRestrictions: Bool) -> String {
        hadRestrictions
            ? "The redacted copy is not password-protected. It carries none of the original's usage restrictions."
            : "The redacted copy is not password-protected."
    }

    /// Keep Editing's spoken label: the action, then the undo boundary.
    static let keepEditingAccessibilityLabel =
        "Keep Editing. Return to the editor to adjust regions, then run Redact again. "
        + "Redact cleared undo; use Delete Region instead."

    // MARK: - Trust strip
    //
    // HomeView's words ("On-device · No tracking · Open source") as one
    // plain centred line, the page's last: standing facts about the app,
    // status-independent; the run's outcome lives in the masthead.

    private var trustStrip: some View {
        Text("On-device · No tracking · Open source")
            .font(.footnote)
            .foregroundStyle(ResectaTokens.SemanticColor.supportText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    /// The completion line, then the legal text as the last section's
    /// footer: 18 pt under the completion line; on SKIPPED, with no run to
    /// describe, 32 pt under the undo footnote.
    private var footerBlock: some View {
        VStack(alignment: .leading, spacing: ResectaTokens.Results.completionToLegal) {
            if Self.shouldShowRunBreakdown(report: report) {
                Text(Self.completionLineText(report: report))
                    .font(.footnote)
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
            }
            if Self.shouldShowHonestyDisclaimer(overallStatus: report.overallStatus) {
                honestyDisclaimer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.top, Self.shouldShowRunBreakdown(report: report)
            ? ResectaTokens.Spacing.xs + ResectaTokens.Spacing.xxs
            : ResectaTokens.Results.undoToLegalSkipped)
    }

    /// The completion line: the duration (the ring states the count), the
    /// minutes form from 60 s; the page-count gate's report, where no check
    /// completed, says where it stopped.
    static func completionLineText(report: VerificationReport) -> String {
        if isPageCountGateRun(report) { return "Stopped at the Page Count check." }
        guard report.durationSeconds > 0 else {
            return report.layers.count == 1 ? "1 check." : "\(report.layers.count) checks."
        }
        return "Completed in \(durationText(report.durationSeconds))."
    }

    /// "under 0.1 seconds" · "4.1 seconds" · "5 min 12 s" (whole seconds,
    /// never "60 s").
    static func durationText(_ seconds: Double) -> String {
        if seconds < 0.1 { return "under 0.1 seconds" }
        if seconds < 60 { return String(format: "%.1f seconds", seconds) }
        return minutesText(seconds)
    }

    /// "5 min 12 s", from 60 s up; rounded to whole seconds.
    static func minutesText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return "\(total / 60) min \(total % 60) s"
    }

    // MARK: - Honesty disclaimer
    //
    // The legally reviewed scope-limitation copy (`HonestyDisclaimer`,
    // `.redacted` profile) mounts at ONE site on every verdict: the last
    // section's footer, under the completion line. The component supplies
    // its text and accessibility label; the call site owns the placement.

    /// Disclaimer mount gate. Deliberately true for EVERY verdict state —
    /// the exhaustive switch (no `default`) forces a decision here if a new
    /// status is ever added. Static so the all-statuses rule is
    /// unit-testable without a SwiftUI host (mirrors `shouldShowRunBreakdown`).
    static func shouldShowHonestyDisclaimer(
        overallStatus: VerificationStatus
    ) -> Bool {
        switch overallStatus {
        case .pass, .warn, .info, .attention, .fail, .skipped, .notApplicable: true
        }
    }

    private var honestyDisclaimer: some View {
        // The disclaimer's copy is markCount-independent (its switch binds
        // no value); this view does not inject RedactionState, so 0 stands
        // in rather than threading a count the component never reads.
        HonestyDisclaimer(profile: .redacted(markCount: 0), style: .sectionFooter)
            .accessibilityIdentifier("honestyDisclaimer")
    }
}
