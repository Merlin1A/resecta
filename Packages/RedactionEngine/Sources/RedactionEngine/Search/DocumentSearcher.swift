import Foundation
import NaturalLanguage
import PDFKit

// Engine-layer document search with text-layer,
// regex, and OCR paths. Returns results via AsyncStream for progressive UI.
// Page coverage reporting for the verification re-check
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
    static let maxOCRPixelDimension: CGFloat = 10_000

    /// Total-pixel ceiling for OCR rendering. The per-axis cap above
    /// admits a 10000 × 10000 thumbnail (≈ 400 MB RGBA8) that can trip
    /// jetsam on memory-constrained devices; cap the product at ≈ 36 MP
    /// (≈ 144 MB RGBA8) so near-axis-cap pages are also skipped.
    static let maxOCRPixelCount: CGFloat = 36_000_000

    // MARK: - Dependencies

    let ocrEngine: OCREngine

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
    let piiDetector = DocumentSearcher.sharedPIIDetectorLoad.detector

    /// Diagnostics for the process-shared search detector.
    /// Cached with the detector — the probe reflects load-time state, which
    /// is the state every search in this process actually runs under.
    public static var sharedLoadDiagnostics: GazetteerLoadDiagnostics {
        sharedPIIDetectorLoad.diagnostics
    }

    // Site-B / Search parity. The five scored families
    // {account, phone, mrn, ein, itin} gate at Search on the composed
    // posterior (prior floor, context term, calibrated scorer),
    // rather than on raw match.confidence. Both are `Sendable` value types,
    // constructed once at actor init and shared across pages.
    // `contextScorer` is whole-scorer
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

    // Spatial address assembly on the Search legs. Without
    // `AddressSpatialAssembler` over per-line records,
    // both Search legs ran
    // only the flat single-line regex arms, so a multi-line address block
    // never became a Search candidate on either leg. The assembler is a
    // Sendable value whose gazetteer load is cached statically
    // (`AddressSpatialAssembler.sharedAddressComponents`), so per-searcher
    // construction is cheap. See `assembledAddressMatches(lines:haystack:boxOf:)`.
    let addressAssembler = AddressSpatialAssembler()

    // Optional preset-threshold vector applied to PII matches before
    // conversion to SearchResult. nil disables gating (no vector installed).
    // Set via `setThresholdVector(_:)` before each search kickoff so the UI
    // layer can snapshot the user's current settings state.
    var thresholdVector: PresetThresholdVector?

    // Optional compiled user term index. nil (or an empty
    // index) leaves `.piiScan` behavior unchanged. Set via
    // `setUserTerms(_:)` alongside `setThresholdVector(_:)` before each
    // scan kickoff. The index wraps the underlying `UserTermMatcher` in
    // `UserTermsIndex` so never-flag suppression can run pre-threshold
    // via `UserTermsIndex.merge(into:doctype:)`.
    var userTermsIndex: UserTermsIndex?

    // Optional sink for per-page cross-category overlap-suppressed
    // counts. Installed before a scan to route resolver output into the
    // app-layer CoverageReport aggregator. Runs after `piiDetector.detect`
    // and before threshold filtering, mirroring DetectionOrchestrator.
    var overlapSink: (@Sendable ([PIICategory: Int]) -> Void)?

    // Optional sink for the per-page count of matches dropped
    // for falling below their preset threshold (the raw-gate drops on `restText`
    // / `restOCR`). Fired beside `overlapSink` so the app-layer CoverageReport's
    // "below threshold" line is truthful instead of a hardcoded 0. Scored
    // families bypass the raw gate via `composedSurvivors`, so their posterior
    // drops are intentionally NOT counted here.
    var belowThresholdSink: (@Sendable (Int) -> Void)?

    // Optional sink for per-page regex-timeout pages.
    // Fires once per page where the regex enumerator bails on the
    // `perPageRegexTimeout` ceiling, in both the live-preview path
    // (`previewRegex`) and the full-scan path (`searchRegex`). The app
    // layer accumulates page indices to render the regex-timeout banner.
    var regexTimeoutSink: (@Sendable (Int) -> Void)?
    /// Fired once, with the gate's reason, when a regex search starts on a
    /// pattern the safety gate refuses; the stream then finishes empty.
    /// Without it an empty stream reads as "0 results" to every consumer.
    var regexRejectionSink: (@Sendable (String) -> Void)?

    // Optional sink for per-page oversized-OCR-skip reporting.
    // Fires once per page whose 300-DPI render exceeds the OCR pixel caps
    // (`maxOCRPixelDimension` / `maxOCRPixelCount`) and is therefore never
    // OCR'd, in all three OCR entry paths (manual OCR search, PII scan,
    // regex OCR fallback). Reporting-only: the skip behavior itself is
    // unchanged. The app layer accumulates page indices to render the
    // OCR-skip banner alongside the regex-timeout banner.
    var ocrSkipSink: (@Sendable (Int) -> Void)?

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
    var userTermsTimeoutSink: (@Sendable (Int, String) -> Void)?

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
    var textLayerStatusByPage: [Int: TextLayerStatus]

    // Optional sink fired once per page that carries a scanned
    // region (`.sparse`/`.none`) left un-analyzed because `options.includeOCR`
    // is false, so its body text was not searched. The app layer surfaces the
    // "scanned region not analyzed" signal. Only trips when text-layer status is
    // supplied (production); absent-status callers (default `[:]`) never fire it.
    // Side-effect only — never changes which results are yielded.
    var scannedRegionNotAnalyzedSink: (@Sendable (Int) -> Void)?

    // Per-page coverage reporting. Fires for every page a search visits
    // with which evidence the page was read from (text layer · OCR) or why
    // it was not read (OCR pixel cap · OCR unavailable · unopenable page).
    // Set by the verification search re-check and by the app's Search run,
    // whose account of what was read is made from these reports; nil in
    // every other caller. A page is reported as it starts, before it is
    // matched, so a consumer that stops early must not take a report for a
    // page past its stop as a read (the app's account does not).
    // Reporting-only: it never changes which results are yielded. May fire
    // more than once per page (the multi-term OCR path runs per term);
    // consumers dedupe by page.
    var pageCoverageSink: (@Sendable (PageSearchCoverage) -> Void)?

    /// The coverage sink as it stood when this walk started, for every report
    /// the walk makes. A walk reads it, never `pageCoverageSink`, so a walk a
    /// later run has replaced reports into its own run's sink and not the new
    /// one's, however long its awaits take.
    @TaskLocal static var walkCoverageSink: (@Sendable (PageSearchCoverage) -> Void)? = nil

    // MARK: - Per-Session Caches

    /// The OCR page caches — the verbatim Vision lines, the LRU access
    /// order and the normalized PII-scan inputs — one value owned by this
    /// actor. See `OCRPageCache`.
    var ocrPageCache = OCRPageCache()
    typealias NormalizedOCRPage = OCRPageCache.NormalizedPage
    typealias NormalizedLineEntry = OCRPageCache.NormalizedLineEntry
    let ocrNormalizer = OCRTextNormalizer()

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
    func composedSurvivors(
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
}
