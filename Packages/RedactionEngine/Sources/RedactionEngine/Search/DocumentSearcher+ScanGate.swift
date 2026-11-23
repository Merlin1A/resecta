import Foundation
import PDFKit

// Moved from DocumentSearcher.swift (cd4d1afc); the address placing and
// boxing have changed since (each copy placed and boxed by its own lines).

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
    /// case). Each address is placed at the occurrence of its text whose own
    /// box (`boxOf`, the leg's range-to-box reader) meets the address's union
    /// box, and at the sentinel when none meets: never at another copy's
    /// occurrence, where the overlap step would fold it into that copy. Each
    /// address's union box is kept by its place (`boxesByPlace`, text and
    /// range, a list where copies share the sentinel), so two copies of one
    /// address are each boxed on their own lines; `spatialRectByText` keeps
    /// the first copy's box by text alone, for a match no place names.
    func assembledAddressMatches(
        lines: [OCREngine.TextLine],
        haystack: NSString,
        boxOf: (NSRange) -> CGRect?
    ) -> (matches: [PIIDetector.PIIMatch], spatialRectByText: [String: TextLayerBox], boxesByPlace: [AddressPlace: [TextLayerBox]]) {
        let assembled = addressAssembler.assemble(lines: lines)
        guard !assembled.isEmpty else { return ([], [:], [:]) }

        var matches: [PIIDetector.PIIMatch] = []
        var spatialRectByText: [String: TextLayerBox] = [:]
        var boxesByPlace: [AddressPlace: [TextLayerBox]] = [:]
        for address in assembled {
            let box = TextLayerBox(rect: address.unionRect, textLayerRect: address.textLayerUnionRect, degraded: address.inkFitDegraded,
                                   identity: address.identityUnionRect)
            if spatialRectByText[address.text] == nil { spatialRectByText[address.text] = box }
            let matchRange = Self.place(address.text, meeting: address.unionRect, in: haystack, boxOf: boxOf)
            boxesByPlace[AddressPlace(text: address.text, range: matchRange), default: []].append(box)
            matches.append(PIIDetector.PIIMatch(
                text: address.text,
                range: matchRange,
                kind: .address,
                confidence: address.confidence
            ))
        }
        return (matches, spatialRectByText, boxesByPlace)
    }

    /// Where an assembled address's box is kept: its text and the range it
    /// was placed at.
    struct AddressPlace: Hashable, Sendable {
        let text: String
        let location: Int
        let length: Int
        init(text: String, range: NSRange) {
            self.text = text
            location = range.location
            length = range.length
        }
    }

    /// The occurrence of `text` in `haystack` whose own box meets `union`,
    /// else the sentinel past the end.
    nonisolated static func place(_ text: String, meeting union: CGRect, in haystack: NSString,
                                  boxOf: (NSRange) -> CGRect?) -> NSRange {
        let end = haystack.length
        var from = 0
        while from < end {
            let found = haystack.range(of: text, options: [], range: NSRange(location: from, length: end - from))
            guard found.location != NSNotFound else { break }
            if let box = boxOf(found), box.intersects(union) { return found }
            from = found.location + 1
        }
        return NSRange(location: end, length: 0)
    }

    /// The next box kept at a surviving address match's place, taken so
    /// that two copies at one place each get their own. A survivor the
    /// overlap step widened (`resolveOverlaps`, `withRange`: the text kept,
    /// the range grown to its group's span) is no longer at its own place
    /// but still contains it, so where no box is kept at its exact range it
    /// takes every box kept for its text at a place inside that range, never
    /// a sentinel's, united. Nil where none is kept.
    nonisolated static func takeBox(for match: PIIDetector.PIIMatch,
                                    from boxes: inout [AddressPlace: [TextLayerBox]]) -> TextLayerBox? {
        let key = AddressPlace(text: match.text, range: match.range)
        if var kept = boxes[key], !kept.isEmpty {
            let box = kept.removeFirst()
            boxes[key] = kept
            return box
        }
        let start = match.range.location, end = NSMaxRange(match.range)
        let inside = boxes.keys
            .filter { $0.text == match.text && $0.length > 0 && $0.location >= start && $0.location + $0.length <= end }
            .sorted { $0.location < $1.location }
        var taken: [TextLayerBox] = []
        for place in inside {
            taken += boxes[place] ?? []
            boxes[place] = []
        }
        return united(taken)
    }

    /// The boxes as one: the paint, the hidden glyphs' boxes (where any
    /// has one) and the identities (where any has one) each united, degraded
    /// when any is. Nil for none.
    nonisolated static func united(_ boxes: [TextLayerBox]) -> TextLayerBox? {
        guard let first = boxes.first else { return nil }
        guard boxes.count > 1 else { return first }
        let strips = boxes.compactMap(\.textLayerRect)
        return TextLayerBox(
            rect: boxes.dropFirst().reduce(first.rect) { $0.union($1.rect) },
            textLayerRect: strips.first.map { strips.dropFirst().reduce($0) { $0.union($1) } },
            degraded: boxes.contains(where: \.degraded),
            identity: boxes.contains { $0.identity != nil }
                ? boxes.dropFirst().reduce(first.mergeIdentity) { $0.union($1.mergeIdentity) } : nil)
    }

    /// The text layer's lines for the address assembly
    /// (`EmbeddedTextSource.make(from:fitLines:)`, each line boxed on its ink
    /// over a page image), each grown to its own words' drawn glyphs by the
    /// rule a text match's box grows by (`grown`): a line whose last letter
    /// PDFKit boxes short, or whose first word a TJ draws back, is covered to
    /// its glyphs. A line any of whose words the page's drawing does not
    /// place (`ownGlyphs` nil) keeps its box. A grown line keeps its box
    /// before the growth as `ungrownRect` (the join) and as its identity
    /// (what a hybrid page tells its repeat by). Nil where `make` is nil.
    nonisolated func addressLines(on page: PDFPage) -> [OCREngine.TextLine]? {
        guard let embedded = EmbeddedTextSource.make(from: page, fitLines: true) else { return nil }
        guard embedded.lineSpans.count == embedded.lines.count else { return embedded.lines }
        return zip(embedded.lines, embedded.lineSpans).map { line, span in
            var glyphs: [OwnGlyph]? = []
            for range in span.ranges {
                guard let own = Self.ownGlyphs(for: range, page: page) else { glyphs = nil; break }
                glyphs?.append(contentsOf: own)
            }
            let rect = grown(line.normalizedRect, line: span.pageRect, by: glyphs, page: page)
            guard rect != line.normalizedRect else { return line }
            return line.grown(to: rect)
        }
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
