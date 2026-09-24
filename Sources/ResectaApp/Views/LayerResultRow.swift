import SwiftUI
import RedactionEngine

// Per-layer result row with expand/collapse.
// Shared between VerificationProgressView and VerificationResultsView.

struct LayerResultRow: View {
    /// The row's shape. `.full` — the icon column, the name, the subtitle
    /// and, when there is something to expand, the chevron; `.compact` —
    /// the one-line ledger row for a clean pass (its rendering lands with
    /// the ledger; until then every row renders full). `rowStyle(for:)`
    /// picks, the section passes.
    // nonisolated: a plain value read from `@Test(arguments:)` arrays,
    // which Swift Testing hoists into a nonisolated peer (the SE-0466
    // rationale on `ResectaTokens.SemanticColor`).
    nonisolated enum Style: Equatable {
        case full
        case compact
    }

    /// The row's chrome. `.card` — the row paints its own material (the
    /// progress view's rows; today's look); `.plain` — flat, the section
    /// that stacks the rows owns the hairlines between them.
    nonisolated enum Chrome: Equatable {
        case card
        case plain
    }

    // Routes the detail-expansion `.move(edge:)` transition through
    // `Anim.resolvedTransition`.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // At accessibility sizes a subtitle wraps to many lines and a centred
    // icon drifts down the row — the header top-aligns there.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The icon column, scaling with the row's title text. The expanded
    /// block and the section's hairlines inset past it
    /// (`iconColumn + Spacing.sm`), so the detail starts at the name's
    /// left edge.
    @ScaledMetric(relativeTo: .title3) private var iconColumn: CGFloat = 30

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

    var style: Style = .full
    var chrome: Chrome = .card

    /// Whether the row opens: expandable by its host AND with something to
    /// show. A row whose expanded block would carry nothing but its timing
    /// is a full row with no chevron and no button.
    private var opens: Bool {
        isExpandable && Self.hasExpandedPayload(layer: layer)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — always visible. A Button only when the row opens;
            // otherwise the header renders directly, with no chevron and
            // no hint.
            if opens {
                Button(action: onTap) {
                    header
                }
                .buttonStyle(.plain)
                // Explicit label so what the check reported (`shortDescription`)
                // is spoken — combining children then labeling the CONTAINER
                // (the prior shape) silenced it. Collapsed, the outer `.combine` merges this
                // into the single row element; expanded (`.contain`), the header
                // stays one focusable element with the same label while the
                // detail text and page chips become real, reachable elements.
                .accessibilityLabel(Self.accessibilityLabel(layerIndex: layerIndex, layer: layer))
                .accessibilityHint(Self.accessibilityHint(isExpandable: true, isExpanded: isExpanded))
            } else {
                header
                    .accessibilityLabel(Self.accessibilityLabel(layerIndex: layerIndex, layer: layer))
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
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center,
               spacing: ResectaTokens.Spacing.sm) {
            VerificationSymbol.icon(for: layer)
                .foregroundStyle(useIntermediateColors
                                 ? layer.status.intermediateColor
                                 : layer.status.color)
                .font(.title3)
                .frame(width: iconColumn)

            VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                // The check's name alone — the ledger lists every check
                // and VoiceOver keeps "Layer N" in the label.
                Text(layer.name)
                    .font(.subheadline.weight(.medium))
                Text(Self.rowSubtitleText(layer: layer))
                    .font(.caption)
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    // An attention row's sentence quotes the
                    // review terms; the layer name, status
                    // phrase and every other row's description
                    // stay readable under a capture.
                    .privacySensitive(Self.rowSubtitleIsPrivacySensitive(layer: layer))
            }

            Spacer()

            if opens {
                // A fixed trailing slot, shared with the ledger's ✓ column.
                DisclosureChevron(isExpanded: isExpanded)
                    .frame(width: 16)
            }
        }
        .padding(ResectaTokens.Spacing.sm)
    }

    // MARK: - Expanded block

    private var expandedBlock: some View {
        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.sm) {
            if layer.hasDetail {
                Text(layer.detailDescription)
                    .font(.caption)
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
            }

            // Search Re-check per-query lines (display-only, like
            // `reviewTermTexts`): one line per applied query with
            // its found / applied / remaining counts, per-term
            // sub-lines beneath a multi-term query. Each `Text`
            // is its own reachable element inside the expanded
            // `.contain` container.
            if let lines = layer.queryLines, !lines.isEmpty {
                VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        // Each line quotes the user's own query,
                        // pattern or terms — marked like the
                        // search sheet's rows.
                        Text(Self.queryLineText(line))
                            .font(.caption)
                            .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                            .privacySensitive(Self.queryLinesArePrivacySensitive)
                        ForEach(Array(Self.perTermLineTexts(line).enumerated()), id: \.offset) { _, text in
                            Text(text)
                                .font(.caption)
                                .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                                .padding(.leading, ResectaTokens.Spacing.sm)
                                .privacySensitive(Self.queryLinesArePrivacySensitive)
                        }
                    }
                }
            }

            // Tappable page reference chips (static fallback when onPageTap is nil)
            if let pages = layer.pageReferences, !pages.isEmpty {
                if let onPageTap {
                    FlowLayout(spacing: ResectaTokens.Spacing.xs) {
                        // The label matches the chips' 46 pt hit frame in
                        // height so it sits centred beside them, not above.
                        Text("Go to page")
                            .font(.caption)
                            .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                            .frame(minHeight: ResectaTokens.TouchTarget.minimum)

                        ForEach(pages, id: \.self) { pageRef in
                            PageChip(pageIndex: pageRef) {
                                onPageTap(pageRef)
                            }
                        }
                    }
                } else {
                    // Same 1-based display convention as PageChip (storage is 0-based).
                    Text("Go to page \(pages.map { String($0 + 1) }.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                }
            }

            // The check's own time, last — its own reachable element.
            Text(Self.expandedTimingText(durationSeconds: layer.durationSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(ResectaTokens.SemanticColor.supportText)
        }
        .padding(.horizontal, ResectaTokens.Spacing.sm)
        .padding(.bottom, ResectaTokens.Spacing.sm)
        // Past the icon column and its gap: the detail starts at the name's
        // left edge at every Dynamic Type size.
        .padding(.leading, iconColumn + ResectaTokens.Spacing.sm)
        // Routed through the resolver so Reduce Motion swaps
        // the slide for an opacity-only crossfade.
        .transition(ResectaTokens.Anim.resolvedTransition(
            standard: .opacity.combined(with: .move(edge: .top)),
            reduceMotion: reduceMotion))
    }

    // MARK: - Style + payload (static for unit testability)

    /// The compact ledger row is a pass with nothing to expand; every
    /// other row — any non-pass, or a pass carrying detail, query lines
    /// or page references — is a full row.
    static func rowStyle(for layer: LayerResult) -> Style {
        layer.status == .pass && !hasExpandedPayload(layer: layer) ? .compact : .full
    }

    /// Whether the expanded block would show anything beyond its timing
    /// line: a detail sentence, query lines or page references. The
    /// timing alone is not a payload — a row with none is not expandable.
    static func hasExpandedPayload(layer: LayerResult) -> Bool {
        layer.hasDetail
            || !(layer.queryLines ?? []).isEmpty
            || !(layer.pageReferences ?? []).isEmpty
    }

    /// The expanded row's last line. "Took under 0.1 s" for every duration
    /// below a tenth of a second (most checks finish there, and "0.0s"
    /// read as "did not run"); otherwise one decimal, a space before the
    /// unit. The footer keeps the run's total.
    static func expandedTimingText(durationSeconds seconds: Double) -> String {
        seconds < 0.1 ? "Took under 0.1 s" : String(format: "Took %.1f s", seconds)
    }

    // MARK: - Row subtitle (attention rows name the exact text)

    /// Collapsed-row payload. Attention rows compose a sentence from the
    /// display-only review term texts — the user reads exactly which text
    /// remains and how to remedy it; every other status shows the layer's
    /// own `shortDescription` unchanged. Static so the composition is
    /// unit-testable without a SwiftUI host.
    static func rowSubtitleText(layer: LayerResult) -> String {
        guard layer.status.isAttention,
              let terms = layer.reviewTermTexts, !terms.isEmpty else {
            return layer.shortDescription
        }
        return reviewRowText(termTexts: terms, pages: layer.pageReferences)
    }

    /// Whether the collapsed-row subtitle names user text: true exactly
    /// when `rowSubtitleText(layer:)` takes the attention arm and composes
    /// its sentence from the review terms. Static so the predicate is
    /// unit-testable without a SwiftUI host.
    static func rowSubtitleIsPrivacySensitive(layer: LayerResult) -> Bool {
        layer.status.isAttention && !(layer.reviewTermTexts ?? []).isEmpty
    }

    /// Attention-row sentence: names the term(s), where they remain, and
    /// the remedy. Pages are 0-based storage, displayed 1-based (PageChip
    /// convention).
    static func reviewRowText(termTexts: [String], pages: [Int]?) -> String {
        let quoted = termTexts.map { "'\($0)'" }.joined(separator: ", ")
        let verb = termTexts.count == 1 ? "is" : "are"
        let location: String
        if let pages, !pages.isEmpty {
            let shown = pages.map { String($0 + 1) }
            switch shown.count {
            case 1:  location = "on page \(shown[0])"
            case 2:  location = "on pages \(shown[0]) and \(shown[1])"
            default: location = "on pages \(shown.dropLast().joined(separator: ", ")), and \(shown[shown.count - 1])"
            }
        } else {
            location = "in the document"
        }
        let matchClause = termTexts.count == 1
            ? "It matches text you redacted elsewhere."
            : "They match text you redacted elsewhere."
        return "\(quoted) \(verb) still readable \(location). \(matchClause) "
            + "Use text search to redact remaining instances."
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
    static func queryLineText(_ line: SearchRecheckQueryLine) -> String {
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
    static func perTermLineTexts(_ line: SearchRecheckQueryLine) -> [String] {
        (line.perTerm ?? []).map { term in
            var text = "\u{201C}\(term.term)\u{201D}"
            if let found = term.found { text += " · found \(found)" }
            if let applied = term.applied { text += " · applied \(applied)" }
            text += " · \(term.remaining) remain"
            return text
        }
    }

    /// Every query-line text the expanded row renders, in display order:
    /// each query line followed by its per-term sub-lines. Empty when the
    /// layer carries no query lines (every layer but the Search Re-check,
    /// and the re-check's INFO row).
    static func queryLineTexts(layer: LayerResult) -> [String] {
        (layer.queryLines ?? []).flatMap { line in
            [queryLineText(line)] + perTermLineTexts(line)
        }
    }

    // MARK: - Spoken strings (static for unit testability)

    /// Row label: layer ordinal + name + layer-scoped phrase + what the
    /// check reported. `shortDescription` is the payload for warn/fail/info
    /// rows, and previously was never spoken. Page count rides along when
    /// the layer carries page references. The duration is not spoken: it
    /// is not in the collapsed row, and the expanded row's timing line is
    /// its own reachable element. Attention rows speak the same composed
    /// sentence they display.
    static func accessibilityLabel(layerIndex: Int, layer: LayerResult) -> String {
        var label = "Layer \(layerIndex), \(layer.name), \(layer.status.layerAccessibilityPhrase) \(Self.rowSubtitleText(layer: layer))"
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
