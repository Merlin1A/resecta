import Foundation
import CoreGraphics
import RedactionEngine

// Pure-function contracts for `SearchToolbarSection`. Extracted
// into a sibling file so the main view file
// stays under the M-6 700-LOC cap as additional chip-row
// consumers and disclosure helpers land. Each `static let` / `static
// func` is pinned by a test in `Tests/ResectaAppTests/`; renaming a
// contract requires the matching test rename in the same commit.

// MARK: - WU-08 Pure-Function Contracts

extension SearchToolbarSection {
    /// The "Options" disclosure starts collapsed: expanded-by-default
    /// is false. SO-04 — renamed from `optionsCollapsedByDefault`,
    /// whose name inverted the stored value (it read
    /// "collapsed-by-default = false" while documenting "starts
    /// collapsed"). The view initializes `optionsExpanded` from this
    /// constant.
    /// Pinned by `SearchToolbarSectionTests.optionsDisclosureStartsCollapsed`.
    static let optionsExpandedByDefault: Bool = false

    /// Per WU-08 / [R-07]: caption shown beneath the disabled OCR
    /// controls when Include OCR is on but no OCR results have arrived
    /// yet. Classified SAFE under §19 — factual mechanism description.
    static let awaitingOCRResultsCaption: String = "Awaiting OCR results"

    /// Per WU-08 / [R-07]: OCR slider + source filter visibility gate.
    /// Visible whenever the user has Include OCR on, even pre-scan;
    /// the previous gate (`hasOCRResults`) hid the controls until
    /// results materialized, which made the slider feel like it
    /// appeared and disappeared under the user's hand.
    static func ocrControlsShouldShow(includeOCR: Bool) -> Bool {
        includeOCR
    }

    /// Per WU-08 / [R-07]: when the OCR controls are visible but no
    /// OCR results yet exist, render them disabled with the
    /// `awaitingOCRResultsCaption` underneath.
    static func ocrSliderShouldBeDisabled(hasOCRResults: Bool) -> Bool {
        hasOCRResults == false
    }

    /// UXF-14 — caption under the disabled OCR controls. Two states were
    /// previously conflated into a single indefinite "Awaiting OCR
    /// results" promise: on a document whose every page classifies as
    /// `.rich`, the engine routes no page to OCR (see
    /// `DocumentSearcher.pageHasRichTextLayer`), so no OCR results can
    /// ever arrive and the caption promised something that never comes.
    /// `anyPageAwaitsOCR` is true when at least one page classified
    /// `.sparse`/`.none` — only then is "awaiting" a real state.
    /// Classified SAFE under §19 — factual mechanism description.
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

    // MARK: - Customize-disclosure contracts

    /// Pre-scan, the PII "Customize"
    /// disclosure starts collapsed (Hybrid IA novice default).
    /// Pinned by `PIICategoryChipTests.customizeDisclosureCollapsedPreScan`.
    static let customizeDisclosureCollapsedPreScan: Bool = false

    /// Per WU-12 / ACTION-WU-12: count-badge label for the pre-scan PII
    /// chip row inside the Customize disclosure. Pre-scan, count is 0
    /// for every category; post-scan it reflects `SearchState.categoryCounts`.
    /// Format ships verbatim per ACTION-WU-12. Classified SAFE under §19
    /// — mechanism description (factual count, no outcome promise).
    static func pIICategoryChipLabel(for category: PIICategory, count: Int) -> String {
        "\(category.rawValue) (\(count))"
    }

    /// Per WU-12: VoiceOver label for the pre-scan PII chip — surfaces
    /// the toggle state and result count so VoiceOver users can both
    /// (a) understand what tapping the chip does and (b) hear how many
    /// matches the most recent scan produced for this category.
    static func pIICategoryChipAccessibilityLabel(
        category: PIICategory,
        isEnabled: Bool,
        count: Int
    ) -> String {
        let plural = count == 1 ? "match" : "matches"
        let state = isEnabled ? "enabled" : "disabled"
        return "\(category.rawValue), \(state), \(count) \(plural)"
    }

    // MARK: - WU-15 Pure-Function Contracts

    /// Per WU-15 / [TOKEN_ADDITIONS]: saved-regex submenu section header.
    /// Classified SAFE under §19 — UI label.
    static let savedRegexSectionHeader: String = "Saved..."

    /// Per WU-15 / [TOKEN_ADDITIONS]: "Save current..." menu item label.
    /// Classified SAFE under §19 — UI action label.
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

    // MARK: - WU-18 Pure-Function Contracts

    /// Per WU-18: VoiceOver label for the applied-state filter chip.
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

    // MARK: - WU-22 Pure-Function Contracts

    /// Per WU-22: visible label inside the sort chip's capsule. Reads
    /// "Sort" by default (`.discoveryOrder`) so the affordance is
    /// self-describing pre-interaction; flips to the rawValue of the
    /// active sort once the user picks a non-default order so the
    /// chip-row reads "<chip> · Confidence" / "<chip> · Page" at a
    /// glance. ResultSortOrder rawValues are existing strings (no
    /// new §19 surface). Pinned by `SortChipTests`.
    static func sortChipLabel(active: ResultSortOrder) -> String {
        active == .discoveryOrder ? "Sort" : active.rawValue
    }

    /// Per WU-22: VoiceOver label for the sort chip — surfaces the
    /// active sort verbatim so users know what's selected without
    /// drilling into the Menu. Pinned by `SortChipTests`.
    static func sortChipAccessibilityLabel(active: ResultSortOrder) -> String {
        "Sort order, currently \(active.rawValue)"
    }

    // MARK: - BH-B-04 Pure-Function Contracts

    /// BH-B-04 — an option change re-runs only when the session has
    /// something the change makes stale: a committed run (a no-match
    /// verdict included — toggling case-sensitivity off may produce
    /// matches) or live results. Fresh, carried (UXF-16), and
    /// short-term-guarded queries stay explicit-trigger, so the option
    /// row cannot become a backdoor around the debounce floor.
    /// Pinned by `SearchToolbarSectionTests`.
    static func optionChangeShouldRetrigger(
        hasCompletedRun: Bool,
        hasResults: Bool
    ) -> Bool {
        hasCompletedRun || hasResults
    }

    // MARK: - SO-02 Pure-Function Contracts

    /// SO-02 — visibility gate for the short-term warning + "Search
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

    // MARK: - WU-31 Pure-Function Contracts

    /// Per WU-31 / ACTION-WU-31: minimum vertical extent the regex
    /// error callout reserves while in regex mode so the toolbar
    /// height does NOT reflow when `searchState.regexError` flips
    /// between nil and a string. Picked to seat one line of `.caption`
    /// + the leading icon comfortably without crowding the chip row
    /// above. Pinned by `RegexErrorCalloutTests.calloutReservesFixedHeight`.
    static let regexErrorCalloutMinHeight: CGFloat = 24

    /// Per WU-31: visibility predicate for the regex error callout
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
}
