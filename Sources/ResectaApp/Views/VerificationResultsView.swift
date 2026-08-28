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
    // Routes the
    // page-modes / layer-detail `.move(edge:)` transitions through
    // `Anim.resolvedTransition`.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var expandedLayer: Int?
    @State private var detailsExpanded = false
    @State private var showPageModes = false
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
    // Phase 2 lock: collapsed by default; closed-state row carries the
    // pass/note/issue summary; chevron rotates 90° on expand (mirrors the
    // pageModesSection pattern). The existing pageModesSection body and
    // the ForEach(LayerResultRow) body are preserved verbatim inside.

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(ResectaTokens.Anim.stateChange) {
                    detailsExpanded.toggle()
                }
            } label: {
                HStack(spacing: ResectaTokens.Spacing.sm) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 20))
                        .foregroundStyle(ResectaTokens.BrandTeal.text)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                        Text("Verification Details")
                            .font(.subheadline.weight(.medium))
                        Text(detailsSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(detailsExpanded ? 90 : 0))
                }
                .padding(ResectaTokens.Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Verification Details, \(detailsSummary)")
            .accessibilityHint(detailsExpanded ? "Tap to collapse" : "Tap to expand")

            if detailsExpanded {
                VStack(spacing: ResectaTokens.Spacing.md) {
                    if report.perPageModes.hasMixedModes {
                        pageModesSection
                    }

                    // Deselection visibility at share time: a PASS
                    // legitimately says "without issues" — the checks ran
                    // on what was redacted, not on what the user chose to
                    // leave. When the run started with known scan results
                    // deliberately un-checked, say so here, at the surface
                    // where the share decision is made.
                    if Self.shouldShowDeselectionRow(
                        snapshot: deselectionSnapshot),
                       let snapshot = deselectionSnapshot {
                        deselectionRow(snapshot: snapshot)
                    }

                    // Partition layers into actionable findings vs.
                    // informational metadata vs. clean checks. `layerIndex`
                    // stays engine-position-based (1-indexed) so the
                    // accessibilityIdentifier "layerResult_\(layerIndex - 1)"
                    // and spec cross-references remain stable across grouping.
                    // .skipped rides under FINDINGS (a skipped check
                    // is something the user should notice), not silently in the
                    // passed group.
                    let findings = Array(report.layers.enumerated()).filter {
                        $0.element.status.isWarn
                            || $0.element.status.isAttention
                            || $0.element.status.isFail
                            || $0.element.status.isSkipped
                    }
                    let metadata = Array(report.layers.enumerated()).filter {
                        $0.element.status.isInfo
                    }
                    let passed = Array(report.layers.enumerated()).filter {
                        !$0.element.status.isWarn
                            && !$0.element.status.isAttention
                            && !$0.element.status.isFail
                            && !$0.element.status.isInfo
                            && !$0.element.status.isSkipped
                    }

                    if findings.isEmpty && metadata.isEmpty {
                        // Wholly clean doc — no headers, flat list.
                        ForEach(passed, id: \.element.name) { index, layer in
                            layerRow(layer: layer, index: index)
                        }
                    } else {
                        if !findings.isEmpty {
                            sectionHeader("FINDINGS")
                            ForEach(findings, id: \.element.name) { index, layer in
                                layerRow(layer: layer, index: index)
                            }
                            if Self.shouldShowSkippedChecksFootnote(report: report) {
                                skippedChecksFootnote
                            }
                            // Clean checks ride under FINDINGS so the user
                            // sees the full surface that was inspected.
                            ForEach(passed, id: \.element.name) { index, layer in
                                layerRow(layer: layer, index: index)
                            }
                        } else {
                            // Metadata-only — passed rows lead with no header,
                            // METADATA group below.
                            ForEach(passed, id: \.element.name) { index, layer in
                                layerRow(layer: layer, index: index)
                            }
                        }
                        if !metadata.isEmpty {
                            // INFO emitters include OCR/spatial
                            // observations, not just Layer-5 metadata —
                            // "NOTES" covers the whole isInfo set.
                            sectionHeader("NOTES")
                            ForEach(metadata, id: \.element.name) { index, layer in
                                layerRow(layer: layer, index: index)
                            }
                        }
                    }
                }
                .padding(.horizontal, ResectaTokens.Spacing.sm)
                .padding(.bottom, ResectaTokens.Spacing.sm)
                // Routed
                // through the resolver so Reduce Motion swaps the slide
                // for an opacity-only crossfade.
                .transition(ResectaTokens.Anim.resolvedTransition(
                    standard: .opacity.combined(with: .move(edge: .top)),
                    reduceMotion: reduceMotion))
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(
            cornerRadius: ResectaTokens.CornerRadius.medium, style: .continuous))
        .frame(maxWidth: columnMaxWidth)
    }

    /// At the display surface: the generic skipped-row copy says the
    /// layer "was not applicable for this pipeline mode", but on the
    /// digest-less verify-only path the layer applies and merely lacked
    /// data — the user's actual remedy is a full re-run. One caption under
    /// the FINDINGS group names that remedy. Rendered only when a skipped
    /// layer is present on a WARN or skipped report (the layer copy itself
    /// belongs to the engine and is out of scope here).
    static let skippedChecksFootnoteText =
        "Skipped checks need data from a full redaction run — run Redact again to include them."

    /// Footnote visibility. Static so the condition is unit-testable
    /// without a SwiftUI host (mirrors `shouldAutoExpand`).
    static func shouldShowSkippedChecksFootnote(report: VerificationReport) -> Bool {
        report.layers.contains(where: \.status.isSkipped)
            && (report.overallStatus.isWarn
                || report.overallStatus.isAttention
                || report.overallStatus.isSkipped)
    }

    private var skippedChecksFootnote: some View {
        Text(Self.skippedChecksFootnoteText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Deselection row

    /// Row visibility: a snapshot with at least one deselected item.
    /// Zero-deselection runs (and runs with no live scan session at entry,
    /// where the snapshot is nil) render nothing — no noise. Static so the
    /// gate is unit-testable without a SwiftUI host (mirrors
    /// `shouldAutoExpand`).
    static func shouldShowDeselectionRow(
        snapshot: RedactionState.DeselectionSnapshot?
    ) -> Bool {
        (snapshot?.deselectedCount ?? 0) > 0
    }

    /// Row copy. States the user's own choice as a fact — no verdict
    /// language, since leaving items unredacted is a legitimate decision
    /// the verification checks do not evaluate. Static so tests pin the
    /// exact string.
    static func deselectionRowText(deselected: Int, total: Int) -> String {
        "You left \(deselected) of \(total) detected "
            + "\(total == 1 ? "item" : "items") unredacted."
    }

    @ViewBuilder
    private func deselectionRow(
        snapshot: RedactionState.DeselectionSnapshot
    ) -> some View {
        let rowText = Self.deselectionRowText(
            deselected: snapshot.deselectedCount, total: snapshot.totalCount)
        HStack(spacing: ResectaTokens.Spacing.sm) {
            Image(systemName: "checklist.unchecked")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)

            Text(rowText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let onReviewDeselections {
                Button("Review", action: onReviewDeselections)
                    .font(.caption.weight(.medium))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(
                        "Review deselected items. Returns to the editor and opens the scan coverage panel.")
            }
        }
        .padding(ResectaTokens.Spacing.sm)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(rowText)
        .accessibilityIdentifier("deselectionRow")
    }

    @ViewBuilder
    private func sectionHeader(_ label: String) -> some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, ResectaTokens.Spacing.xs)
    }

    @ViewBuilder
    private func layerRow(layer: LayerResult, index: Int) -> some View {
        LayerResultRow(
            layer: layer,
            layerIndex: index + 1,
            isExpanded: expandedLayer == index,
            onTap: {
                withAnimation(ResectaTokens.Anim.stateChange) {
                    expandedLayer = expandedLayer == index ? nil : index
                }
            },
            onPageTap: { pageIndex in
                documentState.currentPageIndex = pageIndex
                documentState.transition(to: .editing)
            }
        )
    }

    /// Closed-state summary line: counts vary by status per the plan lock.
    private var detailsSummary: String { Self.detailsSummaryText(for: report) }

    /// Static for exact-string test pinning (house pattern —
    /// `fallbackReasonRowText`). Pinned by `VerificationDisplayTests`.
    static func detailsSummaryText(for report: VerificationReport) -> String {
        let total = report.layers.count
        // "Passed" counts only .pass + .info (no actionable issue).
        // `.skipped` is surfaced separately below — never rolled into the
        // passed count. `.info` still rides here and also appears under the
        // METADATA group, preserving the prior shape.
        let passed = report.layers.filter { $0.status == .pass || $0.status.isInfo }.count
        let infoCount = report.layers.filter(\.status.isInfo).count
        let skippedCount = report.layers.filter(\.status.isSkipped).count
        // "· 1 metadata" read as a dangling adjective — name the
        // noun. "informational", not "metadata" — INFO rows include
        // OCR/spatial observations, and "informational" keeps the segment
        // distinct from the WARN arm's "· N note(s)".
        let metaSuffix = infoCount > 0
            ? " · \(infoCount) informational \(infoCount == 1 ? "note" : "notes")" : ""
        let skippedSuffix = skippedCount > 0 ? " · \(skippedCount) skipped" : ""
        switch report.overallStatus {
        case .pass, .info, .skipped:
            return "\(passed) of \(total) checks passed" + metaSuffix + skippedSuffix
        case .warn:
            // An overall WARN can now be skip-induced with zero
            // WARN layers — omit the notes segment in that case.
            // Under the "Completed with Notes" masthead, "4 of 5
            // checks passed" implied the noted check failed. "Completed"
            // keeps the arithmetic honest (a note is a note, not a
            // failure) without touching any verdict semantics; the
            // completed tally counts every layer that ran (WARN aggregate
            // carries no FAILs — fail forces the .fail arm below).
            let warnCount = report.layers.filter(\.status.isWarn).count
            let notesSuffix = warnCount > 0
                ? " · \(warnCount) \(warnCount == 1 ? "note" : "notes")" : ""
            let completed = total - skippedCount
            return "\(completed) of \(total) checks completed" + notesSuffix + metaSuffix + skippedSuffix
        case .attention:
            // ATTENTION aggregate carries no FAILs (fail forces the .fail arm
            // below) but may ride beside WARN notes — surface both segments.
            let attentionCount = report.layers.filter(\.status.isAttention).count
            let reviewSuffix = " · " + (attentionCount == 1
                ? "1 needs review" : "\(attentionCount) need review")
            let warnCount = report.layers.filter(\.status.isWarn).count
            let notesSuffix = warnCount > 0
                ? " · \(warnCount) \(warnCount == 1 ? "note" : "notes")" : ""
            return "\(passed) of \(total) checks passed" + reviewSuffix + notesSuffix + metaSuffix + skippedSuffix
        case .fail:
            let failCount = report.layers.filter(\.status.isFail).count
            let issuesSuffix = " · \(failCount) \(failCount == 1 ? "issue" : "issues")"
            return "\(passed) of \(total) checks passed" + issuesSuffix + metaSuffix + skippedSuffix
        }
    }

    // MARK: - Trust strip
    //
    // Mirrors HomeView's strip exactly ("On device · No tracking · Open
    // source") and is status-independent: the strip states standing facts
    // about the app, while the run's outcome lives in the status banner and
    // the footer. The former PASS/INFO-gated "Verification complete" item is
    // gone entirely, and with it the outcome-promise concern.

    private var trustStrip: some View {
        FlowLayout(spacing: ResectaTokens.Spacing.sm, alignment: .center) {
            TrustItem(label: "On device")
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

    // MARK: - Page Modes Section (verbatim from prior implementation)
    //
    // Collapsible section showing per-page pipeline mode breakdown. Only
    // rendered when modes are mixed (at least one page fell back). Follows
    // the LayerResultRow expand/collapse pattern. Lives inside the new
    // details disclosure; identifier preserved.

    @ViewBuilder
    private var pageModesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row (always visible)
            Button {
                withAnimation(ResectaTokens.Anim.stateChange) {
                    showPageModes.toggle()
                }
            } label: {
                HStack(spacing: ResectaTokens.Spacing.sm) {
                    Image(systemName: "square.2.layers.3d")
                        .font(.system(size: 20))
                        .foregroundStyle(ResectaTokens.SemanticColor.searchableMode)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                        Text("Page Modes")
                            .font(.subheadline.weight(.medium))
                        Text(modeChipSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showPageModes ? 90 : 0))
                }
                .padding(ResectaTokens.Spacing.sm)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Page Modes, \(modeChipSummary)")
            .accessibilityHint("Tap to \(showPageModes ? "collapse" : "expand") details")

            // Expanded: color-coded page chips
            if showPageModes {
                VStack(alignment: .leading, spacing: ResectaTokens.Spacing.sm) {
                    FlowLayout(spacing: ResectaTokens.Spacing.xs) {
                        ForEach(Array(report.perPageModes.enumerated()), id: \.offset) { index, mode in
                            Button {
                                documentState.currentPageIndex = index
                                documentState.transition(to: .editing)
                            } label: {
                                Text("\(index + 1)")
                                    .font(.caption.monospacedDigit())
                                    // Searchable chips carry blue-family
                                    // small TEXT → AA text tier; rasterized chips
                                    // keep .secondary via badgeColor. The 0.1 wash
                                    // below stays on the glyph/fill tier.
                                    .foregroundStyle(
                                        mode == .searchableRedaction
                                            ? ResectaTokens.SemanticColor.infoText
                                            : mode.badgeColor
                                    )
                                    .padding(.horizontal, ResectaTokens.Spacing.xs)
                                    .padding(.vertical, ResectaTokens.Spacing.xxs)
                                    .background(
                                        mode.badgeColor.opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: ResectaTokens.CornerRadius.small, style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                Self.pageChipAccessibilityLabel(
                                    pageNumber: index + 1, mode: mode,
                                    reason: fallbackReason(at: index))
                            )
                        }
                    }

                    // Legend
                    HStack(spacing: ResectaTokens.Spacing.md) {
                        // Caption2 legend text takes the AA text-tier
                        // blue; the glyph keeps the searchableMode tint (glyph tier).
                        Label {
                            Text("Searchable")
                                .foregroundStyle(ResectaTokens.SemanticColor.infoText)
                        } icon: {
                            PipelineMode.searchableRedaction.glyph
                                .foregroundStyle(ResectaTokens.SemanticColor.searchableMode)
                        }
                        .font(.caption2)
                        Label {
                            Text("Rasterized")
                        } icon: {
                            PipelineMode.secureRasterization.glyph
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    // Why each rasterized page fell back, for
                    // Searchable-mode runs only (secure-raster runs carry no
                    // reasons — every page rasterized by choice). One caption
                    // row per fallback page, same factual register as the
                    // legend above.
                    if report.perPageFallbackReasons.hasAnyFallbackReason {
                        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                            ForEach(
                                Array(report.perPageFallbackReasons.enumerated())
                                    .compactMap { index, reason in
                                        reason.map { (index: index, reason: $0) }
                                    },
                                id: \.index
                            ) { entry in
                                Text(Self.fallbackReasonRowText(
                                    pageNumber: entry.index + 1,
                                    reason: entry.reason))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, ResectaTokens.Spacing.sm)
                .padding(.bottom, ResectaTokens.Spacing.sm)
                // Routed
                // through the resolver so Reduce Motion swaps the slide
                // for an opacity-only crossfade.
                .transition(ResectaTokens.Anim.resolvedTransition(
                    standard: .opacity.combined(with: .move(edge: .top)),
                    reduceMotion: reduceMotion))
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(
            cornerRadius: ResectaTokens.CornerRadius.medium, style: .continuous))
        .accessibilityIdentifier("pageModesSection")
    }

    private var modeChipSummary: String {
        let modes = report.perPageModes
        let searchable = modes.count(where: { $0 == .searchableRedaction })
        let secure = modes.count - searchable
        return "\(searchable) Searchable, \(secure) Rasterized"
    }

    /// The report's fallback reason for a page index, nil when the
    /// reasons array is absent (old-session verify-only resume) or shorter
    /// than the mode array.
    private func fallbackReason(at index: Int) -> TextLayerDetector.FallbackReason? {
        guard report.perPageFallbackReasons.indices.contains(index) else { return nil }
        return report.perPageFallbackReasons[index]
    }

    /// Fallback-reason row copy. Static so tests pin the exact string (mirrors
    /// `deselectionRowText`).
    static func fallbackReasonRowText(
        pageNumber: Int, reason: TextLayerDetector.FallbackReason
    ) -> String {
        "Page \(pageNumber) — Rasterized — \(reason.shortReasonText)"
    }

    /// Chip VoiceOver label: carries the fallback reason when the page has
    /// one, so the reason rows below are not the only disclosure surface.
    static func pageChipAccessibilityLabel(
        pageNumber: Int, mode: PipelineMode,
        reason: TextLayerDetector.FallbackReason?
    ) -> String {
        if let reason {
            return "Page \(pageNumber), \(mode.shortDisplayName) — \(reason.shortReasonText)"
        }
        return "Page \(pageNumber), \(mode.shortDisplayName)"
    }
}
