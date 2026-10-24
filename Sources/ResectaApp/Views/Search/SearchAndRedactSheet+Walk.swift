import SwiftUI

// The ONE walk-navigation seam — split from `SearchAndRedactSheet.swift`
// under the M-6 hub cap. Every way of moving a walk's "current" onto
// the canvas routes through `focusWalk`: the ‹ › chevrons (⌘G / ⇧⌘G ride
// those Buttons) through `stepWalk`, the results-row tap and the J/K
// keyboard step. The two former inline copies — the hub's
// `navigateToCurrentResult(dropToCompact:)` and the results section's
// row-tap body — are gone; `WalkSeamTests` pins that every caller names
// the seam and that no other file asks the canvas to scroll.
//
// Two detent targets behind the one seam: the sheet-parking walk
// (`parking: true` — the chevrons, ⌘G, the row taps) frames the item at
// the readability scale CENTRED in the visible canvas and parks the
// sheet at the compact float, so the outlined match is in view and the
// walk continues from the handle's cluster; the keyboard step
// (`parking: false` — J/K) keeps the prior page-only intent and the
// large → medium rule, so a keyboard user reads the list while stepping.

extension SearchAndRedactSheet {

    /// Focus the search walk on the result `id`: the index write, then
    /// the canvas half. A nil or unknown id (the walk has no current, or
    /// a re-flush dropped the row) is a no-op.
    func focusWalk(on id: UUID?, parking: Bool) {
        guard let id, let index = searchState.index(of: id) else { return }
        searchState.currentResultIndex = index
        guard let result = searchState.currentResult else { return }
        focusWalk(onPage: result.pageIndex, normalizedRect: result.normalizedRect, parking: parking)
    }

    /// The canvas half: the page write, the rect-level scroll request
    /// (the canvas consumes it with the engine's canonical rect
    /// conversion), and the detent rule.
    func focusWalk(onPage page: Int, normalizedRect: CGRect, parking: Bool) {
        documentState.currentPageIndex = page
        documentState.requestCanvasScroll(
            toPageIndex: page,
            normalizedRect: normalizedRect,
            zoom: parking ? .readability : .none,
            anchor: parking ? .center : .visible
        )
        if parking {
            // The results-arrival detent raise is untouched — the first
            // step from large drops straight to compact.
            if selectedDetent != .compactFloat {
                selectedDetent = .compactFloat
            }
        } else if selectedDetent == .large {
            // Only minimize from .large; .medium keeps the list visible.
            selectedDetent = .medium
        }
    }

    /// One chevron tap at either site: step the search walk from the page
    /// shown (`SearchState+WalkNavigator`), then focus through the seam.
    func stepWalk(_ direction: ResultNavDirection) {
        switch direction {
        case .next:
            searchState.walkToNext(fromPage: documentState.currentPageIndex)
        case .previous:
            searchState.walkToPrevious(fromPage: documentState.currentPageIndex)
        }
        focusWalk(on: searchState.currentResult?.id, parking: true)
    }
}
