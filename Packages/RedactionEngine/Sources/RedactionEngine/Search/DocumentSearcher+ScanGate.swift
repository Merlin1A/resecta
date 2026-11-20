import Foundation
import PDFKit

// Moved whole from DocumentSearcher.swift; no line inside a moved body changes.

extension DocumentSearcher {

    // MARK: - Spatial address assembly (both PII-scan legs)

    /// Run spatial address assembly over per-line records and convert
    /// each `Assembled` into a `PIIDetector.PIIMatch`; callers append
    /// the matches
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
    func assembledAddressMatches(
        lines: [OCREngine.TextLine],
        haystack: NSString
    ) -> (matches: [PIIDetector.PIIMatch], spatialRectByText: [String: TextLayerBox]) {
        let assembled = addressAssembler.assemble(lines: lines)
        guard !assembled.isEmpty else { return ([], [:]) }

        var matches: [PIIDetector.PIIMatch] = []
        var spatialRectByText: [String: TextLayerBox] = [:]
        let sentinelLocation = haystack.length
        for address in assembled {
            if spatialRectByText[address.text] == nil {
                spatialRectByText[address.text] = TextLayerBox(rect: address.unionRect, textLayerRect: address.textLayerUnionRect, degraded: address.inkFitDegraded,
                                                             identity: address.identityUnionRect)
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
    /// `reportsToSinks` is false for the OCR leg's second pass over the fast
    /// read on iOS 27, whose drops the accurate pass already counted.
    func gateAndCompose(
        _ matches: [PIIDetector.PIIMatch],
        pageText: String,
        reportsToSinks: Bool = true
    ) -> [PIIDetector.PIIMatch] {
        let (scored, rest) = matches.partitionedByScoredFamily()
        let gated = rest.applyingCountingDrops(thresholdVector: thresholdVector)
        if reportsToSinks, gated.droppedBelowThreshold > 0 {
            belowThresholdSink?(gated.droppedBelowThreshold)
        }
        return (gated.survivors + composedSurvivors(scored, pageText: pageText))
            .sorted { $0.range.location < $1.range.location }
    }

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
    /// verification search re-check. Reporting-only; pass nil
    /// to disable. See `PageSearchCoverage`.
    public func setPageCoverageSink(_ sink: (@Sendable (PageSearchCoverage) -> Void)?) {
        self.pageCoverageSink = sink
    }

    /// Actor-isolated reader so the `nonisolated previewMatches`
    /// bridge can snapshot the sink before invoking `previewRegex`.
    func currentRegexTimeoutSink() -> (@Sendable (Int) -> Void)? {
        regexTimeoutSink
    }

    /// One read of the per-page text-layer classification for the preview's
    /// page walk (the preview is `nonisolated`; this is its one actor hop
    /// for the routing, the shape `currentRegexTimeoutSink()` already has).
    func textLayerStatusSnapshot() -> [Int: TextLayerStatus] {
        textLayerStatusByPage
    }
}
