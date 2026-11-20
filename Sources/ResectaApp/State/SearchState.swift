import Foundation
import RedactionEngine

// Ephemeral search session state.
// Results and document-derived fields are in-memory only; cleared on dismiss.
// Last-used filter shape is cross-session and persisted to UserDefaults.
// The multi-term recall ring is in-memory for the session only. Never log.

/// Ephemeral search session state.
/// Document-derived state is in-memory only; cleared on dismiss.
/// Last-used filter shape persists via UserDefaults; the multi-term
/// recall ring is session-only and never persisted.
/// Some stored properties here have an internal setter, and some helpers
/// are internal, only because the type's methods live in its extension
/// files (`SearchState+*.swift`); only those files and this one write
/// the properties or call the helpers.
@Observable
@MainActor
final class SearchState: Identifiable {

    let id = UUID()

    // MARK: - UserDefaults seam (testable injection)

    /// Injected at init; defaults to `.standard`. @ObservationIgnored so
    /// the macro does not wrap the concrete UserDefaults reference.
    @ObservationIgnored let defaults: UserDefaults

    // MARK: - Last-used filter shape

    /// Task reference for debounced filter persistence; cancel before
    /// scheduling a new one (mirrors the flushTask idiom).
    @ObservationIgnored var filterFlushTask: Task<Void, Never>?

    // MARK: - Search Configuration

    /// Current search query text.
    var queryText: String = ""

    /// Active search mode selector.
    var searchModeType: SearchModeType = .text
    /// What the last Scan kickoff ran with (the preset thresholds and the
    /// user terms); nil for a typed run or before any run. Set by
    /// `SearchAndRedactSheet+Trigger.prepareSearchRun()`, read by
    /// `appliedSearchRecord()` so the record reproduces the run.
    var lastRunScanConfiguration: ScanRunConfiguration?

    /// One shot: the next run posts no re-run notice (a recall names its own
    /// drop, so its run says nothing more). Reset by that run.
    var skipNextRerunNotice = false

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
    @ObservationIgnored var triggerSetupInFlight = false

    /// Set when a trigger arrived while another held the setup window.
    /// Consumed by `endTriggerSetup()`: the window owner re-triggers
    /// once, so the final run reflects the latest query shape.
    @ObservationIgnored var pendingRetrigger = false

    // MARK: - Run-state discriminators

    /// True once a non-cancelled run has completed since the last
    /// `clearResults()`. The empty-state discriminator uses it to
    /// distinguish "ran and found nothing" from "this query was never
    /// run in this mode" — a mode switch carries the query text but
    /// deliberately does not re-run, and that carried state
    /// must not render as a definitive no-match verdict.
    var hasCompletedRunSinceClear = false

    /// True when the last Scan attempt exited before kickoff (document
    /// not ready). Distinguishes "never scanned" from "the scan failed
    /// to start" after the failure toast expires. Reset by
    /// `clearResults()` — every trigger clears before its guards run.
    var scanStartFailed = false

    /// The last run's kickoff snapshots, so a later chip, option or query change cannot
    /// rewrite the description of a run that already happened: the Scan's detector count
    /// (the engine query's own `enabledCategories`; nil until a Scan kicks off, reset by
    /// `clearResults()`), the pages a typed run reads by text recognition (the no-match copy,
    /// `SearchEmptyStateCopy.ocrReadPageCount`) and what it searched for (both at every kickoff).
    var lastRunDetectorCount: Int?
    var lastRunOCRPageCount = 0
    var lastRunShape: SearchRunShape?

    /// Search options (toggles in UI).
    var options: SearchOptions = SearchOptions()

    /// Regex validation error message, shown inline in options bar.
    /// An arriving error clears any stale result list via
    /// `clearResultState()` (the same reset a run attempt performs):
    /// a standing list beneath a non-compiling pattern read as "the
    /// invalid pattern found N". Only the nil → message transition
    /// acts, and the shared clear deliberately skips this field so the
    /// error survives its own observer.
    var regexError: String? {
        didSet {
            if regexError != nil, oldValue == nil,
               !results.isEmpty || !pendingResults.isEmpty {
                clearResultState()
            }
        }
    }

    // MARK: - Filters

    /// Filter results by source type.
    var sourceFilter: SourceFilter = .all {
        didSet {
            invalidateFilterCaches()
            scheduleFilterFlush()
        }
    }

    /// Minimum OCR confidence threshold (0.0 = show all).
    var minimumOCRConfidence: Float = 0.0 {
        didSet {
            invalidateFilterCaches()
            scheduleFilterFlush()
        }
    }

    /// Group results by search term instead of by page (multi-term mode).
    var groupByTerm: Bool = false

    // MARK: - PII Scan Configuration

    /// Categories enabled for PII scan (all enabled by default).
    var enabledPIICategories: Set<PIICategory> = Set(PIICategory.allCases)

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
        didSet {
            if piiCategoryFilter == nil { customTermMatchesInFilter = false }
            invalidateFilterCaches()
        }
    }

    /// With a category filter active, whether custom-term matches (no
    /// detector category) stay listed: the Scan's "Custom" chip. Cleared
    /// with the filter.
    var customTermMatchesInFilter = false {
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

    // MARK: - Diagnostics

    /// Last classifier explanation for the first scanned page text.
    /// Session-scoped; cleared on mode switch and sheet dismiss. Populated
    /// at scan kickoff by `SearchAndRedactSheet.triggerSearch`.
    var lastDoctypeExplanation: DoctypeExplanation?

    /// Last scan coverage report. Populated when a PII scan completes.
    /// Session-scoped; cleared on mode switch and sheet dismiss.
    private(set) var lastCoverageReport: CoverageReport?

    /// Running tally of cross-category overlap-suppressed detector
    /// matches across pages, keyed by the losing category. Populated by
    /// DocumentSearcher's per-page sink during a PII scan. Drained into
    /// `CoverageReport.overlapSuppressedCountByCategory` when the scan
    /// completes; reset on scan kickoff and on the two existing
    /// `lastCoverageReport = nil` sites.
    var pendingOverlapSuppressed: [PIICategory: Int] = [:]

    /// Running total of matches dropped for falling below their
    /// per-category preset threshold during a PII scan. Populated by
    /// `DocumentSearcher`'s per-page below-threshold sink; drained into
    /// `CoverageReport.belowThresholdSuppressedCount` when the scan completes.
    /// Reset on scan kickoff and on the two `lastCoverageReport = nil` sites,
    /// mirroring `pendingOverlapSuppressed`.
    var pendingBelowThresholdSuppressed: Int = 0

    /// Setter used by the scan orchestration in `SearchAndRedactSheet`.
    func setCoverageReport(_ report: CoverageReport?) {
        lastCoverageReport = report
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

    /// Page indices whose raster exceeded the OCR pixel caps, so
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

    /// Result IDs the apply path dedup-SKIPPED because an
    /// existing region already covers them (>80% overlap). Distinct
    /// from `appliedResultIDs` on purpose: skipped results get
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

    /// Pages the cap-cancelled scan never reached. Snapshotted in
    /// `appendResult` at the moment the cap fires (`totalPages` minus the
    /// engine's last-reported `currentSearchPage`; the current page itself
    /// may be partially scanned and is not counted). Drives the remainder
    /// sentence in `SearchFooterSection`'s cap banner so the cap stops
    /// reading as full coverage. Reset wherever `resultsAtCap` resets.
    private(set) var capUnscannedPageCount: Int = 0

    // @ObservationIgnored: the memo store is a memoization internal, not
    // view state. The getters WRITE it mid-body-evaluation; if the macro
    // wrapped it, that write would re-enter the ObservationRegistrar
    // during List body evaluation and trip AG::precondition_failure
    // (SIGABRT — the Mark-for-Redaction crash). A plain struct stored on
    // this class, never a child `@Observable`. View updates still flow
    // through the observed inputs: `results`/`resultVersion` and every
    // field of `_currentCacheKey`, all read by the getters on every access.
    @ObservationIgnored var _filterCache = FilterCache()

    struct FilterCache {
        /// One memoized value, valid while its key still matches.
        struct Slot<Key: Equatable, Value> {
            private var key: Key?
            private var value: Value?
            func value(for key: Key) -> Value? { self.key == key ? value : nil }
            mutating func store(_ value: Value, for key: Key) { (self.key, self.value) = (key, value) }
        }
        var filtered = Slot<_FilterCacheKey, [SearchResult]>()
        var byPage = Slot<_FilterCacheKey, [Int: [SearchResult]]>()
        var byTerm = Slot<_FilterCacheKey, [String: [SearchResult]]>()
        var byCategory = Slot<_FilterCacheKey, [PIICategory: [SearchResult]]>()
        /// The O(1) id→index map behind `result(for:)` (the per-row
        /// binding get previously linear-scanned `results` ~7-8× per row
        /// body). Keyed on `resultVersion` alone: every in-app `results`
        /// mutation bumps it, and in-place `isSelected` writes never
        /// move indices.
        var indexByID = Slot<Int, [UUID: Int]>()

        /// Drop the four filter slots; the id map keys on the version.
        mutating func invalidateFilters() { self = FilterCache(indexByID: indexByID) }
    }

    struct _FilterCacheKey: Equatable {
        let version: Int
        let source: SourceFilter
        let minOCRConfidence: Float
        let piiCategoryFilter: Set<PIICategory>?
        let customTermMatchesInFilter: Bool
        let sortOrder: ResultSortOrder
        let appliedResultIDs: Set<UUID>
        let appliedFilter: AppliedFilter
    }

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
    var recentMultiTermSets: [[String]] = []

    // MARK: - Init (UserDefaults seam)

    /// Designated init. Hydrates the last-used filter shape from
    /// `defaults` (fail-closed: missing / malformed → in-type
    /// defaults). Pass a scratch `UserDefaults` suite in tests.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Last-used filter — fail-closed JSON decode → property defaults
        if let shape = Self.storedFilterShape(in: defaults) {
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

    /// Pending results buffered before flush, each tagged with the run
    /// it was appended under so a flush moves only the current run's.
    var pendingResults: [(run: Int, result: SearchResult)] = []
    /// Flush timer task.
    var flushTask: Task<Void, Never>?

    // MARK: - Run token

    /// Names the run whose results the sheet is collecting. Minted by
    /// `beginRun()` and bumped by every result clear, so a result from a
    /// superseded run — a stream still draining after the sheet cancelled
    /// it and started the next — is told apart from the current run's
    /// and dropped instead of appended. The current run's results are
    /// never dropped by it.
    var runToken: Int = 0

    /// The account of what the run in hand has read (`SearchState+Account.swift`).
    var accountInHand: SearchAccount?
    var accountInHandRun: Int = 0
    var accountInHandToken: UUID?
    /// True once an Apply took a record from the run in hand.
    var accountInHandApplied = false
    /// The last run's closed account, its run and its token.
    var lastAccount: SearchAccount?
    var lastAccountRun: Int = 0
    var lastAccountToken: UUID?
    /// Where a closed account goes: the document's store, installed by the run.
    @ObservationIgnored var accountClosedSink: (@MainActor (UUID, SearchAccount) -> Void)?
    /// Where an opened account's run and query go: the document's run log (`SearchState+RunLog.swift`).
    @ObservationIgnored var accountOpenedSink: (@MainActor (UUID, AppliedSearchQuery) -> Void)?
    /// Where a replaced run's kept account is named: it counts at the stop only while its boxes remain.
    @ObservationIgnored var accountReplacedSink: (@MainActor (UUID) -> Void)?

    /// The options the current run started with, which the applied
    /// record names (`appliedSearchRecord()`); nil before any run.
    var lastRunOptions: SearchOptions?

    // MARK: - Result Navigation

    /// Index of the currently focused result for prev/next navigation.
    var currentResultIndex: Int?

    /// Session-scoped scope for J / K / Cmd+G traversal. Not persisted;
    /// every fresh document opens at `.wholeDocument`.
    var navigationScope: SearchNavigationScope = .wholeDocument

    // MARK: - Live Preview

    /// Most recent live-preview snapshot (engine NSRanges + counts).
    /// nil while no preview is in flight or after `clearLivePreview()`.
    var livePreview: SearchPreviewResult?

    /// Resolved bounding rects for the visible page's preview matches,
    /// in normalized PDF coords. Filled by the sheet (which owns the
    /// `DocumentSearcher` reference for `boundingRect`) right after
    /// `livePreview` updates. Drawn by the per-page UIKit overlay.
    var livePreviewRects: [CGRect] = []

    var livePreviewTask: Task<Void, Never>?

    // MARK: - Version Tracking

    /// Monotonic counter for overlay dirty checking.
    /// Incremented on every results mutation.
    var resultVersion: Int = 0

    // MARK: - Methods

    /// Full teardown at sheet dismiss / full reset: the session-scoped
    /// fields, then the per-run result state through the one
    /// `clearResults()` path (which nils `regexError` too).
    func clear() {
        clearSessionState()
        clearResults()
    }

    /// The fields only a sheet dismiss / full reset drops — a re-run
    /// (`clearResults()`) leaves every one of them standing: the query
    /// and the multi-term inputs, the recall ring, the in-flight task,
    /// the touched-selections dismiss gate, an armed-but-unconsumed
    /// auto-run (normally consumed by the sheet's `.onAppear` before any
    /// teardown can run), the intra-session
    /// diff snapshot (asymmetric with `clearResults()` by design — see
    /// `priorScanFingerprints`), the navigation scope and the pending
    /// filter write, flushed before the session tears down.
    private func clearSessionState() {
        queryText = ""
        lastRunScanConfiguration = nil
        isSearching = false
        searchTerms = []
        recentMultiTermSets = []
        activeSearchTask?.cancel()
        activeSearchTask = nil
        pendingAutoRunScan = false
        priorScanFingerprints = nil
        navigationScope = .wholeDocument
        filterFlushTask?.cancel()
        filterFlushTask = nil
        flushFilterShape()
    }

    /// True while the Home close dialog holds this session parked: the
    /// sheet's teardown then spares it, so Cancel re-presents it whole.
    var parkedForHomeClose: Bool = false

    /// The document state's per-import token the session was parked over: restored only over that document.
    var parkedDocument: UUID?

    /// The run reached the engine's result cap: mark it, snapshot how many
    /// pages the cancelled scan will never reach (so the footer reports
    /// the remainder rather than presenting the first N results as full
    /// coverage), publish what is buffered and stop the scan.
    func markCapReached() {
        noteCapReached()
        flushPendingResults()
        cancelSearchWithoutAwait()
    }

    /// The run's matches reached the cap: mark it and snapshot the
    /// unscanned remainder, once per run, without stopping the scan (the
    /// last match's later lines are still to arrive).
    func noteCapReached() {
        guard !resultsAtCap else { return }
        resultsAtCap = true
        capUnscannedPageCount = max(0, totalPages - currentSearchPage)
    }

    /// Clear results and increment version for overlay refresh. The
    /// shared reset runs before the error is nilled (the ruled order;
    /// the `regexError` observer acts only on a nil → message
    /// transition, so neither order re-enters it).
    func clearResults() {
        clearResultState()
        regexError = nil
    }

    /// Result-state clear shared by `clearResults()` and the
    /// `regexError` observer: everything a run attempt resets EXCEPT
    /// `regexError` itself, so the observer can wipe a stale list
    /// without nilling the error it is reacting to.
    private func clearResultState() {
        // An account still open describes results about to go: it is dropped.
        closeAccount(.dropped)
        lastAccount = nil
        lastAccountToken = nil
        flushTask?.cancel()
        flushTask = nil
        runToken += 1
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
        // Scan-progress counters reset with results. Leaving
        // `currentSearchPage` non-zero across a mode switch made the
        // piiScan empty state read as post-scan ("Scan complete … 0
        // candidates") before any scan ran: the empty-state context
        // discriminator uses `currentSearchPage > 0` as its
        // scan-has-run signal.
        currentSearchPage = 0
        totalPages = 0
        // Full search supersedes live preview; drop the transient state
        // so highlights don't briefly stack with full results during the
        // 100 ms gap before flushPendingResults fires.
        livePreviewTask?.cancel()
        livePreviewTask = nil
        livePreview = nil
        livePreviewRects = []
        resultVersion += 1
    }
}
