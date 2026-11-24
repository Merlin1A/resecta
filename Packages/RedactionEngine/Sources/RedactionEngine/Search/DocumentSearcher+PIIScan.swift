import Foundation
import PDFKit

// Moved from DocumentSearcher.swift (cd4d1afc); both legs now take each
// address copy's box by its place (`takeBox`), not by its text alone.

extension DocumentSearcher {

    // MARK: - PII Scan

    /// Scan the document for PII patterns using PIIDetector.
    /// Text-layer first with OCR fallback, same as text search.
    /// Each PIIMatch is converted to a SearchResult with category and confidence.
    func searchPII(
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
            // Per-page yield (mirrors searchRegex) so queued actor setters drain on each page boundary.
            await Task.yield()
            progress(pageIndex + 1, pageCount)

            guard let page = doc.page(at: pageIndex) else {
                pageCoverageSink?(PageSearchCoverage(pageIndex: pageIndex, route: .unopenable))
                continue
            }
            let pageText = page.string ?? ""

            if !pageText.isEmpty && pageHasRichTextLayer(pageIndex) {
                // Text-layer path: PIIDetector on the extracted text, then NSRange → bounding rect via PDFKit selection.
                pageCoverageSink?(PageSearchCoverage(pageIndex: pageIndex, route: .textLayer))
                var rawMatches = await afterInkFitRead(page, await piiDetector.detect(in: pageText, categories: categories))
                // Spatial address assembly on the text leg. The line
                // records come from `EmbeddedTextSource.make` — the SAME
                // provider the orchestrator's embedded fast path feeds
                // the assembler (word enumeration → per-word selection bounds
                // → y-bucketed lines, displayed-space normalized) —
                // so Search and the detection path see identical line
                // geometry for the same page; each line grown to its own
                // drawn glyphs (`addressLines(on:)`).
                var spatialRectByText: [String: TextLayerBox] = [:]
                var boxesByPlace: [AddressPlace: [TextLayerBox]] = [:]
                if categories.contains(.address),
                   let lines = addressLines(on: page) {
                    let assembly = assembledAddressMatches(
                        lines: lines, haystack: pageText as NSString,
                        boxOf: { [self] in textLayerBox(for: $0, page: page)?.rect })
                    rawMatches.append(contentsOf: assembly.matches)
                    spatialRectByText = assembly.spatialRectByText
                    boxesByPlace = assembly.boxesByPlace
                }
                // Cross-category overlap resolution before the threshold filter.
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
                var pageRects: [CGRect] = []
                for match in matches {
                    if Task.isCancelled || totalYielded >= Self.maxResults { break }

                    // An assembled spatial survivor uses the stored
                    // union rect: its range is either the sentinel (no
                    // selection exists) or the located anchor text (whose
                    // selection would cover only part of the block). Every
                    // other match keeps PDFKit selection geometry unchanged.
                    let found: TextLayerBox?
                    if let spatialBox = match.kind == .address
                        ? Self.takeBox(for: match, from: &boxesByPlace) ?? spatialRectByText[match.text] : nil {
                        found = spatialBox
                    } else {
                        found = textLayerBox(for: match.range, page: page)
                    }
                    // Sentinel-ranged assembly (zero length): the joined
                    // block is its own context, so the window is the whole
                    // text. Regex/detector matches always carry a non-empty
                    // range and take the canonical context window.
                    let window = match.range.length > 0
                        ? contextSnippet(text: pageText, matchNSRange: match.range)
                        : ContextWindow(snippet: match.text, matchRange: 0..<match.text.count)
                    guard let box = found else {
                        // Found, but no box: listed with its page, never dropped.
                        continuation.yield(.unboxed(
                            pageIndex: pageIndex, matchedText: match.text,
                            contextSnippet: window.snippet, source: .textLayer,
                            term: match.category?.rawValue ?? "PII",
                            piiCategory: match.category, piiConfidence: match.confidence,
                            rationale: match.rationale, matchRangeInSnippet: window.matchRange,
                            liesOffVisiblePage: match.range.length > 0 && liesOffVisiblePage(match.range, page: page)))
                        totalYielded += 1
                        continue
                    }

                    pageRects.append(box.mergeIdentity)
                    continuation.yield(SearchResult(
                        pageIndex: pageIndex,
                        normalizedRect: box.rect,
                        matchedText: match.text,
                        contextSnippet: window.snippet,
                        source: .textLayer,
                        term: match.category?.rawValue ?? "PII",
                        piiCategory: match.category,
                        piiConfidence: match.confidence,
                        rationale: match.rationale,
                        matchRangeInSnippet: window.matchRange, textLayerRect: box.textLayerRect, inkFitDegraded: box.degraded
                    ).identified(by: box.identity))
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
                        let ns = pageText as NSString
                        let matchedText = ns.substring(with: hit.range)
                        let window = contextSnippet(
                            text: pageText, matchNSRange: hit.range
                        )
                        guard let box = textLayerBox(for: hit.range, page: page) else {
                            // Found, but no box: listed with its page, never dropped.
                            continuation.yield(.unboxed(
                                pageIndex: pageIndex, matchedText: matchedText,
                                contextSnippet: window.snippet, source: .textLayer, term: "Custom",
                                rationale: MatchRationale.Builder(
                                    ruleID: "user.alwaysFlag", preThresholdScore: 1.0,
                                    signals: [.userAlwaysFlag(pattern: hit.pattern)]
                                ).build(finalScore: 1.0),
                                matchRangeInSnippet: window.matchRange,
                                liesOffVisiblePage: liesOffVisiblePage(hit.range, page: page)))
                            totalYielded += 1
                            continue
                        }
                        pageRects.append(box.mergeIdentity)
                        continuation.yield(SearchResult(
                            pageIndex: pageIndex,
                            normalizedRect: box.rect,
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
                            matchRangeInSnippet: window.matchRange, textLayerRect: box.textLayerRect, inkFitDegraded: box.degraded
                        ).identified(by: box.identity))
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
                emitCapped(await hybridOCRLeg(page: page, pageIndex: pageIndex, textLayerRects: pageRects, includeOCR: options.includeOCR) {
                    await self.scanPagePIIViaOCR(page: page, pageIndex: pageIndex, categories: categories) }, into: continuation, total: &totalYielded)
            } else if options.includeOCR {
                // OCR fallback: render page, OCR, then run PIIDetector on OCR text.
                let ocrResults = await scanPagePIIViaOCR(
                    page: page, pageIndex: pageIndex,
                    categories: categories
                )
                emitCapped(ocrResults, into: continuation, total: &totalYielded)
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

        // PII detection reads the normalized parallel cache, not verbatim
        // Vision output. On miss, run OCRTextNormalizer per line and record
        // UTF-16 offsets (the detector's NSRange unit) into the concatenation.
        let normalizedPage: NormalizedOCRPage
        if let cached = ocrPageCache.normalizedPage(for: pageIndex) {
            normalizedPage = cached
        } else {
            normalizedPage = normalizedOCRPage(textLines)
            ocrPageCache.setNormalizedPage(normalizedPage, for: pageIndex)
        }
        let accurate = await piiOCRMatches(
            normalizedPage: normalizedPage, page: page, pageIndex: pageIndex,
            categories: categories, reportsToSinks: true)
        // iOS 27: the same scan over the page's fast read, merged; its
        // overlap counts and pattern timeouts are not reported twice.
        guard Self.readsFastOCRBeside, let fast = ocrPageCache.fastLines(for: pageIndex), !fast.isEmpty else {
            return accurate
        }
        let fastPage: NormalizedOCRPage
        if let cached = ocrPageCache.fastNormalizedPage(for: pageIndex) {
            fastPage = cached
        } else {
            fastPage = normalizedOCRPage(fast)
            ocrPageCache.setFastNormalizedPage(fastPage, for: pageIndex)
        }
        return Self.unionFastOCRResults(
            accurate: accurate,
            fast: await piiOCRMatches(
                normalizedPage: fastPage, page: page, pageIndex: pageIndex,
                categories: categories, reportsToSinks: false))
    }

    /// One recognition's lines through OCRTextNormalizer, joined with "\n",
    /// with each line's UTF-16 offset (the detector's NSRange unit).
    private func normalizedOCRPage(_ textLines: [OCREngine.TextLine]) -> NormalizedOCRPage {
        var concat = ""
        var entries: [NormalizedLineEntry] = []
        entries.reserveCapacity(textLines.count)
        for line in textLines {
            let normalized = ocrNormalizer.normalize(line.text)
            entries.append(NormalizedLineEntry(
                start: concat.utf16.count,
                normalizedText: normalized,
                normalizedRect: line.normalizedRect,
                confidence: line.confidence
            ))
            concat += normalized + "\n"
        }
        return NormalizedOCRPage(concatenated: concat, entries: entries)
    }

    /// The PII Scan over one recognition of a scanned page.
    private func piiOCRMatches(
        normalizedPage: NormalizedOCRPage,
        page: PDFPage,
        pageIndex: Int,
        categories: Set<PIICategory>,
        reportsToSinks: Bool
    ) async -> [SearchResult] {
        let concatenated = normalizedPage.concatenated
        let lineOffsets = normalizedPage.entries

        var rawMatches = await piiDetector.detect(in: concatenated, categories: categories)
        // Spatial address assembly on the OCR leg, over the SAME
        // normalized per-line records the detector text was built from (the
        // assembler header's long-documented Search-leg rewire). Injected
        // before resolveOverlaps, mirroring the text leg; the haystack is
        // the normalized concatenation so a located
        // range stays consistent with `lineOffsets`.
        var spatialRectByText: [String: TextLayerBox] = [:]
        var boxesByPlace: [AddressPlace: [TextLayerBox]] = [:]
        if categories.contains(.address) {
            let assemblerLines = lineOffsets.map { entry in
                OCREngine.TextLine(
                    text: entry.normalizedText,
                    normalizedRect: entry.normalizedRect,
                    confidence: entry.confidence
                )
            }
            let boxLines = Self.boxLookupLines(lineOffsets)
            let assembly = assembledAddressMatches(
                lines: assemblerLines, haystack: concatenated as NSString,
                boxOf: { [self] in ocrUnionRect(forUTF16Range: $0, lineOffsets: boxLines, page: page)?.rect })
            rawMatches.append(contentsOf: assembly.matches)
            spatialRectByText = assembly.spatialRectByText
            boxesByPlace = assembly.boxesByPlace
        }
        // The overlap resolver runs on the OCR path too. Resolver is a
        // pure static function on DetectionOrchestrator.
        let resolution = DetectionOrchestrator.resolveOverlaps(rawMatches)
        if reportsToSinks, !resolution.suppressedCountByCategory.isEmpty {
            overlapSink?(resolution.suppressedCountByCategory)
        }
        // Site-B parity on the OCR path too (an un-routed site would leak
        // raw-gated FP for the scored families): the OCR feature text is
        // `concatenated` (the normalized page text the detector ran on),
        // NOT a `pageText` variable.
        let matches = gateAndCompose(resolution.surviving, pageText: concatenated, reportsToSinks: reportsToSinks)
        var results: [SearchResult] = []

        // Spatial mapping shared between detector matches and
        // synthetic always-flag hits. Returns nil when no OCR line covers
        // the range, mirroring the existing `continue` behavior.
        func mapToOCR(
            _ range: NSRange
        ) -> (rect: CGRect, window: ContextWindow, ocrConfidence: Float)? {
            guard let (paddedRect, overlappingLines) = ocrUnionRect(
                forUTF16Range: range, lineOffsets: Self.boxLookupLines(lineOffsets), page: page
            ) else { return nil }

            // The canonical context window over the
            // normalized concatenation the detector matched in — the same
            // centered, word-trimmed, ellipsized shape as the text leg,
            // with the match located inside it.
            let window = contextSnippet(text: concatenated, matchNSRange: range)

            let ocrConfidence = overlappingLines.map(\.confidence).min() ?? 1.0
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
                (match.kind == .address
                    ? (Self.takeBox(for: match, from: &boxesByPlace) ?? spatialRectByText[match.text])?.rect : nil) else {
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

            guard let mapped = resolvedMapping(for: match) else {
                // Found, but no recognised line to place it on: listed with
                // its page, never dropped.
                let window = match.range.length > 0
                    ? contextSnippet(text: concatenated, matchNSRange: match.range)
                    : ContextWindow(snippet: match.text, matchRange: 0..<match.text.count)
                results.append(.unboxed(
                    pageIndex: pageIndex, matchedText: match.text,
                    contextSnippet: window.snippet, source: .ocr(confidence: 1.0),
                    term: match.category?.rawValue ?? "PII",
                    piiCategory: match.category, piiConfidence: match.confidence,
                    rationale: match.rationale, matchRangeInSnippet: window.matchRange))
                continue
            }

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
                let ns = concatenated as NSString
                let matchedText = ns.substring(with: hit.range)
                guard let mapped = mapToOCR(hit.range) else {
                    // Found, but no recognised line to place it on: listed.
                    let window = contextSnippet(text: concatenated, matchNSRange: hit.range)
                    results.append(.unboxed(
                        pageIndex: pageIndex, matchedText: matchedText,
                        contextSnippet: window.snippet, source: .ocr(confidence: 1.0), term: "Custom",
                        rationale: MatchRationale.Builder(
                            ruleID: "user.alwaysFlag", preThresholdScore: 1.0,
                            signals: [.userAlwaysFlag(pattern: hit.pattern)]
                        ).build(finalScore: 1.0),
                        matchRangeInSnippet: window.matchRange))
                    continue
                }
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
            if reportsToSinks, let sink = userTermsTimeoutSink {
                for pattern in alwaysFlagResult.timedOutPatterns {
                    sink(pageIndex, pattern)
                }
            }
        }

        return results
    }
}
