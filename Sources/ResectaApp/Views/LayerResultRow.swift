import SwiftUI
import RedactionEngine

// Per-layer result row with expand/collapse.
// Shared between VerificationProgressView and VerificationResultsView.

struct LayerResultRow: View {
    /// The row's chrome. `.card` — the row paints its own material (the
    /// progress view's rows); `.plain` — flat, the section that stacks the
    /// rows owns the hairlines between them.
    // nonisolated: a plain value read from `@Test(arguments:)` arrays,
    // which Swift Testing hoists into a nonisolated peer (the SE-0466
    // rationale on `ResectaTokens.SemanticColor`).
    nonisolated enum Chrome: Equatable {
        case card
        case plain
    }

    /// One item of the expanded block, in display order.
    nonisolated enum ExpandedItem: Equatable {
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

    /// False in VerificationProgressView, where rows are display-only
    /// (`isExpanded: false, onTap: {}`) — a "Tap to expand details" hint
    /// there advertises a no-op.
    var isExpandable: Bool = true

    var chrome: Chrome = .card
    /// The run's per-page modes (the report's) — empty while the run is in
    /// progress, which reads every vacuous pass as passed.
    var perPageModes: [PipelineMode] = []

    private var model: VerificationRowModel {
        VerificationRowModel(layer: layer, perPageModes: perPageModes)
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
        // `.card` paints the row's own material (the progress view); `.plain`
        // draws nothing — the section owns the hairlines.
        .background(
            chrome == .card ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: ResectaTokens.CornerRadius.toast))
        // Collapsed: one combined element (header label above). Expanded:
        // a container, so VoiceOver can reach the detail text and the
        // "Go to page N" chips instead of having them flattened away.
        .accessibilityElement(children: isExpanded ? .contain : .combine)
        .accessibilityIdentifier("layerResult_\(layerIndex - 1)") // zero-indexed
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
                if let caption = model.caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                        // A needs-review sentence quotes the user's redacted
                        // terms; every other caption is the check's own copy.
                        .privacySensitive(model.captionIsPrivacySensitive)
                }
                // The Detection Sweep's gate, on the collapsed row only —
                // the expanded detail states it once already.
                if !isExpanded, let caption = Self.rowCaptionText(layer: layer) {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                }
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
                case .detail(let line):
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

    /// The expanded block's items, in order: the engine detail, the query
    /// lines, the page chips (when the host navigates), the timing.
    static func expandedItems(model: VerificationRowModel, layer: LayerResult,
                              opensPages: Bool) -> [ExpandedItem] {
        var items: [ExpandedItem] = []
        if layer.hasDetail {
            items.append(.detail(layer.detailDescription))
        }
        if !(layer.queryLines ?? []).isEmpty {
            items.append(.queryLines)
        }
        if opensPages, let pages = layer.pageReferences, !pages.isEmpty {
            items.append(.pageChips(pages))
        }
        items.append(.timing(expandedTimingText(durationSeconds: layer.durationSeconds)))
        return items
    }

    /// The expanded row's last line. "Took under 0.1 s" for every duration
    /// below a tenth of a second (most checks finish there, and "0.0s"
    /// read as "did not run"); otherwise one decimal, a space before the
    /// unit. The footer keeps the run's total.
    static func expandedTimingText(durationSeconds seconds: Double) -> String {
        seconds < 0.1 ? "Took under 0.1 s" : String(format: "Took %.1f s", seconds)
    }

    // MARK: - Row subtitle (attention rows name the exact text)

    /// The engine-side line of a row: attention rows compose a sentence from
    /// the display-only review term texts — the user reads exactly which
    /// text remains and how to remedy it; every other status gives the
    /// layer's own `shortDescription` unchanged. Static so the composition
    /// is unit-testable without a SwiftUI host.
    static func rowSubtitleText(layer: LayerResult) -> String {
        guard layer.status.isAttention,
              let terms = layer.reviewTermTexts, !terms.isEmpty else {
            return layer.shortDescription
        }
        return reviewRowText(termTexts: terms, pages: layer.pageReferences)
    }

    /// The Detection Sweep's gate, as a fixed line of the collapsed row and
    /// of its spoken label: the row's own caption reports what the sweep
    /// observed in the categories it reads, and this line says what it
    /// leaves out. The same bytes as the engine's detail sentence
    /// (`DetectionSweep.gateSentence` — internal to the engine; pinned
    /// equal by `DetectionSweepRowCaptionTests`). No content: not
    /// privacy-sensitive.
    static let detectionSweepGateCaption = "Names and addresses are not swept."

    /// The collapsed row's gate line: the gate sentence for the Detection
    /// Sweep — keyed on the layer's identity, never on its label text — and
    /// nil for every other row. Static so the composition is unit-testable
    /// without a SwiftUI host.
    static func rowCaptionText(layer: LayerResult) -> String? {
        layer.layer == .detectionSweep ? detectionSweepGateCaption : nil
    }

    /// Whether `rowSubtitleText(layer:)` names user text: true exactly when
    /// it takes the attention arm and composes its sentence from the review
    /// terms. Static so the predicate is unit-testable without a SwiftUI host.
    static func rowSubtitleIsPrivacySensitive(layer: LayerResult) -> Bool {
        layer.status.isAttention && !(layer.reviewTermTexts ?? []).isEmpty
    }

    /// Attention-row sentence: names the term(s), where they remain, and
    /// the remedy (`VerificationRowModel.reviewSentence`).
    static func reviewRowText(termTexts: [String], pages: [Int]?) -> String {
        VerificationRowModel.reviewSentence(termTexts: termTexts, pages: pages)
    }

    // MARK: - Search Re-check query lines (static for unit testability)

    /// The query lines and per-term sub-lines always render under
    /// `.privacySensitive()`: every one quotes the user's query, pattern or
    /// term list. The modifier is not introspectable, so the row reads this
    /// constant and the display pin holds it true.
    static let queryLinesArePrivacySensitive = true

    /// The per-query line as displayed: "{label} · found {N} · applied {M}
    /// · {R} remain", then the option badges ("case-sensitive", "whole
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
            : "\(line.remainingCount) remain"
        var text = "\(line.label) · found \(found) · applied \(line.appliedCount) · \(remaining)"
        for badge in line.optionBadges {
            text += " · \(badge)"
        }
        return text
    }

    /// A multi-term query's per-term sub-lines: "“term” · {R} remain", with
    /// "found {n} · applied {m}" ahead of the remaining count when the
    /// record carries per-term counts. Empty for single-query lines.
    static func perTermLineTexts(_ line: SearchRecheckQueryLine, in layer: VerificationLayer?) -> [String] {
        // A scan line's sub-lines are per detector category, named as the
        // engine names them — not quoted like a typed term.
        if isScanLine(line, in: layer) {
            let sweep = isSweepLine(line, in: layer)
            return (line.perTerm ?? []).map { category in
                sweep
                    ? "\(category.term) · \(possibleItems(category.remaining))"
                    : "\(category.term) · \(category.remaining) remain"
            }
        }
        return (line.perTerm ?? []).map { term in
            var text = "\u{201C}\(term.term)\u{201D}"
            if let found = term.found { text += " · found \(found)" }
            if let applied = term.applied { text += " · applied \(applied)" }
            text += " · \(term.remaining) remain"
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
    /// (it rides the spoken label as it rides the collapsed row) and the
    /// page count when the layer carries page references. The duration is
    /// not spoken: it is not in the collapsed row, and the expanded row's
    /// timing line is its own reachable element. "Layer N" is not spoken
    /// here — grouped, the ordinals read out of sequence; the mid-run
    /// announcements keep it.
    static func accessibilityLabel(model: VerificationRowModel, layer: LayerResult) -> String {
        var label = model.spokenLabel
        if let caption = Self.rowCaptionText(layer: layer) {
            label += " \(caption)"
        }
        if let pages = layer.pageReferences, !pages.isEmpty {
            label += ", \(pages.count) affected page\(pages.count == 1 ? "" : "s")"
        }
        return label
    }

    /// Hint is empty for non-expandable rows (VerificationProgressView) —
    /// there the tap is a no-op, so advertising it misleads.
    static func accessibilityHint(isExpandable: Bool, isExpanded: Bool) -> String {
        guard isExpandable else { return "" }
        return "Tap to \(isExpanded ? "collapse" : "expand") details"
    }
}
