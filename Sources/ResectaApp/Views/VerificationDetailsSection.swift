import SwiftUI
import RedactionEngine

// The results page's check sections, below the actions: Findings → Could
// not verify → Notes → Nothing to check, each with its count; the
// headerless card of facts about the PDF (handed-in facts, the run's own
// lines, Page Modes, the deselection row: `ResultsFactCard.items`);
// then one row for the checks that passed, on every run with a passed check
// or a riding note, which a tap opens to those checks. One item is open at
// a time across the rows and
// Page Modes. A page link asks the results view to push the Preview at
// that page; it never changes the phase. The static copy builders the
// display tests pin stay on `VerificationResultsView`, in the extension at
// the bottom of this file.

struct VerificationDetailsSection: View {
    let report: VerificationReport
    /// Deselection facts captured at run entry (see
    /// `VerificationResultsView.deselectionSnapshot`).
    let deselectionSnapshot: RedactionState.DeselectionSnapshot?
    /// The run facts' lines (`VerificationResultsView.RunFactsStrip`).
    var runFactsLines: [String] = []
    /// Page links show — and open the Preview — only while the redacted PDF
    /// exists; otherwise the captions carry the pages.
    var previewAvailable: Bool = false
    /// Push the Preview at a page (0-based) on the results view's stack.
    var onOpenPage: (Int) -> Void = { _ in }
    /// Back to the editor with Scan running (the sweep's Review in Scan).
    var onReviewInScan: () -> Void = {}
    /// Facts handed in for the card, each placed by its `place`.
    var facts: [ResultsFact] = []
    /// A fact's link row was tapped (the fact's id).
    var onOpenDoor: (String) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// The one open item: a row (by engine index) or Page Modes.
    enum OpenItem: Hashable {
        case layer(Int)
        case pageModes
        case fact(String)
    }

    @State private var openItem: OpenItem?
    /// The pass cluster's open state once the user has toggled it; until
    /// then `clusterOpensByDefault`.
    @State private var clusterExpanded: Bool?

    var body: some View {
        let partition = VerificationLayerPartition(layers: report.layers, perPageModes: report.perPageModes)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.groups(partition), id: \.header) { group in
                GroupedSection(
                    header: VerificationLayerPartition.sectionHeader(group.header, count: group.indices.count),
                    spokenHeader: VerificationLayerPartition.sectionHeaderSpoken(group.header, count: group.indices.count)
                ) {
                    layerRows(group.indices, layout: .lead, showsStatusWord: group.header == "Findings")
                }
                .padding(.top, ResectaTokens.Results.blockGap)
            }
            let card = cardItems
            if !card.isEmpty {
                GroupedSection { factCard(card) }
                    .padding(.top, ResectaTokens.Spacing.xl)
            }
            if !Self.listRowMembers(partition).isEmpty {
                GroupedSection { passCluster(partition) }
                    .padding(.top, ResectaTokens.Spacing.xl)
            }
        }
    }

    // MARK: - The rules

    /// The groups above the cluster, in screen order, each with its rows'
    /// engine indices; an empty group is left out. While the list row
    /// exists the checks that had nothing to check are inside it, so their
    /// group is drawn only on a run with no list row.
    static func groups(_ partition: VerificationLayerPartition) -> [(header: String, indices: [Int])] {
        [
            ("Findings", partition.findings),
            ("Could not verify", partition.couldNotVerify),
            ("Notes", partition.notes),
            ("Nothing to check", partition.cluster.isEmpty ? partition.nothingToCheck : []),
        ].filter { !$0.1.isEmpty }
    }

    /// The checks the list row opens to, by engine index, in the checks'
    /// own order: the passed checks, the notes riding with them and the
    /// checks that had nothing to check. A run with no passed check and no
    /// riding note has no row. The row is drawn exactly when this is not
    /// empty.
    static func listRowMembers(_ partition: VerificationLayerPartition) -> [Int] {
        partition.cluster.isEmpty ? [] : (partition.cluster + partition.nothingToCheck).sorted()
    }

    /// A member's row: a passed check has no mark; a riding note and a
    /// check that had nothing to check keep their mark and their caption.
    static func memberLayout(_ outcome: VerificationOutcome) -> LayerResultRow.GroupedLayout {
        outcome == .passed ? .member : .lead
    }

    /// The open item after the list row is tapped: closing the list closes
    /// whichever of its members is open; any other open item stays.
    static func openItemAfterTogglingList(isOpen: Bool, openItem: OpenItem?,
                                          partition: VerificationLayerPartition) -> OpenItem? {
        if isOpen, case .layer(let open) = openItem, listRowMembers(partition).contains(open) { return nil }
        return openItem
    }

    /// The cluster opens by default only when it holds riding notes and no
    /// result section sits above it (the run section does not count).
    static func clusterOpensByDefault(_ partition: VerificationLayerPartition) -> Bool {
        partition.isWhollyClean && partition.clusterNoteCount > 0
    }

    /// The one open item after a tap: the tapped item opens and whatever
    /// was open closes; tapping the open item closes it.
    static func openItem(afterTapping item: OpenItem, current: OpenItem?) -> OpenItem? {
        current == item ? nil : item
    }

    private func toggle(_ item: OpenItem) {
        withAnimation(ResectaTokens.Anim.resolved(ResectaTokens.Anim.stateChange, reduceMotion: reduceMotion)) {
            openItem = Self.openItem(afterTapping: item, current: openItem)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func layerRows(_ indices: [Int], layout: LayerResultRow.GroupedLayout, showsStatusWord: Bool) -> some View {
        ForEach(Array(indices.enumerated()), id: \.element) { position, index in
            if position > 0 {
                GroupedRowDivider(inset: ResectaTokens.Results.titleInset)
            }
            layerRow(index: index, layout: layout, showsStatusWord: showsStatusWord)
        }
    }

    private func layerRow(index: Int, layout: LayerResultRow.GroupedLayout, showsStatusWord: Bool) -> some View {
        LayerResultRow(
            layer: report.layers[index],
            layerIndex: index + 1,
            isExpanded: openItem == .layer(index),
            onTap: { toggle(.layer(index)) },
            onPageTap: { page in onOpenPage(page) },
            onReviewInScan: onReviewInScan,
            chrome: .grouped,
            perPageModes: report.perPageModes,
            groupedLayout: layout,
            showsStatusWord: showsStatusWord,
            pagesOnChips: previewAvailable
        )
    }

    // MARK: - The pass cluster

    /// One row — the pass mark, "N checks passed[ · k notes][ · i had
    /// nothing to check]", a chevron — that opens to its members. The
    /// clauses follow on the title's line when the whole title fits, and
    /// go on a second line in the caption grey when it does not.
    /// Collapsing it closes an open member.
    @ViewBuilder
    private func passCluster(_ partition: VerificationLayerPartition) -> some View {
        let isOpen = clusterExpanded ?? Self.clusterOpensByDefault(partition)
        let members = Self.listRowMembers(partition)
        Button {
            withAnimation(ResectaTokens.Anim.resolved(ResectaTokens.Anim.stateChange, reduceMotion: reduceMotion)) {
                openItem = Self.openItemAfterTogglingList(isOpen: isOpen, openItem: openItem, partition: partition)
                clusterExpanded = !isOpen
            }
        } label: {
            HStack(spacing: 0) {
                // A fixed size, as the marks of the rows around it: at the
                // largest text sizes a tick that grew with the text outgrew
                // its column.
                Image(systemName: "checkmark")
                    .font(.system(size: ResectaTokens.Results.clusterTick, weight: .semibold))
                    .foregroundStyle(VerificationOutcome.passed.textColor)
                    .frame(width: ResectaTokens.Results.leadColumn)
                    .padding(.leading, ResectaTokens.Spacing.md)
                    .padding(.trailing, ResectaTokens.Results.titleInset
                             - ResectaTokens.Spacing.md - ResectaTokens.Results.leadColumn)
                ViewThatFits(in: .horizontal) {
                    Text(partition.clusterTitle)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                        Text(partition.clusterTitleBase)
                            .font(.body)
                            .foregroundStyle(.primary)
                        if !partition.clusterTitleClauses.isEmpty {
                            Text(partition.clusterTitleClauses.joined(separator: " · "))
                                .font(.subheadline)
                                .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                DisclosureChevron(isExpanded: isOpen, tint: Color(.secondaryLabel))
                    .frame(width: ResectaTokens.Results.chevronColumn)
                    .padding(.leading, ResectaTokens.Spacing.sm)
                    .padding(.trailing, ResectaTokens.Spacing.md)
            }
            .padding(.vertical, ResectaTokens.Results.rowVerticalPadding)
            .frame(minHeight: ResectaTokens.Results.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(ResultsRowButtonStyle())
        .accessibilityLabel(partition.clusterSpokenLabel)
        .accessibilityHint(isOpen ? "Hides the passed checks" : "Shows the passed checks")
        .accessibilityIdentifier("passedChecksCluster")
        if isOpen {
            ForEach(members, id: \.self) { index in
                GroupedRowDivider()
                layerRow(index: index, layout: Self.memberLayout(partition.outcomes[index]),
                         showsStatusWord: false)
            }
            .transition(.opacity)
        }
    }

    // MARK: - The card of facts

    /// The run's own lines as facts, in their order: each line whole, with
    /// nothing behind a tap. The first carries the `runFactsStrip`
    /// identifier.
    static func runLineFacts(_ lines: [String]) -> [ResultsFact] {
        lines.enumerated().map { position, line in
            ResultsFact(id: position == 0 ? "runFactsStrip" : "runFactsLine_\(position)", shown: line)
        }
    }

    /// The row about items left unredacted, when it shows.
    static func deselectionFact(snapshot: RedactionState.DeselectionSnapshot?) -> ResultsFact? {
        guard VerificationResultsView.shouldShowDeselectionRow(snapshot: snapshot), let snapshot else { return nil }
        return deselectionFact(deselected: snapshot.deselectedCount, total: snapshot.totalCount)
    }

    /// The row's fact for these counts: the shipped sentence, nothing to open.
    static func deselectionFact(deselected: Int, total: Int) -> ResultsFact {
        ResultsFact(id: "deselectionRow",
                    shown: VerificationResultsView.deselectionRowText(deselected: deselected, total: total))
    }

    private var cardItems: [ResultsCardItem] {
        ResultsFactCard.items(
            handedIn: facts, runLines: Self.runLineFacts(runFactsLines),
            showsPageModes: VerificationResultsView.showsPageModes(report: report),
            deselection: Self.deselectionFact(snapshot: deselectionSnapshot))
    }

    @ViewBuilder
    private func factCard(_ items: [ResultsCardItem]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { position, item in
            if position > 0 { GroupedRowDivider(inset: ResectaTokens.Spacing.md) }
            switch item {
            case .pageModes:
                pageModesRow
            case .fact(let fact):
                ResultsFactRow(fact: fact, isOpen: openItem == .fact(fact.id),
                               onTap: { toggle(.fact(fact.id)) }, onDoor: { onOpenDoor(fact.id) })
            }
        }
    }

    /// Page Modes: the summary, and opened, one line per mode with ranges,
    /// then the fallback lines. One of the open items.
    private var pageModesRow: some View {
        let isOpen = openItem == .pageModes
        let summary = VerificationResultsView.pageModesSummaryText(modes: report.perPageModes)
        return VStack(alignment: .leading, spacing: 0) {
            Button { toggle(.pageModes) } label: {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                        Text("Page Modes")
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, ResectaTokens.Spacing.md)
                    DisclosureChevron(isExpanded: isOpen, tint: Color(.secondaryLabel))
                        .frame(width: ResectaTokens.Results.chevronColumn)
                        .padding(.top, ResectaTokens.Spacing.xs)
                        .padding(.leading, ResectaTokens.Spacing.sm)
                        .padding(.trailing, ResectaTokens.Spacing.md)
                }
                .padding(.vertical, ResectaTokens.Spacing.sm + ResectaTokens.Spacing.xs - 1)
                .frame(minHeight: ResectaTokens.Results.rowMinHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(ResultsRowButtonStyle())
            .accessibilityLabel("Page Modes, \(summary)")
            .accessibilityHint(isOpen ? "Hides details" : "Shows details")
            if isOpen {
                VStack(alignment: .leading, spacing: ResectaTokens.Spacing.sm) {
                    VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                        ForEach(VerificationResultsView.pageModeLines(modes: report.perPageModes), id: \.self) { line in
                            Text(line)
                        }
                    }
                    if report.perPageFallbackReasons.hasAnyFallbackReason {
                        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                            ForEach(VerificationResultsView.fallbackReasonRowTexts(
                                reasons: report.perPageFallbackReasons), id: \.self) { line in
                                Text(line)
                            }
                        }
                    }
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                .padding(.leading, ResectaTokens.Spacing.md)
                .padding(.trailing, ResectaTokens.Spacing.md)
                .padding(.bottom, ResectaTokens.Spacing.md - 2)
                .transition(.opacity)
            }
        }
        .background(isOpen ? LayerResultRow.rowWash(colorScheme) : .clear)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pageModesSection")
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

    /// The Page Modes lines: one per mode present, Searchable first, with
    /// runs of three or more pages as en-dash ranges — "Searchable · pages
    /// 1–12, 14, and 16–40" · "Rasterized · page 3".
    static func pageModeLines(modes: [PipelineMode]) -> [String] {
        [(PipelineMode.searchableRedaction, "Searchable"), (.secureRasterization, "Rasterized")]
            .compactMap { mode, name in
                let pages = modes.indices.filter { modes[$0] == mode }
                guard !pages.isEmpty else { return nil }
                let items = pageRanges(pages)
                let noun = pages.count == 1 ? "page" : "pages"
                return "\(name) · \(noun) \(VerificationRowModel.listPhrase(items))"
            }
    }

    /// 0-based pages → 1-based items, a run of three or more as "a–b".
    static func pageRanges(_ pages: [Int]) -> [String] {
        var items: [String] = []
        var start = 0
        while start < pages.count {
            var end = start
            while end + 1 < pages.count, pages[end + 1] == pages[end] + 1 { end += 1 }
            if end - start >= 2 {
                items.append("\(pages[start] + 1)\u{2013}\(pages[end] + 1)")
            } else {
                items += pages[start...end].map { String($0 + 1) }
            }
            start = end + 1
        }
        return items
    }

    /// Page Modes shows when the modes are mixed or any page fell back.
    static func showsPageModes(report: VerificationReport) -> Bool {
        report.perPageModes.hasMixedModes || report.perPageFallbackReasons.hasAnyFallbackReason
    }
}
