import Foundation
import os
import RedactionEngine

// Log only closed-vocabulary facts as .public (an error domain and code).
// Never log document content, file paths, or redaction coordinates.
private let logger = Logger(subsystem: "com.resecta.app", category: "state")

/// Redaction regions and detection results. MainActor by SE-0466 default.
@Observable
class RedactionState {
    var regions: [Int: [RedactionRegion]] = [:]          // pageIndex → regions

    /// Monotonic counter incremented on every region mutation.
    /// Enables O(1) dirty checking in PDFViewCoordinator overlay refresh.
    var regionVersion: Int = 0

    /// Multi-region selection set. Single selection is the common case.
    var selectedRegionIDs: Set<UUID> = []

    /// The last lasso cut at the selection limit, with the selection it
    /// left; nil when the last lasso was not cut. The selection bar reads it
    /// for its second line.
    var lassoCut: LassoCut?

    /// Backward-compatible single-selection accessor.
    /// Get: returns the sole selected ID when exactly one is selected, else nil.
    /// Set: replaces the entire selection with a singleton (or clears).
    var selectedRegionID: UUID? {
        get { selectedRegionIDs.count == 1 ? selectedRegionIDs.first : nil }
        set {
            if let id = newValue {
                selectedRegionIDs = [id]
            } else {
                selectedRegionIDs = []
            }
        }
    }

    var outputURL: URL?

    /// Everything verification consumed for the redaction run that
    /// produced `outputURL`, as ONE value — the run's inputs plus the two
    /// facts the results strip states about the run. Retained so a
    /// verify-only re-run checks the same terms and re-check requests and
    /// reports the same per-page modes as the run that built the output,
    /// and so the results screen describes THIS run rather than the
    /// session's most recent scan. Written by the coordinator when
    /// `processDocument` returns; cleared with the output (`clearOutput()`,
    /// which both document boundaries route through). Nil means no
    /// completed run this session — e.g. a resumed old session — and the
    /// verify-only path falls back to re-synthesis. Per-page filter
    /// digests are NOT retained: they cannot be rebuilt from the output
    /// PDF, by design. In-memory only — nothing here is persisted.
    private(set) var lastRunInputs: LastRunInputs?

    /// Record the inputs of a completed redaction run alongside `outputURL`.
    /// Called by `PipelineCoordinator` at the same point the output URL is
    /// re-asserted after `processDocument` returns.
    func recordLastRunInputs(_ inputs: LastRunInputs) {
        lastRunInputs = inputs
    }

    /// Deselection facts for a run: the scan results the user left
    /// un-checked — as values (page · category · rect · text), so the
    /// output re-run can subtract them — and the session's total. Built by
    /// `SearchState.deselectionSnapshotForRun()` (the same derivation the
    /// scan coverage panel renders); captured at the apply commit
    /// (`pendingRunDeselection`) and read at run entry
    /// (`runEntryDeselectionSnapshot()`). `deselectedCount` counts matches
    /// by occurrence; `items` keep one per line. In-memory only.
    struct DeselectionSnapshot: Equatable, Sendable {
        let items: [SearchResult]
        let totalCount: Int
        var deselectedCount: Int { SearchState.occurrenceCount(items) }
    }

    /// The deselection facts of the search sessions the user *applied*
    /// results from, captured at the apply commit rather than at
    /// pipeline run entry. Closes the common-path gap where the search
    /// sheet dismisses (nil-ing `activeSearch`) between the apply and the
    /// Redact tap, so `runEntryDeselectionSnapshot()` below would
    /// otherwise see no live session and ship no disclosure even though
    /// the user deliberately left results un-checked when they applied.
    ///
    /// Lifetime: one part per session (`pendingRunDeselectionParts`),
    /// merged here. A later apply from the same session replaces its
    /// part, an apply from another Scan adds one, and a typed search,
    /// which has no deselection facts, leaves them alone; undoing an
    /// apply restores the parts it found. It survives a pipeline run
    /// (including cancel/fail, both of which route through
    /// `clearOutput()`) so a retry that didn't re-apply still reports
    /// the same counts — `clearOutput()` deliberately does NOT clear
    /// this field, only `lastRunInputs` (which describes a
    /// completed/attempted run's recorded inputs, not the pending
    /// apply fact). It must not leak across documents, so both
    /// document-boundary resets (`clearForNewDocument()`,
    /// `clearAll()`) clear it explicitly.
    var pendingRunDeselection: DeselectionSnapshot? {
        DeselectionSnapshot(merging: pendingRunDeselectionParts.map(\.snapshot))
    }
    var pendingRunDeselectionParts: [RunDeselectionPart] = []
    var coveredSearchRecords: [CoveredSearchRecord] = [] // searches whose every result a box held (`noteCoveredSearch`)

    /// Set when any gazetteer / context-keywords loader failed to
    /// initialize for this session. Drives the persistent degrade
    /// banner on the search sheet's Scan interface and gates
    /// the one-time warning toast posted by `PipelineCoordinator`.
    /// Per-session (not persisted) — a relaunch re-evaluates loader
    /// state from scratch.
    var autoDetectionDegraded: Bool = false

    /// Engine-facing names of the loaders behind the current
    /// degrade (`GazetteerLoadDiagnostics.failedGazetteers`). Drives the
    /// banner/toast copy branch: an NER-only degrade (OS model absent) is
    /// described as such instead of blaming the bundled corpus. Same
    /// lifetime as `autoDetectionDegraded`.
    var autoDetectionDegradeFailures: [String] = []

    /// Text extraction buffer for Searchable Redaction mode.
    /// Populated during the extraction phase; nil for Secure Rasterization.
    var textExtractionBuffer: [Int: [CharacterInfo]]? = nil

    /// Record of how the most recent Scan-interface run ended (results
    /// listed in-sheet). Written on every run exit path (staged, nothing
    /// found, failed). The run reads its `ocrSkippedPages`
    /// (`PipelineRunner`). Session-scoped; cleared on new-document import.
    struct DetectionRunRecord: Equatable {
        enum Outcome: Equatable {
            /// Findings listed in-sheet for review. Nothing is applied
            /// until the user selects and applies.
            case staged
            /// The run completed and flagged nothing.
            case nothingFound(pageCount: Int)
            /// The run ended early on a render/detection error.
            case failed
        }
        /// Present for Scan-interface (in-sheet) runs.
        struct ScanRunSummary: Equatable {
            let foundCount: Int
            let pageCount: Int
        }
        let run: Int
        let outcome: Outcome
        let scanSummary: ScanRunSummary?
        /// Pages whose raster exceeded the OCR pixel caps
        /// during the run this record describes
        /// (`SearchState.ocrSkippedPages`), snapshotted at record time so
        /// the verification screen reads a stable value instead of a
        /// live session set the sheet later clears.
        var ocrSkippedPages: Set<Int> = []
        /// The degrade-failure list active when this run was
        /// recorded; nil when the run was not degraded.
        var degradeFailures: [String]? = nil
    }
    var lastDetectionRun: DetectionRunRecord? = nil

    /// Every closed search account of this document, by the token minted
    /// when its run started. An applied search's record names its token.
    var searchAccounts: [UUID: SearchAccount] = [:]
    /// The newest closed account's token: the latest run, applied or not.
    var latestSearchAccountToken: UUID?

    /// Every search run of this document that started reading, oldest first,
    /// with its query: the stop at Redact counts every run, applied or not.
    var searchRunLog: [SearchRunLogEntry] = []

    struct SearchRunLogEntry: Equatable {
        let token: UUID
        let query: AppliedSearchQuery
    }

    func recordSearchRunOpened(token: UUID, query: AppliedSearchQuery) {
        searchRunLog.append(SearchRunLogEntry(token: token, query: query))
    }

    /// The runs whose accounts closed, oldest first, each with its query. A
    /// replaced run kept no account and is not among them.
    var closedSearchRuns: [(query: AppliedSearchQuery, account: SearchAccount)] {
        searchRunLog.compactMap { entry in searchAccounts[entry.token].map { (entry.query, $0) } }
    }

    func recordSearchAccount(_ account: SearchAccount, token: UUID) {
        searchAccounts[token] = account
        latestSearchAccountToken = token
    }

    /// The pages too large for recognition in the accounts that matter: the
    /// applied searches' (by their records' tokens) and the latest run's.
    /// Zero-based, as the results strip reads them.
    func pagesTooLarge(applied tokens: [UUID]) -> Set<Int> {
        var pages = Set<Int>()
        for token in Set(tokens + [latestSearchAccountToken].compactMap { $0 }) {
            guard let account = searchAccounts[token] else { continue }
            pages.formUnion(account.pages(for: .tooLarge))
            pages.formUnion(account.pages(for: .picturesNotRead(.tooLarge)))
        }
        return pages
    }

    /// Writer for `lastDetectionRun` — bumps the run counter.
    /// `scanSummary` is passed by the Scan-interface run path.
    func recordDetectionRun(
        _ outcome: DetectionRunRecord.Outcome,
        scanSummary: DetectionRunRecord.ScanRunSummary? = nil,
        ocrSkippedPages: Set<Int> = []
    ) {
        lastDetectionRun = DetectionRunRecord(
            run: (lastDetectionRun?.run ?? 0) + 1, outcome: outcome,
            scanSummary: scanSummary, ocrSkippedPages: ocrSkippedPages,
            degradeFailures: autoDetectionDegraded ? autoDetectionDegradeFailures : nil)
    }

    /// Canvas-side "View rationale" request. Set
    /// by `RedactionOverlayView`'s long-press menu when the user taps the
    /// "View rationale" action on a region whose `Source` carries a
    /// non-nil `MatchRationale`. `DocumentEditorView` observes this and
    /// presents a sheet with the rationale summary; clears on dismiss.
    /// The action shares the existing `UIContextMenuInteraction`
    /// — no second interaction is added.
    var pendingCanvasRationaleRequest: UUID?

    // --- Region Metadata ---

    /// Metadata for auto-detected regions, keyed by the RedactionRegion.id created
    /// from the DetectionResult. Populated by every `applyFindings`
    /// origin. Enables canvas badges and region info display
    /// without modifying RedactionRegion itself.
    ///
    /// This is a parallel dictionary, not a field on RedactionRegion, because:
    /// (a) RedactionRegion is a RedactionEngine SPM type — adding UI metadata
    ///     would leak UI concerns into the engine package.
    /// (b) Manual regions have no metadata to store.
    /// (c) Metadata survives undo/redo because it keys on the stable region UUID.
    var regionMetadata: [UUID: RegionMetadata] = [:]

    // Active search session.
    // Non-nil triggers search sheet presentation. Ephemeral — never persisted.
    //
    // Any transition (nil → non-nil, non-nil → nil, or
    // replacement) is treated as the boundary of a search session for
    // nudge-suppression accounting. The didSet resets
    // `manualDrawNudgeSuppressedForSession` so a re-opened sheet starts
    // a fresh nudge budget without inheriting the previous session's
    // suppression state.
    var activeSearch: SearchState? {
        didSet {
            manualDrawNudgeSuppressedForSession = false
            if activeSearch == nil {
                pendingManualDrawNudge = nil
            }
        }
    }

    /// Pending manual-draw nudge candidate. Set by
    /// `addRegion` after a `.manual` region commits, when
    /// `activeSearch.results` carries a high-confidence PII match
    /// within `manualDrawNudgeProximityNormalized` of the new region
    /// that has NOT been applied or suppressed for this session.
    /// Observed by `DocumentEditorView` via `.onChange(of:)` to enqueue
    /// the non-modal "Mark it too?" toast. Cleared after enqueue
    /// (and on any `activeSearch` transition per the didSet above).
    /// The surface is a toast — NOT a new canvas long-press
    /// action — so the canvas density cap stays at 6 menu items.
    var pendingManualDrawNudge: SearchResult?

    /// Per-search-session suppression flag. Set after
    /// the first nudge is enqueued so the user sees at most one toast
    /// per search session — the V1.x interpretation of the
    /// "Suppressible per session" contract. Resets on (a) any
    /// `activeSearch` transition via the didSet above (sheet dismiss
    /// or re-open), (b) `clearForNewDocument()` (new document load),
    /// (c) `clearAll()` (document close). Pinned by
    /// `ManualDrawNudgeTests` load-bearing scope.
    var manualDrawNudgeSuppressedForSession: Bool = false

    /// Proximity threshold for the nudge predicate.
    /// The design contract names "50pt" — converted to normalized
    /// document coordinates via the standard US letter page width at
    /// 72 DPI (50 / 612 ≈ 0.0817). Non-letter pages get an approximate
    /// threshold that still matches the design intent within ±25 % on
    /// common formats (A4: 595pt wide → 50pt ≈ 0.0840 normalized; legal:
    /// 612pt wide identical). Pure-function `nearbyUnappliedPIIMatch`
    /// compares the edge-to-edge normalized distance between the new
    /// region and a candidate `SearchResult.normalizedRect` against
    /// this constant.
    static let manualDrawNudgeProximityNormalized: CGFloat = 0.082

    // Per-document audit of search matches that the user applied as
    // redactions. Keyed by the created RedactionRegion.id so undo/redo can
    // drop and restore entries in lockstep with the regions themselves.
    // Reset on clearAll() — never leaks across documents.
    var appliedMatchAudit: [UUID: MatchAuditSnapshot] = [:]

    /// The pages the person closed the fit notice on: every page holding a
    /// widened box when it was closed (`closeFitNotice()`). Never crosses
    /// documents.
    var fitNoticeClosedPages: Set<Int> = []

    /// Audit snapshots sorted by pageIndex then appliedAt for stable
    /// ordering in the exported CSV / JSON.
    var appliedMatchAuditSnapshots: [MatchAuditSnapshot] {
        appliedMatchAudit.values.sorted {
            if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
            return $0.appliedAt < $1.appliedAt
        }
    }

    // ID of the region currently under the pointer on iPad.
    // Stored on @Observable RedactionState so SwiftUI can observe changes.
    var hoveredRegionID: UUID?

    /// Look up the `MatchRationale` a region's
    /// `Source` carries, if any. Used by `RegionInfoPopover` (iPad) and
    /// the canvas long-press action sheet (iPhone) to surface a "View
    /// rationale" disclosure without bouncing through `appliedMatchAudit`.
    func rationale(forRegionID id: UUID) -> MatchRationale? {
        for pageRegions in regions.values {
            if let region = pageRegions.first(where: { $0.id == id }) {
                switch region.source {
                case .detectedPII(_, let rationale): return rationale
                case .searchMatch(_, let rationale): return rationale
                case .manual, .detectedFace:        return nil
                }
            }
        }
        return nil
    }

    /// Tracks whether regions have been modified since the last verification run.
    /// Security-relevant: stale verification is a data-leakage vector.
    var regionsModifiedSinceVerification = false

    /// Reverse index: region UUID → page index. O(1) lookup instead of O(n×m) scan.
    /// Written by the region mutations (`RedactionState+RegionMutations.swift`).
    var regionPageIndex: [UUID: Int] = [:]

    /// The two one-way writes every region mutation makes to the state
    /// above, for the mutations in `RedactionState+RegionMutations.swift`:
    /// the version only counts up, and the verification flag is only set.
    func bumpRegionVersion() { regionVersion += 1 }
    func markRegionsModified() {
        regionsModifiedSinceVerification = true
        clearOutput()
    }

    /// The one public path that clears the flag; a run reaches it through the burned-version guard.
    func markVerificationCurrent() {
        regionsModifiedSinceVerification = false
    }

    /// True when at least one region is one a run admits (the run's own
    /// admission, `RedactionRegion.isAdmitted`).
    /// Short-circuits on first match (avoids full count).
    var hasEffectiveRegions: Bool {
        regions.values.contains { pageRegions in
            pageRegions.contains { RedactionRegion.isAdmitted(normalizedRect: $0.normalizedRect) }
        }
    }

    /// True when redaction regions have been modified since the last pipeline run.
    var isVerificationStale: Bool {
        regionsModifiedSinceVerification
    }

    /// Find the page index containing a given region ID. O(1) via reverse index.
    func pageIndex(for regionID: UUID) -> Int? {
        regionPageIndex[regionID]
    }

    // MARK: - Cleanup

    /// Reset all state for a new document import. Called only after validation
    /// succeeds — old state is preserved until the new document is confirmed valid.
    /// The teardown itself is `resetDocumentSession()` (shared with
    /// `clearAll()`); the statements below are the ones only a replacement
    /// document performs.
    func clearForNewDocument() {
        resetDocumentSession()
        // A healthy second-document run must not show the prior run's
        // "auto-detect degraded" banner (`signalDegradedDetection` treats the
        // flag as an already-toasted gate and never resets it).
        autoDetectionDegraded = false
        autoDetectionDegradeFailures = []
    }

    /// The teardown both document boundaries share — `clearForNewDocument()`
    /// (a replacement document) and `clearAll()` (document close). Order:
    /// `regionVersion` bumps first and `clearOutput()` runs before any
    /// region wipe, so the published `outputURL` is nil before a UI
    /// observer reacts to the regions going; the rest is a plain reset of
    /// per-document state, each drop named by what it keeps from leaking
    /// into the next document.
    private func resetDocumentSession() {
        regionVersion += 1
        clearOutput()
        // The apply-commit deselection facts and covered-search records describe the PRIOR document;
        // `clearOutput()` leaves them (they survive pipeline retries), so the document boundary drops them.
        (pendingRunDeselectionParts, coveredSearchRecords) = ([], [])
        // A full-document reset: no regions remain, so "regions modified
        // since verification" is logically false.
        regionsModifiedSinceVerification = false
        regions = [:]
        selectedRegionIDs = []
        // Cancel and drop any in-flight search so its sheet does not
        // linger into the next document (the `activeSearch` didSet does
        // not itself cancel the search task).
        dismissActiveSearch()
        // The detection-run record would describe a run
        // that never happened on the next document.
        lastDetectionRun = nil
        searchAccounts = [:]
        latestSearchAccountToken = nil
        searchRunLog = []
        // A stale region UUID must not present a blank rationale sheet
        // over the next document.
        pendingCanvasRationaleRequest = nil
        // The manual-draw nudge state
        // never carries across documents. The `activeSearch` didSet above
        // already resets the nudge flag; the explicit reset keeps the
        // contract for a caller that clears state without crossing that
        // boundary.
        manualDrawNudgeSuppressedForSession = false
        pendingManualDrawNudge = nil
        regionPageIndex.removeAll()
        regionMetadata = [:]
        appliedMatchAudit = [:] // holds matched text: never crosses documents
        fitNoticeClosedPages = []
    }

    /// Clear pre-redaction text extraction buffer on success path.
    func clearTextExtractionBuffer() {
        textExtractionBuffer = nil
    }

    /// Wipe stale verification state. Does NOT clear outputURL — the redacted
    /// document is valid even if verification is incomplete.
    ///
    /// No longer calls `markVerificationCurrent()`. The two
    /// operations are independent: clearing verification means "the
    /// verification report attached to this run is gone," while marking
    /// verification current means "regions are NOT modified since the
    /// last successful verify." Cancel / output-discard paths flow through
    /// `clearVerification()` and must NOT falsely tell the banner that
    /// regions are verified — that was the staleness leak.
    /// The flag is reset only at `clearForNewDocument()` (a new document
    /// has no regions and no verify history) and at the explicit
    /// `markVerificationCurrent()` call from the pipeline runner after a
    /// successful verify completes.
    func clearVerification() {
        // Intentionally empty — the verification-block surface has no
        // separate cached state to wipe today; the doc-comment exists so
        // call sites continue to express the intent.
    }

    /// Reset all output state. Called on pipeline cancel/fail, new import,
    /// and every region mutation (the output no longer matches the regions).
    ///
    /// Clear `outputURL` first, then attempt `removeItem`
    /// against a local capture. The previous order (`removeItem(at: url)`
    /// THEN `outputURL = nil`) opened a narrow window where an observer
    /// reading the published `outputURL` between the removeItem and the
    /// nil-out could pick up a URL whose file had already been unlinked.
    /// On removeItem failure (filesystem race, file already purged) we
    /// still nil the URL — the document state is the authority on
    /// "where the redacted PDF lives," and the orphan sweep
    /// (`cleanOrphanedTempFiles()`, at launch and on each return to the
    /// foreground) handles leftover bytes.
    func clearOutput() {
        let url = outputURL
        outputURL = nil
        if let url {
            // Best-effort delete — a failure leaves the file for
            // `cleanOrphanedTempFiles()` to sweep (next launch or the next
            // return to the foreground) and is logged content-free: the
            // error's domain and code only, never the path.
            do {
                try FileManager.default.removeItem(at: url)
            } catch { // LegalPhrases:safe (Swift keyword)
                let failure = error as NSError
                logger.error(
                    "Output unlink failed: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
            }
        }
        clearVerification()
        textExtractionBuffer = nil
        // The retained run inputs describe the output that was just
        // discarded — a later run must not verify against them.
        lastRunInputs = nil
    }

    // MARK: - Apply serialization state

    // The apply gate (`waitForApplyTurn()` / `endApplyTurn()` in
    // `RedactionApplyEngine.swift`) keeps its two flags here.

    /// True while an `applyFindings` call owns the apply path. Handed
    /// straight to the next waiter, so it stays true across a hand-off.
    /// Not observed by any view.
    @ObservationIgnored var applyInProgress = false

    /// Callers waiting for the apply path, in arrival order. Each is
    /// resumed by `endApplyTurn()` with the path already handed over.
    @ObservationIgnored var applyWaiters: [CheckedContinuation<Void, Never>] = []

    /// Search origin. The overlap rejection + per-result region /
    /// metadata / audit construction runs in a detached task so a
    /// 1000-result apply over pages that already hold prior regions
    /// doesn't freeze MainActor; the MainActor segment performs only
    /// the write-back transaction + undo registration.
    func applySelectedSearchResultsOrigin(
        undoManager: UndoManager?,
        documentState: DocumentState?
    ) async -> ApplyOutcome? {
        guard let search = activeSearch else { return nil }

        let selected = search.results.filter(\.isSelected)
        guard !selected.isEmpty else { return .zero }

        // Snapshot existing rects per page so the overlap test can run
        // off-MainActor without re-entering actor state.
        let (existingRectsByPage, existingStripRectsByPage) = coveringRectsByPage(regions)
        let appliedAt = Date()
        // The session's applied-search record, read on MainActor before
        // the detached prepare like the rects snapshot: it is stamped on
        // every search-origin audit snapshot so the Search Re-check can
        // re-run this query on the output. Nil for a `.piiScan` session.
        let searchRecord = search.appliedSearchRecord()

        let prepared = await Task.detached(priority: .userInitiated) {
            prepareApply(
                selected: selected,
                existingRectsByPage: existingRectsByPage, existingStripRectsByPage: existingStripRectsByPage,
                appliedAt: appliedAt,
                searchRecord: searchRecord
            )
        }.value

        // Re-check after the suspension: a pipeline that started while
        // the prepare step ran must not receive a mutation on resume.
        if let documentState, !documentState.canMutateRegions {
            return nil
        }
        let outcome = ApplyOutcome(
            applied: prepared.appliedCount,
            skippedOverlaps: prepared.skippedOverlaps,
            appliedResultIDs: prepared.appliedResultIDs,
            coveredResultIDs: prepared.coveredResultIDs
        )
        // A selection the regions already cover creates nothing, so it
        // commits nothing: no version bump, no empty undo step. Its
        // deselection facts still join the run's, as an apply's always do.
        guard prepared.appliedCount > 0 else {
            pendingRunDeselectionParts = runDeselectionParts(after: search)
            noteCoveredSearch(searchRecord, selected: selected, covered: prepared.coveredResultIDs, at: appliedAt)
            return outcome
        }

        // The CAPTURED session's deselection facts join the pending
        // parts at the moment of commit, before the caller dismisses the
        // sheet and nils `activeSearch` out from under a later
        // pipeline-entry read. Derivation is unchanged — the same
        // `deselectionSnapshotForRun()` the coverage panel and the
        // live-session pipeline-entry path use.
        commitApply(
            createdRegions: prepared.createdRegions,
            createdMetadata: prepared.createdMetadata,
            createdAudit: prepared.createdAudit,
            actionName: UndoName.mark(search.countingOccurrences(prepared.appliedCount, ids: prepared.appliedResultIDs)),
            runDeselectionParts: runDeselectionParts(after: search),
            undoManager: undoManager
        )
        // Caller is responsible for clearing activeSearch after showing feedback.
        return outcome
    }

    /// Single-result search origin: the
    /// compact handle's per-item Apply. One result of the active search,
    /// addressed by id and resolved against `results` HERE — never by
    /// index, never from a value captured at the tap (a search
    /// still running re-flushes the array in batches, so the id can be
    /// gone by the time the apply turn arrives; a missing id refuses
    /// with zero mutations, and the handle's button state re-derives on
    /// the next render). Selection state is not consulted — the tap IS
    /// the accept for that one result (the wand / nudge precedent), so
    /// a result the user left unchecked still applies.
    ///
    /// Everything else is the bulk search origin, one result at a time:
    /// the same `prepareApply` builds the region + `RegionMetadata` +
    /// `MatchAuditSnapshot` trio (same `.searchMatch(term:rationale:)`
    /// source, same rationale handoff, same overlap test — a result an
    /// existing region already covers is dedup-skipped as covered: no
    /// badge, no audit entry), the same `commitApply`
    /// transaction recording the search apply-version marker,
    /// the same action-name construction in its singular form, and the
    /// same deselection parts at the commit.
    /// One result needs no detached prepare, so nothing suspends between
    /// the mutation guard in `applyFindings` and the commit — the
    /// post-suspension re-check the bulk origin needs has no window
    /// here. As in the bulk origin, a covered result creates nothing,
    /// so it commits nothing (no version bump, no empty undo step — an
    /// inert apply must not signal a region mutation). One difference by
    /// design: this is a PARTIAL commit — the remaining selections stay
    /// live work, which the dismiss rule reads from the rows (the
    /// entity-group rule).
    func applySearchResultOrigin(
        id: UUID,
        undoManager: UndoManager?
    ) -> ApplyOutcome? {
        guard let search = activeSearch else { return nil }
        guard let result = search.results.first(where: { $0.id == id }) else { return nil }

        let (existingRectsByPage, existingStripRectsByPage) = coveringRectsByPage(regions)
        let prepared = prepareApply(
            selected: search.pieces(of: result.id),
            existingRectsByPage: existingRectsByPage, existingStripRectsByPage: existingStripRectsByPage,
            appliedAt: Date(),
            searchRecord: search.appliedSearchRecord()
        )
        let outcome = ApplyOutcome(
            applied: prepared.appliedCount,
            skippedOverlaps: prepared.skippedOverlaps,
            appliedResultIDs: prepared.appliedResultIDs,
            coveredResultIDs: prepared.coveredResultIDs
        )
        guard prepared.appliedCount > 0 else { return outcome }

        commitApply(
            createdRegions: prepared.createdRegions,
            createdMetadata: prepared.createdMetadata,
            createdAudit: prepared.createdAudit,
            actionName: UndoName.mark(1),
            runDeselectionParts: runDeselectionParts(after: search),
            undoManager: undoManager
        )
        return outcome
    }

    /// Tear the live Search & Redact
    /// session down. The editor's ONE `.sheet(item:)` slot reads
    /// `activeSearch`, so this dismisses the sheet (its `onDisappear`
    /// clears the results, the same outcome as its own Dismiss); the
    /// in-flight search task is cancelled without awaiting (the
    /// `activeSearch` didSet does not cancel it). Shared by the two
    /// document-lifecycle resets, the KI-4 purge re-run and the Apply
    /// seam (`PipelineCoordinator.runFullPipeline`). Idempotent.
    func dismissActiveSearch() {
        let search = activeSearch
        activeSearch = nil
        MainActor.assumeIsolated { search?.cancelSearchWithoutAwait() }
    }

    // MARK: - Full Reset

    /// Reset all state when the document is closed or a new document is imported.
    /// Must be called on .editing → .empty and .editing → .importing transitions.
    /// Extends clearOutput() to also clear regions and
    /// metadata — preventing PII (matchedText) from persisting in memory across documents.
    /// The teardown itself is `resetDocumentSession()` (shared with
    /// `clearForNewDocument()`); the statements below are the ones only a
    /// document close performs.
    func clearAll() {
        resetDocumentSession()
        hoveredRegionID = nil
    }

    // MARK: - Undo Helper state (`RedactionState+RegionMutations.swift`)

    /// The last Undo or Redo step: the pages it changed, its name and a
    /// serial, so a repeat on the same page is a change too. A step that
    /// registers once per page (a delete across pages) unions its pages:
    /// the first record of a step opens it, and the next main-actor turn
    /// closes it.
    var lastUndoRedo: UndoRedoStep?
    @ObservationIgnored var undoRedoStepOpen = false
    @ObservationIgnored weak var mutationGate: DocumentState?  // whether a region step may run now (+MutationGuard)

    // MARK: - The canvas's touch (the run door)

    /// The editor's canvas, which sets itself here when it is given this
    /// state. Not observed: the run door asks it when a run would start.
    @ObservationIgnored weak var canvas: (any CanvasTouchHolding)?

    /// True while a finger is down on the canvas. During a draw, a move, a
    /// group move or a resize the box on screen is the overlay's working
    /// copy and `regions` changes only at the lift, so no run starts until
    /// then (`DocumentState.redactRefusal(with:)`).
    var canvasHoldsATouch: Bool { canvas?.holdsATouch ?? false }
}

/// What the editor's canvas tells the run door: whether any of its live
/// page overlays holds a touch now.
protocol CanvasTouchHolding: AnyObject {
    var holdsATouch: Bool { get }
}
