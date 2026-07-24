import SwiftUI

// UI_UX §6.5: iPhone-only floating page navigation bar.
// Placed as .safeAreaInset(edge: .bottom) on the editor view.
// WA/D-75 (R-2): chevron-only buttons — the word titles ellipsized on
// iPhone widths ("Previo…") — and the center counter drops the word
// "Page"; the full words survive as accessibility labels. Matches the
// sheet's result-nav chevron idiom.

struct PageNavigationBar: View {
    @Environment(DocumentState.self) private var documentState
    @Environment(RedactionState.self) private var redactionState

    var body: some View {
        HStack(spacing: ResectaTokens.Spacing.md) {
            Button {
                documentState.currentPageIndex = max(0, documentState.currentPageIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            // Label + identifier BEFORE `.disabled` — the header-section
            // modifier order, keeping the AX surface (and XCUI queries)
            // alive in the disabled state (first / last page).
            .accessibilityLabel("Previous page")
            .accessibilityIdentifier("pageNavPrevious")
            .disabled(documentState.currentPageIndex <= 0)

            // Phase 4B: page position + region count for iPhone
            HStack(spacing: ResectaTokens.Spacing.xs) {
                Text("\(documentState.currentPageIndex + 1) of \(documentState.pageCount)")
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

            Button {
                documentState.currentPageIndex = min(
                    documentState.pageCount - 1,
                    documentState.currentPageIndex + 1
                )
            } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel("Next page")
            .accessibilityIdentifier("pageNavNext")
            .disabled(documentState.currentPageIndex >= documentState.pageCount - 1)
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.sm)
        .glassEffect(.regular.interactive())
        // `.contain` scopes the bar identifier to the CONTAINER: a
        // bare identifier on a plain stack cascades onto every
        // descendant AX element (live-observed: both chevrons and the
        // counter all reported "pageNav"), which erases the per-button
        // identifiers the page-bar pin queries.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pageNav") // §A8
    }
}
