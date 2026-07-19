import Foundation
import RedactionEngine

/// Redaction regions and detection results. MainActor by SE-0466 default.
@Observable
class RedactionState {
    var regions: [Int: [RedactionRegion]] = [:]          // pageIndex → regions
    var detectionResults: [Int: [DetectionResult]] = [:]  // pageIndex → detections

    /// Monotonic counter incremented on every region mutation.
    /// Enables O(1) dirty checking in PDFViewCoordinator overlay refresh.
    private(set) var regionVersion: Int = 0

    /// The `regionVersion` value produced by the most recent
    /// search-origin apply write-back. The Search & Redact sheet compares
    /// the new `regionVersion` against this to skip clearing applied
    /// markers for the apply that created them (vs a real undo/redo). The
    /// `-1` sentinel never collides with a real `regionVersion` (which
    /// starts at 0 and only increments).
    private(set) var lastAppliedSearchRegionVersion: Int = -1

    /// Multi-region selection set. Single selection is the common case.
    var selectedRegionIDs: Set<UUID> = []

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

    /// Inputs of the redaction run that produced `outputURL`, retained so a
    /// verify-only re-run (CANCEL-009) checks the same terms and reports the
    /// same per-page modes as the run that built the output. Without the
    /// snapshot, `runVerifyOnly` re-synthesized both: a uniform mode array
    /// erased a mixed run's per-page fallback record, and re-collected terms
    /// could differ from the artifact's if regions changed since the run.
    /// Written by the coordinator when `processDocument` returns; cleared
    /// with the output (`clearOutput()`, which `clearForNewDocument()` also
    /// routes through). Nil means no completed run this session — e.g. a
    /// resumed old session — and the verify-only path falls back to
    /// re-synthesis. Per-page filter digests are NOT retained: they cannot
    /// be rebuilt from the output PDF, by design.
    private(set) var lastRunPerPageModes: [PipelineMode]?
    /// PD-5: sibling of `lastRunPerPageModes` — the run's per-page fallback
    /// reasons, retained so a verify-only re-run reports why each page
    /// rasterized, not just that it did.
    private(set) var lastRunPerPageFallbackReasons: [TextLayerDetector.FallbackReason?]?
    private(set) var lastRunSensitiveTerms: [SensitiveTerm]?

    /// Record the inputs of a completed redaction run alongside `outputURL`.
    /// Called by `PipelineCoordinator` at the same point the output URL is
    /// re-asserted after `processDocument` returns.
    func recordLastRunInputs(perPageModes: [PipelineMode],
                             perPageFallbackReasons: [TextLayerDetector.FallbackReason?],
                             sensitiveTerms: [SensitiveTerm]) {
        lastRunPerPageModes = perPageModes
        lastRunPerPageFallbackReasons = perPageFallbackReasons
        lastRunSensitiveTerms = sensitiveTerms
    }

    /// Deselection facts of the search session that was live when the
    /// redaction run started: how many scan results the user left
    /// un-checked, out of how many total. Captured by `runFullPipeline`
    /// at run entry (so re-selection while the pipeline is in flight does
    /// not drift the recorded counts) with the same derivation the scan
    /// coverage panel renders (`SearchState.deselectionSnapshotForRun()`),
    /// and recorded here beside `lastRunPerPageModes` when
    /// `processDocument` returns. Read by `DocumentEditorView` to thread
    /// the counts into the verification-results details disclosure. Nil
    /// when no PII-scan session was live at run entry — the results
    /// screen renders no deselection row in that case. Cleared with the
    /// output in `clearOutput()`.
    struct DeselectionSnapshot: Equatable {
        let deselectedCount: Int
        let totalCount: Int
    }
    private(set) var lastRunDeselection: DeselectionSnapshot?

    /// Record (or clear, with nil) the run-entry deselection snapshot.
    /// Sibling of `recordLastRunInputs` — same call site, same lifetime.
    func recordLastRunDeselection(_ snapshot: DeselectionSnapshot?) {
        lastRunDeselection = snapshot
    }

    /// Set when any gazetteer / context-keywords loader failed to
    /// initialize for this session. Drives the persistent degrade
    /// banner on the search sheet's Scan interface and gates
    /// the one-time warning toast posted by `PipelineCoordinator`.
    /// Per-session (not persisted) — a relaunch re-evaluates loader
    /// state from scratch.
    var autoDetectionDegraded: Bool = false

    /// Text extraction buffer for Searchable Redaction mode.
    /// Populated during the extraction phase; nil for Secure Rasterization.
    var textExtractionBuffer: [Int: [CharacterInfo]]? = nil

    // --- Triage Support ---

    /// Staged detections awaiting user review. Non-nil presents the
    /// review inside the search sheet's Scan interface (the
    /// `DocumentEditorView` bridge opens/switches the one sheet).
    /// Populated by runDetectionPipeline() on every detection run —
    /// every run is reviewed (the auto-apply path retired with its
    /// setting).
    /// Cleared when the user accepts (applies selected findings) or dismisses (discards).
    /// Structure: pageIndex → array of DetectionResult.
    var pendingTriage: [Int: [DetectionResult]]? = nil

    /// Per-detection acceptance state during review. Review-first
    /// arrival: staged detections arrive with NOTHING selected, and an
    /// ABSENT id reads as NOT accepted everywhere — the one apply path
    /// promotes only explicit `true` entries. Producers stage with an
    /// empty map; no per-id arrival entries are required. (The former
    /// explicit-entry producer contract and its normalization belt
    /// existed only for the retired absent-reads-accepted fallback.)
    /// Key: DetectionResult.id. Value: true = accepted, false = rejected.
    var triageSelections: [UUID: Bool] = [:]

    /// UXF-06 — record of how the most recent detection run ended, for
    /// BOTH run origins: pipeline detection runs (staged for triage)
    /// and the sheet's Scan-interface runs (results listed in-sheet).
    /// Written on every run exit path (staged, nothing found, failed)
    /// and read by `DocumentEditorView` to drive the detection summary
    /// banner — zero/failed runs previously surfaced only as transient
    /// toasts. `run` increments per record so two identical consecutive
    /// outcomes still read as a change to `.onChange` observers.
    /// Session-scoped; cleared on new-document import.
    struct DetectionRunRecord: Equatable {
        enum Outcome: Equatable {
            /// Findings staged for user review — triage for pipeline
            /// runs, the in-sheet result list for Scan-interface runs.
            /// Nothing is applied until the user selects and applies.
            case staged
            /// The run completed and flagged nothing.
            case nothingFound(pageCount: Int)
            /// The run ended early on a render/detection error.
            case failed
        }
        /// Present for Scan-interface (in-sheet) runs: the counts the
        /// banner reports. Pipeline runs leave it nil and the banner
        /// derives its counts from `pendingTriage`.
        struct ScanRunSummary: Equatable {
            let foundCount: Int
            let pageCount: Int
        }
        let run: Int
        let outcome: Outcome
        let scanSummary: ScanRunSummary?
    }
    var lastDetectionRun: DetectionRunRecord? = nil

    /// UXF-06/UXF-29 — true once any pending detection from the current
    /// run has been promoted to a region (sheet-level "Apply N" or a
    /// group apply). Gates the summary banner's "Review" re-entry action:
    /// re-staging `detectionResults` after a promotion would stage the
    /// already-promoted detections a second time. Reset by
    /// `recordDetectionRun` and on new-document import.
    var triagePromotionOccurred: Bool = false

    /// Writer for `lastDetectionRun` — bumps the run counter and resets
    /// the per-run promotion flag. `scanSummary` is passed by the
    /// Scan-interface run path only; the pipeline writer sites use the
    /// default and the banner reads `pendingTriage` for their counts.
    func recordDetectionRun(
        _ outcome: DetectionRunRecord.Outcome,
        scanSummary: DetectionRunRecord.ScanRunSummary? = nil
    ) {
        lastDetectionRun = DetectionRunRecord(
            run: (lastDetectionRun?.run ?? 0) + 1, outcome: outcome,
            scanSummary: scanSummary)
        triagePromotionOccurred = false
    }

    /// Canvas-side "View rationale" request. Set
    /// by `RedactionOverlayView`'s long-press menu when the user taps the
    /// "View rationale" action on a region whose `Source` carries a
    /// non-nil `MatchRationale`. `DocumentEditorView` observes this and
    /// presents a sheet with the rationale summary; clears on dismiss.
    /// The action shares the existing `UIContextMenuInteraction`
    /// — no second interaction is added.
    var pendingCanvasRationaleRequest: UUID?

    /// Live vertex count of the in-progress polygon on the
    /// active overlay. Drives the bottom-capsule caption + Close/Cancel
    /// buttons without reaching into the UIKit overlay. Reset on commit,
    /// discard, or tool switch.
    var inProgressPolygonVertexCount: Int = 0

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

    // --- Priors + surface-form propagation ---

    /// Per-category Beta priors. Updated on triage accept/reject. Passed by
    /// value into `DetectionOrchestrator.detectPage(...)` per page, merged
    /// back here at yield.
    ///
    /// Priors now PERSIST across
    /// document sessions — hydrated at WORKSPACE creation (RedactWorkspace
    /// init; a bare `RedactionState()` stays inert so tests are isolated),
    /// saved (then rehydrated) by clearAll() so the next document starts
    /// with the accumulated triage history. The stored payload is
    /// per-category accept/reject counts only: behavioral curation
    /// metadata, never document content, values, or timestamps. Streaks
    /// are session-scoped and reset on restore.
    var priors: PerCategoryPriors = PerCategoryPriors()

    // MARK: - priors persistence

    /// Versioned storage key; a format change bumps to v2 and ignores v1.
    static let priorsStorageKey = "perCategoryPriors.v1"

    /// Persistence target for the clearAll() save/rehydrate hook.
    /// `.standard` in production; tests inject a scratch suite so the
    /// shared test-host defaults stay clean.
    @ObservationIgnored var priorsDefaults: UserDefaults = .standard

    /// Encode alpha/beta per category into a plain plist-safe dictionary
    /// (`[String: [String: Double]]`) — no Codable struct crossing the
    /// @Observable boundary per the design. Streaks are not stored.
    static func savePriors(_ priors: PerCategoryPriors, defaults: UserDefaults = .standard) {
        var payload: [String: [String: Double]] = [:]
        for (category, beta) in priors.byCategory {
            payload[category.rawValue] = ["alpha": beta.alpha, "beta": beta.beta]
        }
        defaults.set(payload, forKey: priorsStorageKey)
    }

    /// Fail-closed hydration: a missing key or any malformed entry
    /// degrades to the uniform Beta(1,1) default for that category.
    /// Values are clamped to the G10 invariants (α, β ≥ 1; ESS ≤ 50) so
    /// a tampered plist cannot poison scoring; streaks reset on restore
    /// (cross-session streak continuation is not meaningful).
    static func loadPriors(defaults: UserDefaults = .standard) -> PerCategoryPriors {
        guard let payload = defaults.dictionary(forKey: priorsStorageKey)
                as? [String: [String: Double]] else {
            return PerCategoryPriors()
        }
        var byCategory: [PIICategory: PerCategoryPriors.Beta] = [:]
        for (rawValue, values) in payload {
            guard let category = PIICategory(rawValue: rawValue),
                  let alpha = values["alpha"], let beta = values["beta"],
                  alpha.isFinite, beta.isFinite else { continue }
            var clampedAlpha = max(1.0, alpha)
            var clampedBeta = max(1.0, beta)
            let total = clampedAlpha + clampedBeta
            if total > 50 {
                let scale = 50 / total
                clampedAlpha = max(1.0, clampedAlpha * scale)
                clampedBeta = max(1.0, clampedBeta * scale)
            }
            byCategory[category] = PerCategoryPriors.Beta(
                alpha: clampedAlpha, beta: clampedBeta, streakDir: 0, streakLen: 0
            )
        }
        return PerCategoryPriors(byCategory: byCategory)
    }

    /// "Reset Detection History" affordance: drop the
    /// persisted history. Callers with a live instance should also reset
    /// the in-memory `priors` so clearAll() cannot re-save the old state.
    static func clearPersistedPriors(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: priorsStorageKey)
    }

    /// Exact-match surface-form dictionary (e.g., "Dr. Jane Smith" → accepted).
    /// Enables A7 short-circuit: later pages with the same surface skip re-scoring.
    /// Cleared by clearAll().
    var surfaceForms: SurfaceFormDictionary = SurfaceFormDictionary()

    /// Per-page classification diagnostic for the G5 "Why this classification?"
    /// panel in the triage sheet. In-memory only — never logged, never persisted.
    /// Released on clearAll().
    var pageDiagnostics: [Int: ClassificationDiagnostic] = [:]

    /// ST-83 — pages whose raster exceeded the OCR pixel caps during the
    /// detection run, so Vision OCR never ran there (page-level
    /// `PageDetectionResult.ocrProvenance` reports `.pixelCapExceeded`).
    /// Populated by `PipelineCoordinator.runDetectionPipeline`; consumed
    /// by the triage sheet's OCR-skip banner so the user learns those
    /// pages' image content was not text-scanned. In-memory only,
    /// document-derived; cleared with `pageDiagnostics`.
    var ocrPixelCapSkippedPages: Set<Int> = []

    /// DetectionResult IDs whose matched name belongs to a bare-surname cluster
    /// with ≥ 15 ambiguous entries. Populated post-clustering in
    /// PipelineCoordinator.runDetectionPipeline; consumed by the review rows
    /// to show the inline "Common surname — verify context" hint. Cleared by clearAll().
    var ambiguousSurnameDetectionIDs: Set<UUID> = []

    /// Cross-page entity groups produced by the post-loop
    /// clustering step in `PipelineCoordinator.runDetectionPipeline`.
    /// Each group bundles every `DetectionResult` whose `matchedText`
    /// normalizes to the same canonical form within the same PII
    /// category. Drives the "Grouped" view mode in `ScanReviewSection`;
    /// `applyFindings(.entityGroup(_:))` consumes a member to atomically
    /// accept the entire group. Cleared by clearAll().
    var crossPageEntityGroups: [CrossPageEntityGroup] = []

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
    /// the non-modal "Add to selection?" toast. Cleared after enqueue
    /// (and on any `activeSearch` transition per the didSet above).
    /// The surface is a toast — NOT a new canvas long-press
    /// action — so the canvas density cap stays at 6 menu items.
    var pendingManualDrawNudge: SearchResult?

    /// Pending magic-wand search request. Set by
    /// `RedactionOverlayView.contextMenuInteraction` when the user taps
    /// "Select all instances" on a long-pressed OCR word; observed by
    /// `DocumentEditorView` via `.onChange(of:)` to open / re-use the
    /// `SearchAndRedactSheet` pre-filled with an exact-match query.
    /// Cleared by the host after dispatch.
    var pendingMagicWandRequest: MagicWandSearchRequest?

    /// Per-search-session suppression flag. Set after
    /// the first nudge is enqueued so the user sees at most one toast
    /// per search session — the V1.x interpretation of the
    /// "Suppressible per session" contract. Resets on (a) any
    /// `activeSearch` transition via the didSet above (sheet dismiss
    /// or re-open), (b) `clearForNewDocument()` (new document load),
    /// (c) `clearAll()` (document close). Pinned by
    /// `ManualDrawNudgeTests` load-bearing scope.
    private(set) var manualDrawNudgeSuppressedForSession: Bool = false

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
    private(set) var appliedMatchAudit: [UUID: MatchAuditSnapshot] = [:]

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
    private(set) var regionsModifiedSinceVerification = false

    // MARK: - Performance Caches

    /// Cached effective region count — invalidated on any region mutation.
    /// Avoids O(n) reduce+filter on every view body evaluation.
    /// @ObservationIgnored: `effectiveRegionCount` writes this on a cache
    /// miss; a registrar-wrapped write during a SwiftUI body evaluation
    /// re-enters the observation graph and SIGABRTs (same pattern as the
    /// SearchState filter caches). Views tracking `effectiveRegionCount`
    /// still update via the observed `regions` read inside the getter.
    @ObservationIgnored private var _cachedEffectiveCount: Int?

    /// Reverse index: region UUID → page index. O(1) lookup instead of O(n×m) scan.
    private var regionPageIndex: [UUID: Int] = [:]

    /// Called by the pipeline runner after successful verification completes.
    /// This is the ONLY public path for setting the flag to false.
    func markVerificationCurrent() {
        regionsModifiedSinceVerification = false
    }

    /// Count of regions surviving the minimum-dimension filter (> 0.001 on both axes).
    /// Raw region count includes sub-threshold regions that produce no visible fill.
    /// Cached — invalidated on region mutations, computed lazily on access.
    var effectiveRegionCount: Int {
        // Read the observed `regions` BEFORE the cache check: with the cache
        // var @ObservationIgnored, this read is what registers the tracking
        // dependency, so a cache-hit access still re-evaluates when regions
        // mutate. O(1) — binds the dictionary, no traversal.
        let regions = self.regions
        if let cached = _cachedEffectiveCount { return cached }
        let count = regions.values.reduce(0) { $0 + $1.count(where: {
            $0.normalizedRect.width > 0.001 && $0.normalizedRect.height > 0.001
        })}
        _cachedEffectiveCount = count
        return count
    }

    /// True when at least one region survives the minimum-dimension filter.
    /// Short-circuits on first match (avoids full count).
    var hasEffectiveRegions: Bool {
        regions.values.contains { pageRegions in
            pageRegions.contains {
                $0.normalizedRect.width > 0.001 && $0.normalizedRect.height > 0.001
            }
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

    /// Invalidate cached counts after any region mutation.
    private func invalidateRegionCaches() {
        _cachedEffectiveCount = nil
    }

    /// Rebuild the entire reverse index from the regions dictionary.
    private func rebuildPageIndex() {
        regionPageIndex.removeAll(keepingCapacity: true)
        for (page, pageRegions) in regions {
            for region in pageRegions {
                regionPageIndex[region.id] = page
            }
        }
    }

    // MARK: - Cleanup

    /// Reset all state for a new document import. Called only after validation
    /// succeeds — old state is preserved until the new document is confirmed valid.
    func clearForNewDocument() {
        regionVersion += 1
        clearOutput()
        regions = [:]
        detectionResults = [:]
        ocrPixelCapSkippedPages = []
        selectedRegionIDs = []
        regionsModifiedSinceVerification = false
        invalidateRegionCaches()
        regionPageIndex.removeAll()
        // New-document load. Reset the
        // manual-draw nudge state explicitly so a new document never
        // inherits the previous document's suppression.
        manualDrawNudgeSuppressedForSession = false
        pendingManualDrawNudge = nil
        // Also drop any pending magic-wand request so a
        // new-document / clearAll path doesn't inherit a stale term.
        pendingMagicWandRequest = nil
        // Data integrity: a replacement document must not inherit the
        // prior document's pending detection review. `pendingTriage` /
        // `triageSelections` carry detections whose page/coordinate data belong
        // to the PRIOR document; left un-cleared, an Accept in a stranded triage
        // sheet would stamp wrong-coordinate regions onto the new document.
        pendingTriage = nil
        triageSelections = [:]
        // A replacement document must not inherit the prior document's
        // detection-run record or promotion flag — the banner would
        // describe a run that never happened on this document.
        lastDetectionRun = nil
        triagePromotionOccurred = false
        // Cancel and drop any in-flight search so its sheet does not
        // linger into the new document — mirrors the clearAll() pattern (the
        // `activeSearch` didSet does not itself cancel the search task).
        let search = activeSearch
        activeSearch = nil
        MainActor.assumeIsolated { search?.cancelSearchWithoutAwait() }
        // A healthy second-document run must not show the prior run's
        // "auto-detect degraded" banner (`signalDegradedDetection` treats the
        // flag as an already-toasted gate and never resets it).
        autoDetectionDegraded = false
        // Drop any pending canvas-rationale request so a stale region
        // UUID does not present a blank rationale sheet over the new document.
        pendingCanvasRationaleRequest = nil
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

    /// Reset all output state. Called on pipeline cancel/fail or new import.
    ///
    /// Clear `outputURL` first, then attempt `removeItem`
    /// against a local capture. The previous order (`removeItem(at: url)`
    /// THEN `outputURL = nil`) opened a narrow window where an observer
    /// reading the published `outputURL` between the removeItem and the
    /// nil-out could pick up a URL whose file had already been unlinked.
    /// On removeItem failure (filesystem race, file already purged) we
    /// still nil the URL — the document state is the authority on
    /// "where the redacted PDF lives," and a register-orphan sweep on
    /// next launch handles leftover bytes (cleanOrphanedTempFiles).
    func clearOutput() {
        let url = outputURL
        outputURL = nil
        if let url {
            // Best-effort delete — failure to remove leaves the file
            // for `cleanOrphanedTempFiles()` to sweep on next launch.
            try? FileManager.default.removeItem(at: url)
        }
        clearVerification()
        textExtractionBuffer = nil
        // The retained run inputs describe the output that was just
        // discarded — a later run must not verify against them.
        lastRunPerPageModes = nil
        lastRunPerPageFallbackReasons = nil
        lastRunSensitiveTerms = nil
        lastRunDeselection = nil
    }

    // MARK: - Region Mutations with Undo

    func addRegion(_ region: RedactionRegion, page: Int, undoManager: UndoManager?) {
        regionVersion += 1
        regions[page, default: []].append(region)
        regionPageIndex[region.id] = page
        invalidateRegionCaches()
        regionsModifiedSinceVerification = true
        outputURL = nil
        let regionID = region.id
        registerUndo(undoManager, "Add Redaction") { target in
            target.removeRegion(regionID, page: page, undoManager: undoManager)
        }
        // Post-add hook for the manual-draw nearby-PII
        // nudge. Only fires for `.manual` source regions — the search-
        // apply path that creates `.searchMatch` regions is itself the
        // origin of nudge candidates, so we deliberately skip it to
        // avoid recursive toast spam. The predicate handles all other
        // filtering (proximity, applied-IDs, category, suppression).
        if case .manual = region.source,
           let search = activeSearch,
           !manualDrawNudgeSuppressedForSession {
            let resultsSnapshot = MainActor.assumeIsolated { search.results }
            let appliedSnapshot = MainActor.assumeIsolated { search.appliedResultIDs }
            if let match = RedactionState.nearbyUnappliedPIIMatch(
                addedRegion: region,
                page: page,
                results: resultsSnapshot,
                appliedIDs: appliedSnapshot,
                suppressed: manualDrawNudgeSuppressedForSession,
                proximityNormalized: RedactionState.manualDrawNudgeProximityNormalized
            ) {
                pendingManualDrawNudge = match
            }
        }
    }

    func removeRegion(_ id: UUID, page: Int, undoManager: UndoManager?) {
        regionVersion += 1
        guard var pageRegions = regions[page],
              let index = pageRegions.firstIndex(where: { $0.id == id }) else { return }
        let removed = pageRegions.remove(at: index)
        regions[page] = pageRegions
        regionPageIndex.removeValue(forKey: id)
        invalidateRegionCaches()
        let removedMetadata = regionMetadata.removeValue(forKey: id) // Capture metadata
        regionsModifiedSinceVerification = true
        outputURL = nil
        registerUndo(undoManager, "Delete Redaction") { target in
            target.addRegion(removed, page: page, undoManager: undoManager)
            if let removedMetadata { // Restore metadata on undo
                target.regionMetadata[removed.id] = removedMetadata
            }
        }
    }

    func resizeRegion(
        _ id: UUID, page: Int,
        newRect: CGRect, undoManager: UndoManager?
    ) {
        regionVersion += 1
        guard var pageRegions = regions[page],
              let index = pageRegions.firstIndex(where: { $0.id == id }) else { return }
        let oldRect = pageRegions[index].normalizedRect
        pageRegions[index].normalizedRect = newRect
        regions[page] = pageRegions
        invalidateRegionCaches()
        regionsModifiedSinceVerification = true
        outputURL = nil
        registerUndo(undoManager, "Resize Redaction") { target in
            target.resizeRegion(id, page: page, newRect: oldRect, undoManager: undoManager)
        }
    }

    // Move region to new position. Follows resizeRegion undo pattern.
    func moveRegion(
        _ id: UUID, page: Int,
        newRect: CGRect, undoManager: UndoManager?
    ) {
        regionVersion += 1
        guard var pageRegions = regions[page],
              let index = pageRegions.firstIndex(where: { $0.id == id }) else { return }
        let oldRect = pageRegions[index].normalizedRect
        pageRegions[index].normalizedRect = newRect
        regions[page] = pageRegions
        invalidateRegionCaches()
        regionsModifiedSinceVerification = true
        outputURL = nil
        registerUndo(undoManager, "Move Redaction") { target in
            target.moveRegion(id, page: page, newRect: oldRect, undoManager: undoManager)
        }
    }

    /// Batch move multiple regions on the same page. Single undo action.
    func moveRegions(_ moves: [(id: UUID, newRect: CGRect)], page: Int, undoManager: UndoManager?) {
        regionVersion += 1
        guard var pageRegions = regions[page] else { return }
        var mutableOldRects: [(id: UUID, oldRect: CGRect)] = []
        for move in moves {
            guard let index = pageRegions.firstIndex(where: { $0.id == move.id }) else { continue }
            mutableOldRects.append((move.id, pageRegions[index].normalizedRect))
            pageRegions[index].normalizedRect = move.newRect
        }
        regions[page] = pageRegions
        invalidateRegionCaches()
        regionsModifiedSinceVerification = true
        outputURL = nil
        let snapshot = mutableOldRects
        registerUndo(undoManager, "Move Redactions") { target in
            let restoreMoves = snapshot.map { (id: $0.id, newRect: $0.oldRect) }
            target.moveRegions(restoreMoves, page: page, undoManager: undoManager)
        }
    }

    /// Batch remove multiple regions from a single page. Single undo action.
    func removeRegions(_ ids: Set<UUID>, page: Int, undoManager: UndoManager?) {
        regionVersion += 1
        guard var pageRegions = regions[page] else { return }
        var mutableRemoved: [(region: RedactionRegion, metadata: RegionMetadata?)] = []
        for id in ids {
            guard let index = pageRegions.firstIndex(where: { $0.id == id }) else { continue }
            let region = pageRegions.remove(at: index)
            let metadata = regionMetadata.removeValue(forKey: id)
            mutableRemoved.append((region, metadata))
        }
        regions[page] = pageRegions
        for id in ids { regionPageIndex.removeValue(forKey: id) }
        invalidateRegionCaches()
        regionsModifiedSinceVerification = true
        outputURL = nil
        selectedRegionIDs.subtract(ids)
        let snapshot = mutableRemoved
        registerUndo(undoManager, "Delete Redactions") { target in
            for item in snapshot {
                target.regions[page, default: []].append(item.region)
                target.regionPageIndex[item.region.id] = page
                if let meta = item.metadata {
                    target.regionMetadata[item.region.id] = meta
                }
            }
            target.invalidateRegionCaches()
            target.regionsModifiedSinceVerification = true
            target.outputURL = nil
            // Undo re-inserts the deleted regions — bump so the overlay
            // refresh gate observes it (the redo leg recurses into
            // `removeRegions`, which bumps at entry).
            target.regionVersion += 1
            target.registerUndo(undoManager, "Delete Redactions") { target2 in
                target2.removeRegions(ids, page: page, undoManager: undoManager)
            }
        }
    }

    /// Delete all selected regions, grouped by page for batch undo.
    /// Returns affected page indices so callers can refresh overlays.
    @discardableResult
    func deleteSelected(undoManager: UndoManager?) -> Set<Int> {
        let ids = selectedRegionIDs
        guard !ids.isEmpty else { return [] }
        var affectedPages: Set<Int> = []
        var byPage: [Int: Set<UUID>] = [:]
        for id in ids {
            if let page = pageIndex(for: id) {
                byPage[page, default: []].insert(id)
                affectedPages.insert(page)
            }
        }
        for (page, pageIDs) in byPage {
            if pageIDs.count == 1, let id = pageIDs.first {
                removeRegion(id, page: page, undoManager: undoManager)
            } else {
                removeRegions(pageIDs, page: page, undoManager: undoManager)
            }
        }
        selectedRegionIDs = []
        return affectedPages
    }

    /// Duplicate a region with a small offset. The copy is manual-sourced.
    /// Routes through `addRegion` for the actual mutation but
    /// overrides the inner action name so the iOS long-press Undo menu
    /// reads "Duplicate Redaction" rather than the generic "Add Redaction".
    func duplicateRegion(_ id: UUID, page: Int, undoManager: UndoManager?) {
        regionVersion += 1
        guard let pageRegions = regions[page],
              let region = pageRegions.first(where: { $0.id == id }) else { return }
        let newRect = RedactionState.duplicateOffsetClamp(
            source: region.normalizedRect
        )
        let copy = RedactionRegion(id: UUID(), normalizedRect: newRect, source: .manual)
        addRegion(copy, page: page, undoManager: undoManager)
        // Override the inner addRegion's "Add Redaction" name. UndoManager
        // setActionName is last-write-wins on the current registration.
        undoManager?.setActionName("Duplicate Redaction")
    }

    /// 0.02-offset clamp for `duplicateRegion`. Normalized PDF coords are
    /// rotation-independent (rotation is a display transform), so a clamp
    /// to [0, 1]² covers every page-size / rotation combination. Right
    /// edge is bounded by `1 - width`; bottom edge is bounded by 0.
    /// Pure function — testable without a full RedactionState.
    static func duplicateOffsetClamp(source: CGRect) -> CGRect {
        let offset: CGFloat = 0.02
        return CGRect(
            x: min(source.minX + offset, 1 - source.width),
            y: max(source.minY - offset, 0),
            width: source.width,
            height: source.height
        )
    }

    // MARK: - The one apply seam

    /// Which staged work an `applyFindings` call promotes to regions.
    enum ApplyOrigin {
        /// The selected rows of `activeSearch.results` — the search
        /// side and the Scan interface's in-sheet run results.
        case selectedSearchResults
        /// The staged detection review: every explicit-true entry in
        /// `triageSelections` across `pendingTriage`.
        case stagedDetections
        /// Every member of one cross-page entity group still pending in
        /// the review. Selection state is not consulted — accepting the
        /// group IS the selection gesture.
        case entityGroup(CrossPageEntityGroup)
        /// A raw detection map applied directly, with signature
        /// candidates split out to the review (never applied directly).
        /// No production caller — the absorbed shape of the former
        /// direct-apply entry, retained until a pipeline path needs it.
        case detectionResults([Int: [DetectionResult]])
    }

    /// What one `applyFindings` call did. Counts feed the shared
    /// commit-toast copy (`CommitFeedback`), which reports regions
    /// actually created — never the raw detection or selection total.
    struct ApplyOutcome: Equatable {
        /// Regions actually created (signature candidates and overlap
        /// skips excluded).
        let applied: Int
        /// Search origin only: selected results skipped for >80%
        /// overlap with an existing region. Skipped results earn no
        /// applied badge and no audit entry (QW-1).
        let skippedOverlaps: Int
        /// Search origin only: the `SearchResult.id`s that produced a
        /// region this pass.
        let appliedResultIDs: Set<UUID>
        /// Detection-map origin only: detections routed to the review
        /// instead of applied.
        let signatureCandidates: Int

        static let zero = ApplyOutcome(
            applied: 0, skippedOverlaps: 0,
            appliedResultIDs: [], signatureCandidates: 0)
    }

    /// The one apply path for BOTH result origins. Every origin creates
    /// its regions AND writes the audit records — `RegionMetadata` plus
    /// `MatchAuditSnapshot` with `regionID` populated — through the one
    /// commit transaction, with one undo implementation
    /// (`commitApply`). Returns nil when the call is refused (no active
    /// search for the search origin, or the pipeline owns `regions`);
    /// otherwise an outcome whose counts feed the shared commit toast.
    ///
    /// Mutation guard: when `documentState` is passed, the call refuses
    /// to mutate `regions` / `regionMetadata` while the pipeline owns
    /// them (`!canMutateRegions`) — re-checked HERE, inside the action,
    /// so a caller racing a pipeline start cannot slip a mutation in
    /// behind a button-level `.disabled` gate. The search origin checks
    /// again after its detached prepare step resumes, closing the
    /// window a pipeline start opens during that suspension. The
    /// parameter stays optional for source compatibility and test
    /// seams; the sheet entry points pass it.
    @discardableResult
    func applyFindings(
        _ origin: ApplyOrigin,
        undoManager: UndoManager?,
        documentState: DocumentState? = nil
    ) async -> ApplyOutcome? {
        if let documentState, !documentState.canMutateRegions {
            return nil
        }
        // The conditional-dismiss tracker reset is owned by this path:
        // the search and staged-review origins reset it on every
        // non-refused outcome (they resolve the session's whole
        // selection context); a group promotion is a partial commit —
        // the remaining review selections are still live work, so the
        // tracker stays set for them. Each branch resets the session it
        // actually applied against.
        switch origin {
        case .selectedSearchResults:
            return await applySelectedSearchResultsOrigin(
                undoManager: undoManager, documentState: documentState)
        case .stagedDetections:
            let outcome = applyStagedDetectionsOrigin(undoManager: undoManager)
            if outcome != nil {
                activeSearch?.userModifiedSelections = false
            }
            return outcome
        case .entityGroup(let group):
            return applyEntityGroupOrigin(group, undoManager: undoManager)
        case .detectionResults(let results):
            return applyDetectionMapOrigin(results, undoManager: undoManager)
        }
    }

    /// Search origin. The overlap rejection + per-result region /
    /// metadata / audit construction runs in a detached task so a
    /// 1000-result apply over pages that already hold prior regions
    /// doesn't freeze MainActor; the MainActor segment performs only
    /// the write-back transaction + undo registration.
    private func applySelectedSearchResultsOrigin(
        undoManager: UndoManager?,
        documentState: DocumentState?
    ) async -> ApplyOutcome? {
        guard let search = activeSearch else { return nil }

        let selected = search.results.filter(\.isSelected)
        guard !selected.isEmpty else {
            search.userModifiedSelections = false
            return .zero
        }

        // Snapshot existing rects per page so the overlap test can run
        // off-MainActor without re-entering actor state.
        let existingRectsByPage: [Int: [CGRect]] = regions.mapValues { $0.map(\.normalizedRect) }
        let appliedAt = Date()

        let prepared = await Task.detached(priority: .userInitiated) {
            prepareApply(
                selected: selected,
                existingRectsByPage: existingRectsByPage,
                appliedAt: appliedAt
            )
        }.value

        // Re-check after the suspension: a pipeline that started while
        // the prepare step ran must not receive a mutation on resume.
        if let documentState, !documentState.canMutateRegions {
            return nil
        }

        let termDescription = selected.first?.term ?? "search"
        let count = selected.count
        commitApply(
            createdRegions: prepared.createdRegions,
            createdMetadata: prepared.createdMetadata,
            createdAudit: prepared.createdAudit,
            actionName: "Redact \(count) Instances of '\(termDescription)'",
            priorsRestore: nil,
            recordsSearchApplyVersion: true,
            undoManager: undoManager
        )
        // Reset the CAPTURED session's tracker — the one this apply ran
        // against — not whatever `activeSearch` points at after the
        // prepare suspension (a dismissed-and-reopened sheet must not
        // inherit a stale apply's reset).
        search.userModifiedSelections = false

        // Caller is responsible for clearing activeSearch after showing feedback.
        return ApplyOutcome(
            applied: prepared.appliedCount,
            skippedOverlaps: prepared.skippedOverlaps,
            appliedResultIDs: prepared.appliedResultIDs,
            signatureCandidates: 0
        )
    }

    // MARK: - Detection origins (staged review, entity group, raw map)

    /// Staged-detections origin: promotes explicit-true selections and
    /// records accept AND reject decisions into `priors` +
    /// `surfaceForms` (both inform). An ABSENT selection id reads as
    /// NOT accepted — the review-first arrival default — so only work
    /// the user opted into becomes a region. Resolves the review either
    /// way; undo removes the applied regions with their metadata +
    /// audit records and restores the recorded decisions, but does not
    /// reopen the review (re-running detection rebuilds it).
    private func applyStagedDetectionsOrigin(
        undoManager: UndoManager?
    ) -> ApplyOutcome? {
        guard let pending = pendingTriage else { return .zero }

        let priorsSnapshot = priors
        let surfaceFormsSnapshot = surfaceForms
        let appliedAt = Date()

        for (_, results) in pending {
            for detection in results {
                let accepted = triageSelections[detection.id] ?? false
                if case .pii(let piiKind) = detection.kind,
                   let category = PIICategory(piiKind: piiKind) {
                    priors = priors.updated(
                        category: category,
                        decision: accepted ? .accepted : .rejected
                    )
                }
                if let matched = detection.matchedText, !matched.isEmpty {
                    surfaceForms = surfaceForms.recording(
                        matched,
                        decision: accepted ? .accepted : .rejected
                    )
                }
            }
        }

        var createdRegions: [Int: [RedactionRegion]] = [:]
        var createdMetadata: [UUID: RegionMetadata] = [:]
        var createdAudit: [UUID: MatchAuditSnapshot] = [:]
        for (page, results) in pending {
            let accepted = results.filter { triageSelections[$0.id] ?? false }
            let newRegions = accepted.map { detection -> RedactionRegion in
                let region = detection.toRegion()
                // Preserve the ambiguity flag onto the region's metadata so
                // the canvas and detail view can still surface it after review.
                createdMetadata[region.id] = RegionMetadata(
                    piiKind: detection.kind,
                    confidence: detection.confidence,
                    matchedText: detection.matchedText,
                    recognitionLevel: detection.recognitionLevel,
                    isAmbiguousSurname: ambiguousSurnameDetectionIDs.contains(detection.id)
                )
                createdAudit[region.id] = MatchAuditSnapshot(
                    detection: detection,
                    pageIndex: page,
                    regionID: region.id,
                    appliedAt: appliedAt
                )
                return region
            }
            if !newRegions.isEmpty {
                createdRegions[page] = newRegions
            }
        }

        // The review resolves whether or not anything was promoted. It
        // is deliberately NOT captured in the undo closure — undoing
        // the apply removes the regions but does not reopen the review.
        pendingTriage = nil
        triageSelections = [:]
        let createdCount = createdRegions.values.reduce(0) { $0 + $1.count }
        if createdCount > 0 { triagePromotionOccurred = true }

        commitApply(
            createdRegions: createdRegions,
            createdMetadata: createdMetadata,
            createdAudit: createdAudit,
            actionName: "Apply Detections",
            priorsRestore: (priors: priorsSnapshot, surfaceForms: surfaceFormsSnapshot),
            recordsSearchApplyVersion: false,
            undoManager: undoManager
        )

        return ApplyOutcome(
            applied: createdCount, skippedOverlaps: 0,
            appliedResultIDs: [], signatureCandidates: 0)
    }

    /// Entity-group origin: promotes every member of the group still
    /// pending in the review as one atomic undo step, records their
    /// accepted decisions here (the members bypass the staged-review
    /// bookkeeping loop from now on), and prunes them from the review
    /// so the next full apply cannot double-create and the toolbar
    /// count stays honest (UXF-29). Members no longer pending are
    /// skipped silently; non-member detections stay pending for the
    /// normal review flow. If the prune empties the review, it closes —
    /// the same end state as a full apply.
    private func applyEntityGroupOrigin(
        _ group: CrossPageEntityGroup,
        undoManager: UndoManager?
    ) -> ApplyOutcome? {
        guard let pending = pendingTriage else { return .zero }

        // (detectionID → (page, detection)) lookup over pendingTriage
        // so the group's members resolve without rescanning each page.
        var lookup: [UUID: (page: Int, detection: DetectionResult)] = [:]
        for (page, results) in pending {
            for result in results {
                lookup[result.id] = (page: page, detection: result)
            }
        }

        var createdRegions: [Int: [RedactionRegion]] = [:]
        var createdMetadata: [UUID: RegionMetadata] = [:]
        var createdAudit: [UUID: MatchAuditSnapshot] = [:]
        var appliedDetections: [DetectionResult] = []
        var appliedIDs = Set<UUID>()
        let memberIDs = Set(group.detectionIDs)
        let appliedAt = Date()

        for detectionID in group.detectionIDs {
            guard let hit = lookup[detectionID] else { continue }
            let region = hit.detection.toRegion()
            createdRegions[hit.page, default: []].append(region)
            createdMetadata[region.id] = RegionMetadata(
                piiKind: hit.detection.kind,
                confidence: hit.detection.confidence,
                matchedText: hit.detection.matchedText,
                recognitionLevel: hit.detection.recognitionLevel,
                isAmbiguousSurname:
                    ambiguousSurnameDetectionIDs.contains(hit.detection.id)
            )
            createdAudit[region.id] = MatchAuditSnapshot(
                detection: hit.detection,
                pageIndex: hit.page,
                regionID: region.id,
                appliedAt: appliedAt
            )
            appliedDetections.append(hit.detection)
            appliedIDs.insert(hit.detection.id)
        }
        let appliedCount = appliedDetections.count

        guard appliedCount > 0 else { return .zero }

        let priorsSnapshot = priors
        let surfaceFormsSnapshot = surfaceForms

        // Promoted members bypass the staged-review bookkeeping loop
        // from here on (they are pruned below), so record their
        // accepted decision at the point of promotion.
        for detection in appliedDetections {
            if case .pii(let piiKind) = detection.kind,
               let category = PIICategory(piiKind: piiKind) {
                priors = priors.updated(category: category, decision: .accepted)
            }
            if let matched = detection.matchedText, !matched.isEmpty {
                surfaceForms = surfaceForms.recording(matched, decision: .accepted)
            }
        }

        // UXF-29 — prune the promoted members from `pendingTriage` and
        // drop their selection entries. Leaving them pending meant the
        // next full apply re-created a region for every member.
        var remaining = pending
        for (page, results) in remaining {
            remaining[page] = results.filter { !appliedIDs.contains($0.id) }
        }
        remaining = remaining.filter { !$0.value.isEmpty }
        pendingTriage = remaining.isEmpty ? nil : remaining
        for id in memberIDs { triageSelections.removeValue(forKey: id) }
        triagePromotionOccurred = true

        commitApply(
            createdRegions: createdRegions,
            createdMetadata: createdMetadata,
            createdAudit: createdAudit,
            actionName: "Redact Entity Group",
            priorsRestore: (priors: priorsSnapshot, surfaceForms: surfaceFormsSnapshot),
            recordsSearchApplyVersion: false,
            undoManager: undoManager
        )

        return ApplyOutcome(
            applied: appliedCount, skippedOverlaps: 0,
            appliedResultIDs: [], signatureCandidates: 0)
    }

    /// Detection-map origin — the absorbed shape of the former
    /// direct-apply entry (no production caller). `.signatureCandidate`
    /// detections are never applied directly: the signature heuristic
    /// is review-only by design (confidence is heuristic; the user must
    /// accept in the review before a region is created — locked
    /// decision). They split out to `pendingTriage` and arrive
    /// DESELECTED like every review arrival (absent id = not accepted).
    /// Every region this origin creates now carries the same metadata +
    /// audit records as the other origins.
    private func applyDetectionMapOrigin(
        _ results: [Int: [DetectionResult]],
        undoManager: UndoManager?
    ) -> ApplyOutcome? {
        var autoApplyResults: [Int: [DetectionResult]] = [:]
        var signatureResults: [Int: [DetectionResult]] = [:]
        for (page, pageResults) in results {
            let signatures = pageResults.filter {
                if case .pii(.signatureCandidate) = $0.kind { return true }
                return false
            }
            let others = pageResults.filter {
                if case .pii(.signatureCandidate) = $0.kind { return false }
                return true
            }
            if !signatures.isEmpty { signatureResults[page] = signatures }
            if !others.isEmpty { autoApplyResults[page] = others }
        }

        let appliedAt = Date()
        var createdRegions: [Int: [RedactionRegion]] = [:]
        var createdMetadata: [UUID: RegionMetadata] = [:]
        var createdAudit: [UUID: MatchAuditSnapshot] = [:]
        for (page, pageResults) in autoApplyResults {
            let newRegions = pageResults.map { detection -> RedactionRegion in
                let region = detection.toRegion()
                createdMetadata[region.id] = RegionMetadata(
                    piiKind: detection.kind,
                    confidence: detection.confidence,
                    matchedText: detection.matchedText,
                    recognitionLevel: detection.recognitionLevel,
                    isAmbiguousSurname:
                        ambiguousSurnameDetectionIDs.contains(detection.id)
                )
                createdAudit[region.id] = MatchAuditSnapshot(
                    detection: detection,
                    pageIndex: page,
                    regionID: region.id,
                    appliedAt: appliedAt
                )
                return region
            }
            createdRegions[page] = newRegions
        }

        // Route signature candidates to the review. No selection
        // entries are written — an absent id reads deselected, the
        // arrival default for every review.
        if !signatureResults.isEmpty {
            pendingTriage = signatureResults
        }

        let appliedCount = createdRegions.values.reduce(0) { $0 + $1.count }
        let signatureCount = signatureResults.values.reduce(0) { $0 + $1.count }

        commitApply(
            createdRegions: createdRegions,
            createdMetadata: createdMetadata,
            createdAudit: createdAudit,
            actionName: "Apply Detections",
            priorsRestore: nil,
            recordsSearchApplyVersion: false,
            undoManager: undoManager
        )

        return ApplyOutcome(
            applied: appliedCount, skippedOverlaps: 0,
            appliedResultIDs: [], signatureCandidates: signatureCount)
    }

    /// Dismiss triage without applying any results.
    func dismissTriage() {
        pendingTriage = nil
        triageSelections = [:]
    }

    // MARK: - Shared commit + the one undo implementation

    /// The single write-back transaction every apply origin commits
    /// through: one `regionVersion` bump, region + reverse-index
    /// insert, metadata + audit merge, cache/verification/output
    /// invalidation, and ONE two-leg undo registration. Undo removes
    /// the created regions with their metadata AND audit records in
    /// lockstep, restoring the recorded priors + surface forms when the
    /// origin snapshotted them; redo re-inserts all three without
    /// re-recording decisions.
    ///
    /// `recordsSearchApplyVersion` is set by the search origin only: it
    /// records the produced `regionVersion` so the sheet's
    /// applied-marker handler can tell this apply's own bump apart from
    /// a real undo/redo bump. Captures N+1 (the post-increment value)
    /// atomically within this MainActor write-back — no suspension runs
    /// before the caller returns. Detection-origin applies deliberately
    /// do NOT record it: their bumps clear stale search-applied markers
    /// like any other region mutation.
    private func commitApply(
        createdRegions: [Int: [RedactionRegion]],
        createdMetadata: [UUID: RegionMetadata],
        createdAudit: [UUID: MatchAuditSnapshot],
        actionName: String,
        priorsRestore: (priors: PerCategoryPriors, surfaceForms: SurfaceFormDictionary)?,
        recordsSearchApplyVersion: Bool,
        undoManager: UndoManager?
    ) {
        regionVersion += 1
        if recordsSearchApplyVersion {
            lastAppliedSearchRegionVersion = regionVersion
        }
        for (page, newRegions) in createdRegions {
            regions[page, default: []].append(contentsOf: newRegions)
            for region in newRegions { regionPageIndex[region.id] = page }
        }
        regionMetadata.merge(createdMetadata) { _, new in new }
        appliedMatchAudit.merge(createdAudit) { _, new in new }
        invalidateRegionCaches()
        regionsModifiedSinceVerification = true
        outputURL = nil

        let snapshot = createdRegions
        let metaSnapshot = createdMetadata
        let auditSnapshot = createdAudit
        registerUndo(undoManager, actionName) { target in
            for (page, newRegions) in snapshot {
                let idsToRemove = Set(newRegions.map(\.id))
                target.regions[page]?.removeAll { idsToRemove.contains($0.id) }
                for id in idsToRemove { target.regionPageIndex.removeValue(forKey: id) }
            }
            for id in metaSnapshot.keys {
                target.regionMetadata.removeValue(forKey: id)
            }
            for id in auditSnapshot.keys {
                target.appliedMatchAudit.removeValue(forKey: id)
            }
            if let priorsRestore {
                // Restore the recorded decisions on undo.
                target.priors = priorsRestore.priors
                target.surfaceForms = priorsRestore.surfaceForms
            }
            target.invalidateRegionCaches()
            target.regionsModifiedSinceVerification = true
            target.outputURL = nil
            // The undo leg is a region mutation like any other: bump
            // `regionVersion` so the overlay refresh gate and the search
            // sheet's applied-marker `.onChange` observe the removal.
            // `lastAppliedSearchRegionVersion` stays at the forward
            // apply's value, so the marker handler reads this bump as a
            // real undo rather than the apply's own.
            target.regionVersion += 1
            target.registerUndo(undoManager, actionName) { target2 in
                for (page, newRegions) in snapshot {
                    target2.regions[page, default: []].append(contentsOf: newRegions)
                    for region in newRegions { target2.regionPageIndex[region.id] = page }
                }
                target2.regionMetadata.merge(metaSnapshot) { _, new in new }
                target2.appliedMatchAudit.merge(auditSnapshot) { _, new in new }
                target2.invalidateRegionCaches()
                target2.regionsModifiedSinceVerification = true
                target2.outputURL = nil
                // Redo re-inserts regions — a region mutation; the bump
                // keeps the canvas overlays refreshing. The sheet's
                // applied markers stay cleared (conservative: the
                // re-inserted regions read as coverage, so a re-apply
                // over them no-ops as "already covered").
                target2.regionVersion += 1
            }
        }
    }

    // MARK: - Lasso Multi-Select Batch Apply

    /// Maximum number of regions a single lasso-marquee apply may select.
    /// Defensive cap against accidental select-all on huge documents; the
    /// truncation surfaces as a `.warning` toast so the user can re-target.
    static let lassoSelectionCap: Int = 500

    /// User-facing toast text shown when a lasso marquee would select
    /// more regions than `lassoSelectionCap` permits. Mechanism-description
    /// language — "Selection limited to 500 regions"
    /// names the truncation observably without making a promise claim.
    static let lassoSelectionCapToastMessage: String =
        "Selection limited to \(lassoSelectionCap) regions"

    /// Apply a precomputed batch of regions as the new multi-select set.
    ///
    /// Peer to `applyFindings` — distinct shipping unit. Where
    /// `applyFindings` creates new regions from either result origin,
    /// `applyBatch` selects already-resident regions: the
    /// caller has resolved a rect-marquee against `regions` and produced
    /// the intersecting subset.
    ///
    /// Mirrors the `commitApply` undo-grouping pattern:
    /// the entire selection mutation is one undoable step so a follow-on
    /// batch-delete via `deleteSelected` collapses into a second single
    /// undo step (one `undoManager.undo()` per user-visible action).
    ///
    /// Enforces the 500-region cap (`lassoSelectionCap`) inside this
    /// method so any caller route — the overlay marquee path today,
    /// hypothetical future select-all-by-detector routes — inherits the
    /// same defense automatically. On truncation, posts a `.warning`
    /// toast via the caller-provided `toastManager`; severity is
    /// intentionally `.warning` (not `.error`) because overflow is an
    /// expected outcome on large documents, not a fault state.
    ///
    /// - Parameters:
    ///   - regions: Regions to mark selected. Order is preserved across
    ///     the truncation — the first `lassoSelectionCap` entries are
    ///     kept; later entries are dropped silently after the toast.
    ///   - undoManager: Optional UndoManager for grouping the selection
    ///     mutation as a single undo step. Nil disables undo support
    ///     (test seam).
    ///   - toastManager: Optional ToastQueueManager for surfacing the
    ///     overflow toast. Nil disables the toast surfacing (test seam).
    /// - Returns: A tuple naming the count actually selected and a flag
    ///   recording whether the cap truncated the input. Both fields are
    ///   available without inspecting the toast manager so tests can
    ///   assert on the truncation contract directly.
    @MainActor
    @discardableResult
    func applyBatch(
        _ regions: [RedactionRegion],
        undoManager: UndoManager?,
        toastManager: ToastQueueManager? = nil
    ) -> (selected: Int, truncated: Bool) {
        let truncated = regions.count > Self.lassoSelectionCap
        let kept = truncated
            ? Array(regions.prefix(Self.lassoSelectionCap))
            : regions
        let newSelection = Set(kept.map(\.id))

        let previousSelection = selectedRegionIDs
        selectedRegionIDs = newSelection

        // Undo: restore the prior selection set in one step, then a
        // redo step that re-applies the truncated selection. Mirrors
        // commitApply's two-leg register/re-register pattern
        // so redo after undo lands the same selection
        // (rather than the original, untruncated input).
        let snapshot = newSelection
        let priorSnapshot = previousSelection
        registerUndo(undoManager, "Select Regions") { target in
            target.selectedRegionIDs = priorSnapshot
            target.registerUndo(undoManager, "Select Regions") { target2 in
                target2.selectedRegionIDs = snapshot
            }
        }

        if truncated {
            toastManager?.enqueue(
                Self.lassoSelectionCapToastMessage,
                severity: .warning
            )
        }

        return (selected: newSelection.count, truncated: truncated)
    }

    // MARK: - Manual-Draw Nudge

    /// Pure-function predicate driving the manual-draw nearby-PII nudge.
    /// Returns the first eligible `SearchResult` on `page` that sits
    /// within `proximityNormalized` of `addedRegion`'s edges, or nil if
    /// no candidate qualifies. Eligibility:
    /// - Same page as the added region (cross-page nudges are out of
    ///   scope; the user's mental model is page-local).
    /// - `piiCategory != nil` (text / regex / multi-term hits do not
    ///   qualify — the nudge is specifically about PII discovery).
    /// - `result.id` is NOT in `appliedIDs` — the user has not already
    ///   redacted this match through the apply flow.
    /// - The result's normalized rect does NOT overlap the new region
    ///   by > 80 %; an overlap that large means the user already drew
    ///   over the candidate, and prompting them to "add" it again
    ///   would be redundant. The 80 % gate matches
    ///   the search-origin apply's skip-on-overlap rule so both
    ///   surfaces use the same overlap arithmetic.
    /// - Edge-to-edge normalized distance ≤ `proximityNormalized`.
    /// Bypassed entirely when `suppressed` is true so a session-
    /// suppressed user never re-incurs the per-result scan cost.
    /// Pure — testable without a SwiftUI host or `RedactionState`
    /// instance. Pinned by `ManualDrawNudgeTests`.
    static func nearbyUnappliedPIIMatch(
        addedRegion: RedactionRegion,
        page: Int,
        results: [SearchResult],
        appliedIDs: Set<UUID>,
        suppressed: Bool,
        proximityNormalized: CGFloat
    ) -> SearchResult? {
        guard !suppressed else { return nil }
        guard !results.isEmpty else { return nil }
        let addedRect = addedRegion.normalizedRect
        for result in results {
            guard result.pageIndex == page else { continue }
            guard result.piiCategory != nil else { continue }
            guard !appliedIDs.contains(result.id) else { continue }
            let resultRect = result.normalizedRect
            let intersection = addedRect.intersection(resultRect)
            if !intersection.isNull {
                let overlapArea = intersection.width * intersection.height
                let resultArea = resultRect.width * resultRect.height
                if resultArea > 0 && overlapArea / resultArea > 0.8 {
                    continue
                }
            }
            let dx = max(0, max(addedRect.minX - resultRect.maxX,
                                resultRect.minX - addedRect.maxX))
            let dy = max(0, max(addedRect.minY - resultRect.maxY,
                                resultRect.minY - addedRect.maxY))
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance <= proximityNormalized {
                return result
            }
        }
        return nil
    }

    /// Accept a nudged `SearchResult` directly: convert it into a
    /// redaction region whose `Source` carries the result's
    /// `MatchRationale`. Caller passes
    /// the captured nudge so the accept path works even after the
    /// toast-enqueue path cleared `pendingManualDrawNudge` (the toast
    /// closure captures the value-type `SearchResult` at enqueue
    /// time). Routes through `addRegion` so the standard
    /// undo / region-version / page-index mutations apply —
    /// rationale continuity is preserved because the new region's
    /// `Source.searchMatch(term:rationale:)` carries `nudge.rationale`
    /// verbatim. Side-effects mirror the search-origin apply's
    /// per-result branch (regionMetadata + audit snapshot +
    /// appliedResultIDs membership) so a nudge-accepted region looks
    /// indistinguishable from a sheet-applied region on the canvas.
    /// The suppression flag is NOT set on accept — the user is
    /// engaged; the toast-enqueue path sets it.
    @discardableResult
    func acceptManualDrawNudge(
        _ nudge: SearchResult,
        undoManager: UndoManager?
    ) -> RedactionRegion? {
        guard let search = activeSearch else {
            pendingManualDrawNudge = nil
            return nil
        }
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: nudge.normalizedRect,
            source: .searchMatch(term: nudge.term, rationale: nudge.rationale)
        )
        let confidence: Double = switch nudge.source {
        case .textLayer: 1.0
        case .ocr(let conf): Double(conf)
        }
        // Category stamp — mirrors `prepareApply` so a nudge-accepted
        // region stays indistinguishable from a sheet-applied region.
        let nudgeKind: DetectionResult.Kind = nudge.piiCategory
            .map { .pii($0.piiKind) } ?? .searchMatch(term: nudge.term)
        let metadata = RegionMetadata(
            piiKind: nudgeKind,
            confidence: confidence,
            matchedText: nudge.matchedText,
            recognitionLevel: nudge.source == .textLayer ? .fast : .accurate
        )
        let audit = MatchAuditSnapshot(
            origin: .search,
            resultID: nudge.id,
            regionID: region.id,
            pageIndex: nudge.pageIndex,
            matchedText: nudge.matchedText,
            source: nudge.source,
            piiCategory: nudge.piiCategory,
            piiConfidence: nudge.piiConfidence,
            rationale: nudge.rationale,
            term: nudge.term,
            appliedAt: Date()
        )
        addRegion(region, page: nudge.pageIndex, undoManager: undoManager)
        regionMetadata[region.id] = metadata
        appliedMatchAudit[region.id] = audit
        MainActor.assumeIsolated {
            search.appliedResultIDs.insert(nudge.id)
        }
        pendingManualDrawNudge = nil
        undoManager?.setActionName("Add Nearby Match")
        return region
    }

    /// Set the per-search-session suppression flag. Called by the view
    /// layer after the toast is enqueued OR explicitly dismissed so a
    /// second qualifying manual-draw inside the same session does not
    /// re-spam the toast. Resets when the search session changes (the
    /// `activeSearch` didSet) or the document boundaries reset.
    func markManualDrawNudgeSuppressed() {
        manualDrawNudgeSuppressedForSession = true
        pendingManualDrawNudge = nil
    }

    /// Direct test hook — toggle the suppression flag without going
    /// through the `markManualDrawNudgeSuppressed` side effects. Lets
    /// `ManualDrawNudgeTests` flip the flag to true, then assert the
    /// three boundary resets clear it back to false.
    func setManualDrawNudgeSuppressedForTesting(_ value: Bool) {
        manualDrawNudgeSuppressedForSession = value
    }

    // MARK: - Full Reset

    /// Reset all state when the document is closed or a new document is imported.
    /// Must be called on .editing → .empty and .editing → .importing transitions.
    /// Extends clearOutput() to also clear regions, detections, triage state, and
    /// metadata — preventing PII (matchedText) from persisting in memory across documents.
    func clearAll() {
        regionVersion += 1
        // clearOutput() must be called FIRST so the published
        // `outputURL` is nil before any UI observer reacts to the regions
        // wipe. clearVerification() is decoupled from the
        // verified-current flag; clearAll is a full-document reset, so
        // we set the flag explicitly here — there are no regions left
        // after this method, so "regions modified since verification"
        // is logically false.
        clearOutput()
        regionsModifiedSinceVerification = false
        regions = [:]
        detectionResults = [:]
        selectedRegionIDs = []
        hoveredRegionID = nil
        let search = activeSearch
        activeSearch = nil
        MainActor.assumeIsolated { search?.cancelSearchWithoutAwait() }
        pendingTriage = nil
        triageSelections = [:]
        // Document close drops the detection-run record + promotion flag —
        // the banner must not describe a closed document's run.
        lastDetectionRun = nil
        triagePromotionOccurred = false
        // Drop any pending canvas-rationale request on document close
        // so a stale region UUID cannot present a blank rationale sheet.
        pendingCanvasRationaleRequest = nil
        regionMetadata = [:]
        // Audit is per-document-session only; never leaks across docs.
        appliedMatchAudit = [:]
        // Wipe surface forms, per-page
        // classification diagnostics, and ambiguous-surname flags on close.
        // Priors are saved BEFORE the wipe (the wipe
        // would otherwise store an empty history) and rehydrated from the
        // just-written payload so the next document in this app session
        // starts with the accumulated triage history, streaks reset.
        Self.savePriors(priors, defaults: priorsDefaults)
        priors = Self.loadPriors(defaults: priorsDefaults)
        surfaceForms = SurfaceFormDictionary()
        pageDiagnostics = [:]
        ocrPixelCapSkippedPages = []
        ambiguousSurnameDetectionIDs = []
        crossPageEntityGroups = []
        // Document close. The
        // `activeSearch = nil` assignment above already triggers the
        // didSet which resets the nudge flag; the explicit reset here
        // is defensive so a hypothetical future caller that clears
        // state without crossing the activeSearch boundary still
        // satisfies the contract.
        manualDrawNudgeSuppressedForSession = false
        pendingManualDrawNudge = nil
        // Also drop any pending magic-wand request so a
        // new-document / clearAll path doesn't inherit a stale term.
        pendingMagicWandRequest = nil
        invalidateRegionCaches()
        regionPageIndex.removeAll()
    }

    // MARK: - Undo Helper

    /// Register an undoable action. Under the app target's SE-0466 MainActor
    /// default, `RedactionState` — and this method — are MainActor
    /// isolated, as is `UndoManager.registerUndo` on iOS 26. The `handler` is
    /// typed `@MainActor` because every handler body mutates MainActor region
    /// state and re-registers the inverse action; they already executed on
    /// MainActor via the `assumeIsolated` wrappers below, so the annotation
    /// makes the type system agree without changing runtime behavior. The inner
    /// `MainActor.assumeIsolated` still bridges the iOS-26
    /// `registerUndo(withTarget:)` callback (whose handler is not statically
    /// MainActor-typed).
    private func registerUndo(
        _ undoManager: UndoManager?, _ actionName: String,
        handler: @escaping @MainActor (RedactionState) -> Void
    ) {
        guard let undoManager else { return }
        nonisolated(unsafe) let target = self
        MainActor.assumeIsolated {
            undoManager.registerUndo(withTarget: target) { target in
                MainActor.assumeIsolated {
                    handler(target)
                }
            }
            undoManager.setActionName(actionName)
        }
    }
}

// MARK: - Apply prepare helper

/// Sendable bundle returned by the detached `prepareApply` step.
struct PreparedApply: Sendable {
    let createdRegions: [Int: [RedactionRegion]]
    let createdMetadata: [UUID: RegionMetadata]
    let createdAudit: [UUID: MatchAuditSnapshot]
    let appliedCount: Int
    let skippedOverlaps: Int
    /// QW-1 (D06-F3) — the `SearchResult.id`s that actually produced a
    /// region this pass. Overlap-skipped results are absent, so the
    /// sheet's `appliedResultIDs` union (the green "applied" badge state)
    /// matches the audit-backed set instead of the full selection.
    let appliedResultIDs: Set<UUID>
}

/// Pure-function detached prepare step for the search origin of
/// `RedactionState.applyFindings`.
/// Runs the overlap rejection against a snapshot of existing region
/// rects per page and constructs the per-result region / metadata /
/// audit-snapshot trio. No actor state is read; the result is re-merged
/// on MainActor by the caller. File-level (not a static method) so the
/// detached task body captures no implicit `Self`, which keeps the
/// Swift 6 region-based isolation checker happy.
///
/// `nonisolated`: under the SE-0466 MainActor-default flip an unannotated
/// global function would become MainActor-isolated, but this is INTENTIONALLY
/// dispatched off MainActor via `Task.detached` (the search-origin apply) so a
/// large apply does not freeze the actor — so it must stay nonisolated. No
/// actor state is read; all inputs are Sendable snapshots passed by value.
nonisolated func prepareApply(
    selected: [SearchResult],
    existingRectsByPage: [Int: [CGRect]],
    appliedAt: Date
) -> PreparedApply {
    var createdRegions: [Int: [RedactionRegion]] = [:]
    var createdMetadata: [UUID: RegionMetadata] = [:]
    // Snapshot the rationale + category + matchedText at apply
    // time, before the live SearchResult is lost. Keyed by region.id.
    var createdAudit: [UUID: MatchAuditSnapshot] = [:]
    var skippedOverlaps = 0
    var appliedResultIDs: Set<UUID> = []

    for result in selected {
        // Skip results that overlap > 80% with existing regions.
        let existingRects = existingRectsByPage[result.pageIndex] ?? []
        let overlaps = existingRects.contains { existing in
            let intersection = result.normalizedRect.intersection(existing)
            guard !intersection.isNull else { return false }
            let overlapArea = intersection.width * intersection.height
            let resultArea = result.normalizedRect.width * result.normalizedRect.height
            return resultArea > 0 && overlapArea / resultArea > 0.8
        }
        if overlaps {
            skippedOverlaps += 1
            continue
        }

        // Thread the SearchResult rationale into
        // the region's Source so downstream surfaces (RegionInfoPopover
        // disclosure, canvas long-press action sheet, audit export) can
        // read it without re-querying MatchAuditSnapshot.
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: result.normalizedRect,
            source: .searchMatch(term: result.term, rationale: result.rationale)
        )
        createdRegions[result.pageIndex, default: []].append(region)
        appliedResultIDs.insert(result.id)

        let confidence: Double = switch result.source {
        case .textLayer: 1.0
        case .ocr(let conf): Double(conf)
        }
        // A PII-scan result carries its detected category —
        // stamp the region with it, so downstream surfaces (info popover,
        // long-press row, verifier term collection) see the category the
        // detector reported. Typed text/regex results have no category and
        // keep the search-match kind, where `term` is the user's query.
        let piiKind: DetectionResult.Kind = result.piiCategory
            .map { .pii($0.piiKind) } ?? .searchMatch(term: result.term)
        createdMetadata[region.id] = RegionMetadata(
            piiKind: piiKind,
            confidence: confidence,
            matchedText: result.matchedText,
            recognitionLevel: result.source == .textLayer ? .fast : .accurate
        )
        createdAudit[region.id] = MatchAuditSnapshot(
            origin: .search,
            resultID: result.id,
            regionID: region.id,
            pageIndex: result.pageIndex,
            matchedText: result.matchedText,
            source: result.source,
            piiCategory: result.piiCategory,
            piiConfidence: result.piiConfidence,
            rationale: result.rationale,
            term: result.term,
            appliedAt: appliedAt
        )
    }

    let appliedCount = createdRegions.values.reduce(0) { $0 + $1.count }
    return PreparedApply(
        createdRegions: createdRegions,
        createdMetadata: createdMetadata,
        createdAudit: createdAudit,
        appliedCount: appliedCount,
        skippedOverlaps: skippedOverlaps,
        appliedResultIDs: appliedResultIDs
    )
}

#if DEBUG
extension RedactionState {
    /// DEBUG-only review repro hook. Seeds `pendingTriage` (+ matching
    /// `triageSelections`, all-deselected per the review-first arrival rule) with a handful of
    /// synthetic `DetectionResult`s on page 0 so the unified review —
    /// the search sheet's Scan interface, opened by the
    /// `DocumentEditorView` bridge whenever `pendingTriage != nil` —
    /// can be reached on the Simulator WITHOUT running on-device
    /// detection (the Vision/Core-Graphics page-0 rasterize cannot be
    /// serviced on the sim). Invoked from the `--seedTriage` launch
    /// hook in `ResectaApp` (arg name carried from the triage era —
    /// it is test plumbing). Mirrors the real staging in
    /// `PipelineCoordinator.runDetectionPipeline`. Strictly
    /// `#if DEBUG` — no mock data ships in release.
    ///
    /// The synthetic strings below are fabricated test fixtures (not document
    /// content) chosen to span detection kinds and a confidence range so the
    /// review list, kind-filter chips, Select-Where, and "Apply N" are
    /// all exercised — including the review → Dismiss path this unblocks.
    func seedDebugTriage() {
        let mocks: [DetectionResult] = [
            DetectionResult(
                normalizedRect: CGRect(x: 0.12, y: 0.82, width: 0.34, height: 0.035),
                kind: .pii(.ssn), confidence: 0.97, matchedText: "123-45-6789"),
            DetectionResult(
                normalizedRect: CGRect(x: 0.12, y: 0.74, width: 0.30, height: 0.035),
                kind: .pii(.email), confidence: 0.93, matchedText: "j.doe@example.com"),
            DetectionResult(
                normalizedRect: CGRect(x: 0.12, y: 0.66, width: 0.26, height: 0.035),
                kind: .pii(.phone), confidence: 0.88, matchedText: "(555) 010-2934"),
            DetectionResult(
                normalizedRect: CGRect(x: 0.12, y: 0.58, width: 0.40, height: 0.035),
                kind: .pii(.name), confidence: 0.71, matchedText: "Jordan Avery"),
            DetectionResult(
                normalizedRect: CGRect(x: 0.12, y: 0.50, width: 0.38, height: 0.035),
                kind: .pii(.creditCard), confidence: 0.99, matchedText: "4111 1111 1111 1111"),
            // Second "Jordan Avery" so the Grouped view mode has a real
            // cluster — "Apply Group" (UXF-29) is drivable on the sim.
            DetectionResult(
                normalizedRect: CGRect(x: 0.52, y: 0.42, width: 0.40, height: 0.035),
                kind: .pii(.name), confidence: 0.83, matchedText: "Jordan Avery"),
        ]
        pendingTriage = [0: mocks]
        // Review-first arrival: seeded detections arrive all-DESELECTED
        // like every arrival — an empty map, since an absent id reads
        // as not accepted everywhere.
        triageSelections = [:]
        // Mirror the real staging path's sibling writes so the summary
        // banner (UXF-06), its Review re-entry, and the Grouped view mode
        // are all drivable on the Simulator: `detectionResults` backs the
        // banner's Review action, `crossPageEntityGroups` backs "Apply
        // Group", and the run record drives the banner itself.
        detectionResults = [0: mocks]
        crossPageEntityGroups = CrossPageEntityGroup.clusters(from: [0: mocks])
        recordDetectionRun(.staged)
    }
}
#endif
