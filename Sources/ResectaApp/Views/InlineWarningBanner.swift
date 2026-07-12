import SwiftUI

// §A4d / C2: Non-blocking yellow banner for recoverable states.
// Used for: background resume (D11), import-while-editing warnings.

struct InlineWarningBanner: View {
    let message: String
    var primaryAction: (label: String, action: () -> Void)? = nil
    let onDismiss: () -> Void

    // ACCESSIBILITY.md §9.3 — at AX5 the warning text lifts to 3 lines so
    // the message stays readable at the largest accessibility text size.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: ResectaTokens.Spacing.sm) {
            // ACCESSIBILITY.md §9.2 — decorative; the warning Text below
            // carries the announcement, and `.accessibilityAddTraits(.isHeader)`
            // on the container already routes VoiceOver to the message string.
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(message)
                .font(.subheadline)
                .lineLimit(Self.lineLimit(for: dynamicTypeSize))

            Spacer()

            if let primaryAction {
                Button(primaryAction.label, action: primaryAction.action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Button("Dismiss", systemImage: "xmark.circle.fill") {
                onDismiss()
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
        }
        .padding(ResectaTokens.Spacing.sm)
        .background(ResectaTokens.SemanticColor.warningTint.opacity(0.12),
                    in: .rect(cornerRadius: ResectaTokens.CornerRadius.medium))
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .accessibilityIdentifier("inlineWarning")
        .accessibilityAddTraits(.isHeader) // §A8: ensures VoiceOver announces on appearance
    }

    /// AX5 line-limit predicate. Returns 3 at `.accessibility5` or larger;
    /// 2 otherwise. Exposed as a static so the contract can be unit-tested
    /// without rendering the view.
    static func lineLimit(for size: DynamicTypeSize) -> Int {
        size >= .accessibility5 ? 3 : 2
    }
}
