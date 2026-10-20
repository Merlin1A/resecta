import SwiftUI
import RedactionEngine

// iPhone-only floating page navigation bar.
// Placed as .safeAreaInset(edge: .bottom) on the editor view.
// Chevron-only buttons — the word titles ellipsized on
// iPhone widths ("Previo…") — and the center counter drops the word
// "Page"; the full words survive as accessibility labels. Matches the
// sheet's result-nav chevron idiom. The whole-page action sits at the
// trailing end in the same glyph grammar: one tap marks the page on
// screen as a region through the ordinary add path.

struct PageNavigationBar: View {
    @Environment(DocumentState.self) private var documentState
    @Environment(RedactionState.self) private var redactionState
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        HStack(spacing: ResectaTokens.Spacing.md) {
            Button {
                documentState.currentPageIndex = max(0, documentState.currentPageIndex - 1)
            } label: {
                // This pair measured as the smallest
                // interactive targets in the app (12.7×16.7 at Large
                // type) — the bare glyph carried no hit-area floor.
                Image(systemName: "chevron.left")
                    .frame(
                        width: ResectaTokens.TouchTarget.minimum,
                        height: ResectaTokens.TouchTarget.minimum
                    )
                    .contentShape(Rectangle())
            }
            // Label + identifier BEFORE `.disabled` — the header-section
            // modifier order, keeping the AX surface (and XCUI queries)
            // alive in the disabled state (first / last page).
            .accessibilityLabel("Previous page")
            .accessibilityIdentifier("pageNavPrevious")
            .disabled(documentState.currentPageIndex <= 0)

            // Page position + region count for iPhone — ONE spoken
            // element ("Page k of N, n regions"); the drawn pieces
            // (the counter, the dot, the count) stay separate views.
            let count = redactionState.regions[documentState.currentPageIndex]?.count ?? 0
            HStack(spacing: ResectaTokens.Spacing.xs) {
                Text("\(documentState.currentPageIndex + 1) of \(documentState.pageCount)")
                    .font(.subheadline.monospacedDigit())

                if let countLabel = PageNavigationBar.regionCountLabel(count) {
                    Text("\u{B7}")
                        .foregroundStyle(.quaternary)
                        .padding(.horizontal, ResectaTokens.Spacing.xxs)
                    Text(countLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ResectaTokens.SemanticColor.regionCountAccent)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PageNavigationBar.pageAccessibilityLabel(
                page: documentState.currentPageIndex + 1,
                pageCount: documentState.pageCount,
                regionCount: count
            ))
            .accessibilityIdentifier("pageNavCounter")

            Button {
                documentState.currentPageIndex = min(
                    documentState.pageCount - 1,
                    documentState.currentPageIndex + 1
                )
            } label: {
                Image(systemName: "chevron.right")
                    .frame(
                        width: ResectaTokens.TouchTarget.minimum,
                        height: ResectaTokens.TouchTarget.minimum
                    )
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Next page")
            .accessibilityIdentifier("pageNavNext")
            .disabled(documentState.currentPageIndex >= documentState.pageCount - 1)

            // The whole-page action. Never disabled: the bar shows only
            // in the editing phase of a multi-page document, where a
            // region may always be added to the page on screen.
            Button {
                PageNavigationBar.markWholePage(
                    redactionState: redactionState,
                    documentState: documentState,
                    undoManager: undoManager
                )
            } label: {
                Image(systemName: "rectangle.inset.filled")
                    .frame(
                        width: ResectaTokens.TouchTarget.minimum,
                        height: ResectaTokens.TouchTarget.minimum
                    )
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Mark Whole Page")
            .accessibilityIdentifier("pageNavMarkWholePage")
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
        .accessibilityIdentifier("pageNav")
    }
}

extension PageNavigationBar {
    /// The region the whole-page action adds: the page's unit rectangle
    /// in normalized coordinates — invariant to the page's rotation and
    /// crop, clamped at run entry as every region is, skipped by the
    /// manual-term capture (it covers the page, so it names no term)
    /// and counted by the bar as one region.
    static func wholePageRegion() -> RedactionRegion {
        RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            source: .manual
        )
    }

    /// Mark the page on screen: one `.manual` unit-rect region on
    /// `documentState.currentPageIndex` through `addRegion`, the path a
    /// drawn region takes — the region version moves (the overlay
    /// refreshes on it), the output is cleared, one undo step named
    /// "Add Redaction" is registered. A repeated tap adds another
    /// region, each its own undo step.
    static func markWholePage(
        redactionState: RedactionState,
        documentState: DocumentState,
        undoManager: UndoManager?
    ) {
        redactionState.addRegion(
            wholePageRegion(),
            page: documentState.currentPageIndex,
            undoManager: undoManager
        )
    }

    /// The counter's text for `count` regions on the page: nil when the
    /// page has none, "1 region", else "N regions".
    static func regionCountLabel(_ count: Int) -> String? {
        count > 0 ? "\(count) region\(count == 1 ? "" : "s")" : nil
    }

    /// The counter's one spoken label: "Page k of N" plus ", n regions"
    /// where the page has any (the drawn counter dropped the word
    /// "Page"; the spoken form keeps it).
    static func pageAccessibilityLabel(page: Int, pageCount: Int, regionCount: Int) -> String {
        let base = "Page \(page) of \(pageCount)"
        return regionCountLabel(regionCount).map { "\(base), \($0)" } ?? base
    }
}
