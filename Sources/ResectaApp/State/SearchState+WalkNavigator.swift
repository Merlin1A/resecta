import Foundation

// The match walk follows the page shown. A parked walk kept its current
// match while the page bar moved the page, so the strip's Apply applied a
// match on a page no longer in view, and the next › started from that
// match rather than from the page shown. This file is the walk's one way
// to step and its one way to give up a current match: `walkToNext` /
// `walkToPrevious` anchor the step at the page shown and then step with
// `navigateToNext` / `navigateToPrevious` (their bodies untouched), and
// `yieldWalk(toPage:)` lets a current match on another page go. The
// walk's chevrons, the J / K keys and the page bar's arrows call here.

extension SearchState {

    /// The page shown moved: a current match on another page is let go, so
    /// nothing acts on a match out of view. A match on that page stays.
    func yieldWalk(toPage page: Int) {
        if let current = currentResult, current.pageIndex != page {
            currentResultIndex = nil
        }
    }

    /// › from the page shown: the next match after the current one when
    /// the current match is on that page, else the first match on or after
    /// the page shown (wrapping to the first match past the last).
    func walkToNext(fromPage page: Int) {
        if !currentIsOnPage(page) {
            // Anchor at the last match before the page shown, so the step
            // lands on the first match on or after it.
            let anchor = scopedResults(currentPageIndex: page).last { $0.pageIndex < page }
            currentResultIndex = anchor.flatMap { index(of: $0.id) }
        }
        navigateToNext(currentPageIndex: page)
    }

    /// ‹ from the page shown: the match before the current one when the
    /// current match is on that page, else the last match on or before the
    /// page shown (wrapping to the last match before the first).
    func walkToPrevious(fromPage page: Int) {
        if !currentIsOnPage(page) {
            // Anchor at the first match after the page shown, so the step
            // lands on the last match on or before it.
            let anchor = scopedResults(currentPageIndex: page).first { $0.pageIndex > page }
            currentResultIndex = anchor.flatMap { index(of: $0.id) }
        }
        navigateToPrevious(currentPageIndex: page)
    }

    private func currentIsOnPage(_ page: Int) -> Bool {
        currentResult?.pageIndex == page
    }
}
