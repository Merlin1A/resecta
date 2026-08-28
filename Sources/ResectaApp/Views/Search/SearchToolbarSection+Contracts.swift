import Foundation
import CoreGraphics
import RedactionEngine

// Pure-function contracts for `SearchToolbarSection`. Extracted
// into a sibling file so the main view file
// stays under the M-6 700-LOC cap as additional chip-row
// consumers and disclosure helpers land. Each `static let` / `static
// func` is pinned by a test in `Tests/ResectaAppTests/`; renaming a
// contract requires the matching test rename in the same commit.

// MARK: - Pure-Function Contracts

extension SearchToolbarSection {
    /// The "Options" disclosure starts collapsed: expanded-by-default
    /// is false. Renamed from `optionsCollapsedByDefault`,
    /// whose name inverted the stored value (it read
    /// "collapsed-by-default = false" while documenting "starts
    /// collapsed"). The view initializes `optionsExpanded` from this
    /// constant.
    /// Pinned by `SearchToolbarSectionTests.optionsDisclosureStartsCollapsed`.
    static let optionsExpandedByDefault: Bool = false

    /// Caption shown beneath the disabled OCR
    /// controls when Include OCR is on but no OCR results have arrived
    /// yet. Factual mechanism description, not a promise.
    static let awaitingOCRResultsCaption: String = "Awaiting OCR results"

    /// OCR slider + source filter visibility gate.
    /// Visible whenever the user has Include OCR on, even pre-scan;
    /// the previous gate (`hasOCRResults`) hid the controls until
    /// results materialized, which made the slider feel like it
    /// appeared and disappeared under the user's hand.
    static func ocrControlsShouldShow(includeOCR: Bool) -> Bool {
        includeOCR
    }

    /// When the OCR controls are visible but no
    /// OCR results yet exist, render them disabled with the
    /// `awaitingOCRResultsCaption` underneath.
    static func ocrSliderShouldBeDisabled(hasOCRResults: Bool) -> Bool {
        hasOCRResults == false
    }

    /// Caption under the disabled OCR controls. Two states were
    /// previously conflated into a single indefinite "Awaiting OCR
    /// results" promise: on a document whose every page classifies as
    /// `.rich`, the engine routes no page to OCR (see
    /// `DocumentSearcher.pageHasRichTextLayer`), so no OCR results can
    /// ever arrive and the caption promised something that never comes.
    /// `anyPageAwaitsOCR` is true when at least one page classified
    /// `.sparse`/`.none` — only then is "awaiting" a real state.
    /// Factual mechanism description, not a promise.
    /// Pinned by `SearchToolbarSectionTests`.
    static func ocrDisabledCaption(anyPageAwaitsOCR: Bool) -> String {
        anyPageAwaitsOCR
            ? awaitingOCRResultsCaption
            : "OCR not needed — this document's pages read as searchable text"
    }

    // MARK: - OCR-block visibility contracts

    /// Visibility gate for the whole piiScan OCR block (Include
    /// OCR Pages toggle + `ocrControlsRow`). Hidden ONLY when the
    /// text-layer map is known AND no page awaits OCR (every page
    /// classified `.rich` — the engine routes no page to OCR there, see
    /// `DocumentSearcher.pageHasRichTextLayer`, so hiding is
    /// behavior-neutral). Fails OPEN: `statusKnown == false` (empty
    /// `textLayerStatus`, e.g. reset/mid-import edge) shows the block so
    /// the controls never vanish on a scannable document. Standard modes
    /// keep today's ungated behavior. Pinned by
    /// `SearchToolbarSectionTests`.
    static func piiScanOCRBlockShouldShow(
        anyPageAwaitsOCR: Bool,
        statusKnown: Bool
    ) -> Bool {
        statusKnown == false || anyPageAwaitsOCR
    }

    // MARK: - Pure-Function Contracts

    /// Saved-regex submenu section header.
    /// UI label; not document-derived.
    static let savedRegexSectionHeader: String = "Saved..."

    /// "Save current..." menu item label.
    /// UI action label; not document-derived.
    static let saveCurrentRegexMenuItem: String = "Save current..."

    /// `Save current...` is enabled only when the user has typed a
    /// non-empty pattern AND the user-saved regex list is below the
    /// store's cap. Pinned by `SavedRegexMenuTests`.
    static func canSaveCurrentRegex(savedCount: Int, queryText: String) -> Bool {
        let trimmed = queryText.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && savedCount < SavedRegexStore.userSavedCap
    }

    /// Cap-message text shown when the user-saved regex list is at or
    /// above `SavedRegexStore.userSavedCap`. Returns nil below cap so
    /// the alert (and any future inline label) elides gracefully.
    static func savedRegexCapMessage(savedCount: Int) -> String? {
        guard savedCount >= SavedRegexStore.userSavedCap else { return nil }
        return "Saved regex list at the \(SavedRegexStore.userSavedCap) cap."
    }

    // MARK: - Pure-Function Contracts

    /// VoiceOver label for the applied-state filter chip.
    /// Surfaces both "what this chip is" and "what it's currently set
    /// to" so VoiceOver users don't have to pivot through the Menu
    /// just to read the active state. Pinned by
    /// `SearchStateAppliedFilterTests`.
    static func appliedFilterChipAccessibilityLabel(active: AppliedFilter) -> String {
        "Applied state filter, currently \(active.rawValue)"
    }

    /// Visibility gate for the applied-state filter chip. Before
    /// the first apply the chip filters a set with no applied members
    /// (every option shows the same list), so it renders only once
    /// something has been applied — OR while a non-`.all` filter is
    /// active, so an active filter can never strand invisibly (e.g.
    /// `.applied` selected, then an undo empties `appliedResultIDs`).
    /// Pinned by `SearchStateAppliedFilterTests`.
    static func appliedFilterChipShouldShow(
        hasAppliedResults: Bool,
        activeFilter: AppliedFilter
    ) -> Bool {
        hasAppliedResults || activeFilter != .all
    }

    // MARK: - Pure-Function Contracts

    /// Visible label inside the sort chip's capsule. Reads
    /// "Sort" by default (`.discoveryOrder`) so the affordance is
    /// self-describing pre-interaction; flips to the rawValue of the
    /// active sort once the user picks a non-default order so the
    /// chip-row reads "<chip> · Confidence" / "<chip> · Page" at a
    /// glance. ResultSortOrder rawValues are existing strings (no
    /// new UI surface introduced). Pinned by `SortChipTests`.
    static func sortChipLabel(active: ResultSortOrder) -> String {
        active == .discoveryOrder ? "Sort" : active.rawValue
    }

    /// VoiceOver label for the sort chip — surfaces the
    /// active sort verbatim so users know what's selected without
    /// drilling into the Menu. Pinned by `SortChipTests`.
    static func sortChipAccessibilityLabel(active: ResultSortOrder) -> String {
        "Sort order, currently \(active.rawValue)"
    }

    // MARK: - Pure-Function Contracts

    /// An option change re-runs only when the session has
    /// something the change makes stale: a committed run (a no-match
    /// verdict included — toggling case-sensitivity off may produce
    /// matches) or live results. Fresh, carried, and
    /// short-term-guarded queries stay explicit-trigger, so the option
    /// row cannot become a backdoor around the debounce floor.
    /// Pinned by `SearchToolbarSectionTests`.
    static func optionChangeShouldRetrigger(
        hasCompletedRun: Bool,
        hasResults: Bool
    ) -> Bool {
        hasCompletedRun || hasResults
    }

    // MARK: - Pure-Function Contracts

    /// Visibility gate for the short-term warning + "Search
    /// Anyway" pair. Renders only for a 1–2 character query outside
    /// multi-term mode AND while no regex error stands: with a
    /// non-compiling pattern on screen, tapping "Search Anyway" ran a
    /// no-op loop (the attempt clears the list, the error persists,
    /// the button re-renders). The error wins. Pinned by
    /// `SearchToolbarSectionTests`.
    static func shortTermWarningShouldShow(
        queryCount: Int,
        isMultiTerm: Bool,
        hasRegexError: Bool
    ) -> Bool {
        queryCount > 0 && queryCount < 3 && !isMultiTerm && !hasRegexError
    }

    // MARK: - Pure-Function Contracts

    /// Minimum vertical extent the regex
    /// error callout reserves while in regex mode so the toolbar
    /// height does NOT reflow when `searchState.regexError` flips
    /// between nil and a string. Picked to seat one line of `.caption`
    /// + the leading icon comfortably without crowding the chip row
    /// above. Pinned by `RegexErrorCalloutTests.calloutReservesFixedHeight`.
    static let regexErrorCalloutMinHeight: CGFloat = 24

    /// Visibility predicate for the regex error callout
    /// contents. Returns true when the engine has a non-empty error
    /// string; false when nil or empty (whitespace-only counts as
    /// empty so a trailing `\n` from the regex engine doesn't
    /// flicker the callout). Visibility drives `.opacity` rather
    /// than presence so the surrounding HStack always allocates
    /// `regexErrorCalloutMinHeight`. Pinned by
    /// `RegexErrorCalloutTests.shouldShowMatchesEngineState`.
    static func regexErrorCalloutShouldShow(error: String?) -> Bool {
        guard let error else { return false }
        return !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Pure-Function Contract

    /// The six Search option chips (via `optionChip`),
    /// Scan's "Include OCR Pages" toggle, and the multi-term conjunction
    /// toggle all disable while a search/scan run is in flight, so a
    /// mid-run tap can't restage options a running query has already
    /// consumed. Trivial today (`isSearching` IS the disabled state) —
    /// named so the three call sites read as one contract and so a
    /// future second condition has one place to land. The
    /// `optionBinding` / `optionChangeShouldRetrigger` re-run path is
    /// untouched — this only gates whether the control can be tapped at
    /// all. Pinned by `SearchToolbarSectionTests`.
    static func optionControlsDisabled(isSearching: Bool) -> Bool {
        isSearching
    }
}
