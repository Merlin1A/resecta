import SwiftUI
import RedactionEngine

// UI_UX §4.2: Per-layer result row with expand/collapse.
// Shared between VerificationProgressView and VerificationResultsView.

struct LayerResultRow: View {
    let layer: LayerResult
    let layerIndex: Int
    let isExpanded: Bool
    let onTap: () -> Void
    /// §4.3a: Use neutral gray for PASS during .verifying phase.
    var useIntermediateColors: Bool = false

    /// GAP-4 §7.2: Called when a page reference number is tapped. Nil during .verifying phase
    /// (page navigation from in-progress verification is not supported).
    var onPageTap: ((Int) -> Void)? = nil

    /// False in VerificationProgressView, where rows are display-only
    /// (`isExpanded: false, onTap: {}`) — a "Tap to expand details" hint
    /// there advertises a no-op.
    var isExpandable: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — always visible
            Button(action: onTap) {
                HStack(spacing: ResectaTokens.Spacing.sm) {
                    Image(systemName: layer.symbolName)
                        .foregroundStyle(useIntermediateColors
                                         ? layer.status.intermediateColor
                                         : layer.status.color)
                        .font(.title3)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                        Text("Layer \(layerIndex): \(layer.name)")
                            .font(.subheadline.weight(.medium))
                        Text(Self.rowSubtitleText(layer: layer))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Per-layer timing
                    if layer.durationSeconds > 0 {
                        Text(String(format: "%.1fs", layer.durationSeconds))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }

                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .padding(ResectaTokens.Spacing.sm)
            }
            .buttonStyle(.plain)
            // Explicit label so what the check reported (`shortDescription`)
            // is spoken — combining children then labeling the CONTAINER
            // (the prior shape) silenced it. Collapsed, the outer `.combine` merges this
            // into the single row element; expanded (`.contain`), the header
            // stays one focusable element with the same label while the
            // detail text and page chips become real, reachable elements.
            .accessibilityLabel(Self.accessibilityLabel(layerIndex: layerIndex, layer: layer))
            .accessibilityHint(Self.accessibilityHint(isExpandable: isExpandable, isExpanded: isExpanded))

            // Expanded detail
            if isExpanded {
                VStack(alignment: .leading, spacing: ResectaTokens.Spacing.sm) {
                    Text(layer.detailDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // GAP-4 §7.1: Tappable page reference chips (static fallback when onPageTap is nil)
                    if let pages = layer.pageReferences, !pages.isEmpty {
                        if let onPageTap {
                            FlowLayout(spacing: ResectaTokens.Spacing.xs) {
                                Text("Affected pages:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                ForEach(pages, id: \.self) { pageRef in
                                    PageChip(pageIndex: pageRef) {
                                        onPageTap(pageRef)
                                    }
                                }
                            }
                        } else {
                            // Same 1-based display convention as PageChip (storage is 0-based).
                            Text("Affected pages: \(pages.map { String($0 + 1) }.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, ResectaTokens.Spacing.sm)
                .padding(.bottom, ResectaTokens.Spacing.sm)
                .padding(.leading, 40) // Align with text, past 28pt icon + sm padding
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ResectaTokens.CornerRadius.toast))
        // Collapsed: one combined element (header label above). Expanded:
        // a container, so VoiceOver can reach the detail text and the
        // "Go to page N" chips instead of having them flattened away.
        .accessibilityElement(children: isExpanded ? .contain : .combine)
        .accessibilityIdentifier("layerResult_\(layerIndex - 1)") // §A8: zero-indexed
    }

    // MARK: - Row subtitle (attention rows name the exact text)

    /// Collapsed-row payload. Attention rows compose a sentence from the
    /// display-only review term texts — the user reads exactly which text
    /// remains and how to remedy it; every other status shows the layer's
    /// own `shortDescription` unchanged. Static so the composition is
    /// unit-testable without a SwiftUI host (Pkg J pattern).
    static func rowSubtitleText(layer: LayerResult) -> String {
        guard layer.status.isAttention,
              let terms = layer.reviewTermTexts, !terms.isEmpty else {
            return layer.shortDescription
        }
        return reviewRowText(termTexts: terms, pages: layer.pageReferences)
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

    // MARK: - Spoken strings (static for unit testability, Pkg J pattern)

    /// Row label: layer ordinal + name + layer-scoped phrase + what the
    /// check reported. `shortDescription` is the payload for warn/fail/info
    /// rows, and previously was never spoken. Page count rides along when
    /// the layer carries page references; duration tail as before.
    /// Attention rows speak the same composed sentence they display.
    static func accessibilityLabel(layerIndex: Int, layer: LayerResult) -> String {
        var label = "Layer \(layerIndex), \(layer.name), \(layer.status.layerAccessibilityPhrase) \(Self.rowSubtitleText(layer: layer))"
        if let pages = layer.pageReferences, !pages.isEmpty {
            label += ", \(pages.count) affected page\(pages.count == 1 ? "" : "s")"
        }
        if layer.durationSeconds > 0 {
            label += ", \(String(format: "%.1f", layer.durationSeconds)) seconds"
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
