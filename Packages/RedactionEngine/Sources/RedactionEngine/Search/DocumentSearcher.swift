import Foundation
import NaturalLanguage
import PDFKit
#if canImport(UIKit)
import UIKit
#else
import AppKit

// macOS tooling destination: PDFPage.thumbnail returns NSImage; mirror the
// UIImage.cgImage property so the shared call sites compile unchanged.
private extension NSImage {
    var cgImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
#endif

// SEARCH-AND-REDACT §3: Engine-layer document search with text-layer,
// regex, and OCR paths. Returns results via AsyncStream for progressive UI.

/// Performs text search across a PDF document with dual-path
/// (text layer + OCR) support.
///
/// Returns results via AsyncStream for progressive UI updates.
/// Cancellable via structured concurrency (Task.cancel()).
public actor DocumentSearcher {

    // MARK: - Configuration

    /// Maximum regex pattern length (ReDoS prevention — §S4).
    static let maxRegexPatternLength = 200

    /// Per-page regex timeout (§S4).
    static let perPageRegexTimeout: Duration = .seconds(5)

    /// WU-66 — per-instance test override for `perPageRegexTimeout`. Set via
    /// the optional `regexTimeoutOverride` init parameter; production code
    /// leaves it nil and the production constant applies. Marked
    /// `nonisolated let` so the nonisolated `previewRegex` can read it
    /// without an actor hop. Per-instance avoids the cross-test race a
    /// static override would expose.
    nonisolated let regexTimeoutOverride: Duration?

    /// Maximum results to accumulate (§9.5).
    public static let maxResults = 1000

    /// Maximum pixel dimension for OCR rendering (§S2 / ENGINE §2.5).
    /// Pages exceeding this in either axis are skipped for OCR to
    /// prevent multi-gigabyte bitmap allocations.
    private static let maxOCRPixelDimension: CGFloat = 10_000

    /// Total-pixel ceiling for OCR rendering. The per-axis cap above
    /// admits a 10000 × 10000 thumbnail (≈ 400 MB RGBA8) that can trip
    /// jetsam on memory-constrained devices; cap the product at ≈ 36 MP
    /// (≈ 144 MB RGBA8) so near-axis-cap pages are also skipped.
    private static let maxOCRPixelCount: CGFloat = 36_000_000

    // MARK: - Dependencies

    private let ocrEngine: OCREngine

    // Process-shared PIIDetector. The detector loads
    // two large name Bloom filters at construction; a fresh `PIIDetector()` per
    // DocumentSearcher (one per search session) repeated that heap load every
    // run. The static loads once per process and every searcher shares it:
    // PIIDetector is a stateless `Sendable` value, and its Bloom `Data` is
    // copy-on-write, so the buffer is shared rather than re-copied. Mirrors
    // `AddressSpatialAssembler.sharedAddressComponents`. The
    // `PIIDetector.loadWithDiagnostics()` path builds its own detector
    // explicitly and is unaffected by this cache.
    private static let sharedPIIDetector = PIIDetector()
    private let piiDetector = DocumentSearcher.sharedPIIDetector

    // B06 — Site-B / Search parity. The five scored families
    // {account, phone, mrn, ein, itin} now gate at Search on the SAME composed
    // posterior the detection path uses (DetectionOrchestrator.swift:432-446),
    // rather than on raw match.confidence. Both are `Sendable` value types,
    // constructed once at actor init and shared across pages — mirroring
    // DetectionOrchestrator.swift:176 / :180. `contextScorer` is whole-scorer
    // identity on any load problem (so an absent/garbled artifact reverts Search
    // to the raw-gated behavior); the installed artifact ships account/phone at
    // w_family 1 and mrn/ein/itin at w_family 0.
    private let calibratedScorer = CalibratedScorer()
    private let contextScorer = ContextScorerWeights.loadFromEngineBundle()
    // B06 — empty priors at Search (no triage history is threaded into a scan),
    // so `PerCategoryPriors().mean(category)` is 0.5 for every category ⇒
    // logit(prior) is 0 and priorMean floors to absorbingStateFloor only when the
    // category has accrued enough rejections elsewhere (it has not, at scan time).
    // Held as a stored value for parity with the orchestrator's `priors` local.
    private let searchPriors = PerCategoryPriors()

    // RC-4 — spatial address assembly on the Search legs. The orchestrator
    // has run `AddressSpatialAssembler` over per-line records since WS1 item
    // 1.6 (DetectionOrchestrator.detectPage Step 3a); both Search legs ran
    // only the flat single-line regex arms, so a multi-line address block
    // never became a Search candidate on either leg. The assembler is a
    // Sendable value whose gazetteer load is cached statically
    // (`AddressSpatialAssembler.sharedAddressComponents`), so per-searcher
    // construction is cheap. See `assembledAddressMatches(lines:haystack:)`.
    private let addressAssembler = AddressSpatialAssembler()

    // W4 — optional preset-threshold vector applied to PII matches before
    // conversion to SearchResult. nil preserves pre-W4 behavior (no gating).
    // Set via `setThresholdVector(_:)` before each search kickoff so the UI
    // layer can snapshot the user's current settings state.
    private var thresholdVector: PresetThresholdVector?

    // W3 / W-P — optional compiled user term index. nil (or an empty
    // index) leaves `.piiScan` behavior unchanged. Set via
    // `setUserTerms(_:)` alongside `setThresholdVector(_:)` before each
    // scan kickoff. W-P wraps the underlying `UserTermMatcher` in
    // `UserTermsIndex` so never-flag suppression can run pre-threshold
    // via `UserTermsIndex.merge(into:doctype:)`.
    private var userTermsIndex: UserTermsIndex?

    // W10 — optional sink for per-page cross-category overlap-suppressed
    // counts. Installed before a scan to route resolver output into the
    // app-layer CoverageReport aggregator. Runs after `piiDetector.detect`
    // and before threshold filtering, mirroring DetectionOrchestrator.
    private var overlapSink: (@Sendable ([PIICategory: Int]) -> Void)?

    // D06-F2 Part 1 — optional sink for the per-page count of matches dropped
    // for falling below their preset threshold (the raw-gate drops on `restText`
    // / `restOCR`). Fired beside `overlapSink` so the app-layer CoverageReport's
    // "below threshold" line is truthful instead of a hardcoded 0. Scored
    // families bypass the raw gate via `composedSurvivors`, so their posterior
    // drops are intentionally NOT counted here.
    private var belowThresholdSink: (@Sendable (Int) -> Void)?

    // WU-66 / [P2] — optional sink for per-page regex-timeout pages.
    // Fires once per page where the regex enumerator bails on the §S4
    // `perPageRegexTimeout` ceiling, in both the live-preview path
    // (`previewRegex`) and the full-scan path (`searchRegex`). The app
    // layer accumulates page indices to render the `R-35` timeout banner.
    private var regexTimeoutSink: (@Sendable (Int) -> Void)?

    // ST-83 — optional sink for per-page oversized-OCR-skip reporting.
    // Fires once per page whose 300-DPI render exceeds the OCR pixel caps
    // (`maxOCRPixelDimension` / `maxOCRPixelCount`) and is therefore never
    // OCR'd, in all three OCR entry paths (manual OCR search, PII scan,
    // regex OCR fallback). Reporting-only: the skip behavior itself is
    // unchanged. The app layer accumulates page indices to render the
    // OCR-skip banner alongside the R-35 regex-timeout banner.
    private var ocrSkipSink: (@Sendable (Int) -> Void)?

    // Package C — optional sink for per-page custom-terms always-flag
    // regex timeouts. Fires once per (page, user-authored pattern) when
    // `UserTermMatcher.alwaysFlagHits` reports the pattern bailed on the
    // `perPageRegexTimeout` ceiling. Separate from `regexTimeoutSink`
    // because the UX surface differs — saved-search regex timeouts route
    // to the R-35 banner (no pattern echo per RR-24); custom-terms
    // timeouts route to a `.warning` toast that includes the truncated
    // user-named pattern so the user can identify which list entry to
    // revise. Per-term-per-page semantics — the term remains active on
    // subsequent pages within the same scan. See REDACTION_ENGINE.md §9.4.
    private var userTermsTimeoutSink: (@Sendable (Int, String) -> Void)?

    // Per-page import-time text-layer classification, used to
    // decide whether the text-layer fast path is trustworthy. `.sparse` (a
    // header-only layer over a scanned body) and `.none` pages fall through to
    // the OCR path so scanned text is not silently suppressed. Supplied by the
    // production caller via `setTextLayerStatus(_:)` — the search UI holds a
    // long-lived `@State` searcher, so it installs status per kickoff like the
    // sinks above — or via the `init` parameter (used by tests
    // and any future fresh-construction caller). Default `[:]` ⇒ every page reads
    // as `.rich` (see `pageHasRichTextLayer`) ⇒ the pre-classification behavior, so callers
    // that don't supply status are unaffected.
    private var textLayerStatusByPage: [Int: TextLayerStatus]

    // Optional sink fired once per page that carries a scanned
    // region (`.sparse`/`.none`) left un-analyzed because `options.includeOCR`
    // is false, so its body text was not searched. The app layer surfaces the
    // "scanned region not analyzed" signal. Only trips when text-layer status is
    // supplied (production); absent-status callers (default `[:]`) never fire it.
    // Side-effect only — never changes which results are yielded.
    private var scannedRegionNotAnalyzedSink: (@Sendable (Int) -> Void)?

    // MARK: - Per-Session Caches

    private var ocrCache: [Int: [OCREngine.TextLine]] = [:]
    /// LRU access tracking for OCR cache eviction.
    private var ocrCacheAccess: [Int: Int] = [:]
    private var ocrAccessCounter: Int = 0

    // Plan Phase 2 / §G6 — parallel cache of normalized PII-scan inputs,
    // keyed identically to `ocrCache` and LRU-evicted in lockstep. The PII
    // path (`scanPagePIIViaOCR`) reads this cache; user text search
    // (`searchPageViaOCR`) continues reading verbatim `ocrCache`. Normalizer
    // runs once per page at cache-miss time; cached results stay authoritative.
    private struct NormalizedOCRPage {
        let concatenated: String
        let entries: [NormalizedLineEntry]
    }
    private struct NormalizedLineEntry {
        let start: Int
        let normalizedText: String
        let normalizedRect: CGRect
        let confidence: Float
    }
    private var ocrNormalizedConcat: [Int: NormalizedOCRPage] = [:]
    private let ocrNormalizer = OCRTextNormalizer()

    public init(
        ocrEngine: OCREngine = OCREngine(),
        regexTimeoutOverride: Duration? = nil,
        textLayerStatusByPage: [Int: TextLayerStatus] = [:]
    ) {
        self.ocrEngine = ocrEngine
        self.regexTimeoutOverride = regexTimeoutOverride
        self.textLayerStatusByPage = textLayerStatusByPage
    }

    /// Clear the OCR cache between search sessions.
    public func clearCache() {
        ocrCache.removeAll()
        ocrCacheAccess.removeAll()
        ocrNormalizedConcat.removeAll()
        ocrAccessCounter = 0
    }

    // MARK: - B06 Site-B posterior composition

    /// B06 — Site-B gate for the five scored families, composing the SAME
    /// posterior + learned-context term the detection path applies at
    /// DetectionOrchestrator.swift:432-446 + the W4 gate at :455-460.
    ///
    /// For each match whose category resolves to a vector cutoff:
    ///   finalConfidence = posterior(raw, priorMean, contextLogit)
    ///   priorMean       = max(searchPriors.mean(category), absorbingStateFloor)
    ///   contextLogit    = contextScorer.learnedContextLogit(family:, features:)
    /// and the match survives iff finalConfidence >= cutoff. Survivors get the
    /// identical rationale annotation `ThresholdFilter.applying` writes (the
    /// `.presetThresholdPass(raw:cutoff:)` signal keyed on the RAW confidence,
    /// plus `appliedThreshold`).
    ///
    /// A match with no vector cutoff (nil vector, or no entry for the category's
    /// wire name) passes through unchanged — the same fall-through
    /// `ThresholdFilter.applying` takes, so a non-gated scored family stays
    /// byte-identical to the raw path.
    ///
    /// DOCTYPE: `DocumentSearcher` carries no doctype (the text-layer merge runs
    /// with `doctype: nil`, Q9) and the search path has no classifier output to
    /// mirror Site-A's `effectiveDoctype`, so the feature builder is fed
    /// `.generic` for BOTH the `doctype` and `effectiveDoctype` parameters (the
    /// value the detection seam uses for an unknown doctype). The SAME value is
    /// passed to both params, mirroring the orchestrator passing `effectiveDoctype`
    /// to both. CONSEQUENCE: Site-B parity is exact for generic-doctype documents
    /// and for `account` (whose only non-zero weights are
    /// `nearest_positive_distance` / `digit_run_length`); for `phone` the trained
    /// doctype one-hots carry non-zero weight (e.g. `doctype_is_court` +1.11,
    /// `doctype_is_medical` -0.82), so a phone match on a court/medical/foia
    /// document composes a different posterior at Site B than at Site A. That is an
    /// accepted limitation of the doctype-blind search path, not a measured no-op.
    private func composedSurvivors(
        _ matches: [PIIDetector.PIIMatch],
        pageText: String
    ) -> [PIIDetector.PIIMatch] {
        Self.composedSurvivors(
            matches,
            pageText: pageText,
            thresholdVector: thresholdVector,
            calibratedScorer: calibratedScorer,
            contextScorer: contextScorer,
            priors: searchPriors
        )
    }

    /// Pure, dependency-injected core of `composedSurvivors`. Static so the
    /// observation-only test seam can drive it with a chosen scorer (identity
    /// vs the installed calibrated artifact) without an actor instance, and so
    /// production and the harness exercise the SAME composition code.
    static func composedSurvivors(
        _ matches: [PIIDetector.PIIMatch],
        pageText: String,
        thresholdVector: PresetThresholdVector?,
        calibratedScorer: CalibratedScorer,
        contextScorer: ContextScorerWeights,
        priors: PerCategoryPriors
    ) -> [PIIDetector.PIIMatch] {
        matches.compactMap { match in
            guard let category = match.category,
                  let cutoff = thresholdVector?.threshold(for: category)
            else { return match }

            let priorMean = max(priors.mean(category), DetectionOrchestrator.absorbingStateFloor)
            let wire = PresetThresholdVector.wireName(for: category) ?? ""
            let contextLogit = contextScorer.learnedContextLogit(
                family: wire,
                features: contextFeatures(
                    match: match,
                    doctype: .generic,
                    effectiveDoctype: .generic,
                    pageText: pageText
                )
            )
            // SRCH-S2 D02-scorer-posterior-F1/F2 — under-redaction posterior floor,
            // the Search-path twin of the Site-A (DetectionOrchestrator) seam. The
            // SAME raw-bar helper (DESIGN-DECISIONS DQ2), so a keyword-confirmed
            // account/phone the learned term collapsed is re-floored to the
            // preset-invariant conservative cutoff before the gate. Flooring at
            // BOTH seams keeps Auto-Detect and Search symmetric — leaving either
            // unfloored re-opens the leak on one path. The local `cutoff` stays the
            // ACTIVE-preset gate; the floor's source is the separate conservative
            // lookup. Pure code, no blob change. See ContextPosteriorFloor.
            let scored = calibratedScorer.posterior(
                raw: match.confidence,
                priorMean: priorMean,
                contextLogit: contextLogit
            )
            let finalConfidence = ContextPosteriorFloor.apply(
                scored,
                family: wire,
                raw: match.confidence,
                conservativeCutoff: ContextPosteriorFloor.conservativeCutoff(forWire: wire)
            )
            guard finalConfidence >= cutoff else { return nil }

            // The survival decision above is on the POSTERIOR (finalConfidence),
            // but the annotation records `.presetThresholdPass(raw:cutoff:)` keyed
            // on the RAW confidence (the same signal shape ThresholdFilter.applying
            // writes). For a scored family the posterior can carry a raw below the
            // cutoff over it, so this recorded `raw` may be < `cutoff` by design —
            // the audit trail's raw is pre-posterior, not the value that survived.
            guard let rationale = match.rationale else { return match }
            let annotated = rationale.with(
                appliedThreshold: cutoff,
                addingSignal: .presetThresholdPass(
                    raw: match.confidence, cutoff: cutoff
                )
            )
            return match.withRationale(annotated)
        }
    }

    // MARK: - RC-4 Spatial address assembly (both PII-scan legs)

    /// RC-4 — run spatial address assembly over per-line records and convert
    /// each `Assembled` into a `PIIDetector.PIIMatch`, mirroring
    /// `DetectionOrchestrator.detectPage` Step 3a: callers append the matches
    /// BEFORE `resolveOverlaps` so assembled candidates participate in overlap
    /// dedup and threshold gating exactly like the regex-arm matches (address
    /// is a non-scored family, so an assembled candidate rides the same raw
    /// `applying(thresholdVector:)` gate as the flat arms). Overlap resolution
    /// uses character ranges; an assembled candidate carries no range of its
    /// own, so the haystack is searched for the assembled text — a sentinel
    /// range past the end stands in when the text is not present verbatim
    /// (multi-line assemblies join with ", ", so the sentinel is the common
    /// case). The union rect is returned keyed by assembled text so
    /// SearchResult creation can use it in place of character-range geometry
    /// (the text-keyed lookup mirrors the orchestrator's `spatialRectByText`;
    /// duplicate assembled text on one page gracefully degrades to the first
    /// candidate's rect, as at Site A).
    private func assembledAddressMatches(
        lines: [OCREngine.TextLine],
        haystack: NSString
    ) -> (matches: [PIIDetector.PIIMatch], spatialRectByText: [String: CGRect]) {
        let assembled = addressAssembler.assemble(lines: lines)
        guard !assembled.isEmpty else { return ([], [:]) }

        var matches: [PIIDetector.PIIMatch] = []
        var spatialRectByText: [String: CGRect] = [:]
        let sentinelLocation = haystack.length
        for address in assembled {
            if spatialRectByText[address.text] == nil {
                spatialRectByText[address.text] = address.unionRect
            }
            let searchRange = NSRange(location: 0, length: sentinelLocation)
            let located = haystack.range(of: address.text, options: [], range: searchRange)
            let matchRange = located.location != NSNotFound
                ? located
                : NSRange(location: sentinelLocation, length: 0)
            matches.append(PIIDetector.PIIMatch(
                text: address.text,
                range: matchRange,
                kind: .address,
                confidence: address.confidence
            ))
        }
        return (matches, spatialRectByText)
    }

    // MARK: - Test Seams (internal, observation/seeding only)

    #if DEBUG
    internal var _testOCRCacheKeys: Set<Int> { Set(ocrCache.keys) }
    internal var _testOCRNormalizedConcatKeys: Set<Int> { Set(ocrNormalizedConcat.keys) }

    /// Seeds the three OCR caches with `occupiedCount` placeholder entries,
    /// inserted in ascending page-index order so the smallest index is the
    /// least-recently-used. Page indices equal to `skippingPageIndex` are
    /// skipped so a subsequent OCR pass on that page forces a miss + LRU
    /// eviction — driving the production eviction code path under test.
    internal func _testSeedOCRCacheForCoherence(
        skippingPageIndex: Int,
        occupiedCount: Int
    ) {
        ocrCache.removeAll()
        ocrCacheAccess.removeAll()
        ocrNormalizedConcat.removeAll()
        ocrAccessCounter = 0
        var added = 0
        var idx = 0
        while added < occupiedCount {
            if idx != skippingPageIndex {
                ocrAccessCounter += 1
                ocrCacheAccess[idx] = ocrAccessCounter
                ocrCache[idx] = []
                ocrNormalizedConcat[idx] = NormalizedOCRPage(concatenated: "", entries: [])
                added += 1
            }
            idx += 1
        }
    }

    /// Seeds the OCR cache with known lines for a specific page index,
    /// allowing tests to exercise search paths (text-mode OCR, regex OCR
    /// fallback) without invoking real Vision OCR on the simulator.
    /// The normalized-concat cache entry is NOT pre-seeded here (the PII
    /// path rebuilds it on demand; the text/regex paths do not read it).
    internal func _testSeedOCRLines(_ lines: [OCREngine.TextLine], forPageIndex pageIndex: Int) {
        ocrAccessCounter += 1
        ocrCacheAccess[pageIndex] = ocrAccessCounter
        ocrCache[pageIndex] = lines
        // Invalidate any stale normalized-concat entry so a subsequent PII
        // scan rebuilds it from the newly seeded raw lines.
        ocrNormalizedConcat.removeValue(forKey: pageIndex)
    }

    /// Test seam: base address of the copy-on-write-shared surname
    /// Bloom buffer behind this searcher's PIIDetector. Two searchers backed by
    /// the process-shared static detector report the SAME address (shared COW
    /// storage); per-instance detectors report different addresses. nil when the
    /// name gazetteer is absent from the bundle. `nonisolated` — reads only the
    /// immutable Sendable `piiDetector` let.
    nonisolated var _testNameBloomBufferAddress: Int? { piiDetector._testNameBloomBufferAddress }

    /// B06 — observation-only seam over the Site-B composition (the same
    /// `composedSurvivors` core production calls). The G8 Site-B parity harness
    /// drives this with a chosen scorer — `ContextScorerWeights.identity` for the
    /// w=0 identity control (composed-at-identity == raw), the installed bundle
    /// for the AFTER — so the harness exercises the production path rather than a
    /// re-implementation. `nonisolated static` (the core is pure / injected); it
    /// changes nothing on the actor. Mirrors the `_testSeed*` seams' contract:
    /// internal, DEBUG-only, no production caller.
    nonisolated static func _testComposeSiteB(
        _ matches: [PIIDetector.PIIMatch],
        pageText: String,
        thresholdVector: PresetThresholdVector?,
        scorer: ContextScorerWeights
    ) -> [PIIDetector.PIIMatch] {
        composedSurvivors(
            matches,
            pageText: pageText,
            thresholdVector: thresholdVector,
            calibratedScorer: CalibratedScorer(),
            contextScorer: scorer,
            priors: PerCategoryPriors()
        )
    }
    #endif

    /// W4 — install the threshold vector to apply on future PII scans.
    /// Pass nil to disable gating entirely (pre-W4 behavior).
    public func setThresholdVector(_ vector: PresetThresholdVector?) {
        self.thresholdVector = vector
    }

    /// W3 / W-P — install the user term index to apply on future PII
    /// scans. Pass nil (or an empty index) to disable user-term behavior.
    public func setUserTerms(_ index: UserTermsIndex?) {
        self.userTermsIndex = index
    }

    /// W10 — install a per-page overlap-suppressed-count sink. Pass nil
    /// to disable reporting. Called once per page where the resolver
    /// actually dropped at least one loser.
    public func setOverlapSink(_ sink: (@Sendable ([PIICategory: Int]) -> Void)?) {
        self.overlapSink = sink
    }

    /// D06-F2 Part 1 — install a per-page below-threshold-drop-count sink. Pass
    /// nil to disable reporting. Called once per page where the raw threshold
    /// gate dropped at least one match, mirroring `setOverlapSink`.
    public func setBelowThresholdSink(_ sink: (@Sendable (Int) -> Void)?) {
        self.belowThresholdSink = sink
    }

    /// WU-66 / [P2] — install a per-page regex-timeout sink. Pass nil to
    /// disable reporting. Fires once per page where the §S4 enumerator
    /// bails on the `perPageRegexTimeout` ceiling, in both `previewRegex`
    /// and `searchRegex` branches.
    public func setRegexTimeoutSink(_ sink: (@Sendable (Int) -> Void)?) {
        self.regexTimeoutSink = sink
    }

    /// ST-83 — install a per-page oversized-OCR-skip sink. Pass nil to
    /// disable reporting. Fires once per OCR attempt on a page whose
    /// render exceeds the OCR pixel caps, in all three OCR entry paths
    /// (manual OCR search, PII scan, regex OCR fallback). The consumer
    /// dedupes page indices (Set semantics), mirroring the regex-timeout
    /// sink's contract.
    public func setOCRSkipSink(_ sink: (@Sendable (Int) -> Void)?) {
        self.ocrSkipSink = sink
    }

    /// Package C — install a per-page custom-terms always-flag timeout
    /// sink. Pass nil to disable reporting. Fires once per (pageIndex,
    /// user-authored pattern) when `UserTermMatcher.alwaysFlagHits`
    /// reports a regex term whose enumeration bailed on the §S4
    /// `perPageRegexTimeout` ceiling during a `.piiScan` page loop.
    /// See REDACTION_ENGINE.md §9.4.
    public func setUserTermsTimeoutSink(_ sink: (@Sendable (Int, String) -> Void)?) {
        self.userTermsTimeoutSink = sink
    }

    /// Install the per-page text-layer classification consulted
    /// by all four search paths when choosing the text-layer vs. OCR route. The
    /// search UI installs this per kickoff from `documentState.textLayerStatus`
    /// because it holds a long-lived `@State` searcher (same lifecycle as the
    /// threshold vector and the sinks). Pass `[:]` to restore the default
    /// behavior (every page treated as `.rich`).
    public func setTextLayerStatus(_ status: [Int: TextLayerStatus]) {
        self.textLayerStatusByPage = status
    }

    /// Install the "scanned region not analyzed" sink. Fires
    /// once per page that carries a `.sparse`/`.none` region left un-analyzed
    /// because OCR was disabled for the scan. Pass nil to disable.
    public func setScannedRegionNotAnalyzedSink(_ sink: (@Sendable (Int) -> Void)?) {
        self.scannedRegionNotAnalyzedSink = sink
    }

    /// WU-66 — actor-isolated reader so the `nonisolated previewMatches`
    /// bridge can snapshot the sink before invoking `previewRegex`.
    private func currentRegexTimeoutSink() -> (@Sendable (Int) -> Void)? {
        regexTimeoutSink
    }

    // MARK: - Public API

    /// Search the document, yielding results progressively.
    ///
    /// - Parameters:
    ///   - document: The PDF to search (SendablePDFDocument wrapper).
    ///   - mode: Text, regex, or multi-term search.
    ///   - progress: Callback with (currentPage, totalPages).
    /// - Returns: AsyncStream of SearchResult, one per match.
    public nonisolated func search(
        _ document: SendablePDFDocument,
        mode: SearchMode,
        progress: @Sendable @escaping (Int, Int) -> Void
    ) -> AsyncStream<SearchResult> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: SearchResult.self,
            bufferingPolicy: .bufferingNewest(100)
        )

        let searcher = self
        let sendableDoc = document

        Task {
            await searcher.performSearch(
                sendableDoc, mode: mode,
                progress: progress, continuation: continuation
            )
        }

        return stream
    }

    // MARK: - W7 Live Preview

    /// W7 — total cap on live-preview match count. Above this we report
    /// `saturated` and stop counting. The full search has its own cap
    /// (`maxResults`) and is unaffected.
    public static let maxPreviewMatches = 10_000

    /// W7 — per-page cap on the highlighted ranges returned for the
    /// visible page. Bounds the overlay redraw cost on dense pages.
    public static let maxCurrentPageHighlights = 500

    /// W7 — fast-path counterpart to `search(...)`. Walks the requested
    /// scope, counts matches, and (for the visible page only) collects
    /// up to `maxCurrentPageHighlights` ranges so the overlay can render
    /// transient yellow rectangles before the full search completes.
    ///
    /// Behavior:
    /// - `.text` / `.regex` / `.multiTerm`: counts via the appropriate
    ///   matcher. Regex validation reuses `validateRegexPattern`.
    /// - `.piiScan`: not supported — returns an empty result.
    /// - Caller supplies a `pageTextProvider` that returns the page's
    ///   text-layer string (or nil to skip a page). Live preview never
    ///   pays the OCR cost.
    /// - Per-page work is bounded by `perPageRegexTimeout` (regex path)
    ///   and `Task.isCancelled` checks (all paths).
    public nonisolated func previewMatches(
        mode: SearchMode,
        scope: SearchPreviewScope,
        currentPageIndex: Int,
        totalPageCount: Int,
        pageTextProvider: @Sendable (Int) async -> String?
    ) async -> SearchPreviewResult {
        // Determine the page range to walk based on scope.
        let pageRange: [Int]
        switch scope {
        case .wholeDocument:
            pageRange = Array(0..<totalPageCount)
        case .currentPage(let idx):
            pageRange = (idx >= 0 && idx < totalPageCount) ? [idx] : []
        }

        // Extract pattern + options + decide which path to use.
        switch mode {
        case .piiScan:
            return SearchPreviewResult(
                mode: mode, scope: scope,
                totalCount: 0, saturated: false, regexInvalid: false,
                currentPageMatches: []
            )

        case .regex(let pattern, let options):
            guard let regex = Self.validateRegexPattern(pattern) else {
                return SearchPreviewResult(
                    mode: mode, scope: scope,
                    totalCount: 0, saturated: false, regexInvalid: true,
                    currentPageMatches: []
                )
            }
            let sink = await currentRegexTimeoutSink()
            return await previewRegex(
                regex: regex, options: options, mode: mode, scope: scope,
                pageRange: pageRange, currentPageIndex: currentPageIndex,
                pageTextProvider: pageTextProvider,
                timeoutSink: sink
            )

        case .text(let query, let options):
            guard !query.isEmpty else {
                return SearchPreviewResult(
                    mode: mode, scope: scope,
                    totalCount: 0, saturated: false, regexInvalid: false,
                    currentPageMatches: []
                )
            }
            return await previewLiteral(
                terms: [query], options: options, mode: mode, scope: scope,
                pageRange: pageRange, currentPageIndex: currentPageIndex,
                pageTextProvider: pageTextProvider
            )

        case .multiTerm(let terms, let options):
            let nonEmpty = terms.filter { !$0.isEmpty }
            guard !nonEmpty.isEmpty else {
                return SearchPreviewResult(
                    mode: mode, scope: scope,
                    totalCount: 0, saturated: false, regexInvalid: false,
                    currentPageMatches: []
                )
            }
            return await previewLiteral(
                terms: nonEmpty, options: options, mode: mode, scope: scope,
                pageRange: pageRange, currentPageIndex: currentPageIndex,
                pageTextProvider: pageTextProvider
            )
        }
    }

    private nonisolated func previewRegex(
        regex: NSRegularExpression,
        options: SearchOptions,
        mode: SearchMode,
        scope: SearchPreviewScope,
        pageRange: [Int],
        currentPageIndex: Int,
        pageTextProvider: @Sendable (Int) async -> String?,
        timeoutSink: (@Sendable (Int) -> Void)?
    ) async -> SearchPreviewResult {
        var totalCount = 0
        var currentPageMatches: [NSRange] = []
        var saturated = false

        for pageIndex in pageRange {
            if Task.isCancelled { break }
            guard let pageText = await pageTextProvider(pageIndex), !pageText.isEmpty else { continue }

            var searchText: String
            if options.normalizeUnicode {
                searchText = TextNormalizer.normalize(pageText)
            } else {
                searchText = pageText
            }
            // S7 / §4.4 — page-side smart punctuation (1:1, UTF-16
            // length-preserving, so emitted NSRanges stay valid). The
            // pattern itself is never transformed; see SearchOptions.
            if options.normalizeSmartPunctuation {
                searchText = TextNormalizer.normalizeSmartPunctuation(searchText)
            }

            let nsString = searchText as NSString
            let fullRange = NSRange(location: 0, length: nsString.length)
            let isVisiblePage = (pageIndex == currentPageIndex)
            let startTime = ContinuousClock.now
            let effectiveTimeout: Duration =
                regexTimeoutOverride ?? Self.perPageRegexTimeout

            // F-001 — `.reportProgress` parity with `searchRegex`: the
            // closure fires periodically during a long match attempt
            // so the timeout / cancellation check actually samples.
            regex.enumerateMatches(
                in: searchText,
                options: [.reportProgress],
                range: fullRange
            ) { match, _, stop in
                if Task.isCancelled || totalCount >= Self.maxPreviewMatches {
                    if totalCount >= Self.maxPreviewMatches { saturated = true }
                    stop.pointee = true
                    return
                }
                if ContinuousClock.now - startTime > effectiveTimeout {
                    // WU-66 / [P2] — preview-path timeout branch.
                    timeoutSink?(pageIndex)
                    stop.pointee = true
                    return
                }
                guard let match, match.range.location != NSNotFound else { return }

                if options.wholeWord, let swiftRange = Range(match.range, in: searchText) {
                    if !Self.previewIsWholeWord(swiftRange, in: searchText) { return }
                }

                totalCount += 1
                if isVisiblePage && currentPageMatches.count < Self.maxCurrentPageHighlights {
                    currentPageMatches.append(match.range)
                }
            }

            if saturated || totalCount >= Self.maxPreviewMatches {
                if totalCount >= Self.maxPreviewMatches { saturated = true }
                break
            }
        }

        return SearchPreviewResult(
            mode: mode, scope: scope,
            totalCount: totalCount,
            saturated: saturated,
            regexInvalid: false,
            currentPageMatches: currentPageMatches
        )
    }

    private nonisolated func previewLiteral(
        terms: [String],
        options: SearchOptions,
        mode: SearchMode,
        scope: SearchPreviewScope,
        pageRange: [Int],
        currentPageIndex: Int,
        pageTextProvider: @Sendable (Int) async -> String?
    ) async -> SearchPreviewResult {
        var totalCount = 0
        var currentPageMatches: [NSRange] = []
        var saturated = false

        let normalizedTerms: [String] = options.normalizeUnicode
            ? terms.map { TextNormalizer.normalizeForSearch($0, caseSensitive: options.caseSensitive) }
            : (options.caseSensitive ? terms : terms.map { $0.lowercased() })

        for pageIndex in pageRange {
            if Task.isCancelled { break }
            guard let pageText = await pageTextProvider(pageIndex), !pageText.isEmpty else { continue }

            let nfkcText: String
            if options.normalizeUnicode {
                nfkcText = TextNormalizer.normalizeForSearch(pageText, caseSensitive: options.caseSensitive)
            } else if !options.caseSensitive {
                nfkcText = pageText.lowercased()
            } else {
                nfkcText = pageText
            }

            // S7 / §4.4 — same extension pipeline as findTextMatches so
            // preview counts agree with the full search. Emitted ranges
            // are mapped back to base coordinates before they reach the
            // highlight-rect resolver (leak-class otherwise).
            let ext = TextNormalizer.applySearchExtensions(
                pageText: nfkcText, query: "", options: options
            )
            let searchText = ext.pageText
            let baseChars: [Character]? = ext.offsetMap != nil ? Array(ext.baseText) : nil

            let isVisiblePage = (pageIndex == currentPageIndex)
            let nsString = searchText as NSString
            let nsLength = nsString.length

            for term in normalizedTerms where !term.isEmpty {
                if Task.isCancelled { break }
                if totalCount >= Self.maxPreviewMatches { saturated = true; break }
                let extTerm = TextNormalizer.applySearchExtensions(
                    pageText: "", query: term, options: options
                ).query
                if extTerm.isEmpty { continue }

                var searchLocation = 0
                while searchLocation < nsLength {
                    if Task.isCancelled { break }
                    let searchRange = NSRange(location: searchLocation, length: nsLength - searchLocation)
                    let matchRange = nsString.range(of: extTerm, options: [.literal], range: searchRange)
                    if matchRange.location == NSNotFound { break }

                    // Map to base coordinates when a length-changing
                    // extension is active (Character-offset convention,
                    // same as findTextMatches).
                    var emitRange = matchRange
                    var baseBounds: (start: Int, endExclusive: Int)? = nil
                    if let map = ext.offsetMap, let swiftRange = Range(matchRange, in: searchText) {
                        let start = searchText.distance(from: searchText.startIndex, to: swiftRange.lowerBound)
                        let len = searchText.distance(from: swiftRange.lowerBound, to: swiftRange.upperBound)
                        guard len > 0, start < map.count, start + len - 1 < map.count else {
                            searchLocation = matchRange.location + max(matchRange.length, 1)
                            continue
                        }
                        let baseStart = map[start]
                        let baseEnd = map[start + len - 1] + 1
                        emitRange = NSRange(location: baseStart, length: baseEnd - baseStart)
                        baseBounds = (baseStart, baseEnd)
                    }

                    // DRAW-5 — magic-wand `exactMatch` gates the same
                    // live-preview word-boundary check as `wholeWord`.
                    // Base-coordinate variant when an offset map is active.
                    if options.wholeWord || options.exactMatch {
                        let isBoundaried: Bool
                        if let baseChars, let bounds = baseBounds {
                            isBoundaried = Self.isWholeWordInBase(
                                chars: baseChars, start: bounds.start, endExclusive: bounds.endExclusive
                            )
                        } else if let swiftRange = Range(matchRange, in: searchText) {
                            isBoundaried = Self.previewIsWholeWord(swiftRange, in: searchText)
                        } else {
                            isBoundaried = true
                        }
                        if !isBoundaried {
                            searchLocation = matchRange.location + max(matchRange.length, 1)
                            continue
                        }
                    }

                    totalCount += 1
                    if isVisiblePage && currentPageMatches.count < Self.maxCurrentPageHighlights {
                        currentPageMatches.append(emitRange)
                    }

                    if totalCount >= Self.maxPreviewMatches { saturated = true; break }
                    searchLocation = matchRange.location + max(matchRange.length, 1)
                }
            }
            if saturated { break }
        }

        return SearchPreviewResult(
            mode: mode, scope: scope,
            totalCount: totalCount,
            saturated: saturated,
            regexInvalid: false,
            currentPageMatches: currentPageMatches
        )
    }

    /// W7 — local whole-word check for the preview path. Mirrors the
    /// instance `isWholeWord` but is callable from nonisolated context.
    private nonisolated static func previewIsWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let charBefore = text[text.index(before: range.lowerBound)]
            if charBefore.isLetter || charBefore.isNumber || charBefore == "_" {
                return false
            }
        }
        if range.upperBound < text.endIndex {
            let charAfter = text[range.upperBound]
            if charAfter.isLetter || charAfter.isNumber || charAfter == "_" {
                return false
            }
        }
        return true
    }

    // MARK: - Search Dispatch

    /// Maximum OCR cache entries before eviction.
    private static let maxOCRCacheEntries = 50

    // MARK: - Text-layer routing

    /// Whether the page's import-time classification permits
    /// the text-layer fast path. `.rich` (or unknown — a page absent from the
    /// status map, including the default `[:]`) stays on the text layer;
    /// `.sparse`/`.none` fall through to OCR so a header-only layer over a
    /// scanned body cannot suppress the body text. See `TextLayerStatus`.
    private func pageHasRichTextLayer(_ pageIndex: Int) -> Bool {
        // Unwrap first: a page absent from the map (nil → unknown) takes the
        // text-layer fast path. Switching the Optional directly would bind a bare
        // `.none` to `Optional.none` rather than `TextLayerStatus.none`.
        guard let status = textLayerStatusByPage[pageIndex] else { return true }
        switch status {
        case .rich: return true
        case .sparse, .none: return false
        }
    }

    private func performSearch(
        _ document: SendablePDFDocument,
        mode: SearchMode,
        progress: @Sendable (Int, Int) -> Void,
        continuation: AsyncStream<SearchResult>.Continuation
    ) async {
        let doc = document.document
        let pageCount = doc.pageCount

        switch mode {
        case .text(let query, let options):
            await searchText(
                doc: doc, query: query, options: options,
                pageCount: pageCount, progress: progress,
                continuation: continuation
            )
        case .regex(let pattern, let options):
            await searchRegex(
                doc: doc, pattern: pattern, options: options,
                pageCount: pageCount, progress: progress,
                continuation: continuation
            )
        case .multiTerm(let terms, let options):
            await searchMultiTerm(
                doc: doc, terms: terms, options: options,
                pageCount: pageCount, progress: progress,
                continuation: continuation
            )
        case .piiScan(let categories, let options):
            await searchPII(
                doc: doc, categories: categories, options: options,
                pageCount: pageCount, progress: progress,
                continuation: continuation
            )
        }
    }

    // MARK: - Text Search (§3.1)

    private func searchText(
        doc: PDFDocument,
        query: String,
        options: SearchOptions,
        pageCount: Int,
        progress: @Sendable (Int, Int) -> Void,
        continuation: AsyncStream<SearchResult>.Continuation
    ) async {
        var totalYielded = 0

        for pageIndex in 0..<pageCount {
            if Task.isCancelled { break }
            // Yield between pages so queued actor setters
            // (sinks, thresholds, user-terms) can drain on every page boundary
            // instead of waiting for the full text scan to complete. Mirrors
            // the searchRegex per-page yield; the text-layer fast path has no
            // other await.
            await Task.yield()
            progress(pageIndex + 1, pageCount)

            guard let page = doc.page(at: pageIndex) else { continue }
            let pageText = page.string ?? ""

            if !pageText.isEmpty && pageHasRichTextLayer(pageIndex) {
                // Text-layer path
                let results = findTextMatches(
                    pageText: pageText, query: query, options: options,
                    page: page, pageIndex: pageIndex, term: query
                )
                for result in results {
                    if totalYielded >= Self.maxResults { break }
                    continuation.yield(result)
                    totalYielded += 1
                }
            } else if options.includeOCR {
                // OCR fallback path (§3.2) — page has no usable text layer
                // (empty, or a `.sparse`/`.none` layer over a scanned body)
                let ocrResults = await searchPageViaOCR(
                    page: page, pageIndex: pageIndex,
                    query: query, options: options, term: query
                )
                for result in ocrResults {
                    if totalYielded >= Self.maxResults { break }
                    continuation.yield(result)
                    totalYielded += 1
                }
            } else if !pageHasRichTextLayer(pageIndex) {
                // Scanned region (`.sparse`/`.none`) with OCR
                // disabled: its body text was not analyzed. Surface the signal.
                scannedRegionNotAnalyzedSink?(pageIndex)
            }

            if totalYielded >= Self.maxResults { break }
        }

        continuation.finish()
    }

    // MARK: - Regex Search (§3.3)

    /// Validate a regex pattern for safety before execution.
    /// Returns the compiled regex or nil if the pattern is unsafe.
    /// S6 / 4.7: thin wrapper over `validateRegexPatternWithError` so the
    /// two entry points share one rule set and cannot drift.
    public static func validateRegexPattern(_ pattern: String) -> NSRegularExpression? {
        try? validateRegexPatternWithError(pattern)
    }

    /// Throwing variant that preserves WHY a
    /// pattern was rejected, so the sheet can surface the engine's
    /// `NSRegularExpression` NSError verbatim
    /// (`SearchToolbarSection+Contracts.swift` already promises it).
    ///
    /// Sync entry point gates ad-hoc trigger, compose
    /// sub-mode, custom-terms editor, and saved-regex compile via a
    /// single check. `hasNestedQuantifiers` only spots `(x+)+` shape;
    /// `RegexSafetyPrecheck` additionally rejects unbounded
    /// group-quantifiers over alternation (e.g. `(a|aa)*b`,
    /// `(ab|abc)*xyz`) that compile cleanly but backtrack
    /// catastrophically. The async `RegexSentinelCheck.validate`
    /// adds a sentinel-string runtime probe at compose-execution
    /// and profile-import time on top of this.
    public static func validateRegexPatternWithError(_ pattern: String) throws -> NSRegularExpression {
        // §S4: Pattern length cap
        guard pattern.count <= maxRegexPatternLength else {
            throw RegexValidationError.patternTooLong(maxLength: maxRegexPatternLength)
        }

        if RegexSafetyPrecheck.isLikelyPathological(pattern) {
            throw RegexValidationError.likelyPathological
        }

        // §S4: Nested quantifier rejection — heuristic for catastrophic backtracking.
        // Reject patterns like (a+)+, (.*)+, (a{2,})*
        if hasNestedQuantifiers(pattern) {
            throw RegexValidationError.nestedQuantifiers
        }

        // Attempt compilation; an engine rejection propagates as the
        // system NSError whose localizedDescription the sheet surfaces.
        // Note: case sensitivity handled via text normalization, not regex flags
        return try NSRegularExpression(pattern: pattern)
    }

    /// Detect nested quantifiers that risk catastrophic backtracking.
    /// Matches patterns like (group-with-quantifier)quantifier.
    private static func hasNestedQuantifiers(_ pattern: String) -> Bool {
        // Find groups containing quantifiers, followed by quantifiers
        var depth = 0
        var groupHasQuantifier = [false]
        let chars = Array(pattern)

        for i in 0..<chars.count {
            switch chars[i] {
            case "(":
                // Skip escaped literal parens — not capture groups
                if i > 0 && chars[i - 1] == "\\" { continue }
                depth += 1
                groupHasQuantifier.append(false)
            case ")":
                if i > 0 && chars[i - 1] == "\\" { continue }
                let groupHadQuantifier = groupHasQuantifier.last ?? false
                if depth > 0 {
                    groupHasQuantifier.removeLast()
                    depth -= 1
                }
                // Check if the closing paren is followed by a quantifier
                if groupHadQuantifier {
                    let next = i + 1 < chars.count ? chars[i + 1] : Character(" ")
                    if next == "*" || next == "+" || next == "{" || next == "?" {
                        return true
                    }
                }
            case "*", "+", "?":
                // Skip if escaped
                if i > 0 && chars[i - 1] == "\\" { continue }
                if depth > 0 {
                    groupHasQuantifier[groupHasQuantifier.count - 1] = true
                }
            case "{":
                if i > 0 && chars[i - 1] == "\\" { continue }
                if depth > 0 {
                    groupHasQuantifier[groupHasQuantifier.count - 1] = true
                }
            default:
                break
            }
        }
        return false
    }

    private func searchRegex(
        doc: PDFDocument,
        pattern: String,
        options: SearchOptions,
        pageCount: Int,
        progress: @Sendable (Int, Int) -> Void,
        continuation: AsyncStream<SearchResult>.Continuation
    ) async {
        guard let regex = Self.validateRegexPattern(pattern) else {
            continuation.finish()
            return
        }

        var totalYielded = 0
        // WU-66 / [P2] — snapshot the sink for the synchronous
        // `regex.enumerateMatches` closure; reading `self.regexTimeoutSink`
        // inside the closure would re-enter actor isolation.
        let timeoutSink = self.regexTimeoutSink

        for pageIndex in 0..<pageCount {
            if Task.isCancelled { break }
            // Yield between pages so queued actor setters (sinks, thresholds,
            // user-terms) can drain on every page boundary instead of waiting
            // for the full regex scan to complete.
            await Task.yield()
            progress(pageIndex + 1, pageCount)

            guard let page = doc.page(at: pageIndex) else { continue }
            let pageText = page.string ?? ""
            guard !pageText.isEmpty && pageHasRichTextLayer(pageIndex) else {
                // Mirror the text-search OCR fallback:
                // when a page has no usable text layer (empty, or a `.sparse`/
                // `.none` layer over a scanned body) and the caller has opted
                // into OCR, run the regex against OCR-extracted and
                // confusable-normalized text.
                if options.includeOCR {
                    let ocrResults = await searchPageViaOCRFallback_regex(
                        page: page, pageIndex: pageIndex,
                        pattern: pattern, options: options
                    )
                    for result in ocrResults {
                        if totalYielded >= Self.maxResults { break }
                        continuation.yield(result)
                        totalYielded += 1
                    }
                    if totalYielded >= Self.maxResults { break }
                } else if !pageHasRichTextLayer(pageIndex) {
                    // Scanned region with OCR disabled: not
                    // analyzed. Surface the signal.
                    scannedRegionNotAnalyzedSink?(pageIndex)
                }
                continue
            }

            // PDFPage isn't Sendable; the `enumerateMatches` closure below
            // captures the page reference and the compiler (Swift 6.2 / Xcode
            // 26.3 on CI) flags it. enumerateMatches invokes the closure
            // synchronously per match on the current thread, so the capture
            // is treated as @unchecked Sendable via the wrapper.
            let sendablePage = SendablePDFPage(page)

            var searchText: String
            if options.normalizeUnicode {
                searchText = TextNormalizer.normalize(pageText)
            } else {
                searchText = pageText
            }
            // S7 / §4.4 — page-side smart punctuation only (1:1, UTF-16
            // length-preserving, so match NSRanges still index the page
            // correctly). The pattern is never transformed, and the
            // length-changing extensions are excluded from regex paths;
            // see SearchOptions.
            if options.normalizeSmartPunctuation {
                searchText = TextNormalizer.normalizeSmartPunctuation(searchText)
            }

            let nsString = searchText as NSString
            let fullRange = NSRange(location: 0, length: nsString.length)

            // §S4: enumerateMatches with per-match time check — allows bailing
            // mid-enumeration instead of waiting for all matches to complete.
            // F-001 — `.reportProgress` lets the engine invoke the closure
            // between match-attempt iterations even when no match has been
            // found, so the timeout / cancellation check below fires on
            // long-running alternation walks instead of waiting for the
            // next match. Catastrophic backtracking inside a single
            // match attempt still blocks the synchronous C call;
            // validation in `validateRegexPattern` remains the primary
            // defense.
            let startTime = ContinuousClock.now
            let effectiveTimeout: Duration =
                regexTimeoutOverride ?? Self.perPageRegexTimeout
            regex.enumerateMatches(
                in: searchText,
                options: [.reportProgress],
                range: fullRange
            ) { match, _, stop in
                if Task.isCancelled || totalYielded >= Self.maxResults {
                    stop.pointee = true
                    return
                }
                if ContinuousClock.now - startTime > effectiveTimeout {
                    // WU-66 / [P2] — search-path timeout branch.
                    timeoutSink?(pageIndex)
                    stop.pointee = true
                    return
                }

                guard let match, match.range.location != NSNotFound else { return }
                let matchRange = match.range

                // Whole-word check
                if options.wholeWord {
                    guard let swiftRange = Range(matchRange, in: searchText) else { return }
                    if !isWholeWord(swiftRange, in: searchText) {
                        return
                    }
                }

                if let normalizedRect = boundingRect(for: matchRange, page: sendablePage.page) {
                    let matchedText = nsString.substring(with: matchRange)
                    let snippet = contextSnippet(
                        text: searchText,
                        matchNSRange: matchRange
                    )

                    continuation.yield(SearchResult(
                        pageIndex: pageIndex,
                        normalizedRect: normalizedRect,
                        matchedText: matchedText,
                        contextSnippet: snippet,
                        source: .textLayer,
                        term: pattern
                    ))
                    totalYielded += 1
                }
            }

            if totalYielded >= Self.maxResults { break }
        }

        continuation.finish()
    }

    // MARK: - Multi-Term Search (§3.4)

    private func searchMultiTerm(
        doc: PDFDocument,
        terms: [String],
        options: SearchOptions,
        pageCount: Int,
        progress: @Sendable (Int, Int) -> Void,
        continuation: AsyncStream<SearchResult>.Continuation
    ) async {
        // Design 04 §4.5 — AND mode requires accumulate-then-filter-then-stream.
        // OR mode (default) streams results directly as before (zero behavior change).
        if options.multiTermConjunction {
            // Accumulation phase: collect all per-term results up to maxResults.
            // Peak memory is bounded by the existing cap — no page-streaming
            // variant is needed (design §4.5 memory note).
            var accumulated: [SearchResult] = []

            for pageIndex in 0..<pageCount {
                if Task.isCancelled || accumulated.count >= Self.maxResults { break }
                // Per-page yield (mirrors searchRegex) so
                // queued actor setters drain on each page boundary; the .rich
                // text-layer arm otherwise holds the actor for the whole document.
                await Task.yield()
                progress(pageIndex + 1, pageCount)

                guard let page = doc.page(at: pageIndex) else { continue }
                let pageText = page.string ?? ""
                // Text-layer fast path only for `.rich`/unknown
                // pages; `.sparse`/`.none` fall through to OCR per term.
                let useTextLayer = !pageText.isEmpty && pageHasRichTextLayer(pageIndex)

                for term in terms {
                    if Task.isCancelled || accumulated.count >= Self.maxResults { break }

                    if useTextLayer {
                        let hits = findTextMatches(
                            pageText: pageText, query: term, options: options,
                            page: page, pageIndex: pageIndex, term: term
                        )
                        for hit in hits {
                            if accumulated.count >= Self.maxResults { break }
                            accumulated.append(hit)
                        }
                    } else if options.includeOCR {
                        let ocrHits = await searchPageViaOCR(
                            page: page, pageIndex: pageIndex,
                            query: term, options: options, term: term
                        )
                        for hit in ocrHits {
                            if accumulated.count >= Self.maxResults { break }
                            accumulated.append(hit)
                        }
                    }
                }
                // Scanned region (`.sparse`/`.none`) with OCR
                // off: not analyzed. Fire once per page, after all terms.
                if !pageHasRichTextLayer(pageIndex) && !options.includeOCR {
                    scannedRegionNotAnalyzedSink?(pageIndex)
                }
            }

            // Conjunction filter: retain only pages where every term has
            // at least one result. Design 04 §4.5 snippet.
            let allTerms = Set(terms)
            let pageResults = Dictionary(grouping: accumulated, by: \.pageIndex)
            let conjunctPages = pageResults.filter { _, pageHits in
                let termsOnPage = Set(pageHits.map(\.term))
                return allTerms.isSubset(of: termsOnPage)
            }
            let filteredResults = accumulated.filter { conjunctPages[$0.pageIndex] != nil }

            for result in filteredResults {
                continuation.yield(result)
            }

            continuation.finish()
            return
        }

        // OR mode: stream results directly as terms match, page-first.
        // This arm is unchanged from the pre-AND-mode implementation.
        var totalYielded = 0

        // Page-first iteration: load each page once, search all terms.
        // Fixes progress resetting per-term and improves text locality.
        for pageIndex in 0..<pageCount {
            if Task.isCancelled || totalYielded >= Self.maxResults { break }
            // Per-page yield (mirrors searchRegex) so
            // queued actor setters drain on each page boundary.
            await Task.yield()
            progress(pageIndex + 1, pageCount)

            guard let page = doc.page(at: pageIndex) else { continue }
            let pageText = page.string ?? ""
            // Text-layer fast path only for `.rich`/unknown
            // pages; `.sparse`/`.none` fall through to OCR per term.
            let useTextLayer = !pageText.isEmpty && pageHasRichTextLayer(pageIndex)

            for term in terms {
                if Task.isCancelled || totalYielded >= Self.maxResults { break }

                if useTextLayer {
                    let results = findTextMatches(
                        pageText: pageText, query: term, options: options,
                        page: page, pageIndex: pageIndex, term: term
                    )
                    for result in results {
                        if totalYielded >= Self.maxResults { break }
                        continuation.yield(result)
                        totalYielded += 1
                    }
                } else if options.includeOCR {
                    let ocrResults = await searchPageViaOCR(
                        page: page, pageIndex: pageIndex,
                        query: term, options: options, term: term
                    )
                    for result in ocrResults {
                        if totalYielded >= Self.maxResults { break }
                        continuation.yield(result)
                        totalYielded += 1
                    }
                }
            }
            // Scanned region (`.sparse`/`.none`) with OCR off:
            // not analyzed. Fire once per page, after all terms.
            if !pageHasRichTextLayer(pageIndex) && !options.includeOCR {
                scannedRegionNotAnalyzedSink?(pageIndex)
            }
        }

        continuation.finish()
    }

    // MARK: - PII Scan (§4 bridge)

    /// Scan the document for PII patterns using PIIDetector.
    /// Text-layer first with OCR fallback, same as text search.
    /// Each PIIMatch is converted to a SearchResult with category and confidence.
    private func searchPII(
        doc: PDFDocument,
        categories: Set<PIICategory>,
        options: SearchOptions,
        pageCount: Int,
        progress: @Sendable (Int, Int) -> Void,
        continuation: AsyncStream<SearchResult>.Continuation
    ) async {
        var totalYielded = 0

        for pageIndex in 0..<pageCount {
            if Task.isCancelled || totalYielded >= Self.maxResults { break }
            progress(pageIndex + 1, pageCount)

            guard let page = doc.page(at: pageIndex) else { continue }
            let pageText = page.string ?? ""

            if !pageText.isEmpty && pageHasRichTextLayer(pageIndex) {
                // Text-layer path: run PIIDetector on extracted text,
                // then map NSRange → bounding rect via PDFKit selection.
                var rawMatches = await piiDetector.detect(in: pageText, categories: categories)
                // RC-4 — spatial address assembly on the text leg. The line
                // records come from `EmbeddedTextSource.make` — the SAME
                // provider the orchestrator's PERF-4 embedded fast path feeds
                // the assembler (word enumeration → per-word selection bounds
                // → y-bucketed lines, displayed-space normalized, CND-02) —
                // so Search and the detection path see identical line
                // geometry for the same page.
                var spatialRectByText: [String: CGRect] = [:]
                if categories.contains(.address),
                   let embedded = EmbeddedTextSource.make(from: page) {
                    let assembly = assembledAddressMatches(
                        lines: embedded.lines, haystack: pageText as NSString)
                    rawMatches.append(contentsOf: assembly.matches)
                    spatialRectByText = assembly.spatialRectByText
                }
                // W10 — cross-category overlap resolution before threshold
                // filter, mirroring DetectionOrchestrator.detectPage.
                let resolution = DetectionOrchestrator.resolveOverlaps(rawMatches)
                if !resolution.suppressedCountByCategory.isEmpty {
                    overlapSink?(resolution.suppressedCountByCategory)
                }
                // W-P — never-flag suppression runs BEFORE threshold filter
                // so suppressed matches don't compete in the threshold vote
                // (§D16 = P1, user always wins). V1 flat-N1 passes
                // `doctype: nil` per Q9; the parameter is reserved for V1.1+.
                let merged = userTermsIndex?.merge(
                    into: resolution.surviving, doctype: nil
                ) ?? resolution.surviving
                // B06 — Site-B parity. Partition, then gate (Option A): the five
                // scored families route through the composed posterior; every
                // other family keeps the raw `applying(thresholdVector:)` path
                // byte-for-byte. Text feature source is `pageText` (in scope). The
                // recombined survivors are re-sorted by position so the result list
                // and J/K navigation keep the positional order resolveOverlaps
                // produced — the partition alone groups non-scored ahead of scored.
                let (scoredText, restText) = merged.partitionedByScoredFamily()
                // D06-F2 Part 1 — count the raw-gate below-threshold drops on the
                // text path and fire the sink (mirrors the overlapSink guard
                // above). Only `restText` is gated by `applying(...)`; the scored
                // families flow through `composedSurvivors` and are intentionally
                // NOT counted here (their posterior drops are a separate concern).
                let gatedText = restText.applyingCountingDrops(thresholdVector: thresholdVector)
                if gatedText.droppedBelowThreshold > 0 {
                    belowThresholdSink?(gatedText.droppedBelowThreshold)
                }
                let matches = (gatedText.survivors
                    + composedSurvivors(scoredText, pageText: pageText))
                    .sorted { $0.range.location < $1.range.location }
                for match in matches {
                    if Task.isCancelled || totalYielded >= Self.maxResults { break }

                    // RC-4 — an assembled spatial survivor uses the stored
                    // union rect: its range is either the sentinel (no
                    // selection exists) or the located anchor text (whose
                    // selection would cover only part of the block). Every
                    // other match keeps PDFKit selection geometry unchanged.
                    let normalizedRect: CGRect
                    if let spatialRect =
                        (match.kind == .address ? spatialRectByText[match.text] : nil) {
                        normalizedRect = spatialRect
                    } else if let charRect = boundingRect(for: match.range, page: page) {
                        normalizedRect = charRect
                    } else {
                        continue
                    }
                    // Sentinel-ranged assembly (zero length): the joined
                    // block is its own context. Regex/detector matches always
                    // carry a non-empty range and keep the ±20-char snippet.
                    let snippet = match.range.length > 0
                        ? contextSnippet(text: pageText, matchNSRange: match.range)
                        : match.text

                    continuation.yield(SearchResult(
                        pageIndex: pageIndex,
                        normalizedRect: normalizedRect,
                        matchedText: match.text,
                        contextSnippet: snippet,
                        source: .textLayer,
                        term: match.category?.rawValue ?? "PII",
                        piiCategory: match.category,
                        piiConfidence: match.confidence,
                        rationale: match.rationale
                    ))
                    totalYielded += 1
                }

                // W3 — always-flag synthetic hits. Emitted after detector
                // survivors; downstream `applySearchResults` 80% overlap
                // dedup collapses any collision with a detector-emitted
                // hit at the same range. W-P preserves this path verbatim —
                // by-design post-threshold so synthetic matches always
                // emit regardless of the detector's score for the same text.
                if let matcher = userTermsIndex?.underlyingMatcher, !matcher.alwaysFlag.isEmpty {
                    let alwaysFlagResult = matcher.alwaysFlagHits(
                        in: pageText,
                        timeoutOverride: regexTimeoutOverride
                    )
                    for hit in alwaysFlagResult.hits {
                        if Task.isCancelled || totalYielded >= Self.maxResults { break }
                        guard let normalizedRect = boundingRect(for: hit.range, page: page) else { continue }
                        let ns = pageText as NSString
                        let matchedText = ns.substring(with: hit.range)
                        let snippet = contextSnippet(
                            text: pageText, matchNSRange: hit.range
                        )
                        continuation.yield(SearchResult(
                            pageIndex: pageIndex,
                            normalizedRect: normalizedRect,
                            matchedText: matchedText,
                            contextSnippet: snippet,
                            source: .textLayer,
                            term: "Custom",
                            piiCategory: nil,
                            piiConfidence: nil,
                            rationale: MatchRationale(
                                ruleID: "user.alwaysFlag",
                                signals: [.userAlwaysFlag(pattern: hit.pattern)],
                                preThresholdScore: 1.0,
                                finalScore: 1.0,
                                appliedThreshold: nil
                            )
                        ))
                        totalYielded += 1
                    }
                    // Package C — surface per-(page, pattern) timeouts so the
                    // app layer can enqueue the §9.4 custom-terms-skip toast.
                    if let sink = userTermsTimeoutSink {
                        for pattern in alwaysFlagResult.timedOutPatterns {
                            sink(pageIndex, pattern)
                        }
                    }
                }
            } else if options.includeOCR {
                // OCR fallback: render page, OCR, then run PIIDetector on OCR text.
                let ocrResults = await scanPagePIIViaOCR(
                    page: page, pageIndex: pageIndex,
                    categories: categories
                )
                for result in ocrResults {
                    if totalYielded >= Self.maxResults { break }
                    continuation.yield(result)
                    totalYielded += 1
                }
            } else if !pageHasRichTextLayer(pageIndex) {
                // Scanned region (`.sparse`/`.none`) with OCR
                // disabled: PII in the scanned body was not analyzed.
                scannedRegionNotAnalyzedSink?(pageIndex)
            }
        }

        continuation.finish()
    }

    /// Run PII detection on a page via OCR when no text layer is available.
    /// Concatenates OCR lines into a single text block, runs PIIDetector,
    /// then maps match ranges back to OCR line bounding boxes.
    /// OCR render size for `page.thumbnail(of:for:.cropBox)`.
    ///
    /// Uses the page's DISPLAYED (effective, rotation-
    /// swapped) dimensions. `thumbnail(of:for:.cropBox)` renders the rotation-
    /// applied page and aspect-fits it into the requested size; an unrotated-dims
    /// request on a /Rotate 90/270 page has the transposed aspect, so PDFKit
    /// letterboxes the render and every Vision `normalizedRect` is shifted off
    /// displayed space — the derived redaction region then misses the text. The
    /// W↔H swap leaves the pixel budget (`maxOCRPixelDimension` /
    /// `maxOCRPixelCount`) unchanged, so each call site's memory guard is
    /// unaffected. Mirrors the effective-dims normalization in
    /// `boundingRect(for:page:)`.
    static func ocrThumbnailSize(pageBounds: CGRect, rotation: Int) -> CGSize {
        let scale: CGFloat = 300.0 / 72.0  // 72 DPI → 300 DPI
        let effective = effectiveBounds(pageBounds, rotation: rotation).size
        return CGSize(width: effective.width * scale, height: effective.height * scale)
    }

    private func scanPagePIIViaOCR(
        page: PDFPage,
        pageIndex: Int,
        categories: Set<PIICategory>
    ) async -> [SearchResult] {
        // Render and OCR the page (reuses OCR cache)
        let textLines: [OCREngine.TextLine]
        if let cached = ocrCache[pageIndex] {
            ocrAccessCounter += 1
            ocrCacheAccess[pageIndex] = ocrAccessCounter
            textLines = cached
        } else {
            let pageBounds = page.bounds(for: .cropBox)
            let thumbnailSize = Self.ocrThumbnailSize(
                pageBounds: pageBounds, rotation: page.rotation)
            let pixelCount = thumbnailSize.width * thumbnailSize.height
            guard thumbnailSize.width <= Self.maxOCRPixelDimension,
                  thumbnailSize.height <= Self.maxOCRPixelDimension,
                  pixelCount <= Self.maxOCRPixelCount else {
                // ST-83 — report the skip so the app layer can tell the
                // user this page's image content was never text-scanned.
                ocrSkipSink?(pageIndex)
                return []
            }

            // Render off-actor — page.thumbnail is synchronous PDFKit and
            // can take seconds on a near-cap page. Holding the actor for
            // that span starves queued setters (sinks, thresholds).
            let sendablePage = SendablePDFPage(page)
            let thumbnail = await Task.detached(priority: .userInitiated) {
                sendablePage.page.thumbnail(of: thumbnailSize, for: .cropBox)
            }.value
            guard let cgImage = thumbnail.cgImage else { return [] }

            do {
                let lines = try await ocrEngine.recognizeText(
                    in: cgImage, recognitionLevel: .accurate
                )
                evictOCRCacheIfNeeded()
                ocrAccessCounter += 1
                ocrCacheAccess[pageIndex] = ocrAccessCounter
                ocrCache[pageIndex] = lines
                textLines = lines
            } catch {
                return []
            }
        }

        guard !textLines.isEmpty else { return [] }

        // Plan Phase 2 / §G6 — PII detection reads the normalized parallel
        // cache, not verbatim Vision output. On miss, run OCRTextNormalizer
        // per line and record offsets against the normalized concatenation.
        let normalizedPage: NormalizedOCRPage
        if let cached = ocrNormalizedConcat[pageIndex] {
            normalizedPage = cached
        } else {
            var concat = ""
            var entries: [NormalizedLineEntry] = []
            entries.reserveCapacity(textLines.count)
            for line in textLines {
                let normalized = ocrNormalizer.normalize(line.text)
                entries.append(NormalizedLineEntry(
                    start: concat.count,
                    normalizedText: normalized,
                    normalizedRect: line.normalizedRect,
                    confidence: line.confidence
                ))
                concat += normalized + "\n"
            }
            normalizedPage = NormalizedOCRPage(concatenated: concat, entries: entries)
            ocrNormalizedConcat[pageIndex] = normalizedPage
        }
        let concatenated = normalizedPage.concatenated
        let lineOffsets = normalizedPage.entries

        var rawMatches = await piiDetector.detect(in: concatenated, categories: categories)
        // RC-4 — spatial address assembly on the OCR leg, over the SAME
        // normalized per-line records the detector text was built from (the
        // assembler header's long-documented Search-leg rewire). Injected
        // before resolveOverlaps, mirroring the text leg and detectPage
        // Step 3a; the haystack is the normalized concatenation so a located
        // range stays consistent with `lineOffsets`.
        var spatialRectByText: [String: CGRect] = [:]
        if categories.contains(.address) {
            let assemblerLines = lineOffsets.map { entry in
                OCREngine.TextLine(
                    text: entry.normalizedText,
                    normalizedRect: entry.normalizedRect,
                    confidence: entry.confidence
                )
            }
            let assembly = assembledAddressMatches(
                lines: assemblerLines, haystack: concatenated as NSString)
            rawMatches.append(contentsOf: assembly.matches)
            spatialRectByText = assembly.spatialRectByText
        }
        // W10 — overlap resolver runs on the OCR path too. Resolver is a
        // pure static function on DetectionOrchestrator.
        let resolution = DetectionOrchestrator.resolveOverlaps(rawMatches)
        if !resolution.suppressedCountByCategory.isEmpty {
            overlapSink?(resolution.suppressedCountByCategory)
        }
        // B06 — Site-B parity on the OCR path too (an un-routed site would leak
        // raw-gated FP for the scored families). Same partition-then-gate split;
        // the OCR feature text is `concatenated` (the normalized page text the
        // detector ran on at :1330), NOT a `pageText` variable. Re-sorted by
        // position so the recombined survivors keep positional order (the
        // partition groups non-scored ahead of scored otherwise).
        let (scoredOCR, restOCR) = resolution.surviving.partitionedByScoredFamily()
        // D06-F2 Part 1 — symmetric below-threshold drop count on the OCR path
        // (counting at only one path would under-report). Same scoped gate: only
        // `restOCR` is raw-gated; scored families route through `composedSurvivors`.
        let gatedOCR = restOCR.applyingCountingDrops(thresholdVector: thresholdVector)
        if gatedOCR.droppedBelowThreshold > 0 {
            belowThresholdSink?(gatedOCR.droppedBelowThreshold)
        }
        let matches = (gatedOCR.survivors
            + composedSurvivors(scoredOCR, pageText: concatenated))
            .sorted { $0.range.location < $1.range.location }
        var results: [SearchResult] = []

        // W3 — spatial mapping shared between detector matches and
        // synthetic always-flag hits. Returns nil when no OCR line covers
        // the range, mirroring the existing `continue` behavior.
        func mapToOCR(
            _ range: NSRange
        ) -> (rect: CGRect, snippet: String, ocrConfidence: Float)? {
            let matchStart = range.location
            let matchEnd = matchStart + range.length

            let overlappingLines = lineOffsets.filter { entry in
                let lineEnd = entry.start + entry.normalizedText.count + 1
                return entry.start < matchEnd && lineEnd > matchStart
            }
            guard let firstLine = overlappingLines.first else { return nil }

            var unionRect = firstLine.normalizedRect
            for entry in overlappingLines.dropFirst() {
                unionRect = unionRect.union(entry.normalizedRect)
            }

            let padX = 2.0 / page.bounds(for: .cropBox).width
            let padY = 2.0 / page.bounds(for: .cropBox).height
            let paddedRect = CGRect(
                x: max(0, unionRect.minX - padX),
                y: max(0, unionRect.minY - padY),
                width: min(1, unionRect.width + padX * 2),
                height: min(1, unionRect.height + padY * 2)
            )

            let firstLineEnd = firstLine.start + firstLine.normalizedText.count
            let snippet: String
            if matchEnd <= firstLineEnd {
                snippet = firstLine.normalizedText
            } else {
                snippet = String(concatenated.prefix(min(concatenated.count, matchEnd + 20)).suffix(60))
            }

            let ocrConfidence = overlappingLines.map(\.confidence).min() ?? firstLine.confidence
            return (paddedRect, snippet, ocrConfidence)
        }

        // RC-4 — geometry for assembled spatial survivors: the stored union
        // rect wins over character-range mapping (mirror of the text leg's
        // rect override). When the assembled text is not present verbatim in
        // the concatenation (sentinel range → `mapToOCR` has no overlapping
        // lines), the snippet is the assembled text and the confidence is the
        // minimum over the lines the union rect covers. Non-address matches
        // flow through `mapToOCR` unchanged.
        func resolvedMapping(
            for match: PIIDetector.PIIMatch
        ) -> (rect: CGRect, snippet: String, ocrConfidence: Float)? {
            guard let spatialRect =
                (match.kind == .address ? spatialRectByText[match.text] : nil) else {
                return mapToOCR(match.range)
            }
            if let mapped = mapToOCR(match.range) {
                return (spatialRect, mapped.snippet, mapped.ocrConfidence)
            }
            let coveredConfidence = lineOffsets
                .filter { $0.normalizedRect.intersects(spatialRect) }
                .map(\.confidence)
                .min()
            return (spatialRect, match.text, coveredConfidence ?? 1.0)
        }

        for match in matches {
            // W3 — never-flag suppression on OCR path. W-P keeps this
            // post-threshold for V1; consistency follow-up to mirror the
            // text-layer pre-threshold merge is V1.1+ scope.
            if userTermsIndex?.underlyingMatcher.shouldSuppress(match.text) != nil { continue }

            guard let mapped = resolvedMapping(for: match) else { continue }

            // W1 — fold OCR confidence into the rationale so power users can
            // see the OCR contribution alongside detector evidence.
            let rationale: MatchRationale?
            if let base = match.rationale {
                var signals = base.signals
                signals.append(.ocrConfidence(value: Double(mapped.ocrConfidence)))
                rationale = MatchRationale(
                    ruleID: base.ruleID,
                    signals: signals,
                    preThresholdScore: base.preThresholdScore,
                    finalScore: base.finalScore,
                    appliedThreshold: base.appliedThreshold
                )
            } else {
                rationale = nil
            }

            results.append(SearchResult(
                pageIndex: pageIndex,
                normalizedRect: mapped.rect,
                matchedText: match.text,
                contextSnippet: mapped.snippet,
                source: .ocr(confidence: mapped.ocrConfidence),
                term: match.category?.rawValue ?? "PII",
                piiCategory: match.category,
                piiConfidence: match.confidence,
                rationale: rationale
            ))
        }

        // W3 — always-flag synthetic OCR hits. Matched against the
        // normalized concatenation (same text the detector saw) so range
        // math stays consistent with lineOffsets.
        if let matcher = userTermsIndex?.underlyingMatcher, !matcher.alwaysFlag.isEmpty {
            let alwaysFlagResult = matcher.alwaysFlagHits(
                in: concatenated,
                timeoutOverride: regexTimeoutOverride
            )
            for hit in alwaysFlagResult.hits {
                guard let mapped = mapToOCR(hit.range) else { continue }
                let ns = concatenated as NSString
                let matchedText = ns.substring(with: hit.range)
                results.append(SearchResult(
                    pageIndex: pageIndex,
                    normalizedRect: mapped.rect,
                    matchedText: matchedText,
                    contextSnippet: mapped.snippet,
                    source: .ocr(confidence: mapped.ocrConfidence),
                    term: "Custom",
                    piiCategory: nil,
                    piiConfidence: nil,
                    rationale: MatchRationale(
                        ruleID: "user.alwaysFlag",
                        signals: [
                            .userAlwaysFlag(pattern: hit.pattern),
                            .ocrConfidence(value: Double(mapped.ocrConfidence)),
                        ],
                        preThresholdScore: 1.0,
                        finalScore: 1.0,
                        appliedThreshold: nil
                    )
                ))
            }
            // Package C — surface per-(page, pattern) timeouts so the app
            // layer can enqueue the §9.4 custom-terms-skip toast. Same
            // sink as the text-layer branch above so the toast fires
            // regardless of which path produced the page's text.
            if let sink = userTermsTimeoutSink {
                for pattern in alwaysFlagResult.timedOutPatterns {
                    sink(pageIndex, pattern)
                }
            }
        }

        return results
    }

    // MARK: - OCR Cache Eviction (shared across all OCR paths)

    /// Evict the least-recently-used entry from the OCR caches when the capacity
    /// ceiling is reached. Both `ocrCache` and `ocrNormalizedConcat` are always
    /// evicted in lockstep so the two parallel caches never diverge (N-12).
    /// Callers invoke this BEFORE inserting a new entry.
    private func evictOCRCacheIfNeeded() {
        if ocrCache.count >= Self.maxOCRCacheEntries {
            if let lruPage = ocrCacheAccess.min(by: { $0.value < $1.value })?.key {
                ocrCache.removeValue(forKey: lruPage)
                ocrCacheAccess.removeValue(forKey: lruPage)
                ocrNormalizedConcat.removeValue(forKey: lruPage)
            }
        }
    }

    // MARK: - OCR Search Path (§3.2)

    /// Search a page via OCR when no text layer is available.
    /// Uses existing OCREngine with .accurate recognition level.
    /// Results cached per-session keyed by page index.
    private func searchPageViaOCR(
        page: PDFPage,
        pageIndex: Int,
        query: String,
        options: SearchOptions,
        term: String
    ) async -> [SearchResult] {
        // Get or compute OCR results for this page
        let textLines: [OCREngine.TextLine]
        if let cached = ocrCache[pageIndex] {
            // LRU: record access for eviction ordering
            ocrAccessCounter += 1
            ocrCacheAccess[pageIndex] = ocrAccessCounter
            textLines = cached
        } else {
            // Render page at 300 DPI for OCR accuracy
            let pageBounds = page.bounds(for: .cropBox)
            let thumbnailSize = Self.ocrThumbnailSize(
                pageBounds: pageBounds, rotation: page.rotation)

            // §S2 / ENGINE §2.5: Memory guard for OCR rendering.
            // Oversized pages (e.g., architectural drawings) can produce
            // multi-gigabyte bitmaps at 300 DPI. Skip OCR rather than risk
            // an allocation crash. See KI-5 re: os_proc_available_memory().
            // The per-axis cap admits a 10000 × 10000 (~ 400 MB) bitmap
            // that can still trip jetsam; the pixel-count cap rejects
            // near-axis-cap pages on top of the per-axis check.
            let pixelCount = thumbnailSize.width * thumbnailSize.height
            guard thumbnailSize.width <= Self.maxOCRPixelDimension,
                  thumbnailSize.height <= Self.maxOCRPixelDimension,
                  pixelCount <= Self.maxOCRPixelCount else {
                // ST-83 — report the skip so the app layer can tell the
                // user this page's image content was never text-scanned.
                ocrSkipSink?(pageIndex)
                return []
            }

            // Render off-actor — page.thumbnail is synchronous PDFKit and
            // can take seconds on a near-cap page. Holding the actor for
            // that span starves queued setters (sinks, thresholds).
            let sendablePage = SendablePDFPage(page)
            let thumbnail = await Task.detached(priority: .userInitiated) {
                sendablePage.page.thumbnail(of: thumbnailSize, for: .cropBox)
            }.value
            guard let cgImage = thumbnail.cgImage else { return [] }

            do {
                let lines = try await ocrEngine.recognizeText(
                    in: cgImage, recognitionLevel: .accurate
                )
                evictOCRCacheIfNeeded()
                ocrAccessCounter += 1
                ocrCacheAccess[pageIndex] = ocrAccessCounter
                ocrCache[pageIndex] = lines
                textLines = lines
            } catch {
                return []
            }
        }

        // Search within OCR results
        var results: [SearchResult] = []
        let normalizedQuery = options.normalizeUnicode
            ? TextNormalizer.normalizeForSearch(query, caseSensitive: options.caseSensitive)
            : (options.caseSensitive ? query : query.lowercased())

        for line in textLines {
            // Apply OCR confusable normalization BEFORE
            // NFKC (TextNormalizer.normalizeForSearch) so corrected digit
            // sequences survive NFKC unchanged. The raw line object
            // (bounding rect) is untouched; the same-length property of
            // OCRTextNormalizer keeps character offsets valid.
            // Manual-search per-line normalization stays in-loop — no
            // ocrNormalizedConcat writes (the PII path owns that cache).
            let ocrNormalizedText = self.ocrNormalizer.normalize(line.text)
            let nfkcLineText = options.normalizeUnicode
                ? TextNormalizer.normalizeForSearch(ocrNormalizedText, caseSensitive: options.caseSensitive)
                : (options.caseSensitive ? ocrNormalizedText : ocrNormalizedText.lowercased())

            // Recall extensions on the OCR literal
            // path. The rect below is the whole LINE box (not offset-
            // derived), so length-changing transforms are rect-safe here;
            // the offset map is still used so whole-word boundaries
            // evaluate against the pre-strip line text.
            let ext = TextNormalizer.applySearchExtensions(
                pageText: nfkcLineText, query: normalizedQuery, options: options
            )
            let lineText = ext.pageText
            let lineQuery = ext.query
            if lineQuery.isEmpty { continue }
            let baseLineChars: [Character]? = ext.offsetMap != nil ? Array(ext.baseText) : nil

            // UXF-15 — case-preserved analog of `ext.baseText`, used only
            // to re-slice the DISPLAYED span (see `displaySlice`). Mirrors
            // the base chain minus the case fold: confusable-normalized
            // line → (NFKC) → (smart punctuation).
            let displayLineChars: [Character] = {
                var display = options.normalizeUnicode
                    ? TextNormalizer.normalize(ocrNormalizedText)
                    : ocrNormalizedText
                if options.normalizeSmartPunctuation {
                    display = TextNormalizer.normalizeSmartPunctuation(display)
                }
                return Array(display)
            }()

            var searchStart = lineText.startIndex
            while searchStart < lineText.endIndex {
                guard let matchRange = lineText.range(
                    of: lineQuery,
                    range: searchStart..<lineText.endIndex
                ) else { break }

                // DRAW-5 — magic-wand `exactMatch` gates the same OCR
                // word-boundary check as `wholeWord` (plan §0.4). Base-
                // coordinate variant when an offset map is active, same
                // as findTextMatches.
                if options.wholeWord || options.exactMatch {
                    let isBoundaried: Bool
                    if let baseLineChars, let map = ext.offsetMap {
                        let start = lineText.distance(from: lineText.startIndex, to: matchRange.lowerBound)
                        let len = lineText.distance(from: matchRange.lowerBound, to: matchRange.upperBound)
                        if start < map.count, start + len - 1 < map.count {
                            let baseStart = map[start]
                            let baseEnd = map[start + len - 1] + 1
                            isBoundaried = Self.isWholeWordInBase(
                                chars: baseLineChars, start: baseStart, endExclusive: baseEnd
                            )
                        } else {
                            isBoundaried = false
                        }
                    } else {
                        isBoundaried = isWholeWord(matchRange, in: lineText)
                    }
                    if !isBoundaried {
                        searchStart = matchRange.upperBound
                        continue
                    }
                }

                // Vision bounding boxes are already normalized 0–1, bottom-left origin.
                // Add padding for OCR imprecision (§3.2: 2pt in normalized coords).
                let pageBounds = page.bounds(for: .cropBox)
                let padX = 2.0 / pageBounds.width
                let padY = 2.0 / pageBounds.height
                let paddedRect = CGRect(
                    x: max(0, line.normalizedRect.minX - padX),
                    y: max(0, line.normalizedRect.minY - padY),
                    width: min(1, line.normalizedRect.width + padX * 2),
                    height: min(1, line.normalizedRect.height + padY * 2)
                )

                // UXF-15 — display span re-slices from the case-preserved
                // analog at base offsets; matching stays on the normalized
                // text (REDACTION_ENGINE.md §9.6). The BUG-006-norm-drift
                // trap (Character-count drift on heavy-ligature input) is
                // guarded inside `displaySlice`, which falls back to the
                // normalized slice.
                let normalizedSlice = String(lineText[matchRange.lowerBound..<matchRange.upperBound])
                let displayStart = lineText.distance(
                    from: lineText.startIndex, to: matchRange.lowerBound)
                let displayLength = lineText.distance(
                    from: matchRange.lowerBound, to: matchRange.upperBound)
                let matchedText = Self.displaySlice(
                    start: displayStart, length: displayLength,
                    offsetMap: ext.offsetMap,
                    displayChars: displayLineChars,
                    baseCount: ext.baseText.count,
                    fallback: normalizedSlice)

                results.append(SearchResult(
                    pageIndex: pageIndex,
                    normalizedRect: paddedRect,
                    matchedText: matchedText,
                    contextSnippet: line.text,
                    source: .ocr(confidence: line.confidence),
                    term: term
                ))

                searchStart = matchRange.upperBound
            }
        }

        return results
    }

    // MARK: - Regex OCR Fallback Helpers

    /// Retrieve OCR lines for a page, using the cache when available.
    /// On a cache miss, renders the page at 300 DPI using the same
    /// SendablePDFPage + thumbnail-in-detached-Task idiom as
    /// `searchPageViaOCR`, then inserts through the shared eviction path
    /// so `ocrCache` and `ocrNormalizedConcat` stay in lockstep.
    private func ocrPage(_ page: PDFPage, pageIndex: Int) async -> [OCREngine.TextLine] {
        // Cache hit path — update LRU timestamp, return cached lines.
        if let cached = ocrCache[pageIndex] {
            ocrAccessCounter += 1
            ocrCacheAccess[pageIndex] = ocrAccessCounter
            return cached
        }

        // Cache miss — render then OCR.
        let pageBounds = page.bounds(for: .cropBox)
        let thumbnailSize = Self.ocrThumbnailSize(
            pageBounds: pageBounds, rotation: page.rotation)
        let pixelCount = thumbnailSize.width * thumbnailSize.height
        guard thumbnailSize.width <= Self.maxOCRPixelDimension,
              thumbnailSize.height <= Self.maxOCRPixelDimension,
              pixelCount <= Self.maxOCRPixelCount else {
            // ST-83 — report the skip so the app layer can tell the
            // user this page's image content was never text-scanned.
            ocrSkipSink?(pageIndex)
            return []
        }

        let sendablePage = SendablePDFPage(page)
        let thumbnail = await Task.detached(priority: .userInitiated) {
            sendablePage.page.thumbnail(of: thumbnailSize, for: .cropBox)
        }.value
        guard let cgImage = thumbnail.cgImage else { return [] }

        do {
            let lines = try await ocrEngine.recognizeText(
                in: cgImage, recognitionLevel: .accurate
            )
            // Insert through the shared eviction path so
            // ocrCache and ocrNormalizedConcat are always evicted in lockstep.
            evictOCRCacheIfNeeded()
            ocrAccessCounter += 1
            ocrCacheAccess[pageIndex] = ocrAccessCounter
            ocrCache[pageIndex] = lines
            return lines
        } catch { // LegalPhrases:safe (Swift keyword)
            return []
        }
    }

    /// Map a character offset in a newline-joined OCR text to the bounding
    /// rect of the containing OCR line. Used by the regex fallback to
    /// associate a regex match position with a visual location.
    ///
    /// - Parameters:
    ///   - offset: Character offset into `text` (the "\n"-joined concatenation
    ///             of `lines[i].text` values, same join order as the caller).
    ///   - text: The concatenated OCR text that was searched.
    ///   - lines: The source OCR lines in the same order used when building `text`.
    ///   - page: The page, used to compute padding in normalized coordinates.
    /// - Returns: The normalized bounding rect of the containing line, padded
    ///   for OCR imprecision, or `nil` if no line contains the offset.
    private func ocrLineRect(
        forCharOffset offset: Int,
        inText text: String,
        lines: [OCREngine.TextLine],
        page: PDFPage
    ) -> CGRect? {
        // Walk lines in the same order they were joined with "\n".
        // Each line occupies `line.text.count` characters followed by a
        // "\n" separator (1 character), so the running total advances by
        // `lineLength + 1` per line.
        var cursor = 0
        for line in lines {
            let lineLength = line.text.count
            let lineEnd = cursor + lineLength  // exclusive, before the "\n"
            if offset >= cursor && offset <= lineEnd {
                let pageBounds = page.bounds(for: .cropBox)
                let padX = 2.0 / pageBounds.width
                let padY = 2.0 / pageBounds.height
                return CGRect(
                    x: max(0, line.normalizedRect.minX - padX),
                    y: max(0, line.normalizedRect.minY - padY),
                    width: min(1, line.normalizedRect.width + padX * 2),
                    height: min(1, line.normalizedRect.height + padY * 2)
                )
            }
            cursor += lineLength + 1  // +1 for the "\n"
        }
        return nil
    }

    /// Average OCR confidence across a set of lines. Returns 0 for an empty
    /// slice (caller should guard non-empty before using the result).
    private func averageOCRConfidence(_ lines: [OCREngine.TextLine]) -> Float {
        lines.map(\.confidence).reduce(0, +) / Float(max(lines.count, 1))
    }

    /// Search a scanned (no-text-layer) page via OCR + regex.
    /// Called by `searchRegex` when `options.includeOCR` is true and the
    /// page's text layer is empty.
    ///
    /// Normalization ordering:
    ///   1. OCRTextNormalizer corrects confusable glyphs per-line.
    ///   2. Lines are joined with "\n" preserving line offsets.
    ///   3. NFKC (normalizeUnicode option) is NOT applied here — the regex
    ///      pattern was authored by the user for literal match; applying NFKC
    ///      to the body only (not the pattern) would silently break ASCII
    ///      patterns. This is consistent with the text-layer path in searchRegex.
    private func searchPageViaOCRFallback_regex(
        page: PDFPage,
        pageIndex: Int,
        pattern: String,
        options: SearchOptions
    ) async -> [SearchResult] {
        let lines = await ocrPage(page, pageIndex: pageIndex)
        guard !lines.isEmpty else { return [] }

        // Normalize each line through OCRTextNormalizer (confusable correction)
        // then join with "\n" to build the searchable text. The per-line
        // normalize step preserves line offsets for rect mapping below.
        let normalizedLines = lines.map { self.ocrNormalizer.normalize($0.text) }
        var searchText = normalizedLines.joined(separator: "\n")
        guard !searchText.isEmpty else { return [] }
        // S7 / §4.4 — page-side smart punctuation, same contract as the
        // text-layer regex path. 1:1 substitution keeps both UTF-16
        // NSRanges and the Character-offset line walk in ocrLineRect
        // aligned with the per-line lengths.
        if options.normalizeSmartPunctuation {
            searchText = TextNormalizer.normalizeSmartPunctuation(searchText)
        }

        guard let regex = Self.validateRegexPattern(pattern) else { return [] }

        let nsString = searchText as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        var results: [SearchResult] = []
        let avgConfidence = averageOCRConfidence(lines)

        // Wrap page in SendablePDFPage so the enumerateMatches closure
        // (which is @Sendable in Swift 6.2 strict mode) can capture it
        // without a Sendable violation — same pattern as searchRegex.
        let sendablePage = SendablePDFPage(page)

        // Per-page timeout matching the text-layer regex path.
        let effectiveTimeout: Duration = regexTimeoutOverride ?? Self.perPageRegexTimeout
        let startTime = ContinuousClock.now
        // Snapshot the timeout sink — invoked synchronously inside the
        // enumerateMatches closure where actor re-entry is not permitted.
        let snapshotTimeoutSink = self.regexTimeoutSink

        regex.enumerateMatches(
            in: searchText,
            options: [.reportProgress],
            range: fullRange
        ) { match, _, stop in
            if Task.isCancelled {
                stop.pointee = true
                return
            }
            if ContinuousClock.now - startTime > effectiveTimeout {
                snapshotTimeoutSink?(pageIndex)
                stop.pointee = true
                return
            }
            guard let match, match.range.location != NSNotFound else { return }
            let matchRange = match.range

            if options.wholeWord {
                guard let swiftRange = Range(matchRange, in: searchText) else { return }
                if !isWholeWord(swiftRange, in: searchText) { return }
            }

            // Map the match start character offset to the containing OCR
            // line's bounding rect. The NSRange location is a UTF-16 offset;
            // convert to a Character offset first for the line-walk cursor.
            // NOTE: OCRTextNormalizer is same-length by construction, so
            // Character offset == UTF-16 offset for all ASCII-range confusable
            // substitutions. For robustness, use String.index conversion.
            let charOffset: Int
            if let swiftRange = Range(matchRange, in: searchText) {
                charOffset = searchText.distance(
                    from: searchText.startIndex, to: swiftRange.lowerBound
                )
            } else {
                charOffset = matchRange.location
            }

            guard let normalizedRect = ocrLineRect(
                forCharOffset: charOffset,
                inText: searchText,
                lines: lines,
                page: sendablePage.page
            ) else { return }

            let matchedText = nsString.substring(with: matchRange)
            let snippet = contextSnippet(text: searchText, matchNSRange: matchRange)

            results.append(SearchResult(
                pageIndex: pageIndex,
                normalizedRect: normalizedRect,
                matchedText: matchedText,
                contextSnippet: snippet,
                source: .ocr(confidence: avgConfidence),
                term: pattern
            ))
        }

        return results
    }

    // MARK: - Text Matching Core

    /// Find all substring matches in a page's text and convert to SearchResults.
    private func findTextMatches(
        pageText: String,
        query: String,
        options: SearchOptions,
        page: PDFPage,
        pageIndex: Int,
        term: String
    ) -> [SearchResult] {
        // §9.7: Detect CJK text per-page and disable whole-word matching.
        // Per-page detection is necessary for multilingual documents (e.g.,
        // Japanese-English contracts) where language varies across pages.
        // NLLanguageRecognizer on 500 chars is sub-millisecond.
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(pageText.prefix(500)))
        let cjkLanguages: Set<NLLanguage> = [
            .japanese, .korean, .simplifiedChinese, .traditionalChinese
        ]
        let isCJK = recognizer.dominantLanguage.map { cjkLanguages.contains($0) } ?? false
        var effectiveOptions = options
        // DRAW-5 — `exactMatch` rides the same CJK-disable shape as
        // `wholeWord`. CJK runs lack the alphanumeric run-boundaries the
        // predicate relies on, so the boundary check would always pass
        // (or always fail) and add no signal.
        if isCJK {
            effectiveOptions.wholeWord = false
            effectiveOptions.exactMatch = false
        }

        let normalizedPageText: String
        let normalizedQuery: String

        if effectiveOptions.normalizeUnicode {
            normalizedPageText = TextNormalizer.normalizeForSearch(pageText, caseSensitive: effectiveOptions.caseSensitive)
            normalizedQuery = TextNormalizer.normalizeForSearch(query, caseSensitive: effectiveOptions.caseSensitive)
        } else if !effectiveOptions.caseSensitive {
            normalizedPageText = pageText.lowercased()
            normalizedQuery = query.lowercased()
        } else {
            normalizedPageText = pageText
            normalizedQuery = query
        }

        guard !normalizedQuery.isEmpty else { return [] }

        // Recall extensions on top of the NFKC path.
        // Smart punctuation is 1:1 (length-preserving), so rect NSRanges
        // stay in the normalized text's coordinates. Diacritic fold and
        // separator strip are length-changing: matching runs on the
        // transformed text and every match range routes through
        // `ext.offsetMap` back to base coordinates BEFORE the rect is
        // computed (Risk 1: a wrong rect is a misplaced redaction).
        let ext = TextNormalizer.applySearchExtensions(
            pageText: normalizedPageText,
            query: normalizedQuery,
            options: effectiveOptions
        )
        let searchPageText = ext.pageText
        let searchQuery = ext.query
        // The strip path can empty a query made of separators only.
        guard !searchQuery.isEmpty else { return [] }
        // Boundary checks must run against the PRE-strip text — the
        // stripped text has no separators left, so word boundaries only
        // exist in base coordinates. Materialized once per page for O(1)
        // integer indexing.
        let baseChars: [Character]? = ext.offsetMap != nil ? Array(ext.baseText) : nil

        // UXF-15 — case-preserved analog of `ext.baseText`, used only to
        // re-slice the DISPLAYED span (see `displaySlice`). Mirrors the
        // base chain minus the case fold: page text → (ligature/NFKC
        // normalize) → (smart punctuation).
        let displayBaseChars: [Character] = {
            var display = effectiveOptions.normalizeUnicode
                ? TextNormalizer.normalize(pageText)
                : pageText
            if effectiveOptions.normalizeSmartPunctuation {
                display = TextNormalizer.normalizeSmartPunctuation(display)
            }
            return Array(display)
        }()

        var results: [SearchResult] = []
        var searchStart = searchPageText.startIndex

        while searchStart < searchPageText.endIndex {
            guard let matchRange = searchPageText.range(
                of: searchQuery,
                range: searchStart..<searchPageText.endIndex
            ) else { break }

            // Offsets measured on the searched (most-transformed) text.
            let matchStartOffset = searchPageText.distance(
                from: searchPageText.startIndex, to: matchRange.lowerBound
            )
            let matchLength = searchPageText.distance(
                from: matchRange.lowerBound, to: matchRange.upperBound
            )

            // Map back to base (NFKC-normalized) coordinates when a
            // length-changing extension is active.
            let baseStartOffset: Int
            let baseLength: Int
            if let map = ext.offsetMap {
                guard matchStartOffset < map.count,
                      matchStartOffset + matchLength - 1 < map.count else {
                    // Structurally unreachable (map covers every searched
                    // char); refuse the match rather than risk a bad rect.
                    searchStart = matchRange.upperBound
                    continue
                }
                baseStartOffset = map[matchStartOffset]
                // End = index AFTER the last matched character's base
                // position, so a match spanning removed separators covers
                // them in the rect.
                baseLength = map[matchStartOffset + matchLength - 1] + 1 - baseStartOffset
            } else {
                baseStartOffset = matchStartOffset
                baseLength = matchLength
            }

            // Whole-word check: verify word boundaries around match.
            // DRAW-5 — `exactMatch` is the magic-wand select-by-similar-text
            // call-site flag (plan §0.4); semantically equivalent to
            // `wholeWord` on the text/multi-term/OCR paths. With an offset
            // map active the predicate evaluates in base coordinates
            // (separators are gone from the searched text, so boundaries
            // are only meaningful there).
            if effectiveOptions.wholeWord || effectiveOptions.exactMatch {
                let isBoundaried: Bool
                if let baseChars {
                    isBoundaried = Self.isWholeWordInBase(
                        chars: baseChars, start: baseStartOffset, endExclusive: baseStartOffset + baseLength
                    )
                } else {
                    isBoundaried = isWholeWord(matchRange, in: searchPageText)
                }
                if !isBoundaried {
                    searchStart = matchRange.upperBound
                    continue
                }
            }

            // Get bounding rect via PDFKit selection — base coordinates.
            let nsRange = NSRange(location: baseStartOffset, length: baseLength)
            if let normalizedRect = boundingRect(for: nsRange, page: page) {
                // UXF-15 — display span re-slices from the case-preserved
                // analog at the already-mapped base offsets; matching stays
                // on the normalized text (REDACTION_ENGINE.md §9.6). The
                // BUG-006-norm-drift trap is guarded inside `displaySlice`,
                // which falls back to the normalized slice on drift.
                let normalizedSlice = String(searchPageText[matchRange.lowerBound..<matchRange.upperBound])
                let matchedText = Self.displaySlice(
                    start: baseStartOffset, length: baseLength,
                    offsetMap: nil,
                    displayChars: displayBaseChars,
                    baseCount: ext.baseText.count,
                    fallback: normalizedSlice)
                let snippet = contextSnippet(
                    text: pageText, matchStart: baseStartOffset, matchLength: baseLength
                )

                results.append(SearchResult(
                    pageIndex: pageIndex,
                    normalizedRect: normalizedRect,
                    matchedText: matchedText,
                    contextSnippet: snippet,
                    source: .textLayer,
                    term: term
                ))
            }

            searchStart = matchRange.upperBound
        }

        return results
    }

    /// UXF-15 — re-slice the DISPLAYED match span from the case-preserved
    /// analog of the base text, so a match on "Hartwell" displays as
    /// "Hartwell" rather than the case-folded "hartwell". Matching still
    /// runs on the normalized text; this touches only the display slice.
    /// `start`/`length` are Character offsets in the searched
    /// (most-transformed) text; `offsetMap` routes them to base
    /// coordinates when a length-changing extension is active (pass nil
    /// when the offsets are already base coordinates). Returns `fallback`
    /// (the normalized slice — today's behavior) whenever the
    /// case-preserved analog drifted from the base Character count: the
    /// BUG-006-norm-drift trap (REDACTION_ENGINE.md §9.6) this guard
    /// exists for.
    static func displaySlice(
        start: Int, length: Int, offsetMap: [Int]?,
        displayChars: [Character], baseCount: Int, fallback: String
    ) -> String {
        guard displayChars.count == baseCount, length > 0 else { return fallback }
        let baseStart: Int
        let baseEndExclusive: Int
        if let map = offsetMap {
            guard start >= 0, start < map.count, start + length - 1 < map.count else {
                return fallback
            }
            baseStart = map[start]
            baseEndExclusive = map[start + length - 1] + 1
        } else {
            baseStart = start
            baseEndExclusive = start + length
        }
        guard baseStart >= 0, baseStart < baseEndExclusive,
              baseEndExclusive <= displayChars.count else {
            return fallback
        }
        return String(displayChars[baseStart..<baseEndExclusive])
    }

    /// Word-boundary predicate in base-text coordinates, used when a
    /// length-changing normalization (offset map) is active. Mirrors
    /// `isWholeWord`'s alphanumeric/underscore rule.
    private static func isWholeWordInBase(
        chars: [Character], start: Int, endExclusive: Int
    ) -> Bool {
        if start > 0 {
            let c = chars[start - 1]
            if c.isLetter || c.isNumber || c == "_" { return false }
        }
        if endExclusive < chars.count {
            let c = chars[endExclusive]
            if c.isLetter || c.isNumber || c == "_" { return false }
        }
        return true
    }

    // MARK: - Whole-Word Check

    /// Check if the match range is surrounded by word boundaries.
    private func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let charBefore = text[text.index(before: range.lowerBound)]
            if charBefore.isLetter || charBefore.isNumber || charBefore == "_" {
                return false
            }
        }
        if range.upperBound < text.endIndex {
            let charAfter = text[range.upperBound]
            if charAfter.isLetter || charAfter.isNumber || charAfter == "_" {
                return false
            }
        }
        return true
    }

    // MARK: - Coordinate Conversion (§3.5)

    /// Convert an NSRange in page text to a normalized bounding rect.
    ///
    /// Coordinate path (CANVAS_OVERLAY §S2.3):
    /// PDFPage.selection(for:) → .bounds(for: page) → PDF points (bottom-left,
    /// UN-ROTATED space, confirmed TL-1-1). Transform to post-rotation visual
    /// space before normalizing, so normalized coords align with the post-rotation
    /// bitmap produced by renderPage()/getDrawingTransform().
    ///
    /// SECURITY NOTE: Wrong normalization = fill at wrong pixel position = data leak.
    public nonisolated func boundingRect(for nsRange: NSRange, page: PDFPage) -> CGRect? {
        guard let selection = page.selection(for: nsRange) else { return nil }
        let absoluteBounds = selection.bounds(for: page)
        guard !absoluteBounds.isEmpty else { return nil }

        let pageBounds = page.bounds(for: .cropBox)
        let rawW = pageBounds.width
        let rawH = pageBounds.height
        let rotation = page.rotation

        // PDFSelection.bounds(for:) is in ABSOLUTE, UNROTATED (MediaBox/user)
        // space and INCLUDES the cropBox origin (pinned by RotatedPageCoordinateTests
        // .nonZeroCropBoxSelectionFrameProbe). Translate to cropBox-LOCAL BEFORE the
        // rotation mirror — the rotation cases and the normalize below assume a
        // zero-origin local rect (they use rawW/rawH as extents only). This mirrors
        // TextLayerExtractor's `.offsetBy(dx:-cropBox.origin.x, dy:-cropBox.origin.y)`
        // so both region producers agree on offset-CropBox pages. SECURITY: omitting
        // this displaces the redaction fill by (origin / dimension).
        let bounds = absoluteBounds.offsetBy(
            dx: -pageBounds.origin.x, dy: -pageBounds.origin.y)

        // Transform selection bounds from un-rotated PDF space to post-rotation
        // visual space. PDF /Rotate is CW display rotation (ISO 32000 §8.3.2).
        let visualBounds: CGRect
        switch rotation {
        case 90:
            // CW 90°: (x,y) → (y, rawW - x - w)
            visualBounds = CGRect(
                x: bounds.minY, y: rawW - bounds.maxX,
                width: bounds.height, height: bounds.width)
        case 180:
            // 180°: (x,y) → (rawW - x - w, rawH - y - h)
            visualBounds = CGRect(
                x: rawW - bounds.maxX, y: rawH - bounds.maxY,
                width: bounds.width, height: bounds.height)
        case 270:
            // CCW 90°: (x,y) → (rawH - y - h, x)
            visualBounds = CGRect(
                x: rawH - bounds.maxY, y: bounds.minX,
                width: bounds.height, height: bounds.width)
        default:
            visualBounds = bounds
        }

        // Post-rotation effective dimensions
        let effectiveWidth: CGFloat = (rotation == 90 || rotation == 270) ? rawH : rawW
        let effectiveHeight: CGFloat = (rotation == 90 || rotation == 270) ? rawW : rawH

        guard effectiveWidth > 0, effectiveHeight > 0 else { return nil }

        let normalized = CGRect(
            x: visualBounds.minX / effectiveWidth,
            y: visualBounds.minY / effectiveHeight,
            width: visualBounds.width / effectiveWidth,
            height: visualBounds.height / effectiveHeight
        ).clampedToNormalized()

        return normalized
    }

    // MARK: - Context Snippet

    /// Build a ±20 character context snippet around the match.
    /// `matchStart` and `matchLength` are Character offsets (not UTF-16).
    func contextSnippet(text: String, matchStart: Int, matchLength: Int) -> String {
        let contextRadius = 20
        let textCount = text.count

        let snippetStart = max(0, matchStart - contextRadius)
        let snippetEnd = min(textCount, matchStart + matchLength + contextRadius)

        let startIdx = text.index(text.startIndex, offsetBy: snippetStart)
        let endIdx = text.index(text.startIndex, offsetBy: snippetEnd)

        var snippet = String(text[startIdx..<endIdx])

        if snippetStart > 0 { snippet = "…" + snippet }
        if snippetEnd < textCount { snippet = snippet + "…" }

        snippet = snippet.replacingOccurrences(of: "\n", with: " ")

        return snippet
    }

    /// NSRange-safe overload: converts UTF-16 range to Character offsets
    /// before building the snippet. Use this when the range comes from
    /// NSRegularExpression or PIIDetector (both use NSRange/UTF-16).
    func contextSnippet(text: String, matchNSRange: NSRange) -> String {
        guard let range = Range(matchNSRange, in: text) else { return "" }
        let charStart = text.distance(from: text.startIndex, to: range.lowerBound)
        let charLength = text.distance(from: range.lowerBound, to: range.upperBound)
        return contextSnippet(text: text, matchStart: charStart, matchLength: charLength)
    }
}

// MARK: - Typed validation errors

/// Reasons `DocumentSearcher.validateRegexPatternWithError` rejects a
/// pattern before compilation. Engine-compile failures are NOT wrapped —
/// they propagate as the system `NSError` so its `localizedDescription`
/// reaches the regex error callout verbatim (spec SEARCH_AND_REDACT §S2).
///
/// Copy constraint: these three strings are app-owned user-facing copy and
/// use mechanism-description language per ARCH §1.3 ("has not been
/// accepted" — names the response, promises no outcome). The strings never
/// echo the submitted pattern text (RR-24 precedent).
public enum RegexValidationError: Error, LocalizedError {
    case patternTooLong(maxLength: Int)
    case likelyPathological
    case nestedQuantifiers

    public var errorDescription: String? {
        switch self {
        case .patternTooLong(let max):
            return "Pattern exceeds the \(max)-character limit."
        case .likelyPathological:
            return "Pattern may cause performance issues and has not been accepted."
        case .nestedQuantifiers:
            return "Pattern contains nested quantifiers and has not been accepted."
        }
    }
}
