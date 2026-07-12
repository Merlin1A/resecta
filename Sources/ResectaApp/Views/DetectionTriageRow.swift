import SwiftUI
import RedactionEngine

// GAP §4.3: Per-detection row in the triage sheet.

struct DetectionTriageRow: View {
    @Environment(RedactionState.self) private var redactionState
    let page: Int
    let detection: DetectionResult
    @Binding var isAccepted: Bool
    var onRequestWhy: ((DetectionResult) -> Void)? = nil

    private var isAmbiguousSurname: Bool {
        redactionState.ambiguousSurnameDetectionIDs.contains(detection.id)
    }

    var body: some View {
        HStack(spacing: ResectaTokens.Spacing.sm) {
            // Acceptance toggle (iOS uses checkmark circle; .checkbox is macOS-only)
            Button {
                isAccepted.toggle()
            } label: {
                Image(systemName: isAccepted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isAccepted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .frame(width: 28)
            .sensoryFeedback(.selection, trigger: isAccepted) // §4.6: haptic on toggle

            // PII type badge
            Text(detection.kind.badge)
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, ResectaTokens.Spacing.xs)
                .padding(.vertical, ResectaTokens.Spacing.xxs)
                .background(detection.kind.badgeColor, in: RoundedRectangle(
                    cornerRadius: ResectaTokens.CornerRadius.small,
                    style: .continuous
                ))

            // Detection info
            VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                if let text = detection.matchedText {
                    // §4.5: .privacySensitive() redacts in screen recordings
                    Text(text)
                        .font(.subheadline.monospaced())
                        .lineLimit(1)
                        .privacySensitive()
                } else {
                    Text(detection.kind.fullName)
                        .font(.subheadline)
                }
                HStack(spacing: ResectaTokens.Spacing.xs) {
                    Text("Page \(page + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\u{00B7}")
                        .foregroundStyle(.quaternary)
                    // The bare percent gets its noun so it can't be
                    // confused with the detector score shown in the
                    // evaluation popover (different quantities).
                    Text("\(Int(detection.confidence * 100))% confidence")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(confidenceColor)
                }
                // Phase 3 §A5: bare-surname cluster hint.
                if isAmbiguousSurname {
                    // Caption2 text takes the AA text-tier shade;
                    // the triangle keeps systemYellow (glyph tier — the hint
                    // is redundantly coded by icon + label).
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

            // W9 — reverse rationale entry point. Shown only when a callback
            // is supplied (Triage sheet wires it in; callers that don't want
            // the affordance pass nil).
            if let onRequestWhy, detection.matchedText != nil {
                Button {
                    onRequestWhy(detection)
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show detector evaluation")
            }
        }
        .padding(.vertical, ResectaTokens.Spacing.xxs)
        .opacity(isAccepted ? 1.0 : ResectaTokens.Opacity.disabled)
        .animation(ResectaTokens.Anim.stateChange, value: isAccepted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(isAccepted ? .isSelected : [])
    }

    // MARK: - Computed Properties

    // The % renders as caption-size TEXT, so it uses the
    // AA-validated status text tier, not the shared fill-tier constants
    // (those still drive the SearchResultRow confidence bar).
    private var confidenceColor: Color {
        if detection.confidence >= 0.9 { ResectaTokens.SemanticColor.passText }
        else if detection.confidence >= 0.7 { ResectaTokens.SemanticColor.confidenceMediumText }
        else { ResectaTokens.SemanticColor.warnText }
    }

    // F-7: accessibilityLabel intentionally includes matchedText.
    // The triage sheet is a review context where the user is actively examining
    // PII content to make accept/reject decisions. VoiceOver users need the same
    // content visibility as sighted users. This is a deliberate design asymmetry.
    private var accessibilityDescription: String {
        let status = isAccepted ? "Selected" : "Deselected"
        let text = detection.matchedText.map { ", \($0)" } ?? ""
        return "\(status). \(detection.kind.fullName)\(text). Page \(page + 1). \(Int(detection.confidence * 100))% confidence."
    }
}
