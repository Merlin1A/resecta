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

// Engine-layer document search with text-layer,
// regex, and OCR paths. Returns results via AsyncStream for progressive UI.
// C-5 seam, 1.1.1: page coverage reporting for the verification re-check
// (`setPageCoverageSink`) — reporting-only, no change to what is yielded.

/// Performs text search across a PDF document with dual-path
/// (text layer + OCR) support.
///
/// Returns results via AsyncStream for progressive UI updates.
/// Cancellable via structured concurrency (Task.cancel()).
public actor DocumentSearcher {

    // MARK: - Configuration

    /// Maximum regex pattern length (ReDoS prevention).
    static let maxRegexPatternLength = 200

    /// The largest `{n,m}` upper bound that still counts as BOUNDED for
    /// the nested-quantifier rule: `(a{2,25})+` is a bounded group under
    /// a repetition, `(a{2,63})+` is treated like `(a+)+`. The safe-regex
    /// precedent's ceiling.
    static let boundedQuantifierCeiling = 25

    /// The cap on the product of bounded maxima along a nesting chain —
    /// `(a{0,40}){0,40}` may explore 1,600 repetitions although every
    /// bound is small; the counted-loop precedent's cap.
    static let nestedBoundProductCap = 1000

    /// Per-page regex timeout.
    static let perPageRegexTimeout: Duration = .seconds(5)

    /// Per-instance test override for `perPageRegexTimeout`. Set via
    /// the optional `regexTimeoutOverride` init parameter; production code
    /// leaves it nil and the production constant applies. Marked
    /// `nonisolated let` so the nonisolated `previewRegex` can read it
    /// without an actor hop. Per-instance avoids the cross-test race a
    /// static override would expose.
    nonisolated let regexTimeoutOverride: Duration?

    /// Maximum results to accumulate.
    public static let maxResults = 1000

    /// Maximum pixel dimension for OCR rendering.
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
    // `AddressSpatialAssembler.sharedAddressComponents`.
    //
    // The shared detector is built through
    // `loadWithDiagnostics()` — NOT the bare `PIIDetector()` — so the live
    // scan path carries the same degrade diagnostics the legacy detection
    // pipeline surfaced. On a healthy install the constructed detector is
    // identical to the bare init's; on a corpus/signature failure or an
    // NER-asset-absent OS build, `sharedLoadDiagnostics` records it and the
    // scan kickoff surfaces the degraded-detection banner instead of degrading silently.
    private static let sharedPIIDetectorLoad = PIIDetector.loadWithDiagnostics()
    private let piiDetector = DocumentSearcher.sharedPIIDetectorLoad.detector

    /// Diagnostics for the process-shared search detector.
    /// Cached with the detector — the probe reflects load-time state, which
    /// is the state every search in this process actually runs under.
    public static var sharedLoadDiagnostics: GazetteerLoadDiagnostics {
        sharedPIIDetectorLoad.diagnostics
    }

    // Site-B / Search parity. The five scored families
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
    // Empty priors at Search (no triage history is threaded into a scan),
    // so `PerCategoryPriors().mean(category)` is 0.5 for every category ⇒
    // logit(prior) is 0 and priorMean floors to absorbingStateFloor only when the
    // category has accrued enough rejections elsewhere (it has not, at scan time).
    // Held as a stored value for parity with the orchestrator's `priors` local.
    private let searchPriors = PerCategoryPriors()

    // Spatial address assembly on the Search legs. The orchestrator
    // has run `AddressSpatialAssembler` over per-line records
    // (DetectionOrchestrator.detectPage Step 3a); both Search legs ran
    // only the flat single-line regex arms, so a multi-line address block
    // never became a Search candidate on either leg. The assembler is a
    // Sendable value whose gazetteer load is cached statically
    // (`AddressSpatialAssembler.sharedAddressComponents`), so per-searcher
    // construction is cheap. See `assembledAddressMatches(lines:haystack:)`.
    private let addressAssembler = AddressSpatialAssembler()

    // Optional preset-threshold vector applied to PII matches before
    // conversion to SearchResult. nil disables gating (no vector installed).
    // Set via `setThresholdVector(_:)` before each search kickoff so the UI
    // layer can snapshot the user's current settings state.
    private var thresholdVector: PresetThresholdVector?

    // Optional compiled user term index. nil (or an empty
    // index) leaves `.piiScan` behavior unchanged. Set via
    // `setUserTerms(_:)` alongside `setThresholdVector(_:)` before each
    // scan kickoff. The index wraps the underlying `UserTermMatcher` in
    // `UserTermsIndex` so never-flag suppression can run pre-threshold
    // via `UserTermsIndex.merge(into:doctype:)`.
    private var userTermsIndex: UserTermsIndex?

    // Optional sink for per-page cross-category overlap-suppressed
    // counts. Installed before a scan to route resolver output into the
    // app-layer CoverageReport aggregator. Runs after `piiDetector.detect`
    // and before threshold filtering, mirroring DetectionOrchestrator.
    private var overlapSink: (@Sendable ([PIICategory: Int]) -> Void)?

    // Optional sink for the per-page count of matches dropped
    // for falling below their preset threshold (the raw-gate drops on `restText`
    // / `restOCR`). Fired beside `overlapSink` so the app-layer CoverageReport's
    // "below threshold" line is truthful instead of a hardcoded 0. Scored
    // families bypass the raw gate via `composedSurvivors`, so their posterior
    // drops are intentionally NOT counted here.
    private var belowThresholdSink: (@Sendable (Int) -> Void)?

    // Optional sink for per-page regex-timeout pages.
    // Fires once per page where the regex enumerator bails on the
    // `perPageRegexTimeout` ceiling, in both the live-preview path
    // (`previewRegex`) and the full-scan path (`searchRegex`). The app
    // layer accumulates page indices to render the regex-timeout banner.
    private var regexTimeoutSink: (@Sendable (Int) -> Void)?
    /// Fired once, with the gate's reason, when a regex search starts on a
    /// pattern the safety gate refuses; the stream then finishes empty.
    /// Without it an empty stream reads as "0 results" to every consumer.
    private var regexRejectionSink: (@Sendable (String) -> Void)?

    // Optional sink for per-page oversized-OCR-skip reporting.
    // Fires once per page whose 300-DPI render exceeds the OCR pixel caps
    // (`maxOCRPixelDimension` / `maxOCRPixelCount`) and is therefore never
    // OCR'd, in all three OCR entry paths (manual OCR search, PII scan,
    // regex OCR fallback). Reporting-only: the skip behavior itself is
    // unchanged. The app layer accumulates page indices to render the
    // OCR-skip banner alongside the regex-timeout banner.
    private var ocrSkipSink: (@Sendable (Int) -> Void)?

    // Optional sink for per-page custom-terms always-flag
    // regex timeouts. Fires once per (page, user-authored pattern) when
    // `UserTermMatcher.alwaysFlagHits` reports the pattern bailed on the
    // `perPageRegexTimeout` ceiling. Separate from `regexTimeoutSink`
    // because the UX surface differs — saved-search regex timeouts route
    // to the regex-timeout banner (no pattern echo); custom-terms
    // timeouts route to a `.warning` toast that includes the truncated
    // user-named pattern so the user can identify which list entry to
    // revise. Per-term-per-page semantics — the term remains active on
    // subsequent pages within the same scan.
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

    // C-5 seam (1.1.1): per-page coverage reporting for the verification
    // search re-check. Fires for every page a search visits with which
    // evidence the page was read from (text layer · OCR) or why it was not
    // read (OCR pixel cap · OCR unavailable · unopenable page). Reporting-
    // only: it never changes which results are yielded, and it is nil in
    // every caller except the re-check. May fire more than once per page
    // (the multi-term OCR path runs per term); consumers dedupe by page.
    private var pageCoverageSink: (@Sendable (PageSearchCoverage) -> Void)?

    // MARK: - Per-Session Caches

    /// The OCR page caches — the verbatim Vision lines, the LRU access
    /// order and the normalized PII-scan inputs — one value owned by this
    /// actor. See `OCRPageCache`.
    private var ocrPageCache = OCRPageCache()
    private typealias NormalizedOCRPage = OCRPageCache.NormalizedPage
    private typealias NormalizedLineEntry = OCRPageCache.NormalizedLineEntry
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

    /// The instance-bound Site-B gate: the actor's vector, scorers and priors
    /// applied through the frozen composition in DocumentSearcher+SiteB.swift.
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

    // MARK: - Spatial address assembly (both PII-scan legs)

    /// Run spatial address assembly over per-line records and convert
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

    // MARK: - Site-B gate (both PII-scan legs)

    /// The Site-B gate over one page's resolved matches: partition, then
    /// gate (Option A) — the five scored families route through the
    /// composed posterior (`composedSurvivors`); every other family keeps
    /// the raw `applying(thresholdVector:)` path byte-for-byte, and its
    /// below-threshold drops fire `belowThresholdSink` (the scored
    /// families' posterior drops are a separate concern and are not
    /// counted; counting at only one leg would under-report). The
    /// recombined survivors are re-sorted by position so the result list
    /// and J/K navigation keep the positional order `resolveOverlaps`
    /// produced — the partition alone groups non-scored ahead of scored.
    /// The sort is stable, so its input order (the raw-gated survivors,
    /// then the composed scored survivors) is part of the contract.
    /// `pageText` is the text the detector ran on: the page string on the
    /// text leg, the normalized concatenation on the OCR leg.
    private func gateAndCompose(
        _ matches: [PIIDetector.PIIMatch],
        pageText: String
    ) -> [PIIDetector.PIIMatch] {
        let (scored, rest) = matches.partitionedByScoredFamily()
        let gated = rest.applyingCountingDrops(thresholdVector: thresholdVector)
        if gated.droppedBelowThreshold > 0 {
            belowThresholdSink?(gated.droppedBelowThreshold)
        }
        return (gated.survivors + composedSurvivors(scored, pageText: pageText))
            .sorted { $0.range.location < $1.range.location }
    }

    // MARK: - Test Seams (internal, observation/seeding only)

    #if DEBUG
    internal var _testOCRCacheKeys: Set<Int> { ocrPageCache.cachedKeys }
    internal var _testOCRNormalizedConcatKeys: Set<Int> { ocrPageCache.normalizedKeys }
    /// H3.1 (1.2 instrumentation plan §6) — read-only view of one page's
    /// cached Vision lines so the search-GT harness can emit the exact OCR
    /// text the OCR leg matched against. Observation-only, same contract as
    /// `_testOCRCacheKeys` above; never touches the LRU access ordering.
    internal func _testOCRCachedLines(forPageIndex pageIndex: Int) -> [OCREngine.TextLine]? {
        ocrPageCache.cachedLines(forPageIndex: pageIndex)
    }

    /// Seeds the three OCR caches with `occupiedCount` placeholder entries,
    /// inserted in ascending page-index order so the smallest index is the
    /// least-recently-used. Page indices equal to `skippingPageIndex` are
    /// skipped so a subsequent OCR pass on that page forces a miss + LRU
    /// eviction — driving the production eviction code path under test.
    internal func _testSeedOCRCacheForCoherence(
        skippingPageIndex: Int,
        occupiedCount: Int
    ) {
        ocrPageCache.seedForCoherence(
            skippingPageIndex: skippingPageIndex, occupiedCount: occupiedCount)
    }

    /// Seeds the OCR cache with known lines for a specific page index,
    /// allowing tests to exercise search paths (text-mode OCR, regex OCR
    /// fallback) without invoking real Vision OCR on the simulator.
    /// The normalized-concat cache entry is NOT pre-seeded here (the PII
    /// path rebuilds it on demand; the text/regex paths do not read it).
    internal func _testSeedOCRLines(_ lines: [OCREngine.TextLine], forPageIndex pageIndex: Int) {
        ocrPageCache.seedLines(lines, forPageIndex: pageIndex)
    }

    /// Test seam: base address of the copy-on-write-shared surname
    /// Bloom buffer behind this searcher's PIIDetector. Two searchers backed by
    /// the process-shared static detector report the SAME address (shared COW
    /// storage); per-instance detectors report different addresses. nil when the
    /// name gazetteer is absent from the bundle. `nonisolated` — reads only the
    /// immutable Sendable `piiDetector` let.
    nonisolated var _testNameBloomBufferAddress: Int? { piiDetector._testNameBloomBufferAddress }

    /// Observation-only seam over the Site-B composition (the same
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

    /// Install the threshold vector to apply on future PII scans.
    /// Pass nil to disable gating entirely.
    public func setThresholdVector(_ vector: PresetThresholdVector?) {
        self.thresholdVector = vector
    }

    /// Install the user term index to apply on future PII
    /// scans. Pass nil (or an empty index) to disable user-term behavior.
    public func setUserTerms(_ index: UserTermsIndex?) {
        self.userTermsIndex = index
    }

    /// Install a per-page overlap-suppressed-count sink. Pass nil
    /// to disable reporting. Called once per page where the resolver
    /// actually dropped at least one loser.
    public func setOverlapSink(_ sink: (@Sendable ([PIICategory: Int]) -> Void)?) {
        self.overlapSink = sink
    }

    /// Install a per-page below-threshold-drop-count sink. Pass
    /// nil to disable reporting. Called once per page where the raw threshold
    /// gate dropped at least one match, mirroring `setOverlapSink`.
    public func setBelowThresholdSink(_ sink: (@Sendable (Int) -> Void)?) {
        self.belowThresholdSink = sink
    }

    /// Install a per-page regex-timeout sink. Pass nil to
    /// disable reporting. Fires once per page where the enumerator
    /// bails on the `perPageRegexTimeout` ceiling, in both `previewRegex`
    /// and `searchRegex` branches.
    public func setRegexTimeoutSink(_ sink: (@Sendable (Int) -> Void)?) {
        self.regexTimeoutSink = sink
    }

    /// Install a regex-rejection sink. Pass nil to disable reporting.
    /// Fires once per `search` on a `.regex` mode whose pattern the safety
    /// gate refuses — with the typed reason's copy, or the engine's compile
    /// error text — before the stream finishes empty. Mirrors the timeout
    /// sink's contract; the live preview carries the same reason in its
    /// result instead.
    public func setRegexRejectionSink(_ sink: (@Sendable (String) -> Void)?) {
        self.regexRejectionSink = sink
    }

    /// Install a per-page oversized-OCR-skip sink. Pass nil to
    /// disable reporting. Fires once per OCR attempt on a page whose
    /// render exceeds the OCR pixel caps, in all three OCR entry paths
    /// (manual OCR search, PII scan, regex OCR fallback). The consumer
    /// dedupes page indices (Set semantics), mirroring the regex-timeout
    /// sink's contract.
    public func setOCRSkipSink(_ sink: (@Sendable (Int) -> Void)?) {
        self.ocrSkipSink = sink
    }

    /// Install a per-page custom-terms always-flag timeout
    /// sink. Pass nil to disable reporting. Fires once per (pageIndex,
    /// user-authored pattern) when `UserTermMatcher.alwaysFlagHits`
    /// reports a regex term whose enumeration bailed on the
    /// `perPageRegexTimeout` ceiling during a `.piiScan` page loop.
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

    /// Install the per-page coverage sink — the search-side seam for the
    /// verification search re-check (C-5, 1.1.1). Reporting-only; pass nil
    /// to disable. See `PageSearchCoverage`.
    func setPageCoverageSink(_ sink: (@Sendable (PageSearchCoverage) -> Void)?) {
        self.pageCoverageSink = sink
    }

    /// Actor-isolated reader so the `nonisolated previewMatches`
    /// bridge can snapshot the sink before invoking `previewRegex`.
    private func currentRegexTimeoutSink() -> (@Sendable (Int) -> Void)? {
        regexTimeoutSink
    }

    /// One read of the per-page text-layer classification for the preview's
    /// page walk (the preview is `nonisolated`; this is its one actor hop
    /// for the routing, the shape `currentRegexTimeoutSink()` already has).
    private func textLayerStatusSnapshot() -> [Int: TextLayerStatus] {
        textLayerStatusByPage
    }

    // MARK: - Public API

    /// Search the document, yielding results progressively.
    ///
    /// Delivery is complete: the stream buffers without bound, so a page
    /// that bursts more matches than a lagging consumer has drained loses
    /// nothing. The bound on results in flight is `maxResults`, enforced
    /// at every yield site.
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
            bufferingPolicy: .unbounded
        )

        let searcher = self
        let sendableDoc = document

        // The producer must be cancellable from the consumer side:
        // cancelling/dropping the stream is the caller's only cancel
        // mechanism, and an unstoppable producer keeps scanning every
        // remaining page (OCR included) and fires whichever sinks are
        // installed when it finally reaches them — a later search's,
        // corrupting that scan's suppression counts and banners. The
        // per-page `Task.isCancelled` checks read THIS task's flag, so
        // termination must propagate to it.
        let producer = Task {
            await searcher.performSearch(
                sendableDoc, mode: mode,
                progress: progress, continuation: continuation
            )
        }
        continuation.onTermination = { @Sendable _ in
            producer.cancel()
        }

        return stream
    }

    // MARK: - Live Preview

    /// Total cap on live-preview match count. Above this we report
    /// `saturated` and stop counting. The full search has its own cap
    /// (`maxResults`) and is unaffected.
    static let maxPreviewMatches = 10_000

    /// Per-page cap on the highlighted ranges returned for the
    /// visible page. Bounds the overlay redraw cost on dense pages.
    static let maxCurrentPageHighlights = 500

    /// Fast-path counterpart to `search(...)`. Walks the requested
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
    /// - A page whose installed text-layer classification is `.sparse` or
    ///   `.none` is skipped, exactly as the full search skips its text layer
    ///   (it routes such a page to OCR, which the preview never runs), so the
    ///   preview's count never exceeds what the full text-layer search yields.
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
                scope: scope,
                totalCount: 0, saturated: false, regexInvalid: false,
                currentPageMatches: []
            )

        case .regex(let pattern, let options):
            let regex: NSRegularExpression
            do {
                regex = try Self.validateRegexPatternWithError(pattern)
            } catch { // LegalPhrases:safe (Swift keyword)
                // The reason rides the result so the caller need not
                // re-validate to learn why the count is empty.
                return SearchPreviewResult(
                    scope: scope,
                    totalCount: 0, saturated: false, regexInvalid: true,
                    currentPageMatches: [],
                    regexRejection: error.localizedDescription
                )
            }
            let sink = await currentRegexTimeoutSink()
            let textLayerStatus = await textLayerStatusSnapshot()
            return await previewRegex(
                regex: regex, options: options, mode: mode, scope: scope,
                pageRange: pageRange, currentPageIndex: currentPageIndex,
                textLayerStatus: textLayerStatus,
                pageTextProvider: pageTextProvider,
                timeoutSink: sink
            )

        case .text(let query, let options):
            guard !query.isEmpty else {
                return SearchPreviewResult(
                    scope: scope,
                    totalCount: 0, saturated: false, regexInvalid: false,
                    currentPageMatches: []
                )
            }
            let textLayerStatus = await textLayerStatusSnapshot()
            return await previewLiteral(
                terms: [query], options: options, mode: mode, scope: scope,
                pageRange: pageRange, currentPageIndex: currentPageIndex,
                textLayerStatus: textLayerStatus,
                pageTextProvider: pageTextProvider
            )

        case .multiTerm(let terms, let options):
            let nonEmpty = terms.filter { !$0.isEmpty }
            guard !nonEmpty.isEmpty else {
                return SearchPreviewResult(
                    scope: scope,
                    totalCount: 0, saturated: false, regexInvalid: false,
                    currentPageMatches: []
                )
            }
            let textLayerStatus = await textLayerStatusSnapshot()
            return await previewLiteral(
                terms: nonEmpty, options: options, mode: mode, scope: scope,
                pageRange: pageRange, currentPageIndex: currentPageIndex,
                textLayerStatus: textLayerStatus,
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
        textLayerStatus: [Int: TextLayerStatus],
        pageTextProvider: @Sendable (Int) async -> String?,
        timeoutSink: (@Sendable (Int) -> Void)?
    ) async -> SearchPreviewResult {
        var totalCount = 0
        var currentPageMatches: [NSRange] = []
        var saturated = false

        for pageIndex in pageRange {
            if Task.isCancelled { break }
            // The full search's text-layer gate: a `.sparse`/`.none` page is
            // never counted from its text layer.
            guard SearchCore.textLayerIsSearchable(textLayerStatus[pageIndex]) else { continue }
            guard let pageText = await pageTextProvider(pageIndex), !pageText.isEmpty else { continue }

            let searchText = SearchCore.regexSearchText(pageText, options: options)
            let isVisiblePage = (pageIndex == currentPageIndex)
            let startTime = ContinuousClock.now
            let effectiveTimeout: Duration =
                regexTimeoutOverride ?? Self.perPageRegexTimeout

            // The shared enumeration (`.reportProgress` parity with
            // `searchRegex`); the preview counts every surviving match and
            // keeps the visible page's ranges up to the highlight cap.
            let (count, stoppedAtCap) = SearchCore.enumerateRegexMatches(
                in: searchText, regex: regex,
                wholeWord: options.wholeWord, unconvertibleRangePasses: true,
                cap: Self.maxPreviewMatches - totalCount,
                timeout: effectiveTimeout, startTime: startTime,
                onTimeout: {
                    // Preview-path timeout branch.
                    timeoutSink?(pageIndex)
                }
            ) { matchRange in
                if isVisiblePage && currentPageMatches.count < Self.maxCurrentPageHighlights {
                    currentPageMatches.append(matchRange)
                }
                return true
            }
            totalCount += count
            if stoppedAtCap { saturated = true }

            if saturated || totalCount >= Self.maxPreviewMatches {
                if totalCount >= Self.maxPreviewMatches { saturated = true }
                break
            }
        }

        return SearchPreviewResult(
            scope: scope,
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
        textLayerStatus: [Int: TextLayerStatus],
        pageTextProvider: @Sendable (Int) async -> String?
    ) async -> SearchPreviewResult {
        var totalCount = 0
        var currentPageMatches: [NSRange] = []
        var saturated = false

        // AND mode (multi-term conjunction) counts a page only when every
        // term matched on it — the page set the full search yields from —
        // so a page's hits are buffered and committed after its last term.
        // OR mode and single-term text commit every page, as before.
        let conjunction: Bool
        if case .multiTerm = mode {
            conjunction = options.multiTermConjunction
        } else {
            conjunction = false
        }

        let normalizedTerms: [String] = terms.map { SearchCore.normalizedText($0, options: options) }

        for pageIndex in pageRange {
            if Task.isCancelled { break }
            // The full search's text-layer gate: a `.sparse`/`.none` page is
            // never counted from its text layer.
            guard SearchCore.textLayerIsSearchable(textLayerStatus[pageIndex]) else { continue }
            guard let pageText = await pageTextProvider(pageIndex), !pageText.isEmpty else { continue }

            // The same normalization and extension pipeline as
            // `findTextMatches`, so preview counts agree with the full search;
            // the preview does not detect CJK. Emitted ranges are mapped back
            // to base coordinates before they reach the highlight-rect
            // resolver (leak-class otherwise).
            let page = SearchCore.preparePage(pageText, options: options)
            let isVisiblePage = (pageIndex == currentPageIndex)

            var pageCount = 0
            var pageMatches: [NSRange] = []
            var everyTermMatched = true

            for term in normalizedTerms where !term.isEmpty {
                if Task.isCancelled { break }
                let remaining = Self.maxPreviewMatches - (totalCount + pageCount)
                if remaining <= 0 { saturated = true; break }
                let extTerm = SearchCore.preparedQuery(normalized: term, options: options)
                if extTerm.isEmpty { everyTermMatched = false; continue }

                // The magic-wand `exactMatch` gates the same live-preview
                // word-boundary check as `wholeWord`.
                let (spans, stoppedAtCap) = SearchCore.literalSpans(
                    in: page, query: extTerm, comparison: [.literal],
                    wholeWord: options.wholeWord || options.exactMatch,
                    cap: remaining
                )
                for span in spans {
                    pageCount += 1
                    if isVisiblePage && currentPageMatches.count + pageMatches.count < Self.maxCurrentPageHighlights {
                        // Base coordinates when a length-changing extension is
                        // active (Character-offset convention, same as
                        // `findTextMatches`); the searched range otherwise.
                        let emitRange = span.base.map { NSRange(location: $0.lowerBound, length: $0.count) }
                            ?? span.searchedRange
                        pageMatches.append(emitRange)
                    }
                }
                if spans.isEmpty { everyTermMatched = false }
                if stoppedAtCap { saturated = true; break }
            }
            // A saturated page is committed as counted: past the cap the
            // count is a ceiling, not a page-exact total.
            if !conjunction || everyTermMatched || saturated {
                totalCount += pageCount
                currentPageMatches.append(contentsOf: pageMatches)
            }
            if saturated { break }
        }

        return SearchPreviewResult(
            scope: scope,
            totalCount: totalCount,
            saturated: saturated,
            regexInvalid: false,
            currentPageMatches: currentPageMatches
        )
    }

    // MARK: - Text-layer routing

    /// Whether the page's import-time classification permits the
    /// text-layer fast path — the core's predicate over this actor's status
    /// map (`.rich` or unknown stays on the text layer; `.sparse`/`.none`
    /// fall through to OCR). See `SearchCore.textLayerIsSearchable`.
    private func pageHasRichTextLayer(_ pageIndex: Int) -> Bool {
        SearchCore.textLayerIsSearchable(textLayerStatusByPage[pageIndex])
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

    // MARK: - Text Search

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

            guard let page = doc.page(at: pageIndex) else {
                pageCoverageSink?(PageSearchCoverage(pageIndex: pageIndex, route: .unopenable))
                continue
            }
            let pageText = page.string ?? ""

            if !pageText.isEmpty && pageHasRichTextLayer(pageIndex) {
                // Text-layer path
                pageCoverageSink?(PageSearchCoverage(pageIndex: pageIndex, route: .textLayer))
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
                // OCR fallback path — page has no usable text layer
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

    // MARK: - Regex Search

    private func searchRegex(
        doc: PDFDocument,
        pattern: String,
        options: SearchOptions,
        pageCount: Int,
        progress: @Sendable (Int, Int) -> Void,
        continuation: AsyncStream<SearchResult>.Continuation
    ) async {
        let regex: NSRegularExpression
        do {
            regex = try Self.validateRegexPatternWithError(pattern)
        } catch { // LegalPhrases:safe (Swift keyword)
            // The gate refused the pattern: say so once, then finish empty.
            // A silent empty stream reads as "0 results" to every consumer,
            // the verification re-check included.
            regexRejectionSink?(error.localizedDescription)
            continuation.finish()
            return
        }

        var totalYielded = 0
        // Snapshot the sink for the synchronous
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

            guard let page = doc.page(at: pageIndex) else {
                pageCoverageSink?(PageSearchCoverage(pageIndex: pageIndex, route: .unopenable))
                continue
            }
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
                        regex: regex, options: options
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

            pageCoverageSink?(PageSearchCoverage(pageIndex: pageIndex, route: .textLayer))

            // PDFPage isn't Sendable; the per-match closure below captures
            // the page reference and the compiler (Swift 6.2 / Xcode 26.3 on
            // CI) flags it. The enumeration invokes the closure synchronously
            // per match on the current thread, so the capture is treated as
            // @unchecked Sendable via the wrapper.
            let sendablePage = SendablePDFPage(page)

            let searchText = SearchCore.regexSearchText(pageText, options: options)
            let nsString = searchText as NSString

            // The shared enumeration with the per-match time check — bails
            // mid-enumeration instead of waiting for all matches to complete;
            // the cap counts only the results that could be placed on the page.
            let startTime = ContinuousClock.now
            let effectiveTimeout: Duration =
                regexTimeoutOverride ?? Self.perPageRegexTimeout
            let (yielded, _) = SearchCore.enumerateRegexMatches(
                in: searchText, regex: regex,
                wholeWord: options.wholeWord, unconvertibleRangePasses: false,
                cap: Self.maxResults - totalYielded,
                timeout: effectiveTimeout, startTime: startTime,
                onTimeout: {
                    // Search-path timeout branch.
                    timeoutSink?(pageIndex)
                }
            ) { matchRange in
                guard let normalizedRect = boundingRect(for: matchRange, page: sendablePage.page) else {
                    return false
                }
                let matchedText = nsString.substring(with: matchRange)
                let window = contextSnippet(
                    text: searchText,
                    matchNSRange: matchRange
                )

                continuation.yield(SearchResult(
                    pageIndex: pageIndex,
                    normalizedRect: normalizedRect,
                    matchedText: matchedText,
                    contextSnippet: window.snippet,
                    source: .textLayer,
                    term: pattern,
                    matchRangeInSnippet: window.matchRange
                ))
                return true
            }
            totalYielded += yielded

            if totalYielded >= Self.maxResults { break }
        }

        continuation.finish()
    }

    // MARK: - Multi-Term Search

    private func searchMultiTerm(
        doc: PDFDocument,
        terms: [String],
        options: SearchOptions,
        pageCount: Int,
        progress: @Sendable (Int, Int) -> Void,
        continuation: AsyncStream<SearchResult>.Continuation
    ) async {
        // Empty and whitespace-only entries carry no query: drop them
        // before either arm reads the list. Left in, the AND arm demanded
        // a term no page could carry and its result set was always empty;
        // the OR arm ran a lone space as a live query. The live preview
        // already filters the same way, so the full search now agrees
        // with it. An all-blank list finishes at once.
        let terms = terms.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !terms.isEmpty else {
            continuation.finish()
            return
        }

        // AND mode requires accumulate-then-filter-then-stream.
        // OR mode (default) streams results directly as before (zero behavior change).
        if options.multiTermConjunction {
            // Accumulation phase: collect all per-term results up to maxResults.
            // Peak memory is bounded by the existing cap — no page-streaming
            // variant is needed.
            var accumulated: [SearchResult] = []

            for pageIndex in 0..<pageCount {
                if Task.isCancelled || accumulated.count >= Self.maxResults { break }
                // Per-page yield (mirrors searchRegex) so
                // queued actor setters drain on each page boundary; the .rich
                // text-layer arm otherwise holds the actor for the whole document.
                await Task.yield()
                progress(pageIndex + 1, pageCount)

                guard let page = doc.page(at: pageIndex) else {
                pageCoverageSink?(PageSearchCoverage(pageIndex: pageIndex, route: .unopenable))
                continue
            }
                let pageText = page.string ?? ""
                // Text-layer fast path only for `.rich`/unknown
                // pages; `.sparse`/`.none` fall through to OCR per term.
                let useTextLayer = !pageText.isEmpty && pageHasRichTextLayer(pageIndex)
                if useTextLayer { pageCoverageSink?(PageSearchCoverage(pageIndex: pageIndex, route: .textLayer)) }

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
            // at least one result.
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

            guard let page = doc.page(at: pageIndex) else {
                pageCoverageSink?(PageSearchCoverage(pageIndex: pageIndex, route: .unopenable))
                continue
            }
            let pageText = page.string ?? ""
            // Text-layer fast path only for `.rich`/unknown
            // pages; `.sparse`/`.none` fall through to OCR per term.
            let useTextLayer = !pageText.isEmpty && pageHasRichTextLayer(pageIndex)
            if useTextLayer { pageCoverageSink?(PageSearchCoverage(pageIndex: pageIndex, route: .textLayer)) }

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

    // MARK: - PII Scan

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

            guard let page = doc.page(at: pageIndex) else {
                pageCoverageSink?(PageSearchCoverage(pageIndex: pageIndex, route: .unopenable))
                continue
            }
            let pageText = page.string ?? ""

            if !pageText.isEmpty && pageHasRichTextLayer(pageIndex) {
                // Text-layer path: run PIIDetector on extracted text,
                pageCoverageSink?(PageSearchCoverage(pageIndex: pageIndex, route: .textLayer))
                // then map NSRange → bounding rect via PDFKit selection.
                var rawMatches = await piiDetector.detect(in: pageText, categories: categories)
                // Spatial address assembly on the text leg. The line
                // records come from `EmbeddedTextSource.make` — the SAME
                // provider the orchestrator's embedded fast path feeds
                // the assembler (word enumeration → per-word selection bounds
                // → y-bucketed lines, displayed-space normalized) —
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
                // Cross-category overlap resolution before threshold
                // filter, mirroring DetectionOrchestrator.detectPage.
                let resolution = DetectionOrchestrator.resolveOverlaps(rawMatches)
                if !resolution.suppressedCountByCategory.isEmpty {
                    overlapSink?(resolution.suppressedCountByCategory)
                }
                // Never-flag suppression runs BEFORE threshold filter
                // so suppressed matches don't compete in the threshold vote
                // (user always wins). V1 flat-N1 passes
                // `doctype: nil`; the parameter is reserved for V1.1+.
                let merged = userTermsIndex?.merge(
                    into: resolution.surviving, doctype: nil
                ) ?? resolution.surviving
                // Site-B parity: partition, gate, compose, re-sort — the
                // text feature source is `pageText` (in scope).
                let matches = gateAndCompose(merged, pageText: pageText)
                for match in matches {
                    if Task.isCancelled || totalYielded >= Self.maxResults { break }

                    // An assembled spatial survivor uses the stored
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
                    // block is its own context, so the window is the whole
                    // text. Regex/detector matches always carry a non-empty
                    // range and take the canonical context window.
                    let window = match.range.length > 0
                        ? contextSnippet(text: pageText, matchNSRange: match.range)
                        : ContextWindow(snippet: match.text, matchRange: 0..<match.text.count)

                    continuation.yield(SearchResult(
                        pageIndex: pageIndex,
                        normalizedRect: normalizedRect,
                        matchedText: match.text,
                        contextSnippet: window.snippet,
                        source: .textLayer,
                        term: match.category?.rawValue ?? "PII",
                        piiCategory: match.category,
                        piiConfidence: match.confidence,
                        rationale: match.rationale,
                        matchRangeInSnippet: window.matchRange
                    ))
                    totalYielded += 1
                }

                // Always-flag synthetic hits. Emitted after detector
                // survivors; downstream `applySearchResults` 80% overlap
                // dedup collapses any collision with a detector-emitted
                // hit at the same range. This path stays verbatim —
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
                        let window = contextSnippet(
                            text: pageText, matchNSRange: hit.range
                        )
                        continuation.yield(SearchResult(
                            pageIndex: pageIndex,
                            normalizedRect: normalizedRect,
                            matchedText: matchedText,
                            contextSnippet: window.snippet,
                            source: .textLayer,
                            term: "Custom",
                            piiCategory: nil,
                            piiConfidence: nil,
                            rationale: MatchRationale.Builder(
                                ruleID: "user.alwaysFlag", preThresholdScore: 1.0,
                                signals: [.userAlwaysFlag(pattern: hit.pattern)]
                            ).build(finalScore: 1.0),
                            matchRangeInSnippet: window.matchRange
                        ))
                        totalYielded += 1
                    }
                    // Surface per-(page, pattern) timeouts so the
                    // app layer can enqueue the custom-terms-skip toast.
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

    /// H1.2 document-harness seam -- force the OCR leg on a page regardless of
    /// its text-layer status. The product routes rich pages down the text path,
    /// so the harness's forced-OCR measurement (rotated / born-digital pages)
    /// needs a direct entry to the same private OCR body the product runs on
    /// `.sparse`/`.none` pages. Observation-only, no new behavior; internal for
    /// `@testable` reach, mirroring `_testComposeSiteB` (DEBUG-only like it —
    /// the harness runs Debug builds).
    #if DEBUG
    func _testScanPagePIIViaOCR(
        page: SendablePDFPage,
        pageIndex: Int,
        categories: Set<PIICategory>
    ) async -> [SearchResult] {
        await scanPagePIIViaOCR(page: page.page, pageIndex: pageIndex, categories: categories)
    }
    #endif

    private func scanPagePIIViaOCR(
        page: PDFPage,
        pageIndex: Int,
        categories: Set<PIICategory>
    ) async -> [SearchResult] {
        // Render and OCR the page (reuses OCR cache)
        let textLines = await ocrLines(for: page, pageIndex: pageIndex)
        guard !textLines.isEmpty else { return [] }

        // PII detection reads the normalized parallel
        // cache, not verbatim Vision output. On miss, run OCRTextNormalizer
        // per line and record offsets against the normalized concatenation.
        let normalizedPage: NormalizedOCRPage
        if let cached = ocrPageCache.normalizedPage(for: pageIndex) {
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
            ocrPageCache.setNormalizedPage(normalizedPage, for: pageIndex)
        }
        let concatenated = normalizedPage.concatenated
        let lineOffsets = normalizedPage.entries

        var rawMatches = await piiDetector.detect(in: concatenated, categories: categories)
        // Spatial address assembly on the OCR leg, over the SAME
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
        // The overlap resolver runs on the OCR path too. Resolver is a
        // pure static function on DetectionOrchestrator.
        let resolution = DetectionOrchestrator.resolveOverlaps(rawMatches)
        if !resolution.suppressedCountByCategory.isEmpty {
            overlapSink?(resolution.suppressedCountByCategory)
        }
        // Site-B parity on the OCR path too (an un-routed site would leak
        // raw-gated FP for the scored families): the OCR feature text is
        // `concatenated` (the normalized page text the detector ran on),
        // NOT a `pageText` variable.
        let matches = gateAndCompose(resolution.surviving, pageText: concatenated)
        var results: [SearchResult] = []

        // Spatial mapping shared between detector matches and
        // synthetic always-flag hits. Returns nil when no OCR line covers
        // the range, mirroring the existing `continue` behavior.
        func mapToOCR(
            _ range: NSRange
        ) -> (rect: CGRect, window: ContextWindow, ocrConfidence: Float)? {
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

            let paddedRect = Self.paddedNormalizedRect(unionRect, in: page)

            // The canonical context window over the
            // normalized concatenation the detector matched in — the same
            // centered, word-trimmed, ellipsized shape as the text leg,
            // with the match located inside it.
            let window = contextSnippet(text: concatenated, matchNSRange: range)

            let ocrConfidence = overlappingLines.map(\.confidence).min() ?? firstLine.confidence
            return (paddedRect, window, ocrConfidence)
        }

        // Geometry for assembled spatial survivors: the stored union
        // rect wins over character-range mapping (mirror of the text leg's
        // rect override). When the assembled text is not present verbatim in
        // the concatenation (sentinel range → `mapToOCR` has no overlapping
        // lines), the snippet is the assembled text and the confidence is the
        // minimum over the lines the union rect covers. Non-address matches
        // flow through `mapToOCR` unchanged.
        func resolvedMapping(
            for match: PIIDetector.PIIMatch
        ) -> (rect: CGRect, window: ContextWindow, ocrConfidence: Float)? {
            guard let spatialRect =
                (match.kind == .address ? spatialRectByText[match.text] : nil) else {
                return mapToOCR(match.range)
            }
            if let mapped = mapToOCR(match.range) {
                return (spatialRect, mapped.window, mapped.ocrConfidence)
            }
            let coveredConfidence = lineOffsets
                .filter { $0.normalizedRect.intersects(spatialRect) }
                .map(\.confidence)
                .min()
            return (
                spatialRect,
                ContextWindow(snippet: match.text, matchRange: 0..<match.text.count),
                coveredConfidence ?? 1.0
            )
        }

        for match in matches {
            // Never-flag suppression on OCR path. This stays
            // post-threshold for V1; consistency follow-up to mirror the
            // text-layer pre-threshold merge is V1.1+ scope.
            if userTermsIndex?.underlyingMatcher.shouldSuppress(match.text) != nil { continue }

            guard let mapped = resolvedMapping(for: match) else { continue }

            // Fold OCR confidence into the rationale so power users can
            // see the OCR contribution alongside detector evidence.
            let rationale = match.rationale?.appending(
                .ocrConfidence(value: Double(mapped.ocrConfidence)))

            results.append(SearchResult(
                pageIndex: pageIndex,
                normalizedRect: mapped.rect,
                matchedText: match.text,
                contextSnippet: mapped.window.snippet,
                source: .ocr(confidence: mapped.ocrConfidence),
                term: match.category?.rawValue ?? "PII",
                piiCategory: match.category,
                piiConfidence: match.confidence,
                rationale: rationale,
                matchRangeInSnippet: mapped.window.matchRange
            ))
        }

        // Always-flag synthetic OCR hits. Matched against the
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
                    contextSnippet: mapped.window.snippet,
                    source: .ocr(confidence: mapped.ocrConfidence),
                    term: "Custom",
                    piiCategory: nil,
                    piiConfidence: nil,
                    rationale: MatchRationale.Builder(
                        ruleID: "user.alwaysFlag", preThresholdScore: 1.0,
                        signals: [
                            .userAlwaysFlag(pattern: hit.pattern),
                            .ocrConfidence(value: Double(mapped.ocrConfidence)),
                        ]
                    ).build(finalScore: 1.0),
                    matchRangeInSnippet: mapped.window.matchRange
                ))
            }
            // Surface per-(page, pattern) timeouts so the app
            // layer can enqueue the custom-terms-skip toast. Same
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

    // MARK: - OCR Search Path

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
        let textLines = await ocrLines(for: page, pageIndex: pageIndex)

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

            // Case-preserved analog of `ext.baseText`, used only
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
            let displayLineText = String(displayLineChars)

            var searchStart = lineText.startIndex
            while searchStart < lineText.endIndex {
                guard let matchRange = lineText.range(
                    of: lineQuery,
                    range: searchStart..<lineText.endIndex
                ) else { break }

                // The magic-wand `exactMatch` gates the same OCR
                // word-boundary check as `wholeWord`. Base-
                // coordinate variant when an offset map is active, same
                // as findTextMatches.
                if options.wholeWord || options.exactMatch {
                    let isBoundaried: Bool
                    if let baseLineChars, let map = ext.offsetMap {
                        let start = lineText.distance(from: lineText.startIndex, to: matchRange.lowerBound)
                        let len = lineText.distance(from: matchRange.lowerBound, to: matchRange.upperBound)
                        if let span = SearchCore.baseSpan(start: start, length: len, offsetMap: map) {
                            isBoundaried = SearchCore.isWholeWordInBase(
                                chars: baseLineChars, start: span.lowerBound, endExclusive: span.upperBound
                            )
                        } else {
                            isBoundaried = false
                        }
                    } else {
                        isBoundaried = SearchCore.isWholeWord(matchRange, in: lineText)
                    }
                    if !isBoundaried {
                        searchStart = matchRange.upperBound
                        continue
                    }
                }

                // Vision bounding boxes are already normalized 0–1, bottom-left origin.
                // Add padding for OCR imprecision (2pt in normalized coords).
                let paddedRect = Self.paddedNormalizedRect(line.normalizedRect, in: page)

                // The display span re-slices from the case-preserved
                // analog at base offsets; matching stays on the normalized
                // text. The norm-drift
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
                // The canonical context window in place
                // of the raw line. Built over the same case-preserved
                // analog `displaySlice` re-sliced from, at the base span,
                // so the window's match slice IS `matchedText`; when the
                // display analog drifted (the `displaySlice` fallback) the
                // window comes from the searched line at the searched
                // offsets, matching that fallback slice instead.
                let window = displayWindow(
                    displayChars: displayLineChars, displayText: displayLineText,
                    baseCount: ext.baseText.count,
                    start: displayStart, length: displayLength, offsetMap: ext.offsetMap,
                    searchedText: lineText, searchedStart: displayStart, searchedLength: displayLength
                )

                results.append(SearchResult(
                    pageIndex: pageIndex,
                    normalizedRect: paddedRect,
                    matchedText: matchedText,
                    contextSnippet: window.snippet,
                    source: .ocr(confidence: line.confidence),
                    term: term,
                    matchRangeInSnippet: window.matchRange
                ))

                searchStart = matchRange.upperBound
            }
        }

        return results
    }

    // MARK: - OCR page lines (the one render→cache→evict body for every OCR path)

    /// The OCR lines for a page, from the per-session cache when present.
    /// On a cache miss the page is rendered at 300 DPI off-actor (the
    /// SendablePDFPage + thumbnail-in-detached-Task idiom), read by Vision,
    /// and inserted through the shared eviction path so the verbatim lines
    /// and the normalized inputs stay in lockstep. The three OCR entry paths
    /// (manual OCR search, PII scan, regex OCR fallback) share this body.
    ///
    /// Memory guard: oversized pages (e.g., architectural drawings) can
    /// produce multi-gigabyte bitmaps at 300 DPI, so a page past the OCR
    /// pixel caps is skipped rather than risk an allocation crash (see KI-5
    /// re: os_proc_available_memory()). The per-axis cap admits a
    /// 10000 × 10000 (~ 400 MB) bitmap that can still trip jetsam; the
    /// pixel-count cap rejects near-axis-cap pages on top of it.
    ///
    /// Coverage: the `.ocr` route is reported once per call, after the
    /// get-or-compute block, on both the hit and the miss path; a skipped
    /// or unreadable page reports its own route and returns no lines.
    private func ocrLines(for page: PDFPage, pageIndex: Int) async -> [OCREngine.TextLine] {
        let textLines: [OCREngine.TextLine]
        if let cached = ocrPageCache.touch(pageIndex) {
            textLines = cached
        } else {
            let pageBounds = page.bounds(for: .cropBox)
            let thumbnailSize = Self.ocrThumbnailSize(
                pageBounds: pageBounds, rotation: page.rotation)
            let pixelCount = thumbnailSize.width * thumbnailSize.height
            guard thumbnailSize.width <= Self.maxOCRPixelDimension,
                  thumbnailSize.height <= Self.maxOCRPixelDimension,
                  pixelCount <= Self.maxOCRPixelCount else {
                // Report the skip so the app layer can tell the
                // user this page's image content was never text-scanned.
                ocrSkipSink?(pageIndex)
                pageCoverageSink?(PageSearchCoverage(pageIndex: pageIndex, route: .ocrSkippedOversize))
                return []
            }

            // Render off-actor — page.thumbnail is synchronous PDFKit and
            // can take seconds on a near-cap page. Holding the actor for
            // that span starves queued setters (sinks, thresholds).
            let sendablePage = SendablePDFPage(page)
            let thumbnail = await Task.detached(priority: .userInitiated) {
                sendablePage.page.thumbnail(of: thumbnailSize, for: .cropBox)
            }.value
            guard let cgImage = thumbnail.cgImage else {
                pageCoverageSink?(PageSearchCoverage(pageIndex: pageIndex, route: .ocrUnavailable))
                return []
            }

            do {
                let lines = try await ocrEngine.recognizeText(
                    in: cgImage, recognitionLevel: .accurate
                )
                ocrPageCache.insert(lines, for: pageIndex)
                textLines = lines
            } catch { // LegalPhrases:safe (Swift keyword)
                pageCoverageSink?(PageSearchCoverage(pageIndex: pageIndex, route: .ocrUnavailable))
                return []
            }
        }

        pageCoverageSink?(PageSearchCoverage(pageIndex: pageIndex, route: .ocr))
        return textLines
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
    /// Takes the caller's already-compiled (and safety-validated)
    /// `NSRegularExpression` — re-validating/re-compiling the pattern
    /// string here repeated the full precheck once per scanned page.
    private func searchPageViaOCRFallback_regex(
        page: PDFPage,
        pageIndex: Int,
        regex: NSRegularExpression,
        options: SearchOptions
    ) async -> [SearchResult] {
        let lines = await ocrLines(for: page, pageIndex: pageIndex)
        guard !lines.isEmpty else { return [] }

        // Normalize each line through OCRTextNormalizer (confusable correction)
        // then join with "\n" to build the searchable text. The per-line
        // normalize step preserves line offsets for rect mapping below.
        let normalizedLines = lines.map { self.ocrNormalizer.normalize($0.text) }
        var searchText = normalizedLines.joined(separator: "\n")
        guard !searchText.isEmpty else { return [] }
        // Page-side smart punctuation, same contract as the
        // text-layer regex path. 1:1 substitution keeps both UTF-16
        // NSRanges and the Character-offset line walk in ocrLineRect
        // aligned with the per-line lengths.
        if options.normalizeSmartPunctuation {
            searchText = TextNormalizer.normalizeSmartPunctuation(searchText)
        }

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

        SearchCore.enumerateRegexMatches(
            in: searchText, regex: regex,
            wholeWord: options.wholeWord, unconvertibleRangePasses: false,
            cap: nil,
            timeout: effectiveTimeout, startTime: startTime,
            onTimeout: { snapshotTimeoutSink?(pageIndex) }
        ) { matchRange in
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
            ) else { return false }

            let matchedText = nsString.substring(with: matchRange)
            let window = contextSnippet(text: searchText, matchNSRange: matchRange)

            results.append(SearchResult(
                pageIndex: pageIndex,
                normalizedRect: normalizedRect,
                matchedText: matchedText,
                contextSnippet: window.snippet,
                source: .ocr(confidence: avgConfidence),
                term: regex.pattern,
                matchRangeInSnippet: window.matchRange
            ))
            return true
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
        // Per-page CJK detection disables the boundary check (see
        // `SearchCore.effectiveOptions`); the full tier detects, the preview
        // does not.
        let effectiveOptions = SearchCore.effectiveOptions(options, pageText: pageText, detectCJK: true)

        let normalizedQuery = SearchCore.normalizedText(query, options: effectiveOptions)
        guard !normalizedQuery.isEmpty else { return [] }

        // Recall extensions on top of the NFKC path (the shared
        // preparation). Smart punctuation is 1:1 (length-preserving), so rect
        // NSRanges stay in the normalized text's coordinates. Diacritic fold
        // and separator strip are length-changing: matching runs on the
        // transformed text and every match range routes through the offset
        // map back to base coordinates BEFORE the rect is computed (Risk 1: a
        // wrong rect is a misplaced redaction).
        let prepared = SearchCore.preparePage(pageText, options: effectiveOptions)
        let searchPageText = prepared.searchText
        let searchQuery = SearchCore.preparedQuery(normalized: normalizedQuery, options: effectiveOptions)
        // The strip path can empty a query made of separators only.
        guard !searchQuery.isEmpty else { return [] }

        // Case-preserved analog of the base text, used only to
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
        let displayBaseText = String(displayBaseChars)

        var results: [SearchResult] = []

        // `exactMatch` is the magic-wand select-by-similar-text call-site
        // flag; semantically equivalent to `wholeWord` on the
        // text/multi-term/OCR paths.
        let (spans, _) = SearchCore.literalSpans(
            in: prepared, query: searchQuery, comparison: [],
            wholeWord: effectiveOptions.wholeWord || effectiveOptions.exactMatch,
            cap: nil
        )
        for span in spans {
            // Offsets measured on the searched (most-transformed) text; the
            // base span is the remapped one under an offset map, else the
            // searched offsets themselves.
            let matchStartOffset = span.searchedCharacters.lowerBound
            let matchLength = span.searchedCharacters.count
            let baseStartOffset = span.base?.lowerBound ?? matchStartOffset
            let baseLength = span.base?.count ?? matchLength

            // Get bounding rect via PDFKit selection — base coordinates.
            let nsRange = NSRange(location: baseStartOffset, length: baseLength)
            if let normalizedRect = boundingRect(for: nsRange, page: page) {
                // Display span re-slices from the case-preserved
                // analog at the already-mapped base offsets; matching stays
                // on the normalized text. The
                // norm-drift trap is guarded inside `displaySlice`,
                // which falls back to the normalized slice on drift.
                let normalizedSlice = String(searchPageText[span.searchedIndices])
                let matchedText = Self.displaySlice(
                    start: baseStartOffset, length: baseLength,
                    offsetMap: nil,
                    displayChars: displayBaseChars,
                    baseCount: prepared.baseText.count,
                    fallback: normalizedSlice)
                // The context window is built over the
                // same case-preserved analog `displaySlice` re-sliced from,
                // at the base span, so its match slice IS `matchedText`; on
                // display drift (the `displaySlice` fallback) it comes from
                // the searched text at the searched offsets instead.
                let window = displayWindow(
                    displayChars: displayBaseChars, displayText: displayBaseText,
                    baseCount: prepared.baseText.count,
                    start: baseStartOffset, length: baseLength, offsetMap: nil,
                    searchedText: searchPageText, searchedStart: matchStartOffset, searchedLength: matchLength
                )

                results.append(SearchResult(
                    pageIndex: pageIndex,
                    normalizedRect: normalizedRect,
                    matchedText: matchedText,
                    contextSnippet: window.snippet,
                    source: .textLayer,
                    term: term,
                    matchRangeInSnippet: window.matchRange
                ))
            }
        }

        return results
    }

}
