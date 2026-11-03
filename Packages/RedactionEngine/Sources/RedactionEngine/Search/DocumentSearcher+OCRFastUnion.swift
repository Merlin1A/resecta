import CoreGraphics
import Foundation
import PDFKit

// Text recognition on iOS 27 can lose a word on a scanned page that its
// fast read of the same image still has (a line read as noise, two words
// read as one). On iOS 27 the routes that search a scanned page's
// recognized text (the per-line literal path, the regex fallback and the
// PII Scan) also run over the page's fast read, and add what only it
// matched. iOS 26 reads one recognition, as before.
extension DocumentSearcher {

    /// Whether this OS reads the fast recognition beside the accurate one.
    nonisolated static var readsFastOCRBeside: Bool {
        if #available(iOS 27, *) { return true }
        return false
    }

    /// The union of one route's matches over a page's accurate read and over
    /// its fast read. Accurate matches of one term with one box (the matches
    /// on one recognised line) form a group; the fast matches of that term
    /// whose boxes overlap the group's by at least half the smaller box are
    /// its fast matches, each taken by one group only. When the fast read
    /// holds MORE matches there than the accurate read, the accurate matches
    /// stay as they are and the fast matches are added beside them, with
    /// their own boxes: the accurate read missed an occurrence, and the fast
    /// boxes may not cover the one it did read, so its box is never given up
    /// (on a hybrid page each text-layer occurrence then accounts for one of
    /// these, and the occurrence only the image holds keeps a box of its
    /// own). Otherwise each fast match pairs with one accurate match, which
    /// is kept, boxed by the union of the two (the larger cover). Every fast
    /// match no group took is added. Added matches take their place in page
    /// order; the accurate matches keep theirs.
    nonisolated static func unionFastOCRResults(
        accurate: [SearchResult], fast: [SearchResult]
    ) -> [SearchResult] {
        guard !fast.isEmpty else { return accurate }
        var groups: [[Int]] = []
        for index in accurate.indices {
            if let group = groups.firstIndex(where: {
                accurate[$0[0]].term == accurate[index].term
                    && accurate[$0[0]].normalizedRect == accurate[index].normalizedRect
            }) {
                groups[group].append(index)
            } else {
                groups.append([index])
            }
        }
        var merged = accurate
        var taken = Set<Int>()         // fast matches a group took
        var added: [SearchResult] = []
        for group in groups {
            let first = accurate[group[0]]
            let hits = fast.indices.filter {
                !taken.contains($0) && fast[$0].term == first.term
                    && overlapsHalfTheSmaller(first.normalizedRect, fast[$0].normalizedRect)
            }
            taken.formUnion(hits)
            if hits.count > group.count {
                added += hits.map { fast[$0] }
            } else {
                for (a, f) in zip(group, hits) {
                    merged[a] = merged[a].boxed(merged[a].normalizedRect.union(fast[f].normalizedRect))
                }
            }
        }
        added += fast.indices.filter { !taken.contains($0) }.map { fast[$0] }
        var result = merged
        for match in added { insertInPageOrder(match, into: &result) }
        return result
    }

    /// Inserts `match` before the first result below it on the page, or, on
    /// the same row, before the first result to its right.
    nonisolated static func insertInPageOrder(_ match: SearchResult, into results: inout [SearchResult]) {
        let box = match.normalizedRect
        let index = results.firstIndex { other in
            let otherBox = other.normalizedRect
            if sharesRow(box, otherBox) { return box.minX < otherBox.minX }
            return otherBox.midY < box.midY   // bottom-left origin: lower on the page
        } ?? results.endIndex
        results.insert(match, at: index)
    }

    /// Whether two boxes overlap vertically by at least half the shorter one.
    nonisolated static func sharesRow(_ a: CGRect, _ b: CGRect) -> Bool {
        min(a.maxY, b.maxY) - max(a.minY, b.minY) >= 0.5 * min(a.height, b.height)
    }

    /// Whether two boxes overlap by at least half the smaller one's area.
    nonisolated static func overlapsHalfTheSmaller(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = a.intersection(b)
        guard !overlap.isNull, !overlap.isEmpty else { return false }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 && overlap.width * overlap.height >= 0.5 * smaller
    }

    /// Search a scanned (no-text-layer) page via OCR + regex.
    /// Called by `searchRegex` when `options.includeOCR` is true and the
    /// page's text layer is empty.
    ///
    /// Normalization ordering:
    ///   1. Two readings: the lines as Vision read them, and the lines
    ///      through OCRTextNormalizer's confusable correction.
    ///   2. Each reading's lines are joined with "\n" preserving line offsets.
    ///   3. NFKC (normalizeUnicode option) is NOT applied here — the regex
    ///      pattern was authored by the user for literal match; applying NFKC
    ///      to the body only (not the pattern) would silently break ASCII
    ///      patterns. This is consistent with the text-layer path in searchRegex.
    /// Takes the caller's already-compiled (and safety-validated)
    /// `NSRegularExpression` — re-validating/re-compiling the pattern
    /// string here repeated the full precheck once per scanned page.
    func searchPageViaOCRFallback_regex(
        page: PDFPage,
        pageIndex: Int,
        regex: NSRegularExpression,
        options: SearchOptions
    ) async -> [SearchResult] {
        let lines = await ocrLines(for: page, pageIndex: pageIndex)
        let accurate = regexOCRMatches(lines: lines, page: page, pageIndex: pageIndex, regex: regex, options: options,
                                       reportsToSinks: true)
        // iOS 27: the same pattern over the page's fast read, merged.
        guard Self.readsFastOCRBeside, let fast = ocrPageCache.fastLines(for: pageIndex), !fast.isEmpty else {
            return accurate
        }
        return Self.unionFastOCRResults(
            accurate: accurate,
            fast: regexOCRMatches(lines: fast, page: page, pageIndex: pageIndex, regex: regex, options: options,
                                  reportsToSinks: false))
    }

    /// The regex fallback over one recognition of a scanned page. The page's
    /// timeout is reported only when `reportsToSinks` (not again for the
    /// fast read's pass on iOS 27).
    func regexOCRMatches(
        lines: [OCREngine.TextLine],
        page: PDFPage,
        pageIndex: Int,
        regex: NSRegularExpression,
        options: SearchOptions,
        reportsToSinks: Bool
    ) -> [SearchResult] {
        guard !lines.isEmpty else { return [] }

        // The two readings (`ocrReadings`), each its lines joined with "\n":
        // `Room \d+` matches the "Room 101" Vision read, which the
        // correction turns into "Room IOI", and a digit pattern still
        // matches a digit the correction restored ("67B9" → "6789").
        let (rawLines, correctedLines) = ocrReadings(lines)
        // Page-side smart punctuation, same contract as the text-layer regex
        // path: 1:1, so the UTF-16 NSRanges stay aligned with the offsets.
        let readings = [rawLines, correctedLines].map { lines -> String in
            let joined = lines.joined(separator: "\n")
            return options.normalizeSmartPunctuation ? TextNormalizer.normalizeSmartPunctuation(joined) : joined
        }
        guard !readings[0].isEmpty else { return [] }
        // Each line's start in the joined text, in UTF-16 units (one line
        // feed after each line), for the line union behind every rect.
        var lineOffsets: [NormalizedLineEntry] = []
        var cursor = 0
        for (line, text) in zip(lines, rawLines) {
            lineOffsets.append(NormalizedLineEntry(
                start: cursor, normalizedText: text,
                normalizedRect: line.normalizedRect, confidence: line.confidence))
            cursor += text.utf16.count + 1
        }

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
        let snapshotTimeoutSink = reportsToSinks ? self.regexTimeoutSink : nil
        // One time budget across both readings, reported once; a range both
        // readings match is kept once (the raw reading's).
        var timedOut = false
        var kept = Set<NSRange>()

        for (index, searchText) in readings.enumerated() where !timedOut && (index == 0 || searchText != readings[0]) {
            let nsString = searchText as NSString
            SearchCore.enumerateRegexMatches(
                in: searchText, regex: regex,
                wholeWord: options.wholeWord, unconvertibleRangePasses: false,
                cap: nil,
                timeout: effectiveTimeout, startTime: startTime,
                onTimeout: { timedOut = true; snapshotTimeoutSink?(pageIndex) }
            ) { matchRange in
                guard kept.insert(matchRange).inserted else { return false }
                // The union of every recognised line the match overlaps.
                guard let mapped = ocrUnionRect(
                    forUTF16Range: matchRange, lineOffsets: lineOffsets, page: sendablePage.page
                ) else { return false }
                let normalizedRect = mapped.rect

                let matchedText = nsString.substring(with: matchRange)
                let window = contextSnippet(text: searchText, matchNSRange: matchRange)

                let match = SearchResult(
                    pageIndex: pageIndex,
                    normalizedRect: normalizedRect,
                    matchedText: matchedText,
                    contextSnippet: window.snippet,
                    source: .ocr(confidence: avgConfidence),
                    term: regex.pattern,
                    matchRangeInSnippet: window.matchRange
                )
                // A match only the corrected reading holds takes its place in
                // page order among the raw reading's, as a fast-only match does.
                if index == 0 {
                    results.append(match)
                } else {
                    Self.insertInPageOrder(match, into: &results)
                }
                return true
            }
        }

        return results
    }
}

extension SearchResult {
    /// This result with another box; every other field kept.
    func boxed(_ rect: CGRect) -> SearchResult {
        SearchResult(
            id: id, pageIndex: pageIndex, normalizedRect: rect, matchedText: matchedText,
            contextSnippet: contextSnippet, source: source, term: term, isSelected: isSelected,
            piiCategory: piiCategory, piiConfidence: piiConfidence, rationale: rationale,
            matchRangeInSnippet: matchRangeInSnippet, occurrenceID: occurrenceID,
            textLayerRect: textLayerRect, inkFitDegraded: inkFitDegraded)
    }
}
