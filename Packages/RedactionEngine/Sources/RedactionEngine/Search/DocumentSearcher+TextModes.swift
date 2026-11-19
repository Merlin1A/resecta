import Foundation
import PDFKit

// Moved whole from DocumentSearcher.swift; no line inside a moved body changes.

extension DocumentSearcher {

    // MARK: - Text Search

    func searchText(
        doc: PDFDocument,
        query: String,
        options: SearchOptions,
        pageCount: Int,
        progress: @Sendable (Int, Int) -> Void,
        continuation: AsyncStream<SearchResult>.Continuation
    ) async {
        var totalYielded = 0
        var seam: SeamPage? = nil

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
                let results = await withInkFitRead(page) { findTextMatches(
                    pageText: pageText, query: query, options: options,
                    page: page, pageIndex: pageIndex, term: query
                ) }
                let hybrid = await hybridOCRLeg(page: page, pageIndex: pageIndex, textLayerRects: results.map(\.normalizedRect),
                    includeOCR: options.includeOCR) { await self.searchPageViaOCR(page: page, pageIndex: pageIndex, query: query, options: options, term: query) }
                let seamHits = await pageSeamMatches(from: seam, to: page, pageIndex: pageIndex, pageText: pageText, query: query, options: options, term: query)
                emitCapped(results + hybrid + seamHits, into: continuation, total: &totalYielded)
                seam = SeamPage(index: pageIndex, page: page, text: pageText)
            } else if options.includeOCR {
                // OCR fallback path — page has no usable text layer
                // (empty, or a `.sparse`/`.none` layer over a scanned body)
                let ocrResults = await searchPageViaOCR(
                    page: page, pageIndex: pageIndex,
                    query: query, options: options, term: query
                )
                emitCapped(ocrResults, into: continuation, total: &totalYielded)
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

    func searchRegex(
        doc: PDFDocument,
        pattern: String,
        options: SearchOptions,
        pageCount: Int,
        progress: @Sendable (Int, Int) -> Void,
        continuation: AsyncStream<SearchResult>.Continuation
    ) async {
        let regex: NSRegularExpression
        do {
            regex = try Self.validateRegexPatternWithError(pattern, options: options)
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
                    emitCapped(ocrResults, into: continuation, total: &totalYielded)
                    if totalYielded >= Self.maxResults { break }
                } else if !pageHasRichTextLayer(pageIndex) {
                    // Scanned region with OCR disabled: not
                    // analyzed. Surface the signal.
                    scannedRegionNotAnalyzedSink?(pageIndex)
                }
                continue
            }

            pageCoverageSink?(PageSearchCoverage(pageIndex: pageIndex, route: .textLayer))

            // PDFPage isn't Sendable; the per-match closure below captures the
            // page (the enumeration invokes it synchronously), via the wrapper.
            let sendablePage = await preparedForInkFit(page)
            // The page with its route back to the raw text (`rawNSRange`).
            let regexPage = SearchCore.regexPage(pageText, options: options)
            let searchText = regexPage.text
            let nsString = searchText as NSString

            // The shared enumeration with the per-match time check — bails
            // mid-enumeration instead of waiting for all matches to complete;
            // the cap counts every result yielded, a match with no box included.
            let startTime = ContinuousClock.now
            let effectiveTimeout: Duration =
                regexTimeoutOverride ?? Self.perPageRegexTimeout
            var pageRects: [CGRect] = []
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
                guard let rawRange = regexPage.rawNSRange(matchRange) else { return false }
                let matchedText = nsString.substring(with: matchRange)
                let window = contextSnippet(
                    text: searchText,
                    matchNSRange: matchRange
                )
                guard let rects = textLayerLines(for: rawRange, page: sendablePage.page) else {
                    // Found, but no box: listed with its page, never dropped.
                    continuation.yield(.unboxed(
                        pageIndex: pageIndex, matchedText: matchedText,
                        contextSnippet: window.snippet, source: .textLayer, term: pattern,
                        matchRangeInSnippet: window.matchRange,
                        liesOffVisiblePage: liesOffVisiblePage(rawRange, page: sendablePage.page)))
                    return true
                }
                // One result per line the match touches (the counting rule).
                let occurrence = rects.count > 1 ? UUID() : nil
                pageRects.append(contentsOf: rects.map(\.rect))
                for line in rects {
                    continuation.yield(SearchResult(
                        pageIndex: pageIndex,
                        normalizedRect: line.rect,
                        matchedText: matchedText,
                        contextSnippet: window.snippet,
                        source: .textLayer,
                        term: pattern,
                        matchRangeInSnippet: window.matchRange,
                        occurrenceID: occurrence, textLayerRect: line.textLayerRect, inkFitDegraded: line.degraded
                    ))
                }
                return true
            }
            totalYielded += yielded
            emitCapped(await hybridOCRLeg(page: page, pageIndex: pageIndex, textLayerRects: pageRects, includeOCR: options.includeOCR) {
                await self.searchPageViaOCRFallback_regex(page: page, pageIndex: pageIndex, regex: regex, options: options) }, into: continuation, total: &totalYielded)

            if totalYielded >= Self.maxResults { break }
        }

        continuation.finish()
    }

    // MARK: - Multi-Term Search

    func searchMultiTerm(
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

        // AND mode filters each page as it completes, then streams it: a
        // page is kept when every term matched on it, and the result cap
        // counts the survivors, so a page dense in one term alone cannot
        // use up the cap for the pages that carry every term.
        // OR mode (default) streams results directly as before (zero behavior change).
        if options.multiTermConjunction {
            let allTerms = Set(terms)
            var totalYielded = 0
            var seam: SeamPage? = nil

            for pageIndex in 0..<pageCount {
                if Task.isCancelled || totalYielded >= Self.maxResults { break }
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

                var pageHits: [SearchResult] = []
                for term in terms {
                    if Task.isCancelled { break }

                    if useTextLayer {
                        let hits = await withInkFitRead(page) { findTextMatches(pageText: pageText, query: term, options: options, page: page, pageIndex: pageIndex, term: term) }
                        pageHits += hits + (await hybridOCRLeg(page: page, pageIndex: pageIndex, textLayerRects: hits.map(\.normalizedRect), includeOCR: options.includeOCR,
                            reportsWhenOff: term == terms.first) { await self.searchPageViaOCR(page: page, pageIndex: pageIndex, query: term, options: options, term: term) })
                        pageHits += await pageSeamMatches(from: seam, to: page, pageIndex: pageIndex, pageText: pageText, query: term, options: options, term: term)
                    } else if options.includeOCR {
                        pageHits.append(contentsOf: await searchPageViaOCR(
                            page: page, pageIndex: pageIndex,
                            query: term, options: options, term: term
                        ))
                    }
                }
                if useTextLayer { seam = SeamPage(index: pageIndex, page: page, text: pageText) }
                // Scanned region (`.sparse`/`.none`) with OCR
                // off: not analyzed. Fire once per page, after all terms.
                if !pageHasRichTextLayer(pageIndex) && !options.includeOCR {
                    scannedRegionNotAnalyzedSink?(pageIndex)
                }

                // The conjunction: the page streams only when every term
                // matched on it; the cap counts what streams.
                guard allTerms.isSubset(of: Set(pageHits.map(\.term))) else { continue }
                emitCapped(pageHits, into: continuation, total: &totalYielded)
            }

            continuation.finish()
            return
        }

        // OR mode: stream results directly as terms match, page-first.
        var totalYielded = 0
        var seam: SeamPage? = nil

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
                    let results = await withInkFitRead(page) { findTextMatches(
                        pageText: pageText, query: term, options: options,
                        page: page, pageIndex: pageIndex, term: term
                    ) }
                    let hybrid = await hybridOCRLeg(page: page, pageIndex: pageIndex, textLayerRects: results.map(\.normalizedRect), includeOCR: options.includeOCR,
                        reportsWhenOff: term == terms.first) { await self.searchPageViaOCR(page: page, pageIndex: pageIndex, query: term, options: options, term: term) }
                    let seamHits = await pageSeamMatches(from: seam, to: page, pageIndex: pageIndex, pageText: pageText, query: term, options: options, term: term)
                    emitCapped(results + hybrid + seamHits, into: continuation, total: &totalYielded)
                } else if options.includeOCR {
                    let ocrResults = await searchPageViaOCR(
                        page: page, pageIndex: pageIndex,
                        query: term, options: options, term: term
                    )
                    emitCapped(ocrResults, into: continuation, total: &totalYielded)
                }
            }
            if useTextLayer { seam = SeamPage(index: pageIndex, page: page, text: pageText) }
            // Scanned region (`.sparse`/`.none`) with OCR off:
            // not analyzed. Fire once per page, after all terms.
            if !pageHasRichTextLayer(pageIndex) && !options.includeOCR {
                scannedRegionNotAnalyzedSink?(pageIndex)
            }
        }

        continuation.finish()
    }
}
