import Foundation
import RedactionEngine

// The result walk's published state for the chrome outside the sheet, and
// what the parked strip's second line names.
//
// `walkLive` is the ONE read of "a walk is on" — the editor's bottom-chrome
// model hides the page bar on it, and the sheet's compact strip mounts its
// ‹ › cluster and per-item Apply / Select on the same predicate — so the
// two surfaces cannot drift. Live = search results on board, or the staged
// detection review pending on the Scan interface (the review walk,
// `ReviewWalk`: the review owns the Scan interface while it is pending,
// so stale sheet-scan results never show a walk under it).
//
// The match line (`WalkLine`): kind · page · text for the current match —
// Scan names the category, Search the term, and the matched text rides
// along except in a literal text search where it equals the term
// (case-insensitively); regex and multi-term keep it. A current hidden by
// the active filters reads "Hidden by filters"; with no walk the slot
// carries the list's own headline verbatim ("No matches", "Not run yet",
// "Not scanned yet", …) and stays empty in the pre-search contexts. A
// pending review owns the slot with its own line (`ReviewWalk.line`).
// `WalkSummaryTests` pins the rules.

extension SearchState {
    /// Whether a walk is live for this search session: the review walk
    /// while the staged review owns the Scan interface, else the search
    /// walk over the results on board. `reviewPending` is the store's
    /// `pendingTriage != nil`, passed in because the review belongs to
    /// `RedactionState`.
    func isWalkLive(reviewPending: Bool) -> Bool {
        reviewOwnsInterface(reviewPending: reviewPending) || !results.isEmpty
    }

    /// The staged review is pending AND this session is on the Scan
    /// interface — the review's surface (`SearchAndRedactSheet.isReviewActive`).
    func reviewOwnsInterface(reviewPending: Bool) -> Bool {
        reviewPending && searchModeType.interface == .scan
    }
}

extension RedactionState {
    /// The one published read of the walk's liveness for the editor:
    /// false with no sheet session; else the session's own predicate
    /// against this store's pending review.
    var walkLive: Bool {
        activeSearch?.isWalkLive(reviewPending: pendingTriage != nil) ?? false
    }
}

// MARK: - The match line

/// What the strip's match line names for the walk's current result —
/// a search result here, a staged detection through `ReviewWalk`.
struct WalkSummary: Equatable {
    /// Scan: the PII category's display name; Search: the term.
    let kind: String
    /// "Page k of N" — the page readout that replaces the hidden page bar's.
    let pageLabel: String
    /// The matched text; nil when the line drops it (a literal text
    /// search whose match equals the term) or the kind carries none.
    let text: String?

    /// The page readout, 1-based over the document's page count.
    static func pageLabel(pageIndex: Int, pageCount: Int) -> String {
        "Page \(pageIndex + 1) of \(pageCount)"
    }
}

/// The strip's second line, per state.
enum WalkLine: Equatable {
    case match(WalkSummary)
    case hiddenByFilters
    /// The list's own empty-state headline, verbatim.
    case status(String)
    case empty

    static let hiddenByFiltersText = "Hidden by filters"
}

extension SearchState {

    static func walkPageLabel(pageIndex: Int, pageCount: Int) -> String {
        WalkSummary.pageLabel(pageIndex: pageIndex, pageCount: pageCount)
    }

    /// The line for one result.
    func walkSummary(for result: SearchResult, pageCount: Int) -> WalkSummary {
        let kind = result.piiCategory?.rawValue ?? result.term
        let dropsText = result.piiCategory == nil
            && searchModeType == .text
            && result.matchedText.caseInsensitiveCompare(result.term) == .orderedSame
        return WalkSummary(
            kind: kind,
            pageLabel: Self.walkPageLabel(pageIndex: result.pageIndex, pageCount: pageCount),
            text: dropsText ? nil : result.matchedText
        )
    }

    /// The line for the session's current state.
    func walkLine(pageCount: Int, reviewPending: Bool) -> WalkLine {
        // A pending review owns the slot with the review walk's own line
        // (`ReviewWalk.line`); stale results under it show nothing.
        if reviewOwnsInterface(reviewPending: reviewPending) { return .empty }
        guard !results.isEmpty else {
            if reviewPending { return .empty }
            return walkStatusHeadline.map { .status($0) } ?? .empty
        }
        guard let current = currentResult else { return .empty }
        guard currentResultFilteredPosition != nil else { return .hiddenByFilters }
        return .match(walkSummary(for: current, pageCount: pageCount))
    }

    /// The per-mode empty-state discriminator from this session's
    /// shape — the results list's own read (`WU20Strings.context`).
    var emptyStateContext: WU20Strings.EmptyContext {
        WU20Strings.context(
            mode: searchModeType,
            queryText: queryText,
            multiTermTerms: searchTerms,
            recentMultiTermSets: recentMultiTermSets,
            multiTermConjunction: options.multiTermConjunction,
            currentSearchPage: currentSearchPage,
            totalPages: totalPages,
            totalCount: totalCount,
            // The completion copy describes the run that
            // executed (kickoff snapshot), not the live chip state.
            enabledPIICategoryCount: lastRunDetectorCount
                ?? effectiveScanCategories.count,
            hasCompletedRun: hasCompletedRunSinceClear,
            scanStartFailed: scanStartFailed
        )
    }

    /// The list's headline for the no-results slot, verbatim; nil in the
    /// pre-search contexts (the interface names are not a status).
    var walkStatusHeadline: String? {
        let context = emptyStateContext
        switch context {
        case .textPreSearch, .regexPreSearch,
             .multiTermPreSearchNoRecents, .multiTermPreSearchWithRecents:
            return nil
        default:
            return WU20Strings.headline(for: context)
        }
    }
}
