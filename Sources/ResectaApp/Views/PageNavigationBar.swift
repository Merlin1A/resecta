import SwiftUI
import RedactionEngine

// iPhone-only floating page navigation bar.
// Placed as .safeAreaInset(edge: .bottom) on the editor view.
// Chevron-only buttons — the word titles ellipsized on
// iPhone widths ("Previo…") — and the center counter drops the word
// "Page"; the full words survive as accessibility labels. Matches the
// sheet's result-nav chevron idiom. The whole-page control sits at the
// trailing end in the same glyph grammar: one tap marks the page on
// screen as a region, the next tap unmarks it. A one-page document gets
// the bar for its region count, without the page arrows or the control
// (the editor's … menu keeps Mark Whole Page for that case).

struct PageNavigationBar: View {
    @Environment(DocumentState.self) private var documentState
    @Environment(RedactionState.self) private var redactionState
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let pageCount = documentState.pageCount
        let marked = PageNavigationBar.isWholePageMarked(
            page: documentState.currentPageIndex, in: redactionState)
        HStack(spacing: ResectaTokens.Spacing.md) {
            if PageNavigationBar.showsChevrons(pageCount: pageCount) {
                Button {
                    PageNavigationBar.showPage(
                        max(0, documentState.currentPageIndex - 1),
                        documentState: documentState, redactionState: redactionState)
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
            }

            // Page position + region count for iPhone — ONE spoken
            // element ("Page k of N, n regions"); the drawn pieces
            // (the counter, the dot, the count) stay separate views.
            let count = redactionState.regions[documentState.currentPageIndex]?.count ?? 0
            HStack(spacing: ResectaTokens.Spacing.xs) {
                Text("\(documentState.currentPageIndex + 1) of \(pageCount)")
                    .font(.subheadline.monospacedDigit())

                Text("\u{B7}")
                    .foregroundStyle(.quaternary)
                    .padding(.horizontal, ResectaTokens.Spacing.xxs)
                // The count's slot is as wide as the wider of "0 regions"
                // and the live count (both laid out, one hidden), so the
                // bar keeps its width — and the whole-page control its
                // place under the finger — when a tap adds the first
                // region or removes the last.
                ZStack(alignment: .leading) {
                    Text(PageNavigationBar.regionCountLabel(0))
                        .hidden()
                        .accessibilityHidden(true)
                    Text(PageNavigationBar.regionCountLabel(count))
                        .foregroundStyle(count == 0
                            ? AnyShapeStyle(.tertiary)
                            : AnyShapeStyle(ResectaTokens.SemanticColor.regionCountAccent))
                }
                .font(.caption.monospacedDigit())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PageNavigationBar.pageAccessibilityLabel(
                page: documentState.currentPageIndex + 1,
                pageCount: pageCount,
                regionCount: count
            ))
            .accessibilityIdentifier("pageNavCounter")

            if PageNavigationBar.showsChevrons(pageCount: pageCount) {
                Button {
                    PageNavigationBar.showPage(
                        min(pageCount - 1, documentState.currentPageIndex + 1),
                        documentState: documentState, redactionState: redactionState)
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
                .disabled(documentState.currentPageIndex >= pageCount - 1)
            }

            // The whole-page control. Never disabled: on a page it can
            // show, the page on screen can always be marked or unmarked.
            // Marked, it sits on a plain teal disc with a white glyph — a
            // fill, never a second glass layer inside the glass bar.
            if PageNavigationBar.showsMarkControl(pageCount: pageCount) {
                Button {
                    PageNavigationBar.toggleWholePage(
                        redactionState: redactionState,
                        documentState: documentState,
                        undoManager: undoManager
                    )
                } label: {
                    Image(systemName: "rectangle.inset.filled")
                        .foregroundStyle(marked ? AnyShapeStyle(Color.white) : AnyShapeStyle(.tint))
                        .frame(
                            width: ResectaTokens.TouchTarget.minimum,
                            height: ResectaTokens.TouchTarget.minimum
                        )
                        .background {
                            if marked {
                                Circle()
                                    .fill(ResectaTokens.BrandTeal.fill)
                                    .frame(
                                        width: PageNavigationBar.markedDiscDiameter,
                                        height: PageNavigationBar.markedDiscDiameter
                                    )
                            }
                        }
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(PageNavigationBar.wholePageActionLabel(marked: marked))
                .accessibilityAddTraits(marked ? .isSelected : [])
                .accessibilityIdentifier("pageNavMarkWholePage")
            }
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
    /// The marked control's disc: the 44-pt circle inside the control's
    /// 46-pt touch floor.
    static let markedDiscDiameter: CGFloat = 44

    /// The control's words, which are also the undo steps' names: Mark on
    /// an unmarked page, Unmark on a marked one.
    static let markWholePageLabel = "Mark Whole Page"
    static let unmarkWholePageLabel = "Unmark Whole Page"

    static func wholePageActionLabel(marked: Bool) -> String {
        marked ? unmarkWholePageLabel : markWholePageLabel
    }

    /// The page arrows' page write: the page shown moves, and a parked
    /// search walk lets go of a current match on another page, so the
    /// strip's Apply never acts on a match out of view.
    static func showPage(_ page: Int, documentState: DocumentState, redactionState: RedactionState) {
        documentState.currentPageIndex = page
        redactionState.activeSearch?.yieldWalk(toPage: page)
    }

    /// The page arrows step between pages: none on a one-page document.
    static func showsChevrons(pageCount: Int) -> Bool { pageCount > 1 }

    /// The bar's whole-page control: hidden on a one-page document, where
    /// the … menu's row keeps the action.
    static func showsMarkControl(pageCount: Int) -> Bool { pageCount > 1 }

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

    /// The page's whole-page region: a `.manual` region covering the
    /// page's unit rectangle.
    private static func wholePageRegion(on page: Int, in redactionState: RedactionState) -> RedactionRegion? {
        redactionState.regions[page]?.first {
            $0.source == .manual && $0.normalizedRect == CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }

    /// Whether `page` holds the whole-page region — the control's state.
    static func isWholePageMarked(page: Int, in redactionState: RedactionState) -> Bool {
        wholePageRegion(on: page, in: redactionState) != nil
    }

    /// The control's action on the page on screen — the bar's control and
    /// the … menu's row both call it. A marked page loses its whole-page
    /// region (one undo step named "Unmark Whole Page"); any other page is
    /// marked: one `.manual` unit-rect region through `addRegion`, the path
    /// a drawn region takes (the region version moves, the output is
    /// cleared, one undo step named "Mark Whole Page"). The page's other
    /// regions are never touched.
    static func toggleWholePage(
        redactionState: RedactionState,
        documentState: DocumentState,
        undoManager: UndoManager?
    ) {
        let page = documentState.currentPageIndex
        if let region = wholePageRegion(on: page, in: redactionState) {
            redactionState.removeRegion(
                region.id, page: page, undoManager: undoManager, actionName: unmarkWholePageLabel)
        } else {
            redactionState.addRegion(
                wholePageRegion(), page: page, undoManager: undoManager, actionName: markWholePageLabel)
        }
    }

    /// The counter's text for `count` regions on the page: "0 regions",
    /// "1 region", else "N regions".
    static func regionCountLabel(_ count: Int) -> String {
        "\(count) region\(count == 1 ? "" : "s")"
    }

    /// The counter's one spoken label: "Page k of N, n regions" (the
    /// drawn counter dropped the word "Page"; the spoken form keeps it).
    static func pageAccessibilityLabel(page: Int, pageCount: Int, regionCount: Int) -> String {
        "Page \(page) of \(pageCount), \(regionCountLabel(regionCount))"
    }
}
