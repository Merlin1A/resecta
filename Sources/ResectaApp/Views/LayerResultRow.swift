import SwiftUI
import RedactionEngine

// Per-layer result row with expand/collapse.
// Shared between VerificationProgressView and VerificationResultsView.

struct LayerResultRow: View {
    /// The row's chrome. `.card` — the row paints its own material (the
    /// progress view's rows); `.grouped` — a row of the results page's
    /// inset-grouped sections, which own the hairlines between rows.
    // nonisolated: a plain value read from `@Test(arguments:)` arrays,
    // which Swift Testing hoists into a nonisolated peer (the SE-0466
    // rationale on `ResectaTokens.SemanticColor`).
    nonisolated enum Chrome: Equatable {
        case card
        case grouped
    }

    /// Where a grouped row starts: `.lead` — the outcome mark in the lead
    /// column, the title at 56 (the check sections, a riding note); `.member`
    /// — the title at 56, no mark (a passing check inside the cluster);
    /// `.bare` — the title at 16 (the `Checks` list of a wholly clean run).
    nonisolated enum GroupedLayout: Equatable {
        case lead
        case member
        case bare
    }

    /// One item of the expanded block, in display order.
    nonisolated enum ExpandedItem: Equatable {
        /// What to do about this row, first.
        case lead(String)
        /// What the check reads — on every row whose caption is not
        /// already that line.
        case explainer(String)
        /// What must be true for the check to pass, and what it does not see.
        case rule(String)
        /// The engine's detail sentence, verbatim.
        case detail(String)
        /// The query lines and their per-term sub-lines.
        case queryLines
        /// "Go to page" and one chip per page.
        case pageChips([Int])
        case timing(String)
    }

    // Routes the detail-expansion `.move(edge:)` transition through
    // `Anim.resolvedTransition`.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // At accessibility sizes the status word drops under the title.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // The opened grouped row's wash is per appearance.
    @Environment(\.colorScheme) private var colorScheme

    /// The glyph column and the mark column, each scaling with the title.
    /// The text column, the expanded block and the section's hairlines
    /// start past both and their gaps (`textInset`).
    @ScaledMetric(relativeTo: .subheadline) private var column: CGFloat = 20

    let layer: LayerResult
    let layerIndex: Int
    let isExpanded: Bool
    let onTap: () -> Void
    /// Use neutral gray for PASS during .verifying phase.
    var useIntermediateColors: Bool = false

    /// Called when a page reference number is tapped. Nil during .verifying phase
    /// (page navigation from in-progress verification is not supported).
    var onPageTap: ((Int) -> Void)? = nil
    /// Review in Scan, offered on a Detection Sweep row with possible items
    /// remaining (`offersReviewInScan`); nil where it is not offered.
    var onReviewInScan: (() -> Void)? = nil

    /// False in VerificationProgressView, where rows are display-only
    /// (`isExpanded: false, onTap: {}`) — a "Tap to expand details" hint
    /// there advertises a no-op.
    var isExpandable: Bool = true

    var chrome: Chrome = .card
    /// The run's per-page modes (the report's) — empty while the run is in
    /// progress, which reads every vacuous pass as passed.
    var perPageModes: [PipelineMode] = []
    /// The grouped chrome's layout, its status word (under Findings only)
    /// and its page chips (only while the redacted PDF exists — otherwise
    /// the caption names the pages).
    var groupedLayout: GroupedLayout = .lead
    var showsStatusWord: Bool = false
    var pagesOnChips: Bool = false

    private var model: VerificationRowModel {
        VerificationRowModel(layer: layer, perPageModes: perPageModes,
                             pagesOnChips: chrome == .grouped && pagesOnChips)
    }

    /// The row's own horizontal inset: 8 pt inside its card chrome; none
    /// when flat, where the section's content column carries the inset.
    private var horizontalInset: CGFloat {
        chrome == .card ? ResectaTokens.Spacing.sm : 0
    }

    /// Where the title starts: past the glyph, the mark and their gaps.
    private var textInset: CGFloat { 2 * (column + ResectaTokens.Spacing.sm) }

    /// The mark's and the word's colour: a pass reads neutral while the run
    /// is still in progress (no premature confidence); every other outcome
    /// in its text tier.
    private var statusColor: Color {
        useIntermediateColors && model.outcome == .passed
            ? ResectaTokens.SemanticColor.supportText
            : model.outcome.textColor
    }

    var body: some View {
        Group {
            if chrome == .grouped {
                groupedBody
            } else {
                cardBody
            }
        }
        .accessibilityIdentifier("layerResult_\(layerIndex - 1)") // zero-indexed
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — always visible. A Button when the row opens (every
            // row of a finished run); the progress view's rows render the
            // header directly, with no chevron and no hint.
            if isExpandable {
                Button(action: onTap) {
                    header
                }
                .buttonStyle(.plain)
                // Explicit label so what the check reported is spoken.
                // Collapsed, the outer `.combine` merges this into the
                // single row element; expanded (`.contain`), the header
                // stays one focusable element with the same label while the
                // block's lines and page chips become real, reachable elements.
                .accessibilityLabel(Self.accessibilityLabel(model: model, layer: layer))
                .accessibilityHint(Self.accessibilityHint(isExpandable: true, isExpanded: isExpanded))
            } else {
                header
                    .accessibilityLabel(Self.accessibilityLabel(model: model, layer: layer))
            }

            // Expanded detail
            if isExpanded {
                expandedBlock
            }
        }
        // `.card` paints the row's own material (the progress view).
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ResectaTokens.CornerRadius.toast))
        // Collapsed: one combined element (header label above). Expanded:
        // a container, so VoiceOver can reach the detail text and the
        // "Go to page N" chips instead of having them flattened away.
        .accessibilityElement(children: isExpanded ? .contain : .combine)
        // A collapsed row with pages: each page is a named action, so a
        // VoiceOver user need not open the row to go there.
        .accessibilityActions {
            if !isExpanded, let onPageTap {
                ForEach(layer.pageReferences ?? [], id: \.self) { page in
                    Button("Go to page \(page + 1)") { onPageTap(page) }
                }
            }
        }
    }

    // MARK: - Header

    /// [glyph] [mark] [title · word / caption] [chevron] — one anatomy for
    /// every row. The glyph names the check (identity only, in the support
    /// tier); the mark and the word carry the outcome.
    private var header: some View {
        HStack(alignment: .top, spacing: ResectaTokens.Spacing.sm) {
            VerificationSymbol.icon(for: layer)
                .font(.system(size: column))
                .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                .frame(width: column, height: column)
                .accessibilityHidden(true)

            Image(systemName: model.outcome.markSymbolName)
                .font(.system(size: column, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: column, height: column)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                if dynamicTypeSize.isAccessibilitySize {
                    title
                    word
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: ResectaTokens.Spacing.sm) {
                        title
                            .frame(maxWidth: .infinity, alignment: .leading)
                        word
                    }
                }
                captionText(font: .caption)
                gateLine(font: .caption)
            }

            if isExpandable {
                DisclosureChevron(isExpanded: isExpanded)
                    .frame(width: 16, height: column)
            }
        }
        .padding(.vertical, ResectaTokens.Spacing.sm + ResectaTokens.Spacing.xxs)
        .padding(.horizontal, horizontalInset)
        .frame(minHeight: ResectaTokens.TouchTarget.minimum)
        .contentShape(Rectangle())
    }

    /// The caption under the title — one view for both chromes. A
    /// needs-review caption quotes the user's terms or searches; every other
    /// caption is the check's own copy. A trailing page number keeps its
    /// noun.
    @ViewBuilder
    private func captionText(font: Font) -> some View {
        if let caption = model.caption {
            Text(Self.gluedPageTail(caption))
                .font(font)
                .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                .privacySensitive(model.captionIsPrivacySensitive)
        }
    }

    /// The Detection Sweep's gate, on the collapsed row only — the expanded
    /// detail states it once already.
    @ViewBuilder
    private func gateLine(font: Font) -> some View {
        if !isExpanded, let caption = Self.rowCaptionText(layer: layer) {
            Text(caption)
                .font(font)
                .foregroundStyle(ResectaTokens.SemanticColor.supportText)
        }
    }

    private var title: some View {
        Text(model.title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
    }

    private var word: some View {
        Text(model.outcome.word)
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusColor)
            .lineLimit(1)
            .fixedSize()
    }

    // MARK: - Expanded block

    private var expandedBlock: some View {
        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.sm) {
            ForEach(Array(Self.expandedItems(model: model, layer: layer, opensPages: onPageTap != nil)
                .enumerated()), id: \.offset) { _, item in
                switch item {
                case .lead(let line), .explainer(let line), .rule(let line), .detail(let line):
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                case .timing(let line):
                    Text(line)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                case .queryLines:
                    queryLines
                case .pageChips(let pages):
                    pageChips(pages)
                }
            }
        }
        .padding(.horizontal, horizontalInset)
        .padding(.bottom, ResectaTokens.Spacing.sm)
        // Past the glyph and mark columns: the block starts at the title's
        // left edge at every Dynamic Type size.
        .padding(.leading, textInset)
        // Routed through the resolver so Reduce Motion swaps
        // the slide for an opacity-only crossfade.
        .transition(ResectaTokens.Anim.resolvedTransition(
            standard: .opacity.combined(with: .move(edge: .top)),
            reduceMotion: reduceMotion))
    }

    // Search Re-check per-query lines (display-only, like
    // `reviewTermTexts`): one line per applied query with
    // its found / applied / remaining counts, per-term
    // sub-lines beneath a multi-term query. Each `Text`
    // is its own reachable element inside the expanded
    // `.contain` container.
    private var queryLines: some View {
        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
            ForEach(Array((layer.queryLines ?? []).enumerated()), id: \.offset) { _, line in
                // Each line quotes the user's own query,
                // pattern or terms — marked like the
                // search sheet's rows.
                Text(Self.queryLineText(line, in: layer.layer))
                    .font(.caption)
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    .privacySensitive(Self.queryLinesArePrivacySensitive)
                ForEach(Array(Self.perTermLineTexts(line, in: layer.layer).enumerated()), id: \.offset) { _, text in
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                        .padding(.leading, ResectaTokens.Spacing.sm)
                        .privacySensitive(Self.queryLinesArePrivacySensitive)
                }
            }
        }
    }

    private func pageChips(_ pages: [Int]) -> some View {
        FlowLayout(spacing: ResectaTokens.Spacing.xs) {
            // The label matches the chips' 46 pt hit frame in
            // height so it sits centred beside them, not above.
            Text("Go to page")
                .font(.caption)
                .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                .frame(minHeight: ResectaTokens.TouchTarget.minimum)

            ForEach(pages, id: \.self) { pageRef in
                PageChip(pageIndex: pageRef) {
                    onPageTap?(pageRef)
                }
            }
        }
    }

    /// The expanded block's items, in order: the lead lines, the explainer
    /// (unless the caption already is it — a passing row), the rule, the
    /// engine detail (never on a skipped check, whose engine detail names a
    /// reason that does not apply), the query lines, the page chips (when
    /// the host navigates), the timing. The engine's short line is never
    /// repeated here.
    static func expandedItems(model: VerificationRowModel, layer: LayerResult,
                              opensPages: Bool) -> [ExpandedItem] {
        var items: [ExpandedItem] = model.lead.map(ExpandedItem.lead)
        if let explainer = model.explainer, model.caption != explainer {
            items.append(.explainer(explainer))
        }
        if let rule = model.rule {
            items.append(.rule(rule))
        }
        if model.showsEngineDetail, layer.hasDetail {
            items.append(.detail(layer.detailDescription))
        }
        if !(layer.queryLines ?? []).isEmpty {
            items.append(.queryLines)
        }
        if opensPages, let pages = layer.pageReferences, !pages.isEmpty {
            items.append(.pageChips(pages))
        }
        items.append(.timing(expandedTimingText(durationSeconds: layer.durationSeconds, layer: layer.layer)))
        return items
    }

    /// The expanded row's last line. "Took under 0.1 s" for every duration
    /// below a tenth of a second (most checks finish there, and "0.0s"
    /// read as "did not run"); one decimal below a minute, a space before
    /// the unit; "Took 4 min 56 s" from 60 s. The footer keeps the run's
    /// total.
    static func expandedTimingText(durationSeconds seconds: Double) -> String {
        if seconds < 0.1 { return "Took under 0.1 s" }
        if seconds < 60 { return String(format: "Took %.1f s", seconds) }
        return "Took \(VerificationResultsView.minutesText(seconds))"
    }

    /// The timing line by check: the Search Re-check and the Detection Sweep
    /// share one post pass, timed on the re-check row; the sweep row says so.
    static func expandedTimingText(durationSeconds seconds: Double, layer: VerificationLayer?) -> String {
        switch layer {
        case .searchRecheck: "\(expandedTimingText(durationSeconds: seconds)), shared with Detection Sweep"
        case .detectionSweep: "Timed with Search Re-check"
        default: expandedTimingText(durationSeconds: seconds)
        }
    }

    /// The Detection Sweep's gate, as a fixed line of the collapsed row and
    /// of its spoken label: the row's own caption reports what the sweep
    /// observed in the categories it reads, and this line says what it
    /// leaves out. The same bytes as the engine's detail sentence
    /// (`DetectionSweep.gateSentence` — internal to the engine; pinned
    /// equal by `DetectionSweepRowCaptionTests`). No content: not
    /// privacy-sensitive.
    static let detectionSweepGateCaption = "Names and addresses are not swept."

    /// What else the sweep does not read, after the engine's sentence.
    static let detectionSweepUnreadCaption =
        "Photos, signatures and numbers in formats it does not know are not read either."

    /// The collapsed row's gate line: for the Detection Sweep — keyed on the
    /// layer's identity, never on its label text — the engine's gate
    /// sentence, then what else it does not read, on every outcome (a PASS
    /// included); nil for every other row. Static so the composition is
    /// unit-testable without a SwiftUI host.
    static let reviewInScanLabel = "Review in Scan"

    /// Review in Scan shows on a Detection Sweep row that reports possible
    /// items remaining — the row whose page links open a Preview with
    /// nothing marked (the sweep keeps pages, not locations).
    static func offersReviewInScan(layer: LayerResult) -> Bool {
        VerificationRowModel.hasItemsRemaining(layer)
    }

    static func rowCaptionText(layer: LayerResult) -> String? {
        layer.layer == .detectionSweep ? "\(detectionSweepGateCaption) \(detectionSweepUnreadCaption)" : nil
    }

    // MARK: - Search Re-check query lines (static for unit testability)

    /// The query lines and per-term sub-lines always render under
    /// `.privacySensitive()`: every one quotes the user's query, pattern or
    /// term list. The modifier is not introspectable, so the row reads this
    /// constant and the display pin holds it true.
    static let queryLinesArePrivacySensitive = true

    /// The per-query line as displayed: "{label} · {N} found · {M} redacted
    /// · {R} remaining", then the option badges ("case-sensitive", "whole
    /// word") when set. "found 1,000+" when the original run stopped at
    /// the result cap. The label is the engine's display label (quoted
    /// query / pattern, or the multi-term form); the route is not
    /// repeated here — the layer's detail sentence carries it once.
    static func queryLineText(_ line: SearchRecheckQueryLine, in layer: VerificationLayer?) -> String {
        // The run's sweep: nothing was found or applied because nothing was
        // an apply — the line says what the detectors observed instead.
        if isSweepLine(line, in: layer) {
            return "\(line.label) · \(possibleItems(line.remainingCount))"
        }
        let found = line.foundHitCap ? "1,000+" : String(line.foundCount)
        // A query the search engine refused to re-run (the regex safety
        // gate) has no remaining count: the line says so instead of
        // printing "0 remain", which would read as a clear.
        let remaining = line.unchecked
            ? "not re-checked (pattern not accepted)"
            : "\(line.remainingCount) remaining"
        var text = "\(line.label) · \(found) found · \(line.appliedCount) redacted · \(remaining)"
        for badge in line.optionBadges {
            text += " · \(badge)"
        }
        return text
    }

    /// A multi-term query's per-term sub-lines: "“term” · {R} remaining",
    /// with "{n} found · {m} redacted" ahead of the remaining count when the
    /// record carries per-term counts. Empty for single-query lines.
    static func perTermLineTexts(_ line: SearchRecheckQueryLine, in layer: VerificationLayer?) -> [String] {
        // A scan line's sub-lines are per detector category, named as the
        // engine names them — not quoted like a typed term.
        if isScanLine(line, in: layer) {
            let sweep = isSweepLine(line, in: layer)
            return (line.perTerm ?? []).map { category in
                sweep
                    ? "\(category.term) · \(possibleItems(category.remaining))"
                    : "\(category.term) · \(category.remaining) remaining"
            }
        }
        return (line.perTerm ?? []).map { term in
            var text = "\u{201C}\(term.term)\u{201D}"
            if let found = term.found { text += " · \(found) found" }
            if let applied = term.applied { text += " · \(applied) redacted" }
            text += " · \(term.remaining) remaining"
            return text
        }
    }

    /// A Detection Sweep line: every line the sweep carries is a scan line,
    /// keyed on the layer's identity — never on the label, which a typed
    /// query can share ("Scan (" is a legal search).
    static func isScanLine(_ line: SearchRecheckQueryLine, in layer: VerificationLayer?) -> Bool {
        layer == .detectionSweep
    }

    /// The run's synthesized sweep among the scan lines: it found nothing
    /// and applied nothing because it was never an apply (an applied scan
    /// always found at least what it applied).
    static func isSweepLine(_ line: SearchRecheckQueryLine, in layer: VerificationLayer?) -> Bool {
        isScanLine(line, in: layer) && VerificationRowModel.isUnappliedSweepLine(line)
    }

    /// "N possible item(s)", or "nothing further" at zero.
    private static func possibleItems(_ count: Int) -> String {
        switch count {
        case 0: "nothing further"
        case 1: "1 possible item"
        default: "\(count) possible items"
        }
    }

    /// Every query-line text the expanded row renders, in display order:
    /// each query line followed by its per-term sub-lines. Empty when the
    /// layer carries no query lines (every layer but the Search Re-check
    /// and the Detection Sweep, and their idle rows).
    static func queryLineTexts(layer: LayerResult) -> [String] {
        (layer.queryLines ?? []).flatMap { line in
            [queryLineText(line, in: layer.layer)] + perTermLineTexts(line, in: layer.layer)
        }
    }

    // MARK: - Spoken strings (static for unit testability)

    /// Row label: "{Title}, {Word}." and the caption, then the sweep's gate
    /// (it rides the spoken label as it rides the collapsed row) and, last,
    /// the pages ("Page 2." · "Pages 1 and 3." · up to five, then a count).
    /// Every part ends in a period. The duration is
    /// not spoken: it is not in the collapsed row, and the expanded row's
    /// timing line is its own reachable element. "Layer N" is not spoken
    /// here — grouped, the ordinals read out of sequence; the mid-run
    /// announcements keep it.
    static func accessibilityLabel(model: VerificationRowModel, layer: LayerResult) -> String {
        var label = model.spokenLabel
        if let caption = Self.rowCaptionText(layer: layer) {
            label += " \(caption)"
        }
        if let pages = VerificationRowModel.spokenPages(layer.pageReferences ?? []) {
            label += " \(pages)"
        }
        return label
    }

    /// Hint is empty for non-expandable rows (VerificationProgressView) —
    /// there the tap is a no-op, so advertising it misleads.
    static func accessibilityHint(isExpandable: Bool, isExpanded: Bool) -> String {
        guard isExpandable else { return "" }
        return isExpanded ? "Hides details" : "Shows details"
    }

    // MARK: - Grouped chrome (the results page)

    /// The grouped row: a tap container, never a `Button` — it hosts the
    /// page chips' `Button`s, which a `Button` label cannot (the tap would
    /// never reach them). The header speaks as one button: its label, its
    /// hint, a default action; collapsed, the whole row is one element whose
    /// `Go to page N` actions follow the chips.
    private var groupedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupedHeader
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
                // Open: the header is the row's button element.
                .modifier(GroupedRowAccessibility(
                    applies: isExpanded, combines: true, model: model, layer: layer,
                    isExpanded: isExpanded, action: onTap))
            if isExpanded {
                groupedExpandedBlock
            }
        }
        .background(isExpanded ? Self.rowWash(colorScheme) : .clear)
        .accessibilityElement(children: isExpanded ? .contain : .combine)
        // Collapsed: the whole row is the button element.
        .modifier(GroupedRowAccessibility(
            applies: !isExpanded, combines: false, model: model, layer: layer,
            isExpanded: isExpanded, action: onTap))
        .accessibilityActions {
            if !isExpanded, pagesOnChips, let onPageTap {
                ForEach(layer.pageReferences ?? [], id: \.self) { page in
                    Button("Go to page \(page + 1)") { onPageTap(page) }
                }
            }
            if !isExpanded, let onReviewInScan, Self.offersReviewInScan(layer: layer) {
                Button(Self.reviewInScanLabel, action: onReviewInScan)
            }
        }
    }

    /// [mark] title / caption / gate / meta line [chevron]: the mark in a
    /// 28-pt column, the title at 56; a bare pass row starts its title at
    /// 16 (the clean `Checks` list), a cluster member at 56 with no mark.
    private var groupedHeader: some View {
        HStack(alignment: .top, spacing: 0) {
            switch groupedLayout {
            case .lead:
                Image(systemName: model.outcome.markSymbolName)
                    .font(.system(size: ResectaTokens.Results.leadMark))
                    .foregroundStyle(Self.groupedMarkColor(model.outcome))
                    .frame(width: ResectaTokens.Results.leadColumn)
                    .padding(.leading, ResectaTokens.Spacing.md)
                    .padding(.trailing, ResectaTokens.Results.titleInset
                             - ResectaTokens.Spacing.md - ResectaTokens.Results.leadColumn)
                    .accessibilityHidden(true)
            case .member:
                Color.clear.frame(width: ResectaTokens.Results.titleInset, height: 1)
            case .bare:
                Color.clear.frame(width: ResectaTokens.Spacing.md, height: 1)
            }
            VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                Text(model.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                if groupedLayout == .lead {
                    captionText(font: .subheadline)
                }
                gateLine(font: .subheadline)
                if let meta = metaLine {
                    meta
                        .padding(.top, ResectaTokens.Spacing.xs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            DisclosureChevron(isExpanded: isExpanded, tint: Color(.secondaryLabel))
                .frame(width: ResectaTokens.Results.chevronColumn)
                .padding(.top, ResectaTokens.Spacing.xs)
                .padding(.leading, ResectaTokens.Spacing.sm)
                .padding(.trailing, ResectaTokens.Spacing.md)
        }
        .padding(.vertical, ResectaTokens.Spacing.sm + ResectaTokens.Spacing.xs - 1)
        .frame(minHeight: ResectaTokens.Results.rowMinHeight, alignment: .top)
    }

    /// The status word (under Findings only, grey; the colour stays on the
    /// mark) and the page chips — at most five, else four and `+n more`,
    /// shown only while the redacted PDF exists. Nil when neither shows.
    private var metaLine: AnyView? {
        let pages = pagesOnChips ? (layer.pageReferences ?? []) : []
        guard showsStatusWord || !pages.isEmpty else { return nil }
        let shown = Self.collapsedChipPages(pages)
        return AnyView(FlowLayout(spacing: ResectaTokens.Spacing.sm) {
            if showsStatusWord {
                Text(model.outcome.word)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    .frame(minHeight: ResectaTokens.Results.chipHeight)
            }
            ForEach(shown, id: \.self) { page in
                PageChip(pageIndex: page) { onPageTap?(page) }
            }
            if let more = Self.moreChipsText(pages) {
                Text(more)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    .frame(minHeight: ResectaTokens.Results.chipHeight)
            }
        })
    }

    /// The opened block: the lead group, 12 pt, the glyph line, the rule,
    /// the engine detail, the query lines, the full chip set when capped,
    /// the timing.
    private var groupedExpandedBlock: some View {
        let items = Self.groupedExpandedItems(model: model, layer: layer, pagesOnChips: pagesOnChips)
        let leads = items.compactMap { if case .lead(let line) = $0 { line } else { nil } }
        return VStack(alignment: .leading, spacing: ResectaTokens.Results.leadToReference) {
            if !leads.isEmpty {
                VStack(alignment: .leading, spacing: ResectaTokens.Spacing.sm) {
                    ForEach(Array(leads.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: ResectaTokens.Spacing.sm) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    switch item {
                    case .lead:
                        EmptyView()
                    case .explainer(let line):
                        // The glyph line: the check's glyph in the lead
                        // column, its one-line description at the title.
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .overlay(alignment: .topLeading) {
                                VerificationSymbol.icon(for: layer)
                                    .font(.system(size: ResectaTokens.Results.leadMark - 2))
                                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                                    .frame(width: ResectaTokens.Results.leadColumn)
                                    .offset(x: -(ResectaTokens.Results.titleInset - ResectaTokens.Spacing.md))
                                    .accessibilityHidden(true)
                            }
                    case .rule(let line), .detail(let line):
                        Text(Self.gluedPageTail(line))
                            .font(.subheadline)
                            .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    case .timing(let line):
                        Text(line)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    case .queryLines:
                        queryLines
                    case .pageChips(let pages):
                        FlowLayout(spacing: ResectaTokens.Spacing.sm) {
                            ForEach(pages, id: \.self) { page in
                                PageChip(pageIndex: page) { onPageTap?(page) }
                            }
                        }
                    }
                }
            }
            if let onReviewInScan, Self.offersReviewInScan(layer: layer) {
                Button(Self.reviewInScanLabel, action: onReviewInScan)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("reviewInScanButton")
            }
        }
        .padding(.leading, groupedLayout == .bare ? ResectaTokens.Spacing.md : ResectaTokens.Results.titleInset)
        .padding(.trailing, ResectaTokens.Spacing.md)
        .padding(.bottom, ResectaTokens.Spacing.md - 2)
        .transition(ResectaTokens.Anim.resolvedTransition(
            standard: .opacity, reduceMotion: reduceMotion))
    }

    /// The opened block's items in the grouped chrome: the lead lines, the
    /// glyph line (every row with an identity — the bare pass rows show
    /// no caption), the rule, the engine detail (never on a skipped check),
    /// the query lines, the full chip set when the collapsed row capped it,
    /// the timing.
    static func groupedExpandedItems(model: VerificationRowModel, layer: LayerResult,
                                     pagesOnChips: Bool) -> [ExpandedItem] {
        var items: [ExpandedItem] = model.lead.map(ExpandedItem.lead)
        if let explainer = model.explainer { items.append(.explainer(explainer)) }
        if let rule = model.rule { items.append(.rule(rule)) }
        if model.showsEngineDetail, layer.hasDetail { items.append(.detail(layer.detailDescription)) }
        if !(layer.queryLines ?? []).isEmpty { items.append(.queryLines) }
        if pagesOnChips, let pages = layer.pageReferences, pages.count > ResectaTokens.Results.chipCap {
            items.append(.pageChips(pages))
        }
        items.append(.timing(expandedTimingText(durationSeconds: layer.durationSeconds, layer: layer.layer)))
        return items
    }

    /// The pages a collapsed row shows as chips: all of up to five, else
    /// the first four.
    static func collapsedChipPages(_ pages: [Int]) -> [Int] {
        pages.count <= ResectaTokens.Results.chipCap ? pages : Array(pages.prefix(ResectaTokens.Results.chipCap - 1))
    }

    /// "+8 more" beside four chips; nil when every page has its chip.
    static func moreChipsText(_ pages: [Int]) -> String? {
        guard pages.count > ResectaTokens.Results.chipCap else { return nil }
        return "+\(pages.count - (ResectaTokens.Results.chipCap - 1))\u{00A0}more"
    }

    /// The mark's colour: the outcome's text tier on a failure, a review or a warning; a note,
    /// a check that could not verify and one with nothing to check read
    /// grey — the header names them.
    static func groupedMarkColor(_ outcome: VerificationOutcome) -> Color {
        switch outcome {
        case .note, .couldNotVerify, .nothingToCheck: ResectaTokens.SemanticColor.supportText
        default: outcome.textColor
        }
    }

    /// The opened row's wash.
    static func rowWash(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(ResectaTokens.Results.rowWashDark)
            : Color.black.opacity(ResectaTokens.Results.rowWashLight)
    }

    /// A trailing "on page N" (or any phrase whose last word is a page
    /// number) keeps its last three words together, so a page number never
    /// wraps away from its noun. Text already held together is left alone.
    static func gluedPageTail(_ text: String) -> String {
        var words = text.components(separatedBy: " ")
        guard words.count >= 3, let last = words.last,
              last.trimmingCharacters(in: CharacterSet(charactersIn: ".")).allSatisfy(\.isNumber),
              !last.isEmpty, !last.contains("\u{00A0}") else { return text }
        let tail = words.suffix(3).joined(separator: "\u{00A0}")
        words.removeLast(3)
        return (words + [tail]).joined(separator: " ")
    }
}

/// The grouped row's button element: its label, its hint, the button trait
/// and a default action — on the header while the row is open (combined
/// into one element), on the whole row while it is collapsed.
private struct GroupedRowAccessibility: ViewModifier {
    let applies: Bool
    let combines: Bool
    let model: VerificationRowModel
    let layer: LayerResult
    let isExpanded: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if applies {
            content
                .accessibilityElement(children: combines ? .combine : .contain)
                .accessibilityLabel(LayerResultRow.accessibilityLabel(model: model, layer: layer))
                .accessibilityHint(LayerResultRow.accessibilityHint(isExpandable: true, isExpanded: isExpanded))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { action() }
        } else {
            content
        }
    }
}
