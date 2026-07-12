import SwiftUI

// Shared tappable page pill button — extracted from LayerResultRow inline styling.
// Used in LayerResultRow.
// VERIFICATION_UI §7.1: 1-indexed display, 0-indexed data.

struct PageChip: View {
    let pageIndex: Int  // 0-indexed
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(pageIndex + 1)")  // 1-indexed display
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tint)
                .padding(.horizontal, ResectaTokens.Spacing.xs)
                .padding(.vertical, ResectaTokens.Spacing.xxs)
                .background(.tint.opacity(0.1),
                           in: RoundedRectangle(cornerRadius: ResectaTokens.CornerRadius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Go to page \(pageIndex + 1)")
    }
}
