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
    /// (`RedactionState.lastRunDeselection`), threaded in like
    /// `previewAvailable` since this view does not inject RedactionState.
    /// Nil (also the default, so fixture call sites stay source-compatible)
    /// or zero deselections renders no row.
    var deselectionSnapshot: RedactionState.DeselectionSnapshot? = nil
    /// Tap handler for the deselection row's Review affordance. Routing
    /// (Keep Editing + re-presenting the search sheet's coverage panel)
    /// lives on `DocumentEditorView`, which owns the sheet detent and the
    /// phase transition. Nil hides the affordance — the search session the
    /// counts came from is gone, so there is no panel to reopen.
    var onReviewDeselections: (() -> Void)? = nil
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
    // Phase 2 lock: neutral chrome — no card background; the
    // masthead reads as part of the page, not as a contained card.
    // Title → subtitle, no glyph — the verdict is conveyed by the
    // title/subtitle text and the combined accessibility label below (the
    // former 56pt status-symbol slot above the title is removed; the
    // per-layer status glyphs in `LayerResultRow` are unchanged).
    // PASS renders the title alone — `mastheadSubtitle`
    // is nil on PASS, so the subtitle `Text` is not mounted at all (no
    // empty line, no stray spacing); every other verdict keeps its line.

    private var statusMasthead: some View {
        VStack(spacing: ResectaTokens.Spacing.sm) {
            Text(report.overallStatus.title)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            if let mastheadSubtitle {
                Text(mastheadSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                    // The ATTENTION arm quotes the review terms — text the
                    // checks found still readable in the output — so it
                    // carries the same privacy marking as the search and
                    // review surfaces; every other arm is mechanism copy.
                    .privacySensitive(Self.mastheadSubtitleIsPrivacySensitive(
                        status: report.overallStatus))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.mastheadAccessibilityLabel(report: report))
    }

    /// Combined masthead a11y label. Skipped reports get the same
    /// reason-specific wording as the visible subtitle; every other status
    /// keeps the status-level label.
    static func mastheadAccessibilityLabel(report: VerificationReport) -> String {
        guard report.overallStatus.isSkipped else {
            return report.overallStatus.accessibilityLabel
        }
        return "Verification was skipped. \(skippedSubtitle(reason: report.skipReason))"
    }

    /// Reason-specific subtitle for skipped reports. The status-level
    /// `VerificationStatus.subtitle` cannot see the report, so the
    /// derivation lives here where the report is available.
    static func skippedSubtitle(reason: VerificationReport.SkipReason) -> String {
        switch reason {
        case .autoVerifyOff:
            "Verification is turned off in Settings. Run Redact again with verification on, or share unverified."
        case .cancelled:
            "Verification was stopped before it finished. Run it again before sharing."
        case .error:
            "Verification could not be completed. Run it again before sharing."
        }
    }

    /// Plain subtitle (no timing). Timing moved to the footer; the
    /// per-page-mode summary moves into the details disclosure header.
    /// Nil on PASS — the masthead mounts no subtitle at all.
    private var mastheadSubtitle: String? {
        Self.mastheadSubtitle(report: report)
    }

    /// Whether the masthead subtitle names user text. Only the ATTENTION
    /// arm of `mastheadSubtitle(report:)` quotes the review terms; the
    /// WARN, FAIL and skipped lines describe what the checks did. Static so
    /// the predicate is unit-testable without a SwiftUI host.
    static func mastheadSubtitleIsPrivacySensitive(status: VerificationStatus) -> Bool {
        status.isAttention
    }

    /// Subtitle derivation, lifted to a `static` helper so the skip-induced
    /// WARN arm is unit-testable without a SwiftUI host (mirrors
    /// `skippedSubtitle`). Returns nil exactly when the masthead shows the
    /// title alone (PASS, and the never-aggregated INFO for exhaustiveness);
    /// every verdict that asks the user to do something keeps its line.
    static func mastheadSubtitle(report: VerificationReport) -> String? {
        switch report.overallStatus {
        case .pass:
            // "All N verification checks completed without
            // issues." (+ the informational-notes tail) is gone in both
            // pipeline modes — "Checks Passed" carries the verdict, and the
            // Verification Details header still reads "N of N checks
            // passed · N informational notes" one row down. Reduced
            // assurance never takes this arm: an INFO-only run aggregates
            // to PASS, skips degrade the aggregate to WARN (its arm below).
            return nil
        case .warn:
            let warnCount = report.layers.filter(\.status.isWarn).count
            // Skip-induced WARN: on the digest-less verify-only
            // path Layers 7/9 report `.skipped` and the aggregate degrades
            // to WARN with zero WARN layers. "Completed with 0 notes" named
            // a note count no row backed up; name the skips instead
            // (matches the aggregate's own diagnostic).
            let skippedCount = report.layers.filter(\.status.isSkipped).count
            if warnCount == 0 && skippedCount > 0 {
                return "Completed with \(skippedCount) of \(report.layers.count) checks skipped — results may be incomplete."
            }
            return "Verification completed with \(warnCount) \(warnCount == 1 ? "note" : "notes"). Review below before sharing."
        case .info:
            // Overall status never aggregates to .info — aggregateStatus
            // returns .fail/.warn/.pass, or .skipped when every layer was
            // skipped (skip-aware aggregation). Keep an arm for
            // exhaustiveness; if ever surfaced, treat like .pass (title
            // alone).
            return nil
        case .attention:
            // Name the exact text once at the masthead (display-only
            // field) — each attention row repeats it with the remediation
            // hint. Fallback stays generic if no layer carried term texts.
            let terms = Self.reviewTermTexts(report: report)
            if terms.isEmpty {
                return "Unredacted text remains — review the items below."
            }
            let quoted = terms.map { "'\($0)'" }.joined(separator: ", ")
            return "Unredacted text remains: \(quoted)"
        case .fail:
            return "Review the findings below. You can adjust regions and run redaction again, or share after reviewing."
        case .skipped:
            return Self.skippedSubtitle(reason: report.skipReason)
        }
    }

    /// Union of the report's display-only review term texts, deduplicated,
    /// in layer order. Static so the masthead derivation is unit-testable
    /// without a SwiftUI host (mirrors `skippedSubtitle`).
    static func reviewTermTexts(report: VerificationReport) -> [String] {
        var seen = Set<String>()
        var texts: [String] = []
        for layer in report.layers {
            for text in layer.reviewTermTexts ?? [] where seen.insert(text).inserted {
                texts.append(text)
            }
        }
        return texts
    }

    // MARK: - Run facts strip
    //
    // 0-3 conditional caption-weight lines disclosing what
    // this run's detection did or did not cover. Mounted directly
    // beneath the masthead, above the action stack, on every verdict —
    // a routine PASS with nothing to disclose renders no strip (no
    // empty container). Every line is a pinned static builder
    // so the rendered text is unit-testable without a
    // SwiftUI host.

    /// Pure facts input for the strip. `derive` is the single production
    /// source (called from `DocumentEditorView`); the plain-value
    /// default keeps every field off.
    struct RunFacts: Equatable {
        /// 0-indexed pages whose raster exceeded the OCR pixel
        /// caps during the run behind this output.
        var ocrSkippedPages: Set<Int> = []
        /// No detection ran this session, yet a region was
        /// applied for this output (Search or manual marking produced
        /// it).
        var detectionNeverRan: Bool = false
        /// The degrade-failure list snapshotted when the run
        /// behind this output was recorded; nil when that run was not
        /// degraded.
        var degradeFailures: [String]? = nil

        /// Pure derivation from the two facts `DocumentEditorView`
        /// already computes. `lastDetectionRun` is the session's most
        /// recent detection/scan record, not necessarily the run behind
        /// `report` — the common scan-then-apply-then-Redact-then-Verify
        /// path keeps the two in step, since leaving `.verified` is
        /// required before another scan can start; a later scan not
        /// followed by another Redact would leave this strip describing
        /// the newer scan rather than the on-screen report.
        static func derive(
            lastDetectionRun: RedactionState.DetectionRunRecord?,
            hasAppliedRegions: Bool
        ) -> RunFacts {
            RunFacts(
                ocrSkippedPages: lastDetectionRun?.ocrSkippedPages ?? [],
                detectionNeverRan: lastDetectionRun == nil && hasAppliedRegions,
                degradeFailures: lastDetectionRun?.degradeFailures
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

        static let detectionNeverRanLine =
            "Automated detection did not run on this document. Every region here came from Search or manual marking \u{2014} review each page for anything those did not cover before sharing."

        /// Reuses `DetectionDegradeCopy.banner` verbatim; no new
        /// degrade string.
        static func degradeLine(failedGazetteers: [String]) -> String {
            DetectionDegradeCopy.banner(failedGazetteers: failedGazetteers)
        }

        /// Ordered lines for the given facts: the OCR-skip line, then
        /// the detection-never-ran line, then the degrade line. The first
        /// two are mutually exclusive by construction
        /// (both key off `lastDetectionRun`'s nilness), so at most two
        /// lines render for this fact set today.
        static func lines(for facts: RunFacts) -> [String] {
            var result: [String] = []
            if !facts.ocrSkippedPages.isEmpty {
                result.append(ocrSkipLine(pages: Array(facts.ocrSkippedPages)))
            }
            if facts.detectionNeverRan {
                result.append(detectionNeverRanLine)
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

    /// Reason-specific body copy for the Run Verification card. autoVerifyOff
    /// is a deliberate setting (neutral copy); cancelled/error mean the run
    /// did not finish (urgency copy).
    static func runVerificationCardBodyText(
        reason: VerificationReport.SkipReason
    ) -> String {
        switch reason {
        case .autoVerifyOff:
            "Runs the post-redaction checks on this output."
        case .cancelled, .error:
            "Verification did not finish — run the checks on this output before sharing."
        }
    }

    private var runVerificationCard: some View {
        HomeChoiceCard(
            symbol: "checkmark.shield",
            style: .subtle,
            title: "Run Verification",
            bodyText: LocalizedStringKey(
                Self.runVerificationCardBodyText(reason: report.skipReason)),
            affordance: "Run Checks →",
            action: onRunVerification
        )
        .accessibilityLabel(
            "Run Verification. \(Self.runVerificationCardBodyText(reason: report.skipReason))")
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
        "Preview Redacted Document. Open the redacted output in a read-only viewer."

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
        if !outputExists {
            return "The output file is no longer available — run Redact again."
        }
        if isStale {
            return "Regions changed since this output was made — run Redact again to share."
        }
        return nil
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
        }
    }

    /// Keep Editing body copy states the undo
    /// boundary where it bites — applying redactions cleared the undo
    /// stack, so returning to the editor cannot
    /// Cmd-Z back past the apply. Static so the a11y label and the card
    /// speak the same string and the wording is pinned without a host.
    static let keepEditingBodyText =
        "Return to the editor to adjust regions or rerun detection. "
        + "Applying redactions cleared the undo history — use Delete Region to remove a region."

    private var keepEditingCard: some View {
        HomeChoiceCard(
            symbol: "pencil.and.outline",
            style: .subtle,
            title: "Keep Editing",
            bodyText: LocalizedStringKey(Self.keepEditingBodyText),
            affordance: "Open Editor →",
            action: { documentState.transition(to: .editing) }
        )
        .accessibilityLabel("Keep Editing. \(Self.keepEditingBodyText)")
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
                bodyText: "Open the redacted output in a read-only viewer.",
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
            onReviewDeselections: onReviewDeselections,
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
        Group {
            if report.durationSeconds > 0 {
                Text("Completed in \(String(format: "%.1f", report.durationSeconds)) seconds · \(report.layers.count) checks")
            } else {
                Text("\(report.layers.count) checks")
            }
        }
        .font(.footnote)
        .foregroundStyle(ResectaTokens.SemanticColor.supportText)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, ResectaTokens.Spacing.sm)
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
    /// sized from the measured PASS layout at the default type size: the
    /// timing line ends ≈835 pt from the top of the screen on the 6.3″ and
    /// 6.9″ iPhones, so the note's top edge lands ≈23 pt below the 956-pt
    /// 6.9″ screen (≈105 pt below the 874-pt 6.3″ one) — the first screen,
    /// which is the App Store frame, shows the verdict through the timing
    /// line and the note is one scroll away. Static so the value is pinned
    /// without a SwiftUI host (`HonestySurfacesTests`).
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
