import Foundation
import RedactionEngine

// The result walk's published state for the chrome outside the sheet, and
// what VoiceOver reads for the walk's current match on the parked strip.
//
// `walkLive` is the ONE read of "a walk is on" — the editor's bottom-chrome
// model hides the page bar on it, and the sheet's compact strip mounts its
// ‹ › cluster and per-item Apply / Select on the same predicate — so the
// two surfaces cannot drift. Live = search results on board, or the staged
// detection review pending on the Scan interface (the review walk,
// `ReviewWalk`: the review owns the Scan interface while it is pending,
// so stale sheet-scan results never show a walk under it).
//
// The walk summary (`WalkSummary`): kind · page · text for the current
// match — Scan names the category, Search the term, and the matched text
// rides along except in a literal text search where it equals the term
// (case-insensitively); regex and multi-term keep it. Nothing is drawn
// for it: the parked strip's Apply / Select carries it as its
// accessibility value (`accessibilityValue`), so VoiceOver names the
// match the sighted user sees marked on the page. The review origin
// builds the same summary from its row (`WalkSummary.init(item:pageCount:)`).
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

// MARK: - The walk summary

/// What VoiceOver hears for the walk's current result on the parked
/// strip's Apply / Select — a search result here, a staged detection
/// through `ReviewWalk`.
struct WalkSummary: Equatable {
    /// Scan: the PII category's display name; Search: the term.
    let kind: String
    /// "Page k of N" — the page readout (the page bar is hidden while
    /// the walk is live).
    let pageLabel: String
    /// The matched text; nil when the summary drops it (a literal text
    /// search whose match equals the term) or the kind carries none.
    let text: String?

    /// The page readout, 1-based over the document's page count.
    static func pageLabel(pageIndex: Int, pageCount: Int) -> String {
        "Page \(pageIndex + 1) of \(pageCount)"
    }

    /// The button's accessibility value: kind, page, text — commas for
    /// VoiceOver's pauses, no dots; two parts when there is no text.
    var accessibilityValue: String {
        [kind, pageLabel, text].compactMap { $0 }.joined(separator: ", ")
    }
}

extension SearchState {

    static func walkPageLabel(pageIndex: Int, pageCount: Int) -> String {
        WalkSummary.pageLabel(pageIndex: pageIndex, pageCount: pageCount)
    }

    /// The summary for one result.
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
}
