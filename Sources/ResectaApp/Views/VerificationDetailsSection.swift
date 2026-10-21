import SwiftUI
import RedactionEngine

// The Verification Details disclosure of the results screen: the header
// row and, expanded, the page-modes section, the deselection row and the
// per-layer rows grouped by outcome — Findings → Could not verify → Notes →
// Nothing to check → the pass cluster. Moved out of
// `VerificationResultsView` (the page stack stays there): the parent keeps
// the auto-expand state (`detailsExpanded` + `didAutoExpand` +
// `shouldAutoExpand`) and threads it in as `isExpanded`; this view owns
// which layer row is open, whether the pass cluster is open and whether
// the page-modes section is open. The static copy builders the display
// tests pin (`detailsSummaryText(for:)`, the deselection / fallback-reason
// strings) stay on `VerificationResultsView`, in the extension at the
// bottom of this file.

struct VerificationDetailsSection: View {
    let report: VerificationReport
    /// Deselection facts captured at run entry (see
    /// `VerificationResultsView.deselectionSnapshot`).
    let deselectionSnapshot: RedactionState.DeselectionSnapshot?
    /// The disclosure's open state — owned by the parent, which auto-expands
    /// it on appear per `VerificationResultsView.shouldAutoExpand`.
    @Binding var isExpanded: Bool
    /// The page column's width cap (`VerificationResultsView.columnMaxWidth`).
    let columnMaxWidth: CGFloat?

    @Environment(DocumentState.self) private var documentState
    // The header tile's wash is per appearance (tileWashLight / tileWashDark).
    @Environment(\.colorScheme) private var colorScheme
    // Routes the
    // page-modes / layer-detail `.move(edge:)` transitions through
    // `Anim.resolvedTransition`.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // At accessibility sizes the header stacks: the tile, then the title
    // and the chevron, then the summary.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var expandedLayer: Int?
    @State private var showPageModes = false
    /// The pass cluster's open state once the user has toggled it; until
    /// then it is open exactly when nothing sits above it.
    @State private var clusterExpanded: Bool?

    /// The Page Modes and deselection rows' icon column: the hairline
    /// between them insets past it and the icon's gap.
    @ScaledMetric(relativeTo: .title3) private var iconColumn: CGFloat = 30
    /// Their icon's point size, scaling with the column.
    @ScaledMetric(relativeTo: .title3) private var iconSize: CGFloat = 20
    /// The layer rows' glyph and mark columns (`LayerResultRow.column`, the
    /// same metric): the hairlines between rows inset past both and their
    /// gaps, so they start where the row titles start.
    @ScaledMetric(relativeTo: .subheadline) private var rowColumn: CGFloat = 20

    private var hairlineInset: CGFloat { iconColumn + ResectaTokens.Spacing.sm }
    private var rowHairlineInset: CGFloat { 2 * (rowColumn + ResectaTokens.Spacing.sm) }

    /// The header's teal tile, scaling with the headline it sits beside.
    /// 36 pt with 12 pt of padding is the measured ceiling that keeps the
    /// PASS summary on one line and the timing line above the 6.3″ fold.
    @ScaledMetric(relativeTo: .headline) private var headerTile: CGFloat = 36

    // MARK: - Details disclosure
    //
    // Phase 2 lock: collapsed by default; closed-state row carries the
    // pass/note/issue summary; chevron rotates 90° on expand (mirrors the
    // pageModesSection pattern). The header is a mini-card in the action
    // cards' grammar: the brand glyph on a teal tile, the title and the
    // summary, one chevron; the card's material and shadow are the
    // HomeChoiceCardButtonStyle chrome minus the press scale — a
    // disclosure, not a navigation card.

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(ResectaTokens.Anim.stateChange) {
                    isExpanded.toggle()
                }
            } label: {
                headerLabel
            }
            .buttonStyle(.plain)
            .accessibilityLabel(VerificationResultsView.detailsHeaderAccessibilityLabel(for: report))
            .accessibilityHint(isExpanded ? "Hides the checks" : "Shows the checks")

            if isExpanded {
                groups
            }
        }
        // One material for the whole disclosure (the rows inside are flat).
        // The shadow sits on the background shape itself: a `.shadow` on
        // the whole view would also be cast by every opaque child.
        .background {
            RoundedRectangle(cornerRadius: ResectaTokens.CornerRadius.card, style: .continuous)
                .fill(.regularMaterial)
                .shadow(
                    color: ResectaTokens.Shadow.subtle.color,
                    radius: ResectaTokens.Shadow.subtle.radius,
                    x: ResectaTokens.Shadow.subtle.x,
                    y: ResectaTokens.Shadow.subtle.y)
        }
        .frame(maxWidth: columnMaxWidth)
    }

    // MARK: - The header

    /// The brand glyph on the tile wash (the HomeChoiceCardContent
    /// subtle-tile rule).
    private var headerTileView: some View {
        Image(systemName: "list.bullet.rectangle")
            .font(.body.weight(.semibold))
            .foregroundStyle(ResectaTokens.BrandTeal.text)
            .frame(width: headerTile, height: headerTile)
            .background(
                ResectaTokens.BrandTeal.tint.opacity(
                    colorScheme == .dark
                        ? ResectaTokens.Opacity.tileWashDark
                        : ResectaTokens.Opacity.tileWashLight),
                in: RoundedRectangle(cornerRadius: ResectaTokens.CornerRadius.medium, style: .continuous))
    }

    private var headerSummary: some View {
        Text(detailsSummary)
            .font(.caption)
            .foregroundStyle(ResectaTokens.SemanticColor.supportText)
    }

    /// The tile, the title over the summary, one chevron. At accessibility
    /// sizes "Verification Details" alone is wider than the column beside
    /// the tile, so the header stacks: the tile, the title and the chevron,
    /// the summary.
    @ViewBuilder
    private var headerLabel: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: ResectaTokens.Spacing.sm) {
                headerTileView
                HStack(alignment: .firstTextBaseline, spacing: ResectaTokens.Spacing.sm) {
                    Text("Verification Details")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DisclosureChevron(isExpanded: isExpanded, tint: ResectaTokens.BrandTeal.text)
                }
                headerSummary
            }
            .padding(ResectaTokens.Spacing.sm + ResectaTokens.Spacing.xs)
            .contentShape(Rectangle())
        } else {
            HStack(spacing: ResectaTokens.Spacing.md) {
                headerTileView

                // The text column takes the width a Spacer would have
                // taken — a Spacer costs its minimum length plus two
                // HStack gaps and wraps the PASS summary onto two lines
                // at 402 pt. The summary is caption-sized: at footnote
                // size "5 of 5 checks passed · 2 informational notes"
                // needs ≈ 270 pt against the 262-pt column and wraps
                // (measured on the iPhone 17 simulator, 2026-09-24);
                // at caption size it is one line and the header 60 pt.
                VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xs) {
                    Text("Verification Details")
                        .font(.headline)
                    headerSummary
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                DisclosureChevron(isExpanded: isExpanded, tint: ResectaTokens.BrandTeal.text)
                    .frame(width: 16)
            }
            // 12 pt: the disclosure's own row pads tighter than the
            // 16 pt action cards above it; with the 36 pt tile this
            // keeps the timing line ≈31 pt above the 6.3″ fold.
            .padding(ResectaTokens.Spacing.sm + ResectaTokens.Spacing.xs)
            .contentShape(Rectangle())
        }
    }

    // MARK: - The groups

    /// Groups, 24 pt apart; inside a group the header hugs its rows and the
    /// rows sit flat, a hairline between them.
    private var groups: some View {
        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.lg) {
            // Page Modes and the deselection row are one item.
            //
            // Deselection visibility at share time: a PASS
            // legitimately says "without issues" — the checks ran
            // on what was redacted, not on what the user chose to
            // leave. When the run started with known scan results
            // deliberately un-checked, say so here, at the surface
            // where the share decision is made.
            let showsDeselection = VerificationResultsView.shouldShowDeselectionRow(
                snapshot: deselectionSnapshot)
            if report.perPageModes.hasMixedModes || showsDeselection {
                VStack(alignment: .leading, spacing: 0) {
                    if report.perPageModes.hasMixedModes {
                        pageModesSection
                    }
                    if report.perPageModes.hasMixedModes, showsDeselection {
                        hairline
                    }
                    if showsDeselection, let snapshot = deselectionSnapshot {
                        deselectionRow(snapshot: snapshot)
                    }
                }
            }

            // The layers grouped by outcome — one enumeration
            // (`VerificationLayerPartition`), engine order inside each
            // group: what needs attention first, then the checks that could
            // not verify part of the output (Share asks before sending),
            // then the notes and the checks with nothing to check, then one
            // row for the checks that passed. `layerIndex` stays
            // engine-position-based (1-indexed) so the identifier
            // "layerResult_\(layerIndex - 1)" stays stable across grouping;
            // the rows are keyed by that index.
            let partition = VerificationLayerPartition(
                layers: report.layers, perPageModes: report.perPageModes)
            ForEach(Self.groups(partition), id: \.header) { group in
                VStack(alignment: .leading, spacing: 0) {
                    sectionHeader(group.header, count: group.indices.count)
                    layerRows(group.indices)
                }
            }
            if !partition.cluster.isEmpty {
                passCluster(partition)
            }
        }
        // The content column pads like the action cards (16 pt);
        // the flat rows inside carry no horizontal padding of their
        // own, so the row columns, the hairlines and the group
        // headers all measure from this edge.
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.bottom, ResectaTokens.Spacing.md)
        // Routed
        // through the resolver so Reduce Motion swaps the slide
        // for an opacity-only crossfade.
        .transition(ResectaTokens.Anim.resolvedTransition(
            standard: .opacity.combined(with: .move(edge: .top)),
            reduceMotion: reduceMotion))
    }

    /// One row in the layer rows' anatomy — the pass mark, "N checks
    /// passed", a chevron — that opens to the passing checks (and the notes
    /// with nothing remaining). Open by default only when nothing sits
    /// above it; collapsing it closes an open member.
    @ViewBuilder
    private func passCluster(_ partition: VerificationLayerPartition) -> some View {
        let isOpen = clusterExpanded ?? partition.isWhollyClean
        let clusterTitle = partition.clusterTitle
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(ResectaTokens.Anim.stateChange) {
                    if isOpen, let open = expandedLayer, partition.cluster.contains(open) {
                        expandedLayer = nil
                    }
                    clusterExpanded = !isOpen
                }
            } label: {
                HStack(alignment: .top, spacing: ResectaTokens.Spacing.sm) {
                    // The glyph column stays empty: the cluster names no
                    // single check.
                    Color.clear.frame(width: rowColumn, height: rowColumn)
                    Image(systemName: VerificationOutcome.passed.markSymbolName)
                        .font(.system(size: rowColumn, weight: .semibold))
                        .foregroundStyle(VerificationOutcome.passed.textColor)
                        .frame(width: rowColumn, height: rowColumn)
                    Text(clusterTitle)
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DisclosureChevron(isExpanded: isOpen)
                        .frame(width: 16, height: rowColumn)
                }
                .padding(.vertical, ResectaTokens.Spacing.sm + ResectaTokens.Spacing.xxs)
                .frame(minHeight: ResectaTokens.TouchTarget.minimum)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(partition.clusterSpokenLabel)
            .accessibilityHint(isOpen ? "Hides the passed checks" : "Shows the passed checks")
            .accessibilityIdentifier("passedChecksCluster")

            if isOpen {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(partition.cluster, id: \.self) { index in
                        rowHairline
                        layerRow(layer: report.layers[index], index: index)
                    }
                }
                // Opacity only: the members appear in place.
                .transition(.opacity)
            }
        }
    }

    // MARK: - Deselection row

    @ViewBuilder
    private func deselectionRow(
        snapshot: RedactionState.DeselectionSnapshot
    ) -> some View {
        let rowText = VerificationResultsView.deselectionRowText(
            deselected: snapshot.deselectedCount, total: snapshot.totalCount)
        HStack(spacing: ResectaTokens.Spacing.sm) {
            // The glyph on a neutral tile, the rows' icon column wide — a
            // fact about the run, not a status.
            Image(systemName: "checklist.unchecked")
                .font(.system(size: iconSize))
                .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                .frame(width: iconColumn, height: iconColumn)
                .background(
                    Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: ResectaTokens.CornerRadius.small, style: .continuous))
                .accessibilityHidden(true)

            Text(rowText)
                .font(.caption)
                .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, ResectaTokens.Spacing.sm)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(rowText)
        .accessibilityIdentifier("deselectionRow")
    }

    /// The groups above the cluster, in screen order, each with its rows'
    /// engine indices; an empty group is left out.
    static func groups(_ partition: VerificationLayerPartition) -> [(header: String, indices: [Int])] {
        [
            ("Findings", partition.findings),
            ("Could not verify", partition.couldNotVerify),
            ("Notes", partition.notes),
            ("Nothing to check", partition.nothingToCheck),
        ].filter { !$0.1.isEmpty }
    }

    /// A group's header with its count, one VoiceOver header.
    private func sectionHeader(_ header: String, count: Int) -> some View {
        Text(VerificationLayerPartition.sectionHeader(header, count: count))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(ResectaTokens.SemanticColor.supportText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, ResectaTokens.Spacing.xs)
            .accessibilityLabel(VerificationLayerPartition.sectionHeaderSpoken(header, count: count))
            .accessibilityAddTraits(.isHeader)
    }

    /// The hairline between the Page Modes section and the deselection
    /// row: inset past their icon column.
    private var hairline: some View {
        Divider().padding(.leading, hairlineInset)
    }

    /// The hairline between two layer rows: inset to the row titles.
    private var rowHairline: some View {
        Divider().padding(.leading, rowHairlineInset)
    }

    /// The rows for a group's engine indices, flat, a hairline between
    /// consecutive rows; the section owns the hairlines, the rows none.
    @ViewBuilder
    private func layerRows(_ indices: [Int]) -> some View {
        ForEach(Array(indices.enumerated()), id: \.element) { position, index in
            if position > 0 {
                rowHairline
            }
            layerRow(layer: report.layers[index], index: index)
        }
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
            },
            chrome: .plain,
            perPageModes: report.perPageModes
        )
    }

    /// Closed-state summary line: only passing checks count as passed.
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
                        .font(.system(size: iconSize))
                        .foregroundStyle(ResectaTokens.SemanticColor.searchableMode)
                        .frame(width: iconColumn)

                    VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                        Text("Page Modes")
                            .font(.subheadline.weight(.medium))
                        Text(modeChipSummary)
                            .font(.caption)
                            .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    }

                    Spacer()

                    DisclosureChevron(isExpanded: showPageModes)
                        .frame(width: 16)
                }
                .padding(.vertical, ResectaTokens.Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Page Modes, \(modeChipSummary)")
            .accessibilityHint(showPageModes ? "Hides details" : "Shows details")

            // Expanded: color-coded page chips
            if showPageModes {
                hairline
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
                        .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    }

                    // Why each rasterized page fell back, for
                    // Searchable-mode runs only (secure-raster runs carry no
                    // reasons — every page rasterized by choice). One caption
                    // row per fallback page, same factual register as the
                    // legend above.
                    if report.perPageFallbackReasons.hasAnyFallbackReason {
                        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                            ForEach(
                                VerificationResultsView.fallbackReasonRowTexts(
                                    reasons: report.perPageFallbackReasons),
                                id: \.self
                            ) { line in
                                Text(line)
                                    .font(.caption2)
                                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                            }
                        }
                    }
                }
                .padding(.vertical, ResectaTokens.Spacing.sm)
                // Routed
                // through the resolver so Reduce Motion swaps the slide
                // for an opacity-only crossfade.
                .transition(ResectaTokens.Anim.resolvedTransition(
                    standard: .opacity.combined(with: .move(edge: .top)),
                    reduceMotion: reduceMotion))
            }
        }
        // Flat inside the disclosure card — no nested material.
        .accessibilityIdentifier("pageModesSection")
    }

    private var modeChipSummary: String {
        VerificationResultsView.pageModesSummaryText(modes: report.perPageModes)
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
    /// Row visibility: a snapshot with at least one deselected item. The
    /// row stands beside the Detection Sweep row on every report: the
    /// sweep's line counts only the deselected items it re-detected in the
    /// categories it reads, so the user's own count is stated here in
    /// full (a swept item may be counted on both lines). Zero-deselection
    /// runs (and runs with no live scan session at entry, where the
    /// snapshot is nil) render nothing — no noise. Static so the gate is
    /// unit-testable without a SwiftUI host (mirrors `shouldAutoExpand`).
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

    /// The header's summary line — "{P} of {T} checks passed", where only
    /// a passing check counts as passed, then one clause per other outcome
    /// present (`VerificationLayerPartition.summaryText`). Static for
    /// exact-string test pinning (house pattern — `fallbackReasonRowText`).
    /// Pinned by `VerificationDisplayTests`.
    static func detailsSummaryText(for report: VerificationReport) -> String {
        VerificationLayerPartition(layers: report.layers, perPageModes: report.perPageModes).summaryText
    }

    /// The header's spoken label: "Verification Details. 7 of 12 checks
    /// passed. 1 needs review, 1 warning, …" — line 2's dots spoken as
    /// commas.
    static func detailsHeaderAccessibilityLabel(for report: VerificationReport) -> String {
        let partition = VerificationLayerPartition(layers: report.layers, perPageModes: report.perPageModes)
        var label = "Verification Details. \(partition.summaryLine1)."
        if let line2 = partition.summaryLine2 {
            label += " " + line2.replacingOccurrences(of: " · ", with: ", ") + "."
        }
        return label
    }

    /// The Page Modes summary: "2 Searchable, 1 Rasterized", a zero clause
    /// dropped ("3 Rasterized").
    static func pageModesSummaryText(modes: [PipelineMode]) -> String {
        let searchable = modes.count(where: { $0 == .searchableRedaction })
        let rasterized = modes.count - searchable
        return [
            searchable > 0 ? "\(searchable) Searchable" : nil,
            rasterized > 0 ? "\(rasterized) Rasterized" : nil,
        ].compactMap { $0 }.joined(separator: ", ")
    }

    /// Fallback-reason row copy. Static so tests pin the exact string (mirrors
    /// `deselectionRowText`).
    static func fallbackReasonRowText(
        pageNumber: Int, reason: TextLayerDetector.FallbackReason
    ) -> String {
        "Page \(pageNumber) · Rasterized · \(reason.shortReasonText)"
    }

    /// The fallback lines, one per page, a run of three or more
    /// consecutive pages with the same reason as one line: "Pages 1–200 ·
    /// Rasterized · vertical text".
    static func fallbackReasonRowTexts(
        reasons: [TextLayerDetector.FallbackReason?]
    ) -> [String] {
        var lines: [String] = []
        var index = 0
        while index < reasons.count {
            guard let reason = reasons[index] else { index += 1; continue }
            var end = index
            while end + 1 < reasons.count, reasons[end + 1]?.shortReasonText == reason.shortReasonText { end += 1 }
            if end - index >= 2 {
                lines.append("Pages \(index + 1)\u{2013}\(end + 1) · Rasterized · \(reason.shortReasonText)")
            } else {
                for page in index...end {
                    lines.append(fallbackReasonRowText(pageNumber: page + 1, reason: reason))
                }
            }
            index = end + 1
        }
        return lines
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
