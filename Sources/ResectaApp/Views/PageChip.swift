import SwiftUI

// The page link of a results row: "Page N" on a tertiary capsule, 26 pt
// tall, inside a 46-pt hit frame. It opens the Preview at that page; its
// spoken label names where it goes. 1-indexed display, 0-indexed data.

struct PageChip: View {
    let pageIndex: Int  // 0-indexed
    let action: () -> Void

    @ScaledMetric(relativeTo: .footnote) private var height: CGFloat = ResectaTokens.Results.chipHeight

    var body: some View {
        Button(action: action) {
            Text("Page \(pageIndex + 1)")  // 1-indexed display
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(ResectaTokens.BrandTeal.text)
                .padding(.horizontal, ResectaTokens.Results.chipPadding)
                .frame(minHeight: height)
                .background(Color(.tertiarySystemFill), in: Capsule())
                // The 46-pt hit frame reaches past the drawn capsule
                // without taking layout space: the meta line stays tight.
                .frame(minHeight: ResectaTokens.TouchTarget.minimum)
                .contentShape(Rectangle())
                .padding(.vertical, -(ResectaTokens.TouchTarget.minimum - ResectaTokens.Results.chipHeight) / 2)
        }
        .buttonStyle(PageChipButtonStyle())
        .accessibilityLabel("Go to page \(pageIndex + 1)")
    }
}

/// The chip's press: half opacity, no other effect.
private struct PageChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? ResectaTokens.Results.chipPressedOpacity : 1)
    }
}
