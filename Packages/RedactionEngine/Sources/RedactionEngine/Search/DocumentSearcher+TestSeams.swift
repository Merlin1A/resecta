import Foundation

// The DEBUG-only observation and seeding seams the harness and the cache-coherence
// suites drive. Moved whole from DocumentSearcher.swift; no line inside a moved body
// changes.

extension DocumentSearcher {

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
}
