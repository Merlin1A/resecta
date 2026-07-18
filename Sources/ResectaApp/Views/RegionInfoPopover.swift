import SwiftUI
import RedactionEngine

// GAP §6.2: Hover popover content for detected regions on iPad.
// Shows badge, description, matched text (privacy-sensitive), and scan level.

struct RegionInfoPopover: View {
    let metadata: RegionMetadata
    /// W9 — present the "Why this match?" popover. nil-callback hides the button.
    var onRequestWhy: ((String) -> Void)? = nil
    /// WU-71 / [P10] path (a): forward-rationale carried by the region's
    /// `Source`. nil hides the disclosure entirely. When non-nil the row
    /// renders rule ID + final score so the reviewer sees the detector's
    /// own reasoning without opening a separate sheet.
    var rationale: MatchRationale? = nil

    @State private var isRationaleExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xs) {
            HStack {
                Text(metadata.badgeLabel)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, ResectaTokens.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(kindColor, in: RoundedRectangle(
                        cornerRadius: ResectaTokens.CornerRadius.small,
                        style: .continuous
                    ))
                Text(metadata.accessibilityDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let text = metadata.matchedText {
                Text(text)
                    .font(.caption.monospaced())
                    .privacySensitive()
                    .lineLimit(2)
            }

            HStack(spacing: ResectaTokens.Spacing.xs) {
                Image(systemName: metadata.recognitionLevel == .accurate
                      ? "tortoise" : "hare")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                // Recognition levels present as Fast / Thorough
                // (hare / tortoise icons carry).
                Text(metadata.recognitionLevel == .accurate
                     ? "Thorough scan" : "Fast scan")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)

            // WU-71 — forward rationale disclosure. Visible only when the
            // region's `Source` carries a non-nil `MatchRationale` (i.e.
            // the region was applied from a search result that had detector
            // reasoning attached). Distinct from the W9 reverse-rationale
            // path below — this one shows what the detector recorded at
            // detect time, not what `reverseRationale` synthesizes now.
            if let rationale {
                DisclosureGroup(isExpanded: $isRationaleExpanded) {
                    // Human detector name (shared catalog);
                    // raw ruleID kept for audit correlation; score
                    // labeled as the detector's, not the row confidence.
                    VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                        Text("Detector: \(DetectorNameCatalog.displayName(forRuleID: rationale.ruleID))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if DetectorNameCatalog.humanName(forRuleID: rationale.ruleID) != nil {
                            Text(rationale.ruleID)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        Text("Detector score: \(Self.formatScore(rationale.finalScore))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, ResectaTokens.Spacing.xs)
                } label: {
                    Label("View rationale", systemImage: "doc.text.magnifyingglass")
                        .font(.caption)
                }
                .accessibilityLabel("View rationale, detector \(DetectorNameCatalog.displayName(forRuleID: rationale.ruleID))")
            }

            // W9 — reverse rationale entry. Visible only for PII regions
            // that carry matched text (we need a snippet to score).
            if let text = metadata.matchedText,
               case .pii = metadata.piiKind,
               let onRequestWhy {
                Button {
                    onRequestWhy(text)
                } label: {
                    Label("Why this match?", systemImage: "questionmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, ResectaTokens.Spacing.xxs)
            }
        }
        .padding(ResectaTokens.Spacing.sm)
    }

    /// WU-71: compact percentage formatter for the forward-rationale row.
    /// Mirrors `MatchRationaleSheet.formatScore` so the two surfaces show
    /// the same number for the same input.
    static func formatScore(_ score: Double) -> String {
        let pct = Int((score * 100).rounded())
        return "\(pct)%"
    }

    // F2-2: Match canvas overlay colors — uses SemanticColor tokens
    private var kindColor: Color {
        switch metadata.piiKind {
        case .pii: ResectaTokens.SemanticColor.badgePII
        case .face: ResectaTokens.SemanticColor.badgeFace
        case .searchMatch: Color(uiColor: .systemGreen)
        }
    }
}
