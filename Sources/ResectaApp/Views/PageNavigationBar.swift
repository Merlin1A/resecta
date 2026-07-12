import SwiftUI

// UI_UX §6.5: iPhone-only floating page navigation bar.
// Placed as .safeAreaInset(edge: .bottom) on the editor view.

struct PageNavigationBar: View {
    @Environment(DocumentState.self) private var documentState
    @Environment(RedactionState.self) private var redactionState

    var body: some View {
        HStack(spacing: ResectaTokens.Spacing.md) {
            Button("Previous", systemImage: "chevron.left") {
                documentState.currentPageIndex = max(0, documentState.currentPageIndex - 1)
            }
            .disabled(documentState.currentPageIndex <= 0)

            // Phase 4B: Page label + region count for iPhone
            HStack(spacing: ResectaTokens.Spacing.xs) {
                Text("Page \(documentState.currentPageIndex + 1) of \(documentState.pageCount)")
                    .font(.subheadline.monospacedDigit())

                let count = redactionState.regions[documentState.currentPageIndex]?.count ?? 0
                if count > 0 {
                    Text("\u{B7}")
                        .foregroundStyle(.quaternary)
                        .padding(.horizontal, ResectaTokens.Spacing.xxs)
                    Text("\(count) region\(count == 1 ? "" : "s")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ResectaTokens.SemanticColor.regionCountAccent)
                }
            }

            Button("Next", systemImage: "chevron.right") {
                documentState.currentPageIndex = min(
                    documentState.pageCount - 1,
                    documentState.currentPageIndex + 1
                )
            }
            .disabled(documentState.currentPageIndex >= documentState.pageCount - 1)
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.sm)
        .glassEffect(.regular.interactive())
        .accessibilityIdentifier("pageNav") // §A8
    }
}
