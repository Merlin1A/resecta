import Foundation
import PDFKit

// Moved whole from DocumentSearcher.swift; no line inside a moved body changes.

extension DocumentSearcher {

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
                regex = try Self.validateRegexPatternWithError(pattern, options: options)
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
        var currentPageRawRanges: [NSRange] = []
        var saturated = false

        for pageIndex in pageRange {
            if Task.isCancelled { break }
            // The full search's text-layer gate: a `.sparse`/`.none` page is
            // never counted from its text layer.
            guard SearchCore.textLayerIsSearchable(textLayerStatus[pageIndex]) else { continue }
            guard let pageText = await pageTextProvider(pageIndex), !pageText.isEmpty else { continue }

            let regexPage = SearchCore.regexPage(pageText, options: options)
            let isVisiblePage = (pageIndex == currentPageIndex)
            let startTime = ContinuousClock.now
            let effectiveTimeout: Duration =
                regexTimeoutOverride ?? Self.perPageRegexTimeout

            // The shared enumeration (`.reportProgress` parity with
            // `searchRegex`); the preview counts every surviving match and
            // keeps the visible page's ranges up to the highlight cap.
            let (count, stoppedAtCap) = SearchCore.enumerateRegexMatches(
                in: regexPage.text, regex: regex,
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
                    if let raw = regexPage.rawNSRange(matchRange) { currentPageRawRanges.append(raw) }
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
            currentPageMatches: currentPageMatches,
            currentPageRawRanges: currentPageRawRanges
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
        var currentPageRawRanges: [NSRange] = []
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

            // `findTextMatches`'s normalization and extensions, so the counts
            // agree with the full search (the preview does not detect CJK);
            // each visible match is emitted in base coordinates and, raw,
            // through the full search's page map.
            let page = SearchCore.preparePage(pageText, options: options)
            let isVisiblePage = (pageIndex == currentPageIndex)

            var pageCount = 0
            var pageMatches: [NSRange] = []
            var pageRawRanges: [NSRange] = []
            var everyTermMatched = true

            for term in normalizedTerms where !term.isEmpty {
                if Task.isCancelled { break }
                let remaining = Self.maxPreviewMatches - (totalCount + pageCount)
                if remaining <= 0 { saturated = true; break }
                let extTerm = SearchCore.preparedQuery(normalized: term, options: options)
                if extTerm.isEmpty { everyTermMatched = false; continue }

                let (spans, stoppedAtCap) = SearchCore.literalSpans(
                    in: page, query: extTerm, comparison: [.literal],
                    wholeWord: options.wholeWord,
                    cap: remaining
                )
                for span in spans {
                    pageCount += 1
                    if isVisiblePage && currentPageMatches.count + pageMatches.count < Self.maxCurrentPageHighlights {
                        pageMatches.append(span.previewRange)
                        if let raw = page.rawNSRange(of: span) { pageRawRanges.append(raw) }
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
                currentPageRawRanges.append(contentsOf: pageRawRanges)
            }
            if saturated { break }
        }

        return SearchPreviewResult(
            scope: scope,
            totalCount: totalCount,
            saturated: saturated,
            regexInvalid: false,
            currentPageMatches: currentPageMatches,
            currentPageRawRanges: currentPageRawRanges
        )
    }
}
