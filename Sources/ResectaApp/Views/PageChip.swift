import SwiftUI

// Shared tappable page pill button — extracted from LayerResultRow inline styling.
// Used in LayerResultRow.
// 1-indexed display, 0-indexed data.

struct PageChip: View {
    let pageIndex: Int  // 0-indexed
    let action: () -> Void

    // The wash opacity is per appearance (tileWashLight / tileWashDark).
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            // The numeral on the brand text tier over the teal wash — the
            // `FilterChip` recipe: the drawn capsule stays small, the
            // 46-pt layout frame around it is the hit target.
            Text("\(pageIndex + 1)")  // 1-indexed display
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(ResectaTokens.BrandTeal.text)
                .padding(.horizontal, ResectaTokens.Spacing.sm)
                .padding(.vertical, ResectaTokens.Spacing.xs)
                .background(
                    ResectaTokens.BrandTeal.tint.opacity(
                        colorScheme == .dark
                            ? ResectaTokens.Opacity.tileWashDark
                            : ResectaTokens.Opacity.tileWashLight),
                    in: Capsule())
                .frame(minWidth: ResectaTokens.TouchTarget.minimum,
                       minHeight: ResectaTokens.TouchTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Go to page \(pageIndex + 1)")
    }
}
