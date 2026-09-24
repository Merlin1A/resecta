import SwiftUI
import RedactionEngine

// The Verification Details disclosure of the results screen: the header
// row and, expanded, the page-modes section, the deselection row and the
// per-layer rows grouped FINDINGS → clean → NOTES. Moved out of
// `VerificationResultsView` (the page stack stays there): the parent keeps
// the auto-expand state (`detailsExpanded` + `didAutoExpand` +
// `shouldAutoExpand`) and threads it in as `isExpanded`; this view owns
// which layer row is open and whether the page-modes section is open.
// The static copy builders the display tests pin
// (`detailsSummaryText(for:)`, the footnote / deselection / fallback-reason
// strings) stay on `VerificationResultsView`, in the extension at the
// bottom of this file.

struct VerificationDetailsSection: View {
    let report: VerificationReport
    /// Deselection facts captured at run entry (see
    /// `VerificationResultsView.deselectionSnapshot`).
    let deselectionSnapshot: RedactionState.DeselectionSnapshot?
    /// Tap handler for the deselection row's Review affordance; nil hides
    /// the affordance (see `VerificationResultsView.onReviewDeselections`).
    let onReviewDeselections: (() -> Void)?
    /// The disclosure's open state — owned by the parent, which auto-expands
    /// it on appear per `VerificationResultsView.shouldAutoExpand`.
    @Binding var isExpanded: Bool
    /// The page column's width cap (`VerificationResultsView.columnMaxWidth`).
    let columnMaxWidth: CGFloat?

    @Environment(DocumentState.self) private var documentState
    // Routes the
    // page-modes / layer-detail `.move(edge:)` transitions through
    // `Anim.resolvedTransition`.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var expandedLayer: Int?
    @State private var showPageModes = false

    // MARK: - Details disclosure
    //
    // Phase 2 lock: collapsed by default; closed-state row carries the
    // pass/note/issue summary; chevron rotates 90° on expand (mirrors the
    // pageModesSection pattern). The existing pageModesSection body and
    // the ForEach(LayerResultRow) body are preserved verbatim inside.

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(ResectaTokens.Anim.stateChange) {
                    isExpanded.toggle()
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
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(ResectaTokens.Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Verification Details, \(detailsSummary)")
            .accessibilityHint(isExpanded ? "Tap to collapse" : "Tap to expand")

            if isExpanded {
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
                    if VerificationResultsView.shouldShowDeselectionRow(
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
                            if VerificationResultsView.shouldShowSkippedChecksFootnote(report: report) {
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

    private var skippedChecksFootnote: some View {
        Text(VerificationResultsView.skippedChecksFootnoteText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Deselection row

    @ViewBuilder
    private func deselectionRow(
        snapshot: RedactionState.DeselectionSnapshot
    ) -> some View {
        let rowText = VerificationResultsView.deselectionRowText(
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
    private var detailsSummary: String { VerificationResultsView.detailsSummaryText(for: report) }

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
                                VerificationResultsView.pageChipAccessibilityLabel(
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
                                Text(VerificationResultsView.fallbackReasonRowText(
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
}

// MARK: - The pinned copy builders (stay on VerificationResultsView)
//
// Static so the display tests pin the exact strings without a SwiftUI
// host; kept on the parent type so no test call site moves with the view.

extension VerificationResultsView {
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
