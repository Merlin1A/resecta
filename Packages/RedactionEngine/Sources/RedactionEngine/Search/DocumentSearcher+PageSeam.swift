import Foundation
import PDFKit

// A literal phrase that starts at the end of one page and continues at the
// top of the next ("The claimant is Marisol" ending page 1, "Vance-Oduya and
// her counsel." opening page 2). The page loops read one page at a time, so
// neither page holds the phrase. After page n+1's own results, the loop asks
// this seam for the matches that cross from page n into page n+1.
//
// The bound:
// (a) literal queries only (Text and Multi-term), and only when the
//     normalized query holds a space or a hard hyphen: a one-word query
//     cannot cross a page except at its own hyphen;
// (b) both pages on the text-layer route and adjacent: a page read by OCR
//     between them, or on either side, ends the seam;
// (c) the seam text is page n's last non-blank line, one line feed, and page
//     n+1's first non-blank line, after skipping on each side up to three
//     lines that repeat on both pages: a running header (among the first
//     three non-blank lines of both pages) or footer (among the last three
//     of both), compared with whitespace folded, case folded and every digit
//     run masked, so a page number or a Bates number does not defeat it;
//     each side keeps at most 512 UTF-16 units, cut at a space;
// (d) the seam text goes through the literal tier's own preparation and
//     matcher, so the hyphen-break rule applies at the seam too; only
//     matches touching both sides are kept (a match inside one line is that
//     page's own), and each side's part takes its own page's line boxes —
//     one result per line per page, every part sharing one occurrence;
// (e) the cost, per page boundary per literal term: the edge lines read
//     from at most 1,024 units at each end of the two pages, and one
//     preparation over at most 1,025 units.
// The live preview reads one page at a time and does not count a seam match.
//
// Privacy rule (audit-lint M-1): locate/match/cover vocabulary.
extension DocumentSearcher {

    /// A text-layer page a page loop keeps for its seam with the next page.
    struct SeamPage {
        let index: Int
        let page: PDFPage
        let text: String
    }

    /// The most one side of a seam reads, in UTF-16 units.
    static let seamSideLimit = 512

    /// The span at each end of a page the edge lines are read from, in
    /// UTF-16 units: the seam needs three lines at each end, never the page.
    static let seamEdgeWindow = 1024

    /// The matches of `query` that run from the end of `previous` into the
    /// start of the page at `pageIndex`, boxed on both pages under one
    /// occurrence; empty outside the bound.
    func pageSeamMatches(
        from previous: SeamPage?, to page: PDFPage, pageIndex: Int, pageText: String,
        query: String, options: SearchOptions, term: String
    ) async -> [SearchResult] {
        guard let previous, previous.index + 1 == pageIndex else { return [] }
        let typed = SearchCore.normalizedText(query, options: options)
        guard typed.contains(where: { $0 == " " || TextNormalizer.hardHyphens.contains($0) }) else { return [] }
        guard let sides = Self.seamSides(previous: previous.text, next: pageText) else { return [] }
        let left = (previous.text as NSString).substring(with: sides.left)
        let right = (pageText as NSString).substring(with: sides.right)
        let seam = left + "\n" + right
        let leftLength = (left as NSString).length

        // The CJK check only turns whole word off: skip it when it is off.
        let effective = options.wholeWord ? SearchCore.effectiveOptions(options, pageText: seam, detectCJK: true) : options
        let normalizedQuery = SearchCore.normalizedText(query, options: effective)
        guard !normalizedQuery.isEmpty else { return [] }
        let prepared = SearchCore.preparePage(seam, options: effective)
        let searchQuery = SearchCore.preparedQuery(normalized: normalizedQuery, options: effective)
        guard !searchQuery.isEmpty else { return [] }
        let (matches, _) = SearchCore.literalSpans(
            in: prepared, query: searchQuery, comparison: [], wholeWord: effective.wholeWord, cap: nil)

        var results: [SearchResult] = []
        for match in matches {
            guard let raw = prepared.rawNSRange(of: match),
                  raw.location < leftLength, NSMaxRange(raw) > leftLength + 1 else { continue }
            let leftPart = Self.trimmed(
                NSRange(location: sides.left.location + raw.location, length: leftLength - raw.location), in: previous.text)
            let rightPart = Self.trimmed(
                NSRange(location: sides.right.location, length: NSMaxRange(raw) - leftLength - 1), in: pageText)
            let matchedText = Self.seamDisplay((seam as NSString).substring(with: raw), options: effective)
            let window = seamWindow(seam: seam, raw: raw, matchedText: matchedText, options: effective)
            let occurrence = UUID()
            let previousPage = previous.page
            var boxes: [(pageIndex: Int, box: TextLayerBox)] = []
            if leftPart.length > 0 {
                let left = await withInkFitRead(previousPage) { textLayerLines(for: leftPart, page: previousPage) } ?? []
                boxes += left.map { (previous.index, $0) }
            }
            if rightPart.length > 0 {
                let right = await withInkFitRead(page) { textLayerLines(for: rightPart, page: page) } ?? []
                boxes += right.map { (pageIndex, $0) }
            }
            for (partPage, box) in boxes {
                results.append(SearchResult(
                    pageIndex: partPage,
                    normalizedRect: box.rect,
                    matchedText: matchedText,
                    contextSnippet: window.snippet,
                    source: .textLayer,
                    term: term,
                    matchRangeInSnippet: window.matchRange,
                    occurrenceID: occurrence, textLayerRect: box.textLayerRect, inkFitDegraded: box.degraded))
            }
        }
        return results
    }

    // MARK: - The seam text

    /// The two sides of the seam between two pages' texts: the UTF-16 range
    /// of page n's last content line and of page n+1's first, past the
    /// repeated header and footer lines; nil when either page has none.
    nonisolated static func seamSides(previous: String, next: String) -> (left: NSRange, right: NSRange)? {
        let before = previous as NSString, after = next as NSString
        let a = edgeLines(before), b = edgeLines(after)
        let headers = Set(a.head.prefix(3).map { repeatKey(before.substring(with: $0)) })
        let footers = Set(b.tail.suffix(3).map { repeatKey(after.substring(with: $0)) })
        let firstLines = Array(b.head.prefix(4)), lastLines = Array(a.tail.suffix(4))
        guard !firstLines.isEmpty, !lastLines.isEmpty else { return nil }
        var first = 0
        while first < min(3, firstLines.count), headers.contains(repeatKey(after.substring(with: firstLines[first]))) { first += 1 }
        var last = lastLines.count - 1
        while last >= 0, lastLines.count - 1 - last < 3, footers.contains(repeatKey(before.substring(with: lastLines[last]))) { last -= 1 }
        guard first < firstLines.count, last >= 0 else { return nil }
        return (tail(lastLines[last], in: before), head(firstLines[first], in: after))
    }

    /// A page's content lines at its start and at its end (one read when
    /// the page is no longer than the two windows).
    nonisolated static func edgeLines(_ text: NSString) -> (head: [NSRange], tail: [NSRange]) {
        guard text.length > 2 * seamEdgeWindow else {
            let all = contentLines(text, in: NSRange(location: 0, length: text.length))
            return (all, all)
        }
        return (contentLines(text, in: headWindow(text)), contentLines(text, in: tailWindow(text)))
    }

    /// The first `seamEdgeWindow` units of a page, extended to a line end.
    nonisolated static func headWindow(_ text: NSString) -> NSRange {
        guard text.length > seamEdgeWindow else { return NSRange(location: 0, length: text.length) }
        let end = NSMaxRange(text.lineRange(for: NSRange(location: seamEdgeWindow, length: 0)))
        return NSRange(location: 0, length: end)
    }

    /// The last `seamEdgeWindow` units of a page, extended back to a line start.
    nonisolated static func tailWindow(_ text: NSString) -> NSRange {
        guard text.length > seamEdgeWindow else { return NSRange(location: 0, length: text.length) }
        let start = text.lineRange(for: NSRange(location: text.length - seamEdgeWindow, length: 0)).location
        return NSRange(location: start, length: text.length - start)
    }

    /// Each non-blank line's UTF-16 range inside `window` (whole lines),
    /// without its leading and trailing run characters.
    nonisolated static func contentLines(_ text: NSString, in window: NSRange) -> [NSRange] {
        var lines: [NSRange] = []
        text.enumerateSubstrings(in: window, options: .byLines) { line, range, _, _ in
            guard let line else { return }
            let kept = trimmed(range, in: line, offset: range.location)
            if kept.length > 0 { lines.append(kept) }
        }
        return lines
    }

    /// A line's key for the repeated-line test: whitespace folded, case
    /// folded, each digit run one "#".
    nonisolated static func repeatKey(_ line: String) -> String {
        var key = ""
        var inDigits = false
        for character in TextNormalizer.foldWhitespaceRuns(line.lowercased()) {
            if character.isNumber {
                if !inDigits { key.append("#") }
                inDigits = true
            } else {
                key.append(character)
                inDigits = false
            }
        }
        return key
    }

    /// The last `seamSideLimit` units of a line, cut forward to a space.
    nonisolated static func tail(_ line: NSRange, in text: NSString) -> NSRange {
        guard line.length > seamSideLimit else { return line }
        let window = NSRange(location: NSMaxRange(line) - seamSideLimit, length: seamSideLimit)
        let space = text.rangeOfCharacter(from: .whitespaces, range: window)
        guard space.location != NSNotFound else { return text.rangeOfComposedCharacterSequences(for: window) }
        return NSRange(location: NSMaxRange(space), length: NSMaxRange(line) - NSMaxRange(space))
    }

    /// The first `seamSideLimit` units of a line, cut back to a space.
    nonisolated static func head(_ line: NSRange, in text: NSString) -> NSRange {
        guard line.length > seamSideLimit else { return line }
        let window = NSRange(location: line.location, length: seamSideLimit)
        let space = text.rangeOfCharacter(from: .whitespaces, options: .backwards, range: window)
        guard space.location != NSNotFound else { return text.rangeOfComposedCharacterSequences(for: window) }
        return NSRange(location: line.location, length: space.location - line.location)
    }

    /// `range` (UTF-16, in `text` read from `offset`) without its leading and
    /// trailing run characters.
    nonisolated static func trimmed(_ range: NSRange, in text: String, offset: Int = 0) -> NSRange {
        guard let bounds = Range(NSRange(location: range.location - offset, length: range.length), in: text) else {
            return NSRange(location: range.location, length: 0)
        }
        let slice = text[bounds]
        guard let first = slice.firstIndex(where: { !TextNormalizer.isRunCharacter($0) }),
              let last = slice.lastIndex(where: { !TextNormalizer.isRunCharacter($0) }) else {
            return NSRange(location: range.location, length: 0)
        }
        let kept = NSRange(first...last, in: text)
        return NSRange(location: kept.location + offset, length: kept.length)
    }

    // MARK: - What a seam result shows

    /// The case-preserved text of a seam match: the display chain of
    /// the text-layer matcher (ligature/NFKC, smart punctuation, the run fold).
    nonisolated static func seamDisplay(_ raw: String, options: SearchOptions) -> String {
        var display = options.normalizeUnicode ? TextNormalizer.normalize(raw) : raw
        if options.normalizeSmartPunctuation { display = TextNormalizer.normalizeSmartPunctuation(display) }
        return TextNormalizer.foldWhitespaceRuns(display)
    }

    /// The context window around a seam match, its sides folded as the match
    /// is, so the window's match slice is `matchedText`.
    func seamWindow(seam: String, raw: NSRange, matchedText: String, options: SearchOptions) -> ContextWindow {
        let window = contextSnippet(text: seam, matchNSRange: raw)
        let characters = Array(window.snippet)
        guard window.matchRange.upperBound <= characters.count else { return window }
        let before = Self.seamDisplay(String(characters[..<window.matchRange.lowerBound]), options: options)
        let after = Self.seamDisplay(String(characters[window.matchRange.upperBound...]), options: options)
        return ContextWindow(
            snippet: before + matchedText + after,
            matchRange: before.count..<(before.count + matchedText.count))
    }
}
