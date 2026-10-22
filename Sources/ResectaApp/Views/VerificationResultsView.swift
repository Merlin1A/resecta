import SwiftUI
import RedactionEngine

// Verification results recomposed around HomeView's grammar:
// status masthead →
// action choice stack (Share / Keep Editing / Preview HomeChoiceCards) →
// chevron-disclosed details (page modes + per-layer rows) → trust strip
// → footer block (timing line + audit-scope disclaimer). The
// segmented Picker and the prior contained status
// card are gone; Preview is a NavigationLink push now (matches HomeView's
// "tap card → go deeper" idiom). Action-bar and export dialogs are still
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
    /// Tap handler for the Share `HomeChoiceCard`. Mirrors the bar's
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var detailsExpanded = false
    @State private var didAutoExpand = false

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: ResectaTokens.Spacing.xl) {
                    statusMasthead
                    if !runFactsLines.isEmpty {
                        runFactsStrip
                    }
                    actionChoiceStack
                    if Self.shouldShowRunBreakdown(report: report) {
                        detailsSection
                    }
                    trustStrip
                    // The timing footer and the audit-scope
                    // disclaimer close the page as ONE footer block — the
                    // disclaimer is the LAST element on every verdict,
                    // beneath "Completed in … · N checks". One
                    // gate-wrapped mount, no per-status placement
                    // branches. The block's spacing is
                    // `disclaimerFootGap` (144 pt, was 8) so the note
                    // starts below the first screen on the 6.3″ and 6.9″
                    // phones at the default type size — the timing line
                    // stays in view, the note is one scroll away. On
                    // SKIPPED there is no timing line (`layers.isEmpty`),
                    // so the block holds only the disclaimer, one section
                    // gap under the trust strip — accepted as-falls. The
                    // always-true `shouldShowHonestyDisclaimer` gate
                    // stays: its exhaustive switch forces a mount
                    // decision if a new verdict status is ever added.
                    VStack(spacing: Self.disclaimerFootGap) {
                        if Self.shouldShowRunBreakdown(report: report) {
                            footer
                        }
                        if Self.shouldShowHonestyDisclaimer(
                            overallStatus: report.overallStatus) {
                            honestyDisclaimer
                        }
                    }
                }
                .padding(.horizontal, ResectaTokens.Spacing.md)
                // The verdict title leads the page 24 pt under the
                // bar at every Dynamic Type size; the bottom edge keeps
                // its prior behavior.
                .padding(.top, ResectaTokens.Spacing.lg)
                .padding(.bottom, dynamicTypeSize.isAccessibilitySize
                    ? ResectaTokens.Spacing.lg : ResectaTokens.Spacing.xxl)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("verificationResults")
            // Auto-expand the details disclosure (broadened)
            // on WARN, FAIL, or any mixed-mode page set. PASS + uniform
            // modes ships collapsed so the masthead leads the page.
            .onAppear {
                guard !didAutoExpand else { return }
                didAutoExpand = true
                if Self.shouldAutoExpand(
                    status: report.overallStatus,
                    hasMixedModes: report.perPageModes.hasMixedModes,
                    hasDeselection: Self.shouldShowDeselectionRow(
                        snapshot: deselectionSnapshot)
                ) {
                    detailsExpanded = true
                }
            }
        }
        // VerificationActionBar is placed by the phase router in
        // DocumentEditorView as .safeAreaInset, not embedded here. Export
        // dialogs are also mounted on DocumentEditorView.
    }

    // MARK: - Layout helpers

    /// Mirrors `HomeView.columnMaxWidth` (HomeView.swift:77-81).
    private var columnMaxWidth: CGFloat {
        horizontalSizeClass == .regular
            ? ResectaTokens.BrandedSurface.panelMaxWidthRegular
            : ResectaTokens.BrandedSurface.panelMaxWidthCompact
    }

    /// The details disclosure and the timing footer both describe a
    /// run's layer results. On the skipped sentinel (`layers.isEmpty`) there
    /// is no run to describe — the disclosure read "0 of 0 checks passed"
    /// and expanded to nothing, and the footer read "0 checks". One gate for
    /// both mounts. Static so it's unit-testable without a SwiftUI host
    /// (mirrors `shouldAutoExpand`).
    static func shouldShowRunBreakdown(report: VerificationReport) -> Bool {
        !report.layers.isEmpty
    }

    /// Phase 2 auto-expand gate. Lifted to a static helper so it's testable
    /// without a SwiftUI host (mirrors the `shouldAutoReturnHome`
    /// pattern). PASS + uniform modes → collapsed; WARN/FAIL or mixed
    /// modes → expanded.
    ///
    /// A snapshot with at least one deselected result also forces
    /// the expansion, regardless of verdict — the exact case
    /// `shouldShowDeselectionRow` gates the deselection row on. PASS is
    /// precisely the verdict where "N of M results were left un-checked"
    /// is easiest to miss if the disclosure ships collapsed, since a PASS
    /// masthead reads as "no issues" even though it only speaks to what
    /// was actually redacted. `hasDeselection` defaults to `false` so
    /// call sites that never had a deselection concept (tests pinning the
    /// original status/hasMixedModes contract) are unaffected; the one
    /// production caller (`.onAppear` above) always passes the real
    /// value.
    static func shouldAutoExpand(
        status: VerificationStatus,
        hasMixedModes: Bool,
        hasDeselection: Bool = false
    ) -> Bool {
        if hasMixedModes || hasDeselection { return true }
        switch status {
        case .pass, .info, .skipped:  return false
        case .warn, .attention, .fail: return true
        }
    }

    // MARK: - Status masthead
    //
    // Neutral chrome — no card background; the masthead reads as part of
    // the page. The row-word title, then ONE sentence on every verdict
    // that names the control to use, and one combined accessibility label
    // that also speaks the counts.

    private var statusMasthead: some View {
        VStack(spacing: ResectaTokens.Spacing.sm) {
            Text(Self.mastheadTitle(report: report))
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            if let mastheadSubtitle {
                Text(mastheadSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                    // The ATTENTION sentence can quote the review terms —
                    // text the checks found still readable in the output —
                    // so it carries the same privacy marking as the search
                    // and review surfaces; every other arm is mechanism copy.
                    .privacySensitive(Self.mastheadSubtitleIsPrivacySensitive(report: report))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.mastheadAccessibilityLabel(
            report: report, outputExists: outputExists, mode: runFacts.runMode))
    }

    private var mastheadSubtitle: String? {
        Self.mastheadSubtitle(report: report, outputExists: outputExists, mode: runFacts.runMode)
    }

    /// The control names never break across lines.
    private static let keepEditing = "Keep\u{00A0}Editing"
    private static let textSearch = "text\u{00A0}search"
    private static let runVerification = "Run\u{00A0}Verification"

    /// The longest masthead sentence; the term forms fall back past it.
    static let mastheadSentenceLimit = 70

    /// The masthead title: the status-level title, except a WARN that holds
    /// a check that could not verify (a skipped one included), which reads
    /// `Some Checks Incomplete`.
    static func mastheadTitle(report: VerificationReport) -> String {
        if report.overallStatus.isWarn, partition(report).count(.couldNotVerify) > 0 {
            return "Some Checks Incomplete"
        }
        return report.overallStatus.title
    }

    /// The masthead's spoken label: the title, the counts (line 2's dots
    /// spoken as commas) and the sentence; on SKIPPED, the title and the
    /// sentence.
    static func mastheadAccessibilityLabel(
        report: VerificationReport, outputExists: Bool = true, mode: RunMode = .searchableOrUnknown
    ) -> String {
        let title = mastheadTitle(report: report)
        let sentence = mastheadSubtitle(report: report, outputExists: outputExists, mode: mode) ?? ""
        guard !report.overallStatus.isSkipped else { return "\(title). \(sentence)" }
        let partition = partition(report)
        var parts = ["\(title).", "\(partition.summaryLine1)."]
        if let line2 = partition.summaryLine2 {
            parts.append(line2.replacingOccurrences(of: " · ", with: ", ") + ".")
        }
        parts.append(sentence)
        return parts.joined(separator: " ")
    }

    /// The run's mode as the SKIPPED sentences need it: a Secure run had
    /// every page rasterized by choice (no fallback reason); anything else,
    /// or no record of the run, reads as Searchable.
    enum RunMode: Equatable {
        case secure
        case searchableOrUnknown

        static func of(perPageModes: [PipelineMode],
                       fallbackReasons: [TextLayerDetector.FallbackReason?]) -> RunMode {
            guard !perPageModes.isEmpty,
                  perPageModes.allSatisfy({ $0 == .secureRasterization }),
                  !fallbackReasons.contains(where: { $0 != nil })
            else { return .searchableOrUnknown }
            return .secure
        }
    }

    /// The SKIPPED sentence: the reason, then the step — `Run Verification`,
    /// and on a Searchable (or unknown) run the full Redact that includes
    /// the checks a verify-only run cannot complete.
    static func skippedSubtitle(reason: VerificationReport.SkipReason, mode: RunMode = .searchableOrUnknown) -> String {
        let cause = switch reason {
        case .autoVerifyOff: "Off in Settings."
        case .cancelled:     "Stopped early."
        case .error:         "Could not finish."
        }
        let step = mode == .secure
            ? "\(runVerification) below before you share the PDF."
            : "\(runVerification), or run Redact for all checks."
        return "\(cause) \(step)"
    }

    /// The sentence when the redacted PDF no longer exists: every arm that
    /// names Preview or Run Verification gives way to it.
    static let outputMissingSentence = "\(keepEditing), then run Redact again to share the PDF."

    /// Whether the masthead sentence names user text: true exactly when it
    /// quotes a review term. Static so the predicate is unit-testable
    /// without a SwiftUI host.
    static func mastheadSubtitleIsPrivacySensitive(report: VerificationReport) -> Bool {
        guard report.overallStatus.isAttention else { return false }
        return attentionSentence(report: report).quotesTerms
    }

    /// The masthead sentence, by verdict and the rows behind it. Never nil
    /// (the optional is the shipped call sites' shape). Static so every arm
    /// is unit-testable without a SwiftUI host.
    static func mastheadSubtitle(
        report: VerificationReport, outputExists: Bool = true, mode: RunMode = .searchableOrUnknown
    ) -> String? {
        let partition = partition(report)
        switch report.overallStatus {
        case .pass, .info:
            let notes = visibleNoteCount(partition)
            switch notes {
            case 0:
                return outputExists
                    ? "Look over the redacted PDF in Preview before you share it." : outputMissingSentence
            case 1:  return "Read the note in Verification Details before you share the PDF."
            default: return "Read the notes in Verification Details before you share the PDF."
            }
        case .warn:
            let couldNotVerify = partition.couldNotVerify.map { report.layers[$0] }
            if !couldNotVerify.isEmpty, couldNotVerify.allSatisfy(\.status.isSkipped) {
                return couldNotVerify.count == 1
                    ? "Run Redact again from \(keepEditing) to include the skipped check."
                    : "Run Redact again from \(keepEditing) to include the skipped checks."
            }
            if !couldNotVerify.isEmpty {
                return couldNotVerify.count == 1
                    ? "1 check could not run in full; read it below before you share."
                    : "\(couldNotVerify.count) checks could not run in full; read them below before you share."
            }
            return partition.count(.warning) == 1
                ? "Read the warning below before you share the PDF."
                : "Read the warnings below before you share the PDF."
        case .attention:
            return attentionSentence(report: report).text
        case .fail:
            return isPageCountGateRun(report)
                ? "\(keepEditing) and run Redact again; the other checks did not run."
                : "\(keepEditing) to fix what failed, or share after review."
        case .skipped:
            guard outputExists else { return outputMissingSentence }
            return skippedSubtitle(reason: report.skipReason, mode: mode)
        }
    }

    /// The ATTENTION sentence. Term rows win over a Search Re-check row;
    /// the term forms are tried in order and the first that fits is taken
    /// — every term, then the first term and a count, then "the terms
    /// below" — so a term is never cut.
    static func attentionSentence(report: VerificationReport) -> (text: String, quotesTerms: Bool) {
        let termRows = report.layers.filter {
            $0.status.isAttention && VerificationRowModel.quotesReviewTerms($0.layer)
        }
        let lead = "\(keepEditing), then use \(textSearch) to redact"
        if !termRows.isEmpty {
            let terms = reviewTermTexts(report: report)
            let quoted = terms.map { "\u{201C}\($0)\u{201D}" }
            var candidates: [String] = []
            if terms.count == 1 || terms.count == 2 {
                candidates.append("\(lead) \(VerificationRowModel.listPhrase(quoted)).")
            }
            if terms.count >= 2 {
                candidates.append("\(lead) \(quoted[0]) and \(terms.count - 1) more.")
            }
            if let fit = candidates.first(where: { $0.count <= mastheadSentenceLimit }) {
                return (fit, true)
            }
            return (terms.count > 1 ? "\(lead) the terms below." : "\(lead) the term below.", false)
        }
        let searches = report.layers
            .filter { $0.status.isAttention && $0.layer == .searchRecheck }
            .flatMap(VerificationRowModel.matchingQueryLines)
        if !searches.isEmpty {
            return (searches.count == 1
                ? "\(keepEditing) and run your search again with OCR on."
                : "\(keepEditing) and run your searches again with OCR on.", false)
        }
        return ("\(lead) the terms below.", false)
    }

    /// The review terms the ATTENTION sentence may quote: the needs-review
    /// rows of the three term checks, in engine order, normalised as the
    /// user would type them and de-duplicated case-insensitively. Static so
    /// the masthead derivation is unit-testable without a SwiftUI host.
    static func reviewTermTexts(report: VerificationReport) -> [String] {
        VerificationRowModel.normalizedTerms(report.layers
            .filter { $0.status.isAttention && VerificationRowModel.quotesReviewTerms($0.layer) }
            .flatMap { $0.reviewTermTexts ?? [] })
    }

    /// The notes a PASS reader sees without opening anything: the Notes
    /// section's rows, plus the notes riding in the pass cluster when the
    /// cluster opens by default (nothing sits above it).
    static func visibleNoteCount(_ partition: VerificationLayerPartition) -> Int {
        partition.notes.count + (partition.isWhollyClean ? partition.clusterNoteCount : 0)
    }

    /// The page-count gate's report: its one row is the gate, so the other
    /// checks did not run.
    static func isPageCountGateRun(_ report: VerificationReport) -> Bool {
        report.layers.count == 1
            && report.layers[0].name == VerificationRowModel.pageCountGateName
            && report.layers[0].layer == nil
    }

    private static func partition(_ report: VerificationReport) -> VerificationLayerPartition {
        VerificationLayerPartition(layers: report.layers, perPageModes: report.perPageModes)
    }

    // MARK: - Run facts strip
    //
    // 0-2 conditional caption-weight lines stating what this run's
    // detection did not cover. Mounted directly beneath the masthead,
    // above the action stack, on every verdict — a routine PASS with
    // nothing to state renders no strip (no empty container). Every line
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
        /// 0-indexed input (mirrors
        /// `ScanReviewSection.ocrSkipBannerHeadline`); 1-based page
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

    private var runFactsStrip: some View {
        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xs) {
            ForEach(Array(runFactsLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: columnMaxWidth)
        .accessibilityIdentifier("runFactsStrip")
    }

    // MARK: - Action choice stack
    //
    // Phase 2 lock, amended by the preview/share-tint decouple:
    // Share / Keep Editing always; the Preview card appears whenever a
    // redacted output exists on disk (`previewAvailable`), independent of
    // the verdict. ⌘E binds to the Share card's wrapping Button (locked
    // landing point — Phase 3 parked it on the bar's overflow menu).

    private var actionChoiceStack: some View {
        VStack(spacing: ResectaTokens.Spacing.md) {
            if Self.shouldShowRunVerificationCard(report: report) {
                runVerificationCard
            }
            shareCard
            keepEditingCard
            if previewAvailable {
                previewCard
            }
        }
        .frame(maxWidth: columnMaxWidth)
    }

    // MARK: - Run Verification card
    //
    // A skipped report previously stranded the user: the only "Re-verify"
    // affordance was an overlay in DocumentEditorView gated on a phase whose
    // router branch renders THIS view instead — mutually exclusive by
    // construction, so it never appeared. The recovery CTA now lives where
    // the skipped report is actually shown, above Share so running the
    // checks reads as the primary next step.

    /// Card visibility — skipped reports only. Static so the mount condition
    /// is unit-testable without a SwiftUI host (mirrors `shouldAutoExpand`).
    static func shouldShowRunVerificationCard(report: VerificationReport) -> Bool {
        report.overallStatus.isSkipped
    }

    /// Body copy for the Run Verification card — one body for every skip
    /// reason; the masthead sentence carries the reason.
    static let runVerificationCardBodyText =
        "Run the checks on the redacted PDF before you share it."

    private var runVerificationCard: some View {
        HomeChoiceCard(
            symbol: "checkmark.shield",
            style: .subtle,
            title: "Run Verification",
            bodyText: LocalizedStringKey(Self.runVerificationCardBodyText),
            affordance: "Run Checks →",
            action: onRunVerification
        )
        .accessibilityLabel("Run Verification. \(Self.runVerificationCardBodyText)")
        .accessibilityIdentifier("runVerificationCard")
    }

    // (removed — Preview visibility now keys on `previewAvailable`; Share red
    //  tint now keys on `Self.shouldTintShareRed(report:)`. The two facts are
    //  intentionally separate inputs so they cannot re-couple.)

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
    /// unit-testable without a SwiftUI host (mirrors `shouldAutoExpand`).
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

    /// The Share hint: spoken only, exactly when tapping Share opens a
    /// confirm. It reads the live confirm predicates with their
    /// acknowledgements — never the rows — so after a completed share,
    /// whose acknowledgement stays spent, no hint promises a confirm.
    static let shareConfirmHint = "Asks you to confirm before sharing."

    /// Whether Share will ask for confirmation: Share is enabled and one of
    /// the three confirm families is armed.
    static func shareWillConfirm(
        report: VerificationReport, canExport: Bool,
        failAcknowledged: Bool, skippedAcknowledged: Bool, incompleteWarnAcknowledged: Bool
    ) -> Bool {
        canExport && (
            DocumentEditorView.shareNeedsFailConfirm(report: report, acknowledged: failAcknowledged)
            || DocumentEditorView.shareNeedsSkippedConfirm(report: report, acknowledged: skippedAcknowledged)
            || DocumentEditorView.shareNeedsIncompleteWarnConfirm(
                report: report, acknowledged: incompleteWarnAcknowledged))
    }

    private var shareWillConfirm: Bool {
        Self.shareWillConfirm(
            report: report, canExport: canExport,
            failAcknowledged: documentState.failShareAcknowledged,
            skippedAcknowledged: documentState.skippedShareAcknowledged,
            incompleteWarnAcknowledged: documentState.incompleteWarnShareAcknowledged)
    }

    /// Red-tints the Share tile on ANY verification FAIL verdict. Keyed on the
    /// status verdict ALONE — independent of userOverrodeFailure — so the tint
    /// does NOT flip as a side effect of the "Share Anyway" override / share
    /// round-trip (DocumentEditorView.swift:1408-1411). Static so it is a single
    /// source of truth and unit-testable without a SwiftUI host.
    static func shouldTintShareRed(report: VerificationReport) -> Bool {
        report.overallStatus.isFail
    }

    /// Share-tile tint per verdict: FAIL keeps the red tint (above);
    /// ATTENTION tints in its own status color so the tile matches the
    /// masthead without borrowing FAIL's red. Independent of
    /// userOverrodeFailure for the same reason as `shouldTintShareRed`.
    static func shareTintColor(report: VerificationReport) -> Color? {
        if shouldTintShareRed(report: report) { return .red }
        if report.overallStatus.isAttention { return .pink }
        return nil
    }

    /// The Share-card caption for a source that was encrypted. Static so the
    /// copy is pinned without a SwiftUI host.
    static func notProtectedCaption(hadRestrictions: Bool) -> String {
        hadRestrictions
            ? "The redacted copy is not password-protected. It carries none of the original's usage restrictions."
            : "The redacted copy is not password-protected."
    }

    private var shareCard: some View {
        // One control per card: a real Button whose label is non-interactive
        // chrome (`HomeChoiceCardContent`). The prior structure nested a
        // `HomeChoiceCard` — itself a Button — inside this Button and tried
        // to neutralize it with `.allowsHitTesting(false)` + a trailing
        // `.contentShape(Rectangle())`; that left the outer Button with no
        // working tap target (SwiftUI does not support a Button whose label
        // is a Button). A single Button restores the tap surface, the ⌘E
        // binding, and the press animation from `HomeChoiceCardButtonStyle`.
        // ⌘E is the locked landing point (Phase 2 plan; Phase 3 parked the
        // bar's copy on the overflow menu).
        VStack(spacing: ResectaTokens.Spacing.xs) {
            Button {
                onExport()
            } label: {
                HomeChoiceCardContent(
                    symbol: "square.and.arrow.up",
                    style: .primary,
                    title: "Share Document",
                    bodyText: "Save the redacted PDF or share it from this device.",
                    affordance: "Share →",
                    tintOverride: Self.shareTintColor(report: report)
                )
            }
            .buttonStyle(HomeChoiceCardButtonStyle())
            .disabled(Self.shareDisabled(canExport: canExport))
            .keyboardShortcut("e", modifiers: .command)
            .accessibilityLabel(Self.shareCardAccessibilityLabel)
            .accessibilityHint(shareWillConfirm ? Self.shareConfirmHint : "")

            // A disabled card with no copy reads as broken; say why and what
            // to do. Rendered only when the gate actually disables Share, so
            // the caption can never contradict an enabled card.
            if Self.shareDisabled(canExport: canExport),
               let reason = Self.shareDisabledReason(
                   outputExists: outputExists, isStale: isVerificationStale
               ) {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("shareDisabledReason")
            }

            // The source was encrypted: say what the redacted copy carries,
            // at the moment the user decides to share it.
            if documentState.sourceFacts.wasEncrypted {
                Text(Self.notProtectedCaption(hadRestrictions: documentState.sourceFacts.hadRestrictions))
                    .font(.footnote)
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("shareNotProtectedCaption")
            }
        }
    }

    /// Keep Editing body copy states the undo boundary where it bites —
    /// Redact cleared the undo stack, so returning to the editor cannot
    /// Cmd-Z back past it. Static so the a11y label and the card speak the
    /// same words and the wording is pinned without a host.
    static let keepEditingBodyText =
        "Return to the editor to adjust regions, then run Redact again. "
        + "Redact cleared undo; use Delete\u{00A0}Region instead."

    /// Keep Editing's spoken label: the action, then the undo boundary.
    static let keepEditingAccessibilityLabel =
        "Keep Editing. Return to the editor to adjust regions, then run Redact again. "
        + "Redact cleared undo; use Delete Region instead."

    private var keepEditingCard: some View {
        HomeChoiceCard(
            symbol: "pencil.and.outline",
            style: .subtle,
            title: "Keep Editing",
            bodyText: LocalizedStringKey(Self.keepEditingBodyText),
            affordance: "Open Editor →",
            action: { documentState.transition(to: .editing) }
        )
        .accessibilityLabel(Self.keepEditingAccessibilityLabel)
    }

    private var previewCard: some View {
        // One control per card: a real NavigationLink whose label is
        // non-interactive chrome. NavigationLink honors the custom
        // `.buttonStyle`, so the card's material/shadow chrome and the
        // press animation render. The destination resolves against the
        // NavigationStack in `body` (DocumentEditorView hosts no stack).
        NavigationLink {
            // The preview carries the live verdict so a user
            // reviewing a FAILed or unverified output sees an in-context
            // cue (nav-bar capsule) instead of a bare document.
            RedactedPreviewView(verdict: report.overallStatus)
        } label: {
            HomeChoiceCardContent(
                symbol: "eye",
                style: .subtle,
                title: "Preview Redacted Document",
                bodyText: LocalizedStringKey(Self.previewCardBodyText),
                affordance: "Open Preview →"
            )
        }
        .buttonStyle(HomeChoiceCardButtonStyle())
        .accessibilityLabel(Self.previewCardAccessibilityLabel)
    }

    // MARK: - Details disclosure
    //
    // The disclosure — header row, page modes, the deselection row and the
    // per-layer rows — is `VerificationDetailsSection`; this view keeps the
    // auto-expand state and threads it in as a binding.

    private var detailsSection: some View {
        VerificationDetailsSection(
            report: report,
            deselectionSnapshot: deselectionSnapshot,
            isExpanded: $detailsExpanded,
            columnMaxWidth: columnMaxWidth
        )
    }

    // MARK: - Trust strip
    //
    // Mirrors HomeView's strip exactly ("On-device · No tracking · Open
    // source") and is status-independent: the strip states standing facts
    // about the app, while the run's outcome lives in the status banner and
    // the footer. The former PASS/INFO-gated "Verification complete" item is
    // gone entirely, and with it the outcome-promise concern.

    private var trustStrip: some View {
        FlowLayout(spacing: ResectaTokens.Spacing.sm, alignment: .center) {
            TrustItem(label: "On-device")
            Text("·").foregroundStyle(.tertiary).font(.footnote)
            TrustItem(label: "No tracking")
            Text("·").foregroundStyle(.tertiary).font(.footnote)
            TrustItem(label: "Open source")
        }
        .frame(maxWidth: columnMaxWidth)
    }

    // MARK: - Footer

    private var footer: some View {
        Text(Self.completionLineText(report: report))
        .font(.footnote)
        .foregroundStyle(ResectaTokens.SemanticColor.supportText)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, ResectaTokens.Spacing.sm)
    }

    /// The completion line: the duration and the number of checks, the
    /// minutes form from 60 s; the page-count gate's report, where no check
    /// completed, says where it stopped.
    static func completionLineText(report: VerificationReport) -> String {
        if isPageCountGateRun(report) { return "Stopped at the Page Count check." }
        let n = report.layers.count
        let checks = n == 1 ? "1 check" : "\(n) checks"
        guard report.durationSeconds > 0 else { return checks }
        return "Completed in \(durationText(report.durationSeconds)) · \(checks)"
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
    // `.redacted` profile) had zero production call sites — no surface named
    // the checks' epistemic limits at the point where the share decision is
    // made. It mounts at ONE site on every verdict: it is
    // the last element of the page, in the footer block beneath the
    // timing line — `disclaimerFootGap` under it (8 pt originally, 144 pt
    // now). The component supplies its own caption styling,
    // centered alignment, and accessibility label; the call site owns the
    // spacing; Dynamic Type flows through `Text`.

    /// The footer block's spacing — the distance from the
    /// timing line to the audit-scope note. 3 × `Spacing.xxl` = 144 pt,
    /// sized from the measured PASS layout at the default type size (the
    /// 2026-09-24 re-measure, with the Verification Details header a
    /// 60-pt mini-card): the timing line ends ≈847 pt from the top of the
    /// screen — ≈27 pt above the 874-pt 6.3″ fold, ≈109 pt above the
    /// 956-pt 6.9″ one — so the note's top edge lands ≈117 pt below the
    /// 6.3″ screen (≈35 pt below the 6.9″) — the first screen, which is the
    /// App Store frame, shows the verdict through the timing line and the
    /// note is one scroll away. Static so the value is pinned without a
    /// SwiftUI host (`HonestySurfacesTests`).
    static let disclaimerFootGap: CGFloat = ResectaTokens.Spacing.xxl * 3

    /// Disclaimer mount gate. Deliberately true for EVERY verdict state —
    /// the exhaustive switch (no `default`) forces a decision here if a new
    /// status is ever added. Static so the all-statuses rule is
    /// unit-testable without a SwiftUI host (mirrors `shouldAutoExpand`).
    static func shouldShowHonestyDisclaimer(
        overallStatus: VerificationStatus
    ) -> Bool {
        switch overallStatus {
        case .pass, .warn, .info, .attention, .fail, .skipped: true
        }
    }

    private var honestyDisclaimer: some View {
        // The disclaimer's copy is markCount-independent (its switch binds
        // no value); this view does not inject RedactionState, so 0 stands
        // in rather than threading a count the component never reads.
        HonestyDisclaimer(profile: .redacted(markCount: 0))
            .frame(maxWidth: columnMaxWidth)
            .accessibilityIdentifier("honestyDisclaimer")
    }

}
