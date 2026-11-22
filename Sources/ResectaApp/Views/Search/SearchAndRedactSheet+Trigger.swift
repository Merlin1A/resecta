import SwiftUI
import UIKit
import PDFKit
import RedactionEngine

// Search trigger + debounce + coverage helpers lifted from
// `SearchAndRedactSheet.swift` (split target
// "<500 LOC sheet"). Pure structural lift; no behavior change. The
// run itself is `SearchRun` (State/SearchRun.swift); the static helpers
// (`firstPageText`, `makeCoverageReport`) stay here on the sheet, and
// the run names them on it.

extension SearchAndRedactSheet {

    /// The custom-term time-limit toast: one content-free, page-free
    /// message, shown once for a scan (`ScanOnceLatch`) however many pages
    /// ran out.
    static let customTermTimeoutMessage =
        "A custom term was not fully checked on some pages — time limit reached."

    /// One firing per scan. A new scan installs a new latch with its sinks,
    /// so the time-limit toast is shown once for that scan, including for a
    /// page that runs out after the first toast has left the screen.
    final class ScanOnceLatch {
        private var fired = false

        /// True on the first call only.
        func fire() -> Bool {
            defer { fired = true }
            return !fired
        }
    }

    // MARK: - Search Trigger

    func debounceSearch(query: String) {
        searchDebounceTask?.cancel()
        guard !query.isEmpty else {
            Task { @MainActor in
                await searchState.cancelSearch()
                searchState.clearResults()
            }
            return
        }
        // Short terms require explicit trigger. The floor
        // counts TRIMMED characters (mirroring multi-term's validator
        // trim), so whitespace-only input never auto-runs a real
        // engine pass under a visually-empty field.
        guard Self.queryQualifiesForAutoRun(query) else { return }

        searchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            // A typed run replaces the list like any other run: when it
            // clears ticked matches it says so, once (the clear leaves
            // nothing ticked, so the next letter's run is silent).
            triggerSearch()
        }
    }

    /// The run is a value the sheet builds from its own objects and its
    /// searcher (`SearchRun`, State/SearchRun.swift).
    func triggerSearch() {
        makeRun().trigger()
    }

    func makeRun() -> SearchRun {
        SearchRun(
            searchState: searchState, redactionState: redactionState, documentState: documentState,
            toastManager: toastManager, settingsState: settingsState, userTermsStore: userTermsStore,
            searcher: searcher, messageLayerID: messageLayerID)
    }

    /// Debounce auto-run floor on the trimmed length. The
    /// query still runs VERBATIM (trailing spaces are meaningful to a
    /// literal search); trimming here only gates whether typing alone
    /// starts a run.
    static func queryQualifiesForAutoRun(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
    }

    // MARK: - Regex error hints

    /// Map the common NSRegularExpression failure shapes to a one-line
    /// human hint by inspecting the PATTERN (the NSError text is opaque
    /// boilerplate). A switch on shape, no parsing dependency;
    /// nil when no common shape matches. Order matters: the earlier,
    /// more specific shapes win. Pinned by `RegexErrorHintTests`.
    static func regexErrorHint(pattern: String) -> String? {
        // Walk once, tracking escapes so "\(" doesn't count as a group.
        var parenDepth = 0
        var unmatchedCloseParen = false
        var bracketOpen = false
        var escaped = false
        var previousUnescaped: Character? = nil
        var danglingQuantifier = false
        let quantifiers: Set<Character> = ["*", "+", "?"]
        for ch in pattern {
            if escaped {
                escaped = false
                // An escaped character is a valid quantifier operand
                // ("\d+"); record a neutral placeholder so the dangling
                // check above doesn't misread it as "(", "|", or nothing.
                previousUnescaped = "a"
                continue
            }
            if ch == "\\" {
                escaped = true
                continue
            }
            if bracketOpen {
                if ch == "]" { bracketOpen = false }
                continue
            }
            switch ch {
            case "[": bracketOpen = true
            case "(": parenDepth += 1
            case ")":
                parenDepth -= 1
                if parenDepth < 0 { unmatchedCloseParen = true }
            default: break
            }
            if quantifiers.contains(ch) {
                // A quantifier must follow something repeatable; after
                // nothing, "(", "|", or another dangling position it has
                // no operand. ("?" after a quantifier is lazy-match and
                // fine — previousUnescaped covers that, since the prior
                // quantifier was itself preceded by an operand.)
                switch previousUnescaped {
                case nil, "(", "|":
                    danglingQuantifier = true
                default: break
                }
            }
            previousUnescaped = ch
        }
        if escaped {
            return "The pattern ends with a lone backslash — remove it, or double it (\\\\) to match a literal backslash."
        }
        if bracketOpen {
            return "A [ character class is never closed — add the matching ]."
        }
        if parenDepth > 0 {
            return "A ( group is never closed — add the matching )."
        }
        if unmatchedCloseParen {
            return "A ) has no matching ( — remove it or add the opening (."
        }
        if danglingQuantifier {
            return "A *, +, or ? needs something before it to repeat."
        }
        return nil
    }

    /// Compose the callout text: hint first (when one matched), the
    /// engine's original description preserved after it, then the
    /// built-in detector the pattern's shape already spells out (when one
    /// does) — a refused email or number pattern is not a dead end when
    /// the detector that covers it is one tap away. Both refusal paths
    /// (the pre-validation here and the engine's rejection sink) compose
    /// through this one function.
    static func regexErrorDisplayMessage(
        pattern: String,
        engineDescription: String
    ) -> String {
        var message = engineDescription
        if let hint = regexErrorHint(pattern: pattern) {
            message = "\(hint) (\(engineDescription))"
        }
        if let category = SearchToolbarSection.builtInDetectorCovering(pattern: pattern) {
            message += " \(SearchToolbarSection.builtInDetectorSentence(for: category))"
        }
        return message
    }

    // MARK: - Helpers

    /// Returns the text of the first page (up to `maxPages` scanned) whose
    /// PDFKit text extraction yields a non-empty string. Runs in a
    /// detached task so the per-page `page.string` (synchronous PDFKit,
    /// 10–100 ms per page on scanned-only PDFs) doesn't block MainActor
    /// at scan kickoff.
    static func firstPageText(
        of doc: SendablePDFDocument,
        maxPages: Int = 5
    ) async -> String? {
        await Task.detached(priority: .utility) {
            let document = doc.document
            let cap = min(maxPages, document.pageCount)
            for idx in 0..<cap {
                guard let page = document.page(at: idx) else { continue }
                let text = page.string ?? ""
                if !text.isEmpty { return text }
            }
            return nil
        }.value
    }

    // `internal` (not `private`) so `SearchStateTests` can pin the
    // below-threshold tally → `belowThresholdSuppressedCount` wiring directly.
    static func makeCoverageReport(
        scannedPages: Int,
        enabled: Set<PIICategory>,
        results: [SearchResult],
        overlapSuppressed: [PIICategory: Int],
        belowThresholdSuppressed: Int,
        startedAt: Date,
        completedAt: Date
    ) -> CoverageReport {
        var counts: [PIICategory: Int] = [:]
        for result in results {
            guard let cat = result.piiCategory else { continue }
            counts[cat, default: 0] += 1
        }
        return CoverageReport(
            scannedPageCount: scannedPages,
            enabledCategories: enabled,
            candidateCountByCategory: counts,
            appliedCount: 0,
            deselectedCount: 0,
            belowThresholdSuppressedCount: belowThresholdSuppressed,
            overlapSuppressedCountByCategory: overlapSuppressed,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    // MARK: - Apply (search origin)

    /// The one search-origin apply: the toolbar Apply, the Return
    /// shortcut and the compact handle's per-item Apply all run through
    /// it. `origin` is resolved by the caller BEFORE the await — the
    /// per-item path captures the current match's id at call time; the
    /// walk or a re-flush can move `currentResult` while the apply waits
    /// its turn, and the seam refuses a stale id with zero mutations.
    /// `preflight` runs after the two gates and before the apply flag is
    /// raised (the shortcut's select-the-focused-match-if-none-selected).
    /// `navigateToFirst` moves the page to the first selected result
    /// once the seam returns; the per-item Apply stays put.
    ///
    /// The gates: `isApplying` (the sheet-wide one-apply-at-a-time flag)
    /// and `canMutateRegions` — refuse mutations while the pipeline owns
    /// `redactionState.regions`, the same gate as the buttons'
    /// `.disabled`, re-checked in the action against a pipeline that
    /// started after the last render (and again inside the path). A
    /// refused apply (the path's post-await re-check lost to a pipeline
    /// start) preserves the session for retry — dismissing here
    /// destroyed the user's results and selections over a transient
    /// refusal. Only the results that produced a region join the applied
    /// set: overlap-skipped members of the selection get no audit entry,
    /// so no "applied" badge either; the dedup-covered ids feed the
    /// Apply-graying gate. The success toast goes through the one
    /// `CommitFeedback` builder so the count stays in lockstep with the
    /// review-apply toasts (nil for a no-op apply, so a held shortcut
    /// against an all-overlap selection emits no "Marked 0" message; each
    /// apply that posts is a new message, which the queue does not merge
    /// with the last). The sheet's
    /// markers derive from the live regions after the apply.
    /// (Lives here with `triggerSearch()` per the M-6 hub-cap
    /// decomposition — the run-orchestration family stays together;
    /// internal, not private, because the hub view's toolbar and the
    /// compact handle are callers.)
    func applySearchSelection(
        origin: RedactionState.ApplyOrigin,
        preflight: () -> Bool = { true },
        navigateToFirst: Bool
    ) {
        guard !isApplying else { return }
        guard documentState.canMutateRegions else { return }
        guard preflight() else { return }
        isApplying = true
        // Capture the selected ids before the apply clears the selection.
        let selectedIDs = navigateToFirst
            ? Set(searchState.results.filter(\.isSelected).map(\.id)) : []
        Task { @MainActor in
            defer { isApplying = false }
            guard let outcome = await redactionState.applyFindings(
                origin,
                undoManager: undoManager,
                documentState: documentState
            ) else { return }
            let counts = searchState.markedCounts(outcome)
            if CommitFeedback.markedMessage(applied: counts.applied, alreadyCovered: counts.alreadyCovered) != nil {
                toastManager.post(.marked(applied: counts.applied, alreadyCovered: counts.alreadyCovered))
            }
            if navigateToFirst,
               let firstPage = searchState.results.first(where: { selectedIDs.contains($0.id) })?.pageIndex {
                documentState.currentPageIndex = firstPage
            }
        }
    }

    /// Toolbar Apply for the search origin.
    func applySelectedSearchResults() {
        applySearchSelection(origin: .selectedSearchResults, navigateToFirst: true)
    }

    // MARK: - Apply (keyboard shortcut)

    /// Return-shortcut Apply: the toolbar path, marking the focused
    /// result first when nothing is selected.
    func applyFromKeyboardShortcut() {
        applySearchSelection(
            origin: .selectedSearchResults,
            preflight: { searchState.selectCurrentMatchIfNoneSelected() },
            navigateToFirst: true)
    }

    /// Forwarded to `SearchResultsSection` so the invisible Return-shortcut
    /// Button can disable itself during an in-flight apply.
    var applyShortcutEnabled: Bool { !isApplying }

    // MARK: - Saved-Search Recall

    /// Apply a saved shape and re-run the search. The list sheet dismisses
    /// first (single-modal slot); recall then restores the shape via the
    /// testable static and triggers through the standard path — exactly
    /// one `triggerSearch()` (single-trigger discipline). If the
    /// recalled filter state hides every result, the existing
    /// "filters hide all results" empty state surfaces (already
    /// implemented in SearchResultsSection; no new copy).
    ///
    /// A recall that replaces a results-carrying session names the drop:
    /// the programmatic transition deliberately skips the mode-switch
    /// undo toast (the user explicitly chose a new search — a restore
    /// affordance would race the fresh run), but the trigger's own
    /// clear used to destroy unapplied matches with no signal at all.
    /// The notice closes that silence without adding any affordance.
    func recallSavedSearch(_ saved: SavedSearch) {
        activeModal = nil
        let dropped = Self.unappliedMatchCount(in: searchState)
        SavedSearchListSheet.apply(saved, to: searchState)
        searchState.skipNextRerunNotice = true
        triggerSearch()
        if Self.recallClearedMessage(unappliedCount: dropped) != nil {
            toastManager.post(.recallCleared(count: dropped))
        }
    }

    /// Notice for a recall that drops live unapplied matches. Returns
    /// nil when nothing unapplied is lost so the common recall stays
    /// toast-free. Sibling of `dismissClearedMessage` and the
    /// review-arrival notice — the family that keeps every
    /// results-dropping transition named. Pinned by
    /// `InterfaceSwitchClearTests`.
    static func recallClearedMessage(unappliedCount: Int) -> String? {
        guard unappliedCount > 0 else { return nil }
        let suffix = unappliedCount == 1 ? "" : "es"
        return "Recall cleared \(unappliedCount) unapplied match\(suffix)."
    }
}
