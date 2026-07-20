import Foundation
import RedactionEngine

// Ephemeral search session state.
// Results and document-derived fields are in-memory only; cleared on dismiss.
// Last-used filter shape is cross-session and persisted to UserDefaults.
// Recents (query strings) are in-memory by default and persist only when
// the user opts in via Settings. Never log.

/// Ephemeral search session state.
/// Document-derived state is in-memory only; cleared on dismiss.
/// Last-used filter shape persists via UserDefaults; query recents
/// persist only when the user opts in (in-memory otherwise).
@Observable
@MainActor
final class SearchState: Identifiable {

    let id = UUID()

    // MARK: - UserDefaults seam (testable injection)

    /// Injected at init; defaults to `.standard`. @ObservationIgnored so
    /// the macro does not wrap the concrete UserDefaults reference.
    @ObservationIgnored private let defaults: UserDefaults

    // MARK: - Feature flags

    /// V1.0 ships without the audit-export / scan-coverage surfaces;
    /// the Export Audit button, the Scan Coverage report (incl. Share
    /// Snapshot), and the verification-results "Review" hook are gated off
    /// behind this flag per ~/resecta-ui-polish-planning/00-DIRECTION.md.
    /// All machinery (MatchAuditExporter, MatchExportService, coverage-report
    /// computation) stays compiled and unit-tested; restore = flip to `true`
    /// + update the pin test. PB-75 revisits these surfaces for 1.1. Mirrors
    /// `CustomTermsView.templatePickerEnabled`.
    // nonisolated: Sendable constant read from nonisolated test contexts.
    nonisolated static let searchAuditSurfacesEnabled = false

    /// V1.0 ships without the doctype diagnostic surfaces; the
    /// doctype banner and the footer Document-profile disclosure (two
    /// mounts of `DoctypeDiagnosticView`) are gated off behind this flag
    /// per ~/resecta-ui-polish-planning/02-DIRECTION-UP4-declutter.md.
    /// All machinery (doctype classifier, `lastDoctypeExplanation`,
    /// `WU07Strings`, `DoctypeBannerTests`) stays compiled and
    /// unit-tested; restore = flip to `true` + update the pin test.
    /// SC/PB-75 revisits these surfaces for 1.1.
    // nonisolated: Sendable constant read from nonisolated test contexts.
    nonisolated static let searchDiagnosticSurfacesEnabled = false

    // MARK: - Recents persistence constants

    static let recentQueriesCap = 10
    private static let recentsTextKey    = "search.recents.text.v1"
    private static let recentsRegexKey   = "search.recents.regex.v1"
    private static let recentsEnabledKey = "search.recents.enabled.v1"
    /// One-shot flag for `deletePersistedRecentsOnce(defaults:)`.
    private static let recentsDeletionDoneKey = "search.recents.oneTimeDeletion.v1"

    // MARK: - Persistent recents

    /// Text-mode query history, most-recent-first. Never contains
    /// matched text or document content — query strings only.
    /// In-memory by default; written through to UserDefaults only when
    /// the user opts in (`search.recents.enabled.v1`).
    /// NOT wiped by clear() or clearResults().
    private(set) var recentTextQueries: [String] = []

    /// Regex-mode query history, most-recent-first. Same
    /// carve-out class as recentTextQueries — survives both clear paths.
    private(set) var recentRegexQueries: [String] = []

    // MARK: - Last-used filter shape

    /// Codable bag of the three filter fields that restore across sheet
    /// sessions. `appliedFilter` is intentionally excluded — it is
    /// document-specific.
    struct LastSearchFilterShape: Codable, Sendable {
        var sourceFilter: SourceFilter
        var minimumOCRConfidence: Float
        var sortOrder: ResultSortOrder
    }

    private static let lastFilterKey = "search.lastFilter.v1"

    /// Task reference for debounced filter persistence; cancel before
    /// scheduling a new one (mirrors the flushTask idiom).
    @ObservationIgnored private var filterFlushTask: Task<Void, Never>?

    // MARK: - Search Configuration

    /// Current search query text.
    var queryText: String = ""

    /// Active search mode selector.
    var searchModeType: SearchModeType = .text

    /// One-shot arm for the toolbar Scan button's one-tap contract:
    /// the button sets this before presenting the sheet, and the
    /// sheet's `.onAppear` consumes it exactly once to fire the run.
    /// A single consume site keeps the auto-run to one scan; overlapping
    /// `triggerSearch()` calls additionally coalesce through the
    /// single-flight gate below.
    var pendingAutoRunScan: Bool = false

    // MARK: - Trigger single-flight

    /// True while `triggerSearch()` is between its synchronous entry
    /// and the `activeSearchTask` assignment. The setup window spans
    /// real suspension points (the prior task's cancel-await, the
    /// detached document copy), so without a gate two overlapping
    /// callers both observe a nil task handle and the loser's scan runs
    /// orphaned — appending into shared results and double-writing the
    /// run record. Not observed by any view.
    @ObservationIgnored private(set) var triggerSetupInFlight = false

    /// Set when a trigger arrived while another held the setup window.
    /// Consumed by `endTriggerSetup()`: the window owner re-triggers
    /// once, so the final run reflects the latest query shape.
    @ObservationIgnored private(set) var pendingRetrigger = false

    /// Single-flight gate for `triggerSearch()`. Returns true when the
    /// caller owns the setup window; false coalesces this call into one
    /// deferred re-trigger. Pinned by `SearchStateTests`.
    func beginTriggerSetup() -> Bool {
        guard !triggerSetupInFlight else {
            pendingRetrigger = true
            return false
        }
        triggerSetupInFlight = true
        return true
    }

    /// Close the setup window. Returns true when a coalesced caller
    /// requested a re-trigger while the window was held.
    func endTriggerSetup() -> Bool {
        triggerSetupInFlight = false
        let retrigger = pendingRetrigger
        pendingRetrigger = false
        return retrigger
    }

    // MARK: - Run-state discriminators

    /// True once a non-cancelled run has completed since the last
    /// `clearResults()`. The empty-state discriminator uses it to
    /// distinguish "ran and found nothing" from "this query was never
    /// run in this mode" — a mode switch carries the query text but
    /// deliberately does not re-run (UXF-16), and that carried state
    /// must not render as a definitive no-match verdict.
    var hasCompletedRunSinceClear = false

    /// True when the last Scan attempt exited before kickoff (document
    /// not ready). Distinguishes "never scanned" from "the scan failed
    /// to start" after the failure toast expires. Reset by
    /// `clearResults()` — every trigger clears before its guards run.
    var scanStartFailed = false

    /// BH-A-06 — detector count of the category set the last Scan run
    /// actually executed with (snapshotted at kickoff, mirroring the
    /// engine query's own `enabledCategories` snapshot). The zero-state
    /// completion copy renders from this, never from the live chip
    /// state, so a post-hoc chip toggle cannot rewrite the description
    /// of a run that already happened. nil until a run kicks off; reset
    /// by `clearResults()`.
    var lastRunDetectorCount: Int?

    /// Search options (toggles in UI).
    var options: SearchOptions = SearchOptions()

    /// B2: Regex validation error message, shown inline in options bar.
    var regexError: String?

    // MARK: - Filters (U1, U2)

    /// U1: Filter results by source type.
    var sourceFilter: SourceFilter = .all {
        didSet {
            invalidateFilterCaches()
            scheduleFilterFlush()
        }
    }

    /// U2: Minimum OCR confidence threshold (0.0 = show all).
    var minimumOCRConfidence: Float = 0.0 {
        didSet {
            invalidateFilterCaches()
            scheduleFilterFlush()
        }
    }

    /// U3: Group results by search term instead of by page (multi-term mode).
    var groupByTerm: Bool = false

    // MARK: - PII Scan Configuration

    /// Categories enabled for PII scan (all enabled by default).
    var enabledPIICategories: Set<PIICategory> = Set(PIICategory.allCases)

    /// Categories the next scan actually requests. An empty chip
    /// selection means scan EVERYTHING: the one-tap contract needs no
    /// configuration, so no selection maps to the full category set
    /// rather than a no-op scan. Consumed by `buildSearchMode()`, the
    /// coverage report, and the empty-state detector count so all
    /// three surfaces describe the same run.
    var effectiveScanCategories: Set<PIICategory> {
        enabledPIICategories.isEmpty ? Set(PIICategory.allCases) : enabledPIICategories
    }

    /// Former minimum-confidence value for the retired client-side
    /// post-scan filter. The per-run Confidence slider is gone —
    /// Settings' Detection Sensitivity preset is the one engine-level
    /// control — and results are no longer confidence-filtered
    /// client-side. The property remains because the saved-search
    /// schema (v2, frozen) persists it and `SearchResultRow`'s
    /// confidence-bar tiering reads it; it no longer participates in
    /// result filtering.
    var minimumPIIConfidence: Double = 0.50

    /// Post-scan filter: only show results matching these categories (nil = show all).
    var piiCategoryFilter: Set<PIICategory>? = nil {
        didSet { invalidateFilterCaches() }
    }

    /// Result sort order.
    var sortOrder: ResultSortOrder = .discoveryOrder {
        didSet {
            invalidateFilterCaches()
            scheduleFilterFlush()
        }
    }

    /// Post-scan filter that hides applied or unapplied results
    /// from the active list. User-driven via the applied-state chip
    /// Picker in `SearchToolbarSection.chipRowSubstrate`.
    /// Participates in `_FilterCacheKey`; resets to `.all` in both
    /// `clear()` and `clearResults()`.
    var appliedFilter: AppliedFilter = .all {
        didSet { invalidateFilterCaches() }
    }

    /// Drop the session's filter caches. Called from the local didSet
    /// paths above when the inputs that key `_FilterCacheKey` change.
    func invalidateFilterCaches() {
        _filteredResultsCache = nil
        _resultsByPageCache = nil
        _resultsByTermCache = nil
        _resultsByCategoryCache = nil
    }

    // MARK: - W9 Diagnostics

    /// W9 — last classifier explanation for the first scanned page text.
    /// Session-scoped; cleared on mode switch and sheet dismiss. Populated
    /// at scan kickoff by `SearchAndRedactSheet.triggerSearch`.
    private(set) var lastDoctypeExplanation: DoctypeExplanation?

    /// W9 — last scan coverage report. Populated when a PII scan completes.
    /// Session-scoped; cleared on mode switch and sheet dismiss.
    private(set) var lastCoverageReport: CoverageReport?

    /// W10 — running tally of cross-category overlap-suppressed detector
    /// matches across pages, keyed by the losing category. Populated by
    /// DocumentSearcher's per-page sink during a PII scan. Drained into
    /// `CoverageReport.overlapSuppressedCountByCategory` when the scan
    /// completes; reset on scan kickoff and on the two existing
    /// `lastCoverageReport = nil` sites.
    private(set) var pendingOverlapSuppressed: [PIICategory: Int] = [:]

    /// D06-F2 Part 1 — running total of matches dropped for falling below their
    /// per-category preset threshold during a PII scan. Populated by
    /// `DocumentSearcher`'s per-page below-threshold sink; drained into
    /// `CoverageReport.belowThresholdSuppressedCount` when the scan completes.
    /// Reset on scan kickoff and on the two `lastCoverageReport = nil` sites,
    /// mirroring `pendingOverlapSuppressed`.
    private(set) var pendingBelowThresholdSuppressed: Int = 0

    /// W9 — setter used by the scan orchestration in `SearchAndRedactSheet`.
    func setDoctypeExplanation(_ explanation: DoctypeExplanation?) {
        lastDoctypeExplanation = explanation
    }

    /// W9 — setter used by the scan orchestration in `SearchAndRedactSheet`.
    func setCoverageReport(_ report: CoverageReport?) {
        lastCoverageReport = report
    }

    /// D06-F2 Part 2 — the stored scan report with the two post-scan,
    /// view-state counts folded in: `appliedCount` from `appliedResultIDs`
    /// and `deselectedCount` from triage selections. `makeCoverageReport`
    /// deliberately leaves both at 0 at scan completion — nothing is applied
    /// or deselected yet (see `CoverageReport` in `SearchTypes`). The coverage
    /// panel and the shared audit snapshot read THIS rather than
    /// `lastCoverageReport` directly, so both reflect the user's current
    /// apply/deselect state instead of a frozen scan-time zero. Returns nil
    /// when no scan report exists (panel hidden), mirroring
    /// `lastCoverageReport`. A pure derivation over already-reset state, so it
    /// needs no teardown of its own. See `withAppliedCount` /
    /// `withDeselectedCount`.
    func coverageReportForDisplay() -> CoverageReport? {
        lastCoverageReport?
            .withAppliedCount(appliedResultIDs.count)
            .withDeselectedCount(deselectedCount)
    }

    /// Value snapshot of the session's deselection facts,
    /// captured by `PipelineCoordinator.runFullPipeline` at run entry and
    /// surfaced on the verification-results screen. Gated on the exact
    /// condition the scan coverage panel mounts under
    /// (`SearchResultsSection`: a stored scan report + `.piiScan` mode)
    /// and derived from the same live `isSelected` state
    /// (`deselectedCount`), so the two surfaces read from one
    /// definition and cannot disagree. Nil for plain-text sessions or
    /// before a scan lands — the results screen renders nothing then.
    /// Detection-triage rejections (`RedactionState.triageSelections`)
    /// are NOT counted: the panel's counter never included them, and its
    /// selection state is discarded on triage apply/dismiss.
    func deselectionSnapshotForRun() -> RedactionState.DeselectionSnapshot? {
        guard searchModeType == .piiScan, lastCoverageReport != nil else {
            return nil
        }
        return RedactionState.DeselectionSnapshot(
            deselectedCount: deselectedCount, totalCount: totalCount)
    }

    /// W10 — accumulate per-page overlap-suppressed counts. Invoked from
    /// `DocumentSearcher.overlapSink` during scanning.
    func accumulateOverlapSuppression(_ counts: [PIICategory: Int]) {
        for (category, count) in counts {
            pendingOverlapSuppressed[category, default: 0] += count
        }
    }

    /// W10 — reset the running overlap tally. Called before each scan
    /// kickoff by `SearchAndRedactSheet.triggerSearch`.
    func resetOverlapSuppression() {
        pendingOverlapSuppressed = [:]
    }

    /// D06-F2 Part 1 — accumulate per-page below-threshold drop counts. Invoked
    /// from `DocumentSearcher.belowThresholdSink` during scanning.
    func accumulateBelowThresholdSuppression(_ count: Int) {
        pendingBelowThresholdSuppressed += count
    }

    /// D06-F2 Part 1 — reset the running below-threshold tally. Called before
    /// each scan kickoff by `SearchAndRedactSheet.triggerSearch`.
    func resetBelowThresholdSuppression() {
        pendingBelowThresholdSuppressed = 0
    }

    /// Page indices where a regex enumeration bailed on
    /// the per-page timeout. Populated by `DocumentSearcher`'s
    /// timeout sink via `SearchAndRedactSheet+Trigger.triggerSearch`.
    /// Drives the banner rendered by `SearchResultsSection`.
    /// Cleared in both `clear()` and `clearResults()`.
    /// Field is document-derived (page indices reveal document
    /// structure) and is on the forbidden-key list
    /// for `SavedSearch` decoding.
    private(set) var regexTimeoutPages: Set<Int> = []

    /// Append a page index where regex timed out. Invoked from
    /// `DocumentSearcher.regexTimeoutSink` during scanning. Set semantics
    /// dedupe duplicate calls (preview + search both fire for the same
    /// page when scopes overlap).
    func recordRegexTimeout(page: Int) {
        regexTimeoutPages.insert(page)
    }

    /// Reset the running timeout-pages set. Called before each
    /// scan kickoff by `SearchAndRedactSheet.triggerSearch`.
    func resetRegexTimeoutPages() {
        regexTimeoutPages = []
    }

    /// ST-83 — page indices whose raster exceeded the OCR pixel caps, so
    /// OCR never ran on them during this scan. Populated by
    /// `DocumentSearcher`'s OCR-skip sink via
    /// `SearchAndRedactSheet+Trigger.triggerSearch`. Drives the OCR-skip
    /// banner rendered by `SearchResultsSection`, mirroring
    /// `regexTimeoutPages`. Cleared in both `clear()` and
    /// `clearResults()`. Field is document-derived (page indices reveal
    /// document structure) and is on the forbidden-key list for
    /// `SavedSearch` decoding.
    private(set) var ocrSkippedPages: Set<Int> = []

    /// Append a page index whose OCR pass was skipped on the pixel caps.
    /// Invoked from `DocumentSearcher.ocrSkipSink` during scanning. Set
    /// semantics dedupe duplicate calls (the manual-search, PII-scan, and
    /// regex-fallback OCR paths can each fire for the same page).
    func recordOCRSkip(page: Int) {
        ocrSkippedPages.insert(page)
    }

    /// Reset the running OCR-skip page set. Called before each scan
    /// kickoff by `SearchAndRedactSheet.triggerSearch`.
    func resetOCRSkippedPages() {
        ocrSkippedPages = []
    }

    // MARK: - Intra-Session Diff

    /// Snapshot of fingerprints from the PREVIOUS scan
    /// in this session. `diffSinceLastScan()` compares the snapshot
    /// against the current `results` to surface added / removed /
    /// unchanged counts in `CoverageReportView`.
    ///
    /// SECURITY: geometry + category only — NEVER
    /// matched text. Hashing `matchedText`, even into an in-memory
    /// `Set<String>`, would constitute document-derived retention
    /// under the privacy floor. The fingerprint format is
    /// `"<pageIndex>|<rounded-rect-3dp>|<piiCategory.rawValue ?? '''>"`;
    /// the load-bearing test `fingerprintNoMatchedText` pins the
    /// invariant. The field is on the forbidden-key
    /// list for `SavedSearch` decoding (ephemeral / never persisted /
    /// document-derived).
    ///
    /// CLEAR-PATHS ASYMMETRY: The
    /// canonical invariant is "every `SearchState`
    /// field clears in BOTH `clear()` and `clearResults()`." This
    /// field deviates by design — the cross-scan snapshot MUST
    /// survive `clearResults()` (called by `triggerSearch` at the
    /// top of each re-scan) so the just-completed scan's results
    /// can be diffed against the next scan's results. Without the
    /// carve-out, capture-before-clear in `triggerSearch` would be
    /// immediately undone and the diff would always be nil.
    ///   - `clear()`        — DOES wipe to nil (sheet dismiss / full
    ///                        reset; no cross-session diff —
    ///                        deferred to V1.1+)
    ///   - `clearResults()` — DOES NOT wipe (intra-session preservation)
    /// The asymmetry is pinned by `IntraSessionDiffTests.clearPathsAsymmetric`
    /// and logged for user review.
    private(set) var priorScanFingerprints: Set<String>?

    /// Snapshot the current `results` array's fingerprints into
    /// `priorScanFingerprints`. Called by `triggerSearch` BEFORE
    /// `clearResults()` wipes `results`, so the snapshot reflects the
    /// scan that just completed. Uses an explicit `for` loop (NOT
    /// `results.map { ... }`) as a simulator-host crash
    /// workaround. O(n) over `results`; pinned by perf smoke in
    /// `IntraSessionDiffTests`.
    func captureFingerprintsBeforeScan() {
        var snapshot: Set<String> = []
        snapshot.reserveCapacity(results.count)
        for r in results {
            snapshot.insert(Self.fingerprint(for: r))
        }
        priorScanFingerprints = snapshot
    }

    /// Deterministic, geometry+category-only fingerprint
    /// of a single `SearchResult`. The output string is
    /// `"<pageIndex>|<x>,<y>,<w>,<h>|<categoryRawValue ?? '''>"` where
    /// the rect components are formatted to 3 decimal places. NEVER
    /// includes `matchedText`, `contextSnippet`, `term`, `rationale`,
    /// or any other document-derived value — pinned by
    /// `fingerprintNoMatchedText` load-bearing test.
    /// `static` so the helper can be invoked from `for`-loop bodies
    /// without capturing `self`.
    static func fingerprint(for r: SearchResult) -> String {
        let rounded = String(
            format: "%.3f,%.3f,%.3f,%.3f",
            r.normalizedRect.origin.x,
            r.normalizedRect.origin.y,
            r.normalizedRect.size.width,
            r.normalizedRect.size.height
        )
        return "\(r.pageIndex)|\(rounded)|\(r.piiCategory?.rawValue ?? "")"
    }

    /// Compute the intra-session diff between the most recent
    /// captured snapshot and the current `results`. Returns nil when
    /// no prior snapshot exists (first scan of session, or after
    /// `clear()` wiped the snapshot). The 3-tuple shape mirrors
    /// the `(added, removed, unchanged)` contract.
    /// O(n) over `results` + O(|prior|) for set arithmetic.
    func diffSinceLastScan() -> (added: Int, removed: Int, unchanged: Int)? {
        guard let prior = priorScanFingerprints else { return nil }
        var current: Set<String> = []
        current.reserveCapacity(results.count)
        for r in results {
            current.insert(Self.fingerprint(for: r))
        }
        let added = current.subtracting(prior).count
        let removed = prior.subtracting(current).count
        let unchanged = prior.intersection(current).count
        return (added: added, removed: removed, unchanged: unchanged)
    }

    // MARK: - Results

    /// All search results, accumulated progressively.
    var results: [SearchResult] = []

    /// U4: result IDs whose corresponding `RedactionRegion` exists. Lifted
    /// from `SearchAndRedactSheet` view-state
    /// so downstream features (select-by-applied, applied-only filter,
    /// changes-since-last-apply) can participate in `_FilterCacheKey`
    /// invalidation. Cleared by `clear()` and `clearResults()`.
    /// The set is `Set<UUID>` of view-side
    /// result IDs; not document content; ephemeral.
    var appliedResultIDs: Set<UUID> = [] {
        didSet { invalidateFilterCaches() }
    }

    /// BH-A-03 — result IDs the apply path dedup-SKIPPED because an
    /// existing region already covers them (>80% overlap). Distinct
    /// from `appliedResultIDs` on purpose: QW-1 grants skipped results
    /// no applied badge and no audit entry, but a selection that is
    /// fully covered (applied ∪ covered) must still gray Apply — the
    /// button otherwise stays live forever and every press re-runs a
    /// "Marked 0 … already covered" no-op. Same lifetime as
    /// `appliedResultIDs`.
    var coveredResultIDs: Set<UUID> = []

    /// Reserved for programmatic mode transitions (saved-search
    /// recall). When `true`, the `searchModeType` `.onChange` handler
    /// in `SearchAndRedactSheet` preserves applied markers + filter
    /// chips instead of clearing. Today every transition is user-
    /// initiated (mode picker tap), so this flag is always `false`.
    var isProgrammaticModeChange: Bool = false

    /// Whether the result cap has been reached.
    var resultsAtCap: Bool = false

    /// QW-12 — pages the cap-cancelled scan never reached. Snapshotted in
    /// `appendResult` at the moment the cap fires (`totalPages` minus the
    /// engine's last-reported `currentSearchPage`; the current page itself
    /// may be partially scanned and is not counted). Drives the remainder
    /// sentence in `SearchFooterSection`'s cap banner so the cap stops
    /// reading as full coverage. Reset wherever `resultsAtCap` resets.
    private(set) var capUnscannedPageCount: Int = 0

    /// All results after source/confidence/category filters applied.
    /// Cached and invalidated on resultVersion change or filter change (P3).
    var filteredResults: [SearchResult] {
        let cacheKey = _currentCacheKey
        if _filteredResultsCacheKey == cacheKey, let cached = _filteredResultsCache {
            return cached
        }
        let filtered = applyFilters(to: results)
        _filteredResultsCache = filtered
        _filteredResultsCacheKey = cacheKey
        return filtered
    }

    /// Results grouped by page, with source/confidence filters applied.
    /// Cached and invalidated on resultVersion change or filter change (P3).
    var resultsByPage: [Int: [SearchResult]] {
        let cacheKey = _currentCacheKey
        if _resultsByPageCacheKey == cacheKey, let cached = _resultsByPageCache {
            return cached
        }
        let grouped = Dictionary(grouping: filteredResults, by: \.pageIndex)
        _resultsByPageCache = grouped
        _resultsByPageCacheKey = cacheKey
        return grouped
    }

    /// U3: Results grouped by search term, with filters applied.
    var resultsByTerm: [String: [SearchResult]] {
        let cacheKey = _currentCacheKey
        if _resultsByTermCacheKey == cacheKey, let cached = _resultsByTermCache {
            return cached
        }
        let grouped = Dictionary(grouping: filteredResults, by: \.term)
        _resultsByTermCache = grouped
        _resultsByTermCacheKey = cacheKey
        return grouped
    }

    /// Filtered result count (respects source/confidence filters).
    var filteredCount: Int { filteredResults.count }

    /// 1-based position of `currentResult` within `filteredResults`.
    /// Returns nil when there is no current result or when the current
    /// result is not present in `filteredResults` (i.e. it is hidden by
    /// the active filter). Used by the counter in `SearchAndRedactSheet`
    /// to display the position within the visible filtered set.
    var currentResultFilteredPosition: Int? {
        guard let current = currentResult else { return nil }
        return filteredResults.firstIndex(where: { $0.id == current.id }).map { $0 + 1 }
    }

    /// Count of selected results within the currently filtered set.
    var selectedFilteredCount: Int {
        filteredResults.count { $0.isSelected }
    }

    /// Whether any OCR results exist (controls filter UI visibility).
    var hasOCRResults: Bool {
        results.contains { if case .ocr = $0.source { return true }; return false }
    }

    /// Results grouped by PII category, with filters applied.
    var resultsByCategory: [PIICategory: [SearchResult]] {
        let cacheKey = _currentCacheKey
        if _resultsByCategoryCacheKey == cacheKey, let cached = _resultsByCategoryCache {
            return cached
        }
        let piiOnly = filteredResults.filter { $0.piiCategory != nil }
        let grouped = Dictionary(grouping: piiOnly, by: { $0.piiCategory! })
        _resultsByCategoryCache = grouped
        _resultsByCategoryCacheKey = cacheKey
        return grouped
    }

    /// Counts of results per PII category (for badge display).
    var categoryCounts: [PIICategory: Int] {
        resultsByCategory.mapValues(\.count)
    }

    /// Whether any PII results exist (controls PII filter UI visibility).
    var hasPIIResults: Bool {
        results.contains { $0.piiCategory != nil }
    }

    // @ObservationIgnored: these are memoization internals, not view state.
    // The grouping getters above WRITE them mid-body-evaluation; if the macro
    // wraps them, that write re-enters the ObservationRegistrar during List
    // body evaluation and trips AG::precondition_failure (SIGABRT — the
    // Mark-for-Redaction crash). View updates still flow through the observed
    // inputs: `results`/`resultVersion` and every field of `_currentCacheKey`,
    // all of which the getters read on every access.
    @ObservationIgnored private var _filteredResultsCache: [SearchResult]?
    @ObservationIgnored private var _filteredResultsCacheKey: _FilterCacheKey?
    @ObservationIgnored private var _resultsByPageCache: [Int: [SearchResult]]?
    @ObservationIgnored private var _resultsByPageCacheKey: _FilterCacheKey?
    @ObservationIgnored private var _resultsByTermCache: [String: [SearchResult]]?
    @ObservationIgnored private var _resultsByTermCacheKey: _FilterCacheKey?
    @ObservationIgnored private var _resultsByCategoryCache: [PIICategory: [SearchResult]]?
    @ObservationIgnored private var _resultsByCategoryCacheKey: _FilterCacheKey?

    private var _currentCacheKey: _FilterCacheKey {
        _FilterCacheKey(
            version: resultVersion,
            source: sourceFilter,
            minOCRConfidence: minimumOCRConfidence,
            piiCategoryFilter: piiCategoryFilter,
            sortOrder: sortOrder,
            appliedResultIDs: appliedResultIDs,
            appliedFilter: appliedFilter
        )
    }

    private struct _FilterCacheKey: Equatable {
        let version: Int
        let source: SourceFilter
        let minOCRConfidence: Float
        let piiCategoryFilter: Set<PIICategory>?
        let sortOrder: ResultSortOrder
        let appliedResultIDs: Set<UUID>
        let appliedFilter: AppliedFilter
    }

    private func applyFilters(to results: [SearchResult]) -> [SearchResult] {
        var filtered = results.filter { result in
            // U1: Source filter
            switch sourceFilter {
            case .all: break
            case .textOnly:
                guard result.source == .textLayer else { return false }
            case .ocrOnly:
                guard result.source != .textLayer else { return false }
            }
            // U2: OCR confidence filter
            if minimumOCRConfidence > 0, case .ocr(let conf) = result.source {
                guard conf >= minimumOCRConfidence else { return false }
            }
            // PII category filter
            if let categoryFilter = piiCategoryFilter, let cat = result.piiCategory {
                guard categoryFilter.contains(cat) else { return false }
            }
            // The PII confidence post-filter is retired with the
            // per-run Confidence slider — every above-threshold result
            // the engine returns is listed; selection predicates
            // (Select where… ≥75/≥90) are the confidence tools now.
            // Applied-state filter. `.all` no-ops; `.applied`
            // keeps only results whose IDs are in `appliedResultIDs`;
            // `.unapplied` keeps the complement.
            switch appliedFilter {
            case .all:
                break
            case .applied:
                guard appliedResultIDs.contains(result.id) else { return false }
            case .unapplied:
                guard !appliedResultIDs.contains(result.id) else { return false }
            }
            return true
        }

        // Apply sort order
        switch sortOrder {
        case .discoveryOrder:
            break // Already in discovery order
        case .confidenceDescending:
            filtered.sort { ($0.piiConfidence ?? 0) > ($1.piiConfidence ?? 0) }
        case .pageAscending:
            filtered.sort { $0.pageIndex < $1.pageIndex }
        }

        return filtered
    }

    /// Total selected count.
    var selectedCount: Int {
        results.count { $0.isSelected }
    }

    /// True when the selection is non-empty and every selected result
    /// already carries an applied marker. The toolbar Apply disables on
    /// it — re-applying an all-applied selection can only no-op through
    /// the overlap guard ("Marked 0 … already covered").
    var selectionFullyApplied: Bool {
        let selected = results.filter(\.isSelected)
        guard !selected.isEmpty else { return false }
        // BH-A-03 — dedup-covered counts as applied for the graying
        // gate: a fully covered selection has nothing left to apply.
        return selected.allSatisfy {
            appliedResultIDs.contains($0.id)
                || coveredResultIDs.contains($0.id)
        }
    }

    /// D06-F2 Part 2 — count of results the user left un-checked in triage
    /// (the complement of `selectedCount`). Folded into
    /// `CoverageReport.deselectedCount` at the panel + audit-export boundary
    /// by `coverageReportForDisplay()`. Derived from live `isSelected` state,
    /// so it returns to 0 with `results` on `clear()` / `clearResults()`.
    var deselectedCount: Int {
        results.count { !$0.isSelected }
    }

    /// Total result count.
    var totalCount: Int { results.count }

    // MARK: - Progress

    /// Whether a search is currently running.
    var isSearching: Bool = false

    /// Current page being searched.
    var currentSearchPage: Int = 0

    /// Total pages in document.
    var totalPages: Int = 0

    // MARK: - Multi-term

    /// For multi-term mode: list of terms.
    var searchTerms: [String] = []

    /// In-memory ring of recent multi-term term sets,
    /// surfaced in the multi-term empty state as tappable recall chips.
    /// Capped at `recentMultiTermSetsCap`; dedup is exact-array match
    /// (case-sensitive). Reset on `clear()` (full session) but NOT on
    /// `clearResults()` (per-search reset preserves history within the
    /// session — same pattern as `searchTerms`,
    /// which also persists across `clearResults` in the same session).
    /// Recorded by `SearchAndRedactSheet+Trigger.triggerSearch()` on
    /// each multi-term kickoff via `recordMultiTermSearch(terms:)`.
    private(set) var recentMultiTermSets: [[String]] = []

    static let recentMultiTermSetsCap = 5

    /// Record a multi-term term set into the
    /// in-memory ring. No-op for empty `terms`. Existing matching
    /// entries move to the front (most-recent-first); the ring is
    /// capped at `recentMultiTermSetsCap`, dropping the oldest.
    func recordMultiTermSearch(terms: [String]) {
        guard !terms.isEmpty else { return }
        if let existing = recentMultiTermSets.firstIndex(of: terms) {
            recentMultiTermSets.remove(at: existing)
        }
        recentMultiTermSets.insert(terms, at: 0)
        if recentMultiTermSets.count > Self.recentMultiTermSetsCap {
            recentMultiTermSets = Array(recentMultiTermSets.prefix(Self.recentMultiTermSetsCap))
        }
    }

    // MARK: - Recents recording

    /// Record a query string into the appropriate recents list.
    ///
    /// - No-op for empty query strings.
    /// - No-op for modes other than `.text` / `.regex`.
    /// - Always records into the in-memory list; writes through to
    ///   UserDefaults only when `search.recents.enabled.v1` reads `true`
    ///   (absent key treated as `false` — private by default; recents
    ///   stay in-memory for the session unless the user opts in).
    /// - Stores the QUERY string only — NEVER persists matched text
    ///   or document content.
    /// - Deduplicates with move-to-front; caps at `recentQueriesCap`.
    func recordRecentQuery(_ query: String, mode: SearchModeType) {
        // BH-B-06 — whitespace-only strings are not queries: recording
        // one produced an invisible blank recents chip that re-ran the
        // whitespace on tap. Defensive belt beside the trigger-side
        // trimmed gate (explicit Return paths can still run verbatim
        // whitespace-padded queries; those are worth recalling, a
        // blank chip never is).
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard mode == .text || mode == .regex else { return }
        // Absent key treated as false (default-off). Keep in lockstep
        // with `SettingsState.saveRecentSearches` hydration.
        let persistenceEnabled = defaults.bool(forKey: Self.recentsEnabledKey)

        switch mode {
        case .text:
            recentTextQueries = dedupedAndCapped(
                inserting: query,
                into: recentTextQueries
            )
            if persistenceEnabled {
                defaults.set(recentTextQueries, forKey: Self.recentsTextKey)
            }
        case .regex:
            recentRegexQueries = dedupedAndCapped(
                inserting: query,
                into: recentRegexQueries
            )
            if persistenceEnabled {
                defaults.set(recentRegexQueries, forKey: Self.recentsRegexKey)
            }
        default:
            break
        }
    }

    /// Clear all persisted and in-memory recent search history (both
    /// text and regex query lists, plus the in-memory multi-term ring).
    /// Called by "Clear Search History" and by the Settings toggle
    /// path when "Save Recent Searches" is turned off.
    ///
    /// Cross-session carve-out: this is the ONLY path that wipes
    /// recents; clear() and clearResults() intentionally do NOT
    /// (recents survive both clear paths by design).
    func clearRecentSearchHistory() {
        recentTextQueries = []
        recentRegexQueries = []
        recentMultiTermSets = []
        defaults.removeObject(forKey: Self.recentsTextKey)
        defaults.removeObject(forKey: Self.recentsRegexKey)
    }

    /// One-time deletion of the two persisted recents lists, run at app
    /// launch. Recents are private-by-default from this build on; lists
    /// persisted by earlier builds are removed unconditionally —
    /// regardless of the enabled preference — exactly once. The flag
    /// guard is load-bearing: recents recorded AFTER the user opts back
    /// in must survive subsequent launches.
    static func deletePersistedRecentsOnce(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: recentsDeletionDoneKey) else { return }
        defaults.removeObject(forKey: recentsTextKey)
        defaults.removeObject(forKey: recentsRegexKey)
        defaults.set(true, forKey: recentsDeletionDoneKey)
    }

    // MARK: - Filter flush (debounced 500 ms)

    /// Schedule a debounced write of the current filter shape to
    /// UserDefaults. Cancels any pending write (mirrors flushTask
    /// idiom) so a slider drag does not write on every tick.
    private func scheduleFilterFlush() {
        filterFlushTask?.cancel()
        filterFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.flushFilterShape()
        }
    }

    /// Write the current filter shape to UserDefaults synchronously.
    private func flushFilterShape() {
        let shape = LastSearchFilterShape(
            sourceFilter: sourceFilter,
            minimumOCRConfidence: minimumOCRConfidence,
            sortOrder: sortOrder
        )
        if let data = try? JSONEncoder().encode(shape) {
            defaults.set(data, forKey: Self.lastFilterKey)
        }
    }

    // MARK: - Recents helpers

    /// Move-to-front dedup + cap helper. Pure function; used by
    /// `recordRecentQuery` for both text and regex lists.
    private func dedupedAndCapped(inserting query: String, into list: [String]) -> [String] {
        var updated = list
        if let existing = updated.firstIndex(of: query) {
            updated.remove(at: existing)
        }
        updated.insert(query, at: 0)
        if updated.count > Self.recentQueriesCap {
            updated = Array(updated.prefix(Self.recentQueriesCap))
        }
        return updated
    }

    // MARK: - Init (UserDefaults seam)

    /// Designated init. Hydrates persisted recents and last-used filter
    /// shape from `defaults` (fail-closed: missing / malformed → in-type
    /// defaults). Pass a scratch `UserDefaults` suite in tests.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Recents — fail-closed decode: nil / wrong type → []
        self.recentTextQueries  = (defaults.array(forKey: Self.recentsTextKey)  as? [String]) ?? []
        self.recentRegexQueries = (defaults.array(forKey: Self.recentsRegexKey) as? [String]) ?? []

        // Last-used filter — fail-closed JSON decode → property defaults
        if let data = defaults.data(forKey: Self.lastFilterKey),
           let shape = try? JSONDecoder().decode(LastSearchFilterShape.self, from: data) {
            self.sourceFilter         = shape.sourceFilter
            self.minimumOCRConfidence = shape.minimumOCRConfidence
            self.sortOrder            = shape.sortOrder
        }
        // Note: filter fields set above BEFORE the object is observable,
        // so the scheduleFilterFlush() in their didSet paths is NOT called
        // during init (Swift does not call didSet for initializer assignments).
    }

    // MARK: - Task Management

    /// Active search task for cancellation.
    var activeSearchTask: Task<Void, Never>?

    // MARK: - Result Batching (P2)

    /// Pending results buffered before flush.
    private var pendingResults: [SearchResult] = []
    /// Flush timer task.
    private var flushTask: Task<Void, Never>?
    /// Batch size threshold before immediate flush.
    private static let batchFlushSize = 50
    /// Time interval between automatic flushes.
    private static let flushInterval: Duration = .milliseconds(100)

    // MARK: - Result Navigation (U1, W7)

    /// Index of the currently focused result for prev/next navigation.
    var currentResultIndex: Int?

    /// The currently focused result, if any.
    var currentResult: SearchResult? {
        guard let idx = currentResultIndex, results.indices.contains(idx) else { return nil }
        return results[idx]
    }

    /// W7 — session-scoped scope for J / K / Cmd+G traversal. Not persisted;
    /// every fresh document opens at `.wholeDocument`.
    var navigationScope: SearchNavigationScope = .wholeDocument

    /// W7 — return only the results visible in the active navigation scope.
    /// `.wholeDocument` returns all results; `.currentPage` filters to the
    /// page the caller currently has loaded.
    /// Sources from `filteredResults` so J/K navigation respects
    /// active source/confidence/category/applied filters — results hidden
    /// by the filter are skipped during traversal. `navigateToNext` /
    /// `navigateToPrevious` map back via `results.firstIndex`, which
    /// remains correct because `filteredResults` is a strict subset of
    /// `results`.
    func scopedResults(currentPageIndex: Int) -> [SearchResult] {
        switch navigationScope {
        case .wholeDocument: return filteredResults
        case .currentPage: return filteredResults.filter { $0.pageIndex == currentPageIndex }
        }
    }

    /// Navigate to the next result within the current scope. Wraps. No-op
    /// when the scope is empty (e.g. `.currentPage` on a page with no hits).
    func navigateToNext(currentPageIndex: Int) {
        let scoped = scopedResults(currentPageIndex: currentPageIndex)
        guard !scoped.isEmpty else { return }
        let currentID = currentResult?.id
        let scopedIdx = scoped.firstIndex(where: { $0.id == currentID })
        let nextScopedIdx: Int
        if let scopedIdx { nextScopedIdx = (scopedIdx + 1) % scoped.count }
        else { nextScopedIdx = 0 }
        if let realIdx = results.firstIndex(where: { $0.id == scoped[nextScopedIdx].id }) {
            currentResultIndex = realIdx
        }
    }

    /// Navigate to the previous result within the current scope. Wraps.
    func navigateToPrevious(currentPageIndex: Int) {
        let scoped = scopedResults(currentPageIndex: currentPageIndex)
        guard !scoped.isEmpty else { return }
        let currentID = currentResult?.id
        let scopedIdx = scoped.firstIndex(where: { $0.id == currentID })
        let prevScopedIdx: Int
        if let scopedIdx { prevScopedIdx = (scopedIdx - 1 + scoped.count) % scoped.count }
        else { prevScopedIdx = scoped.count - 1 }
        if let realIdx = results.firstIndex(where: { $0.id == scoped[prevScopedIdx].id }) {
            currentResultIndex = realIdx
        }
    }

    // MARK: - W7 Review Shortcuts

    /// W7 — Space-key handler. Toggles `isSelected` on the focused result
    /// (same field the checkbox drives), so the existing apply pipeline
    /// picks it up without parallel state.
    func toggleSelectionForCurrentMatch() {
        guard let id = currentResult?.id else { return }
        toggleSelection(for: id)
    }

    /// W7 — Return-key prelude. If nothing is selected, mark the focused
    /// result so the caller can apply via the existing `RedactionState`
    /// path. Returns true when the apply path should run.
    @discardableResult
    func selectCurrentMatchIfNoneSelected() -> Bool {
        if results.contains(where: { $0.isSelected }) { return true }
        guard let id = currentResult?.id else { return false }
        toggleSelection(for: id)
        return true
    }

    // MARK: - W7 Live Preview

    /// W7 — most recent live-preview snapshot (engine NSRanges + counts).
    /// nil while no preview is in flight or after `clearLivePreview()`.
    private(set) var livePreview: SearchPreviewResult?

    /// W7 — resolved bounding rects for the visible page's preview matches,
    /// in normalized PDF coords. Filled by the sheet (which owns the
    /// `DocumentSearcher` reference for `boundingRect`) right after
    /// `livePreview` updates. Drawn by the per-page UIKit overlay.
    private(set) var livePreviewRects: [CGRect] = []

    private var livePreviewTask: Task<Void, Never>?

    /// W7 — debounce + run a live-preview pass. Each call cancels the
    /// previous task; only the last result is published. Independent
    /// from the sheet's existing 300 ms full-search debounce.
    func scheduleLivePreview(
        searcher: DocumentSearcher,
        currentPageIndex: Int,
        totalPageCount: Int,
        pageTextProvider: @Sendable @escaping (Int) async -> String?,
        // D10-F3 — match the full-search debounce (300 ms, see `debounceSearch`)
        // so the preview does not issue an extra off-main page.string read ahead
        // of every keystroke; a still-typing user then produces no preview walk
        // at all.
        debounce: Duration = .milliseconds(300)
    ) {
        livePreviewTask?.cancel()

        // Build the engine SearchMode from the same conversion the sheet
        // uses for the full search. Don't preview piiScan.
        let mode: SearchMode
        switch searchModeType {
        case .text:
            guard !queryText.isEmpty else { clearLivePreview(); return }
            mode = .text(queryText, options: options)
        case .regex:
            guard !queryText.isEmpty else { clearLivePreview(); return }
            mode = .regex(queryText, options: options)
        case .multiTerm:
            guard !searchTerms.isEmpty else { clearLivePreview(); return }
            mode = .multiTerm(searchTerms, options: options)
        case .piiScan:
            clearLivePreview(); return
        }

        // D10-F3 — the live preview only renders the visible page's highlight
        // rects; the whole-document total is owned by the full search that the
        // same keystroke kicks off. Always scope the preview to the current page
        // so it stops re-walking every page's `page.string` off-main against the
        // freshly-copied PDFDocument (D10-F1 previewDoc reader).
        let scope: SearchPreviewScope = .currentPage(pageIndex: currentPageIndex)

        livePreviewTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            if Task.isCancelled { return }
            let result = await searcher.previewMatches(
                mode: mode,
                scope: scope,
                currentPageIndex: currentPageIndex,
                totalPageCount: totalPageCount,
                pageTextProvider: pageTextProvider
            )
            if Task.isCancelled { return }
            // CONC-2 (Pkg N): the enclosing Task is MainActor-isolated
            // (SearchState is @MainActor by SE-0466 default and the Task
            // closure inherits the surrounding isolation), and
            // `searcher.previewMatches` returns to MainActor after the
            // actor hop. A second `await MainActor.run` was a redundant
            // re-hop — dropped. The `guard let self` mirrors the
            // original closure's weak-self contract.
            guard let self else { return }
            self.livePreview = result
            // Rects are filled by the caller after this returns; clear
            // any stale rects from a previous query in the meantime.
            self.livePreviewRects = []
        }
    }

    /// W7 — caller-supplied resolved rects (normalized 0–1 PDF coords) for
    /// the visible page. The view layer does the NSRange→CGRect conversion
    /// because the engine has no PDFPage context.
    func setLivePreviewRects(_ rects: [CGRect]) {
        livePreviewRects = rects
        resultVersion += 1
    }

    /// W7 — cancel any in-flight preview and clear the published state.
    func clearLivePreview() {
        livePreviewTask?.cancel()
        livePreviewTask = nil
        let hadPreview = (livePreview != nil) || !livePreviewRects.isEmpty
        livePreview = nil
        livePreviewRects = []
        if hadPreview { resultVersion += 1 }
    }

    // MARK: - Version Tracking

    /// Monotonic counter for overlay dirty checking.
    /// Incremented on every results mutation.
    private(set) var resultVersion: Int = 0

    // MARK: - Methods

    func clear() {
        queryText = ""
        regexError = nil
        flushTask?.cancel()
        flushTask = nil
        pendingResults.removeAll()
        results = []
        appliedResultIDs.removeAll()
        coveredResultIDs.removeAll()
        appliedFilter = .all
        resultsAtCap = false
        currentResultIndex = nil
        isSearching = false
        currentSearchPage = 0
        totalPages = 0
        searchTerms = []
        recentMultiTermSets = []
        // recentTextQueries / recentRegexQueries are
        // intentionally NOT cleared here. Recents are cross-session
        // persistent history; they survive both clear() and clearResults()
        // by design. Use clearRecentSearchHistory() to wipe them.
        activeSearchTask?.cancel()
        activeSearchTask = nil
        lastDoctypeExplanation = nil
        lastCoverageReport = nil
        pendingOverlapSuppressed = [:]
        pendingBelowThresholdSuppressed = 0
        regexTimeoutPages = []
        ocrSkippedPages = []
        capUnscannedPageCount = 0
        hasCompletedRunSinceClear = false
        scanStartFailed = false
        lastRunDetectorCount = nil
        // Drop the magic-wand pre-select flag along with all
        // other session-scoped state so a fresh sheet session starts at
        // the engine default selection shape.
        preselectIncomingResults = false
        // Conditional dismiss: the touched-selections tracker is per-sheet-session.
        userModifiedSelections = false
        // Defensive: an armed-but-unconsumed auto-run must not leak
        // into the next sheet session (the flag is normally consumed
        // by the sheet's `.onAppear` before any teardown can run).
        pendingAutoRunScan = false
        // Also reset the new exactMatch options flag so the
        // sheet's option toggles return to the default substring match.
        options.exactMatch = false
        // Sheet dismiss / full reset wipes the intra-session
        // diff snapshot. Cross-session diff is deferred to V1.1+.
        // Asymmetric with `clearResults()` by design — see
        // `priorScanFingerprints` docstring.
        priorScanFingerprints = nil
        // W7 — drop any in-flight preview and reset session-scoped scope.
        livePreviewTask?.cancel()
        livePreviewTask = nil
        livePreview = nil
        livePreviewRects = []
        navigationScope = .wholeDocument
        // Flush any pending filter write before the session tears down.
        filterFlushTask?.cancel()
        filterFlushTask = nil
        flushFilterShape()
        resultVersion += 1
    }

    func cancelSearch() async {
        let task = activeSearchTask
        activeSearchTask = nil
        task?.cancel()
        _ = await task?.value
        isSearching = false
        flushPendingResults() // Deliver any buffered results
    }

    // Fire-and-forget cancellation for two cases that cannot await the
    // task's `value`: (a) self-cancellation from inside the task
    // (`appendResult` cap-hit) — awaiting a task from within itself
    // deadlocks; (b) document close / sheet teardown, where the caller
    // wipes shared state regardless, so a leaked cleanup tail has
    // nothing to clobber.
    func cancelSearchWithoutAwait() {
        activeSearchTask?.cancel()
        activeSearchTask = nil
        isSearching = false
        flushPendingResults()
    }

    /// Action chain for the saturation banner's "Scope to current
    /// page" shortcut. Flushes the pending result buffer before
    /// cancelling the in-flight scan, then sets the navigation scope
    /// to `.currentPage`. Caller invokes `triggerSearch` after this
    /// returns so the saturated query re-runs against the page-scoped
    /// constraint per state-snapshot lifetime — flush MUST
    /// happen before cancel so accumulated counts in the pending
    /// buffer survive the re-target. (The full re-trigger path
    /// itself wipes `results` via `clearResults`, so the preserved
    /// counts only matter for any UI that reads `results` between the
    /// scope set and the next flush — defensive ordering documented
    /// here for readers + future per-page-banner consumers.)
    func scopeToCurrentPage() async {
        flushPendingResults()
        await cancelSearch()
        navigationScope = .currentPage
    }

    /// Select all results matching `predicate`. Each result's
    /// `isSelected` is replaced with `predicate(result)` — predicates
    /// that match a subset deselect the rest, so the
    /// `SearchResultsSection` "Select where…" Menu can express
    /// "select only PII results above 90%" / "select only OCR" as a
    /// single mutation. Bumps `resultVersion` once for the full pass
    /// (no per-result observer churn). Performance gate: <100ms on
    /// 10k results — pinned by `SearchStateSelectionTests`.
    func selectWhere(_ predicate: (SearchResult) -> Bool) {
        for i in results.indices {
            results[i].isSelected = predicate(results[i])
        }
        resultVersion += 1
    }

    /// Footer bar select-all / deselect-all toggle. Refactored
    /// to compose with `selectWhere` while preserving filtered-only
    /// behavior — results outside the active filter retain their
    /// existing `isSelected`. The captured `filteredIDs` + `target`
    /// makes the predicate a pure function of `result.id`.
    func toggleSelectAll() {
        let filtered = filteredResults
        let filteredIDs = Set(filtered.map(\.id))
        let target = !filtered.allSatisfy(\.isSelected)
        selectWhere { result in
            filteredIDs.contains(result.id) ? target : result.isSelected
        }
    }

    func toggleSelection(for id: UUID) {
        guard let index = results.firstIndex(where: { $0.id == id }) else { return }
        results[index].isSelected.toggle()
        resultVersion += 1
    }

    /// Current index of a result by ID, or nil if removed.
    func index(of id: UUID) -> Int? {
        results.firstIndex(where: { $0.id == id })
    }

    /// When set by the magic-wand entry point, every result
    /// landing via `appendResult` is auto-selected so the user can apply
    /// with one tap. Reset by `triggerSearch` after kickoff so a later
    /// non-magic-wand search in the same session goes back to the
    /// default selection shape. Pinned by `MagicWandUITests`.
    var preselectIncomingResults: Bool = false

    /// Conditional dismiss: whether the USER has modified selections this sheet
    /// session, for either result origin. Gates the sheet's Dismiss:
    /// untouched → one tap; touched → confirmation dialog (the triage
    /// sheet's donor rule, generalized to the whole surface).
    ///
    /// Written `true` only at user-gesture sites (row circle, footer
    /// Select All, Select-Where, keyboard space toggle, Pencil circle
    /// select, review-row equivalents) — NEVER by programmatic
    /// selection writes: the magic-wand arrival preselect, saved-search
    /// recall, and the mode-switch undo restore don't count as user
    /// selection work. Reset by a successful apply (the modified
    /// selections were committed — a post-apply Dismiss confirming
    /// "selections will not be saved" would be false) and by `clear()`
    /// on session teardown.
    var userModifiedSelections: Bool = false

    /// Buffer a result from the search stream. Flushed in batches
    /// to avoid per-result @Observable change notifications (P2).
    /// Stops accepting at engine cap and cancels the search (P3).
    func appendResult(_ result: SearchResult) {
        if results.count + pendingResults.count >= DocumentSearcher.maxResults {
            resultsAtCap = true
            // QW-12 — snapshot how many pages the cancelled scan will
            // never reach, so the footer can report the remainder rather
            // than presenting the first-N results as full coverage.
            capUnscannedPageCount = max(0, totalPages - currentSearchPage)
            flushPendingResults()
            cancelSearchWithoutAwait()
            return
        }
        var stored = result
        // Magic-wand pre-fills the sheet then asks the engine
        // to run; engine `SearchResult.isSelected` defaults to `false`.
        // Flipping the flag here keeps the engine API untouched while
        // delivering the "all instances selected by default" UX.
        if preselectIncomingResults {
            stored.isSelected = true
        }
        pendingResults.append(stored)
        if pendingResults.count >= Self.batchFlushSize {
            flushPendingResults()
        } else if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: Self.flushInterval)
                guard !Task.isCancelled else { return }
                self?.flushPendingResults()
            }
        }
    }

    /// Flush buffered results into the published array. Single version bump.
    func flushPendingResults() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingResults.isEmpty else { return }
        results.append(contentsOf: pendingResults)
        pendingResults.removeAll()
        resultVersion += 1
    }

    /// Clear results and increment version for overlay refresh.
    func clearResults() {
        regexError = nil
        flushTask?.cancel()
        flushTask = nil
        pendingResults.removeAll()
        results = []
        appliedResultIDs.removeAll()
        coveredResultIDs.removeAll()
        appliedFilter = .all
        resultsAtCap = false
        currentResultIndex = nil
        lastDoctypeExplanation = nil
        lastCoverageReport = nil
        pendingOverlapSuppressed = [:]
        pendingBelowThresholdSuppressed = 0
        regexTimeoutPages = []
        ocrSkippedPages = []
        capUnscannedPageCount = 0
        // Run-state discriminators reset with results: the next empty
        // state must read as "not run yet" until a run completes, and a
        // prior failed-start must not outlive the state it described.
        hasCompletedRunSinceClear = false
        scanStartFailed = false
        lastRunDetectorCount = nil
        // UXF-02 — scan-progress counters reset with results. Leaving
        // `currentSearchPage` non-zero across a mode switch made the
        // piiScan empty state read as post-scan ("Scan complete … 0
        // candidates") before any scan ran: the empty-state context
        // discriminator uses `currentSearchPage > 0` as its
        // scan-has-run signal.
        currentSearchPage = 0
        totalPages = 0
        // W7 — full search supersedes live preview; drop the transient state
        // so highlights don't briefly stack with full results during the
        // 100 ms gap before flushPendingResults fires.
        livePreviewTask?.cancel()
        livePreviewTask = nil
        livePreview = nil
        livePreviewRects = []
        resultVersion += 1
    }
}

/// UI selector for search mode (simpler than SearchMode enum for picker).
/// `Codable` conformance is consumed by `SavedSearchStore`.
/// rawValues are stable wire identifiers (persistence + launch-arg
/// mapping), deliberately decoupled from the user-facing strings so a
/// display rename can never invalidate persisted data. Wire values are
/// frozen; display strings live in `displayName` only.
enum SearchModeType: String, CaseIterable, Sendable, Codable {
    case text = "text"
    case regex = "regex"
    case multiTerm = "multiTerm"
    case piiScan = "scan"

    /// User-facing name. Display-only — never persisted, never compared
    /// against stored data.
    var displayName: String {
        switch self {
        case .text: "Text"
        case .regex: "Regex"
        case .multiTerm: "Multi-term"
        case .piiScan: "Scan"
        }
    }

    /// Which of the sheet's two peer interfaces this mode belongs to.
    /// The scan mode IS the Scan interface's machinery; text / regex /
    /// multi-term are the Search interface's second-level modes. The
    /// interface is a pure derivation — mode carries interface
    /// identity, so persistence, launch args, and saved-search recall
    /// need no second field.
    var interface: SearchInterface {
        self == .piiScan ? .scan : .search
    }
}

/// The sheet's top-level interface pair: one chassis, two peer
/// interfaces — Scan (detector-driven) and Search (literal matching).
/// Display-only UI selector — never persisted (the mode's wire value
/// carries interface identity).
enum SearchInterface: Equatable, Sendable {
    case scan
    case search

    /// Per-interface navigation titles.
    var displayName: String {
        switch self {
        case .scan: "Scan"
        case .search: "Search"
        }
    }
}

/// U1: Source type filter for search results.
/// `Codable` conformance is consumed by `SavedSearchStore`.
/// Case renames are migration events.
enum SourceFilter: String, CaseIterable, Sendable, Codable {
    case all = "All"
    case textOnly = "Text"
    case ocrOnly = "OCR"
}

/// Post-scan filter that hides applied or unapplied results.
/// `Codable` conformance is consumed by `SavedSearchStore`.
/// Case renames are migration events.
enum AppliedFilter: String, CaseIterable, Sendable, Codable {
    case all = "All"
    case applied = "Applied"
    case unapplied = "Unapplied"
}

/// Sort order for search results.
/// `Codable` conformance is consumed by `SavedSearchStore`.
/// Case renames are migration events.
enum ResultSortOrder: String, CaseIterable, Sendable, Codable {
    case discoveryOrder = "Default"
    case confidenceDescending = "Confidence"
    case pageAscending = "Page"
}
