import SwiftUI

// The ONE walk-navigation seam — split from `SearchAndRedactSheet.swift`
// under the M-6 hub cap. Every way of moving a walk's "current" onto
// the canvas routes through `focusWalk`: the ‹ › chevrons (⌘G / ⇧⌘G ride
// those Buttons) through `stepWalk`, the results-row tap, the J/K
// keyboard step, and the Scan review's row tap (`focusWalk(onReview:)`,
// by id). The two former inline copies — the hub's
// `navigateToCurrentResult(dropToCompact:)` and the results section's
// row-tap body — are gone; `WalkSeamTests` pins that every caller names
// the seam and that no other file asks the canvas to scroll.
//
// Two walks behind the one seam: the search walk over
// `SearchState.results` (the index write on the session) and the review
// walk over the staged detections (`ReviewWalk`, the sheet's cursor
// re-anchored here against the live staged set on every read). The
// chevrons step whichever is live — the review while it owns the Scan
// interface, else the search — and both frame the current row the same
// way through the canvas half.
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

    // MARK: - The review walk

    /// The review cursor as it stands against the CURRENT staged set —
    /// the stored `@State` re-anchored on every read, so a group apply
    /// that pruned rows under it never leaves a dangling current. Every
    /// reader (the strip's line and counter, the Select) and every
    /// writer (the steps, the row tap) goes through this.
    var liveReviewWalk: ReviewWalk {
        var walk = reviewWalk
        walk.update(items: ReviewWalk.items(from: redactionState.pendingTriage))
        return walk
    }

    /// One chevron tap at either site: step whichever walk is live —
    /// the review cursor while the staged review owns the Scan
    /// interface, else the search walk — then focus through the seam.
    func stepWalk(_ direction: ResultNavDirection) {
        if isReviewActive {
            var walk = liveReviewWalk
            switch direction {
            case .next: walk.next()
            case .previous: walk.previous()
            }
            reviewWalk = walk
            focusReviewWalk(walk)
        } else {
            switch direction {
            case .next:
                searchState.navigateToNext(currentPageIndex: documentState.currentPageIndex)
            case .previous:
                searchState.navigateToPrevious(currentPageIndex: documentState.currentPageIndex)
            }
            focusWalk(on: searchState.currentResult?.id, parking: true)
        }
    }

    /// Focus the review walk on the staged detection `id` (the review
    /// row tap): the cursor write, then the canvas half. An id the
    /// staged set does not hold is a no-op.
    func focusWalk(onReview id: UUID) {
        var walk = liveReviewWalk
        walk.focus(on: id)
        guard walk.currentID == id else { return }
        reviewWalk = walk
        focusReviewWalk(walk)
    }

    /// The review walk's canvas half — the current row's page and rect
    /// through the same request the search walk makes, parking.
    private func focusReviewWalk(_ walk: ReviewWalk) {
        guard let item = walk.current else { return }
        focusWalk(onPage: item.page, normalizedRect: item.rect, parking: true)
    }
}
