import SwiftUI
import RedactionEngine

// One row family for the unified review surface. Both result origins —
// engine `SearchResult`s (search + scan runs) and staged
// `DetectionResult`s (detections under review) — render through
// `FindingRow` from a `FindingRowModel` adapter. The adapter is the
// app-side substitute for a shared engine-level result type: it carries
// the display shape both origins have in common; origin-specific
// accessories (source badges, rationale disclosure, applied markers,
// detector-evaluation entry) mount through the row's slots.

/// Display adapter over the two result origins.
struct FindingRowModel: Identifiable, Equatable {
    let id: UUID
    let pageIndex: Int
    /// Primary line. Matched text when the item carries one; the
    /// kind's full name for non-text kinds (face / signature
    /// candidate), which have no text to show.
    let title: String
    /// True when `title` is document-derived content (matched text) —
    /// drives `.privacySensitive()` and the monospaced content font.
    /// False when the title is a kind name.
    let titleIsContent: Bool
    /// Secondary line: context snippet (search origin) or the
    /// confidence sentence (detection origin). nil hides the line.
    let secondaryText: String?
    /// True when `secondaryText` is document-derived content.
    let secondaryIsContent: Bool
    /// Phase 3 §A5 — bare-surname cluster hint row.
    let showsAmbiguousSurnameHint: Bool
    /// Accessibility label for the combined row. The two origins keep
    /// their deliberate asymmetry: detection review rows speak matched
    /// text (F-7 — an active PII-review context where VoiceOver users
    /// need the same content visibility as sighted users); search rows
    /// never speak matched text.
    let accessibilityDescription: String
}

extension FindingRowModel {
    /// Search-origin adapter. Page + selection state surface through
    /// the row chrome; the a11y contract deliberately names the page
    /// only, never matched text.
    init(result: SearchResult) {
        self.init(
            id: result.id,
            pageIndex: result.pageIndex,
            title: result.matchedText,
            titleIsContent: true,
            secondaryText: result.contextSnippet,
            secondaryIsContent: true,
            showsAmbiguousSurnameHint: false,
            accessibilityDescription: "Search match, page \(result.pageIndex + 1)"
        )
    }

    /// Detection-origin adapter. Non-text kinds (face, signature
    /// candidate) render their kind name as the title; the confidence
    /// line carries the noun so the percent can't be confused with the
    /// detector score shown in the evaluation popover.
    init(
        page: Int,
        detection: DetectionResult,
        isSelected: Bool,
        isAmbiguousSurname: Bool
    ) {
        let hasText = detection.matchedText != nil
        // F-7: detection review rows deliberately include matched text
        // in VoiceOver output — the user is actively examining PII
        // content to make accept/reject decisions.
        let status = isSelected ? "Selected" : "Deselected"
        let text = detection.matchedText.map { ", \($0)" } ?? ""
        self.init(
            id: detection.id,
            pageIndex: page,
            title: detection.matchedText ?? detection.kind.fullName,
            titleIsContent: hasText,
            secondaryText: "\(Int(detection.confidence * 100))% confidence",
            secondaryIsContent: false,
            showsAmbiguousSurnameHint: isAmbiguousSurname,
            accessibilityDescription:
                "\(status). \(detection.kind.fullName)\(text). Page \(page + 1). "
                + "\(Int(detection.confidence * 100))% confidence."
        )
    }
}

/// The shared row: [leading slot][selection circle][badge slot]
/// [title + secondary + hint][spacer][trailing slot][page indicator].
/// Selection circle, content column, privacy redaction, selected trait,
/// and the combined-a11y contract live here once; origin-specific
/// accessories mount through the slots.
struct FindingRow<Leading: View, Badge: View, Trailing: View>: View {
    let model: FindingRowModel
    @Binding var isSelected: Bool
    /// Leading edge (search rows mount the confidence bar; detection
    /// rows the same bar graded on detection confidence).
    @ViewBuilder var leading: () -> Leading
    /// Badge slot (source badge / kind badge).
    @ViewBuilder var badge: () -> Badge
    /// Trailing accessories (term label, rationale chevron, detector
    /// evaluation entry).
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 0) {
            leading()

            HStack(spacing: ResectaTokens.Spacing.sm) {
                // Selection toggle — the one selection circle both
                // origins share.
                Button {
                    isSelected.toggle()
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .frame(width: 28)
                .sensoryFeedback(.selection, trigger: isSelected) // §4.6: haptic on toggle

                badge()

                VStack(alignment: .leading, spacing: 2) {
                    if model.titleIsContent {
                        // §4.5: .privacySensitive() redacts in captures.
                        Text(model.title)
                            .font(.subheadline.monospaced())
                            .lineLimit(1)
                            .privacySensitive()
                    } else {
                        Text(model.title)
                            .font(.subheadline)
                    }

                    if let secondary = model.secondaryText {
                        if model.secondaryIsContent {
                            Text(secondary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .privacySensitive()
                        } else {
                            Text(secondary)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    // Phase 3 §A5: bare-surname cluster hint.
                    if model.showsAmbiguousSurnameHint {
                        Label {
                            Text("Common surname — verify context")
                                .foregroundStyle(ResectaTokens.SemanticColor.confidenceMediumText)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(Color(uiColor: .systemYellow))
                        }
                        .font(.caption2)
                        .accessibilityLabel("Common surname, verify context before applying")
                    }
                }

                Spacer()

                trailing()

                // Page indicator
                Text("p.\(model.pageIndex + 1)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, ResectaTokens.Spacing.xs)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityDescription)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // The `.ignore` merge hides the inner selection circle from
        // VoiceOver; the named action keeps non-visual selection
        // first-class on both origins (the retired triage row's
        // `.combine` surfaced the toggle implicitly).
        .accessibilityAction(named: "Toggle selection") {
            isSelected.toggle()
        }
    }
}

// MARK: - Shared confidence-tier contract

extension FindingRow where Leading == EmptyView, Badge == EmptyView, Trailing == EmptyView {
    /// Convenience for tests/previews: a bare row with empty slots.
    init(model: FindingRowModel, isSelected: Binding<Bool>) {
        self.init(
            model: model,
            isSelected: isSelected,
            leading: { EmptyView() },
            badge: { EmptyView() },
            trailing: { EmptyView() }
        )
    }
}
