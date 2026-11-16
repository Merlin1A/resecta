import Foundation

// A second reading of a page for the literal matcher. A typesetter breaks
// "Brightwater" as "Bright-" at a line end and "water" on the next line; the
// page as read keeps that hyphen (the break folds to nothing and the hyphen
// stays, `TextNormalizer.foldedRun`), so "Bright-water" is found and
// "Brightwater" is not. The rule:
//
// A hyphen that ends a line between two letters of the same case is read
// both ways: kept, as today, and dropped. A match found either way counts
// once and covers the hyphen. A hyphen between digits, between letters of
// different case, or beside a letter that has no case, is only ever kept.
//
// - Same case is judged on the page's own Characters, before any case fold.
// - The dropped reading drops every such hyphen on the page at once, so a
//   phrase holding two such breaks is found with both kept or both dropped.
// - Whole word is tested on the match's span in the page as read.
// - A pattern is never read this way; nor is a one-word search across a
//   page boundary (the page seam asks only for queries with a space or a
//   hyphen).
//
// Privacy rule (audit-lint M-1): locate/match/cover vocabulary.
extension SearchCore {

    /// Whether a run is a closed-spelling break: a line break right after a
    /// hard hyphen (`TextNormalizer.isBreakAfterHardHyphen`) whose letter
    /// before the hyphen and letter after the run are both lower case or both
    /// upper case, on the page's own Characters.
    static func isClosedSpellingBreak(
        _ run: Substring, previous: Character?, beforeThat: Character?, next: Character?
    ) -> Bool {
        guard TextNormalizer.isBreakAfterHardHyphen(run, previous: previous, beforeThat: beforeThat, next: next),
              let beforeThat, let next else { return false }
        return isSameCase(beforeThat, next)
    }

    /// Two letters that are both lower case or both upper case. A digit, or
    /// a letter with no case, is neither.
    static func isSameCase(_ a: Character, _ b: Character) -> Bool {
        (a.isLowercase && b.isLowercase) || (a.isUppercase && b.isUppercase)
    }

    /// The closed-spelling hyphens of a normalized page (Character offsets
    /// in it), expressed in the searched text: through the accent fold's
    /// offset map when one is active, none under the digit-separator strip
    /// (which has already removed every "-"). An offset that does not land
    /// on a hard hyphen of the searched text is not carried.
    static func closedSpellingHyphens(
        _ normalizedOffsets: [Int], searchText: String, offsetMap: [Int]?, options: SearchOptions
    ) -> [Int] {
        guard !normalizedOffsets.isEmpty, !options.stripDigitSeparators else { return [] }
        let searched: [Int]
        if let offsetMap {
            searched = normalizedOffsets.compactMap { offset in
                var low = 0, high = offsetMap.count
                while low < high {
                    let mid = (low + high) / 2
                    if offsetMap[mid] < offset { low = mid + 1 } else { high = mid }
                }
                return low < offsetMap.count && offsetMap[low] == offset ? low : nil
            }
        } else {
            searched = normalizedOffsets
        }
        let characters = Array(searchText)
        return searched.filter { $0 < characters.count && TextNormalizer.hardHyphens.contains(characters[$0]) }
    }

    /// The literal matcher: the walk over the page as read
    /// (`literalSpansAsRead`), and two more readings that only add. On a page
    /// with closed-spelling hyphens, a second walk over the page with them
    /// dropped: a match there is kept only when it crosses a dropped hyphen,
    /// and is expressed as a span of the searched text from its first matched
    /// Character to its last, so it covers the hyphen. For a search of two or
    /// more words, the optional-space walk (`optionalSpaceSpans`), which
    /// `spacesMayMatchNothing` turns off. A span equal to one already found
    /// is dropped. The spans are returned in page order; with a cap, the
    /// first `cap` of the merged list, `stoppedAtCap` true when the list
    /// reached it.
    static func literalSpans(
        in page: PreparedPage,
        query: String,
        comparison: String.CompareOptions,
        wholeWord: Bool,
        cap: Int?,
        spacesMayMatchNothing: Bool = true
    ) -> (spans: [MatchSpan], stoppedAtCap: Bool) {
        let asRead = literalSpansAsRead(in: page, query: query, comparison: comparison, wholeWord: wholeWord, cap: cap)
        var added: [MatchSpan] = []
        if !page.closedSpellingHyphens.isEmpty {
            added += closedSpellingSpans(in: page, query: query, comparison: comparison, wholeWord: wholeWord, cap: cap)
        }
        if spacesMayMatchNothing {
            added += optionalSpaceSpans(in: page, query: query, comparison: comparison, wholeWord: wholeWord, cap: cap)
        }
        guard !added.isEmpty else { return asRead }
        var seen = Set(asRead.spans.map { SpanKey($0.searchedRange) })
        var merged = asRead.spans
        for span in added where seen.insert(SpanKey(span.searchedRange)).inserted {
            merged.append(span)
        }
        merged.sort {
            ($0.searchedRange.location, $0.searchedRange.length) < ($1.searchedRange.location, $1.searchedRange.length)
        }
        guard let cap else { return (merged, false) }
        return merged.count >= cap ? (Array(merged.prefix(cap)), true) : (merged, false)
    }

    private struct SpanKey: Hashable {
        let location: Int
        let length: Int
        init(_ range: NSRange) { location = range.location; length = range.length }
    }

    /// The second walk: `query` over the searched text with every
    /// closed-spelling hyphen removed, each match routed back to the searched
    /// text, kept only when it crosses a removed hyphen, then remapped and
    /// checked for whole word exactly as the first walk does. At most `cap`
    /// spans (nil = unbounded).
    static func closedSpellingSpans(
        in page: PreparedPage,
        query: String,
        comparison: String.CompareOptions,
        wholeWord: Bool,
        cap: Int?
    ) -> [MatchSpan] {
        let text = page.searchText
        let dropped = Set(page.closedSpellingHyphens)
        var reading = ""
        reading.reserveCapacity(text.utf8.count)
        var searchedOffset: [Int] = []     // per Character of `reading`: its Character offset in `text`
        searchedOffset.reserveCapacity(text.count)
        for (offset, character) in text.enumerated() where !dropped.contains(offset) {
            reading.append(character)
            searchedOffset.append(offset)
        }
        // A Character that re-formed across a removed hyphen would shift the
        // route back; refuse the reading rather than risk a bad box.
        guard reading.count == searchedOffset.count else { return [] }

        var spans: [MatchSpan] = []
        let nsReading = reading as NSString
        let nsLength = nsReading.length
        var cursor = 0
        var readingIndex = reading.startIndex
        var readingOffset = 0
        var textIndex = text.startIndex
        var textOffset = 0

        while cursor < nsLength {
            if Task.isCancelled { break }
            let matchRange = nsReading.range(
                of: query, options: comparison, range: NSRange(location: cursor, length: nsLength - cursor), locale: nil)
            if matchRange.location == NSNotFound { break }
            guard let indices = Range(matchRange, in: reading) else { break }
            let advance = matchRange.location + max(matchRange.length, 1)

            let start = readingOffset + reading.distance(from: readingIndex, to: indices.lowerBound)
            let length = reading.distance(from: indices.lowerBound, to: indices.upperBound)
            readingIndex = indices.lowerBound
            readingOffset = start
            guard length > 0 else { cursor = advance; continue }

            let first = searchedOffset[start]
            let last = searchedOffset[start + length - 1]
            // Only a match across a removed hyphen is the dropped reading's
            // own; any other is the page as read, which the first walk owns.
            guard last - first + 1 > length, first >= textOffset else { cursor = advance; continue }

            let lower = text.index(textIndex, offsetBy: first - textOffset)
            let upper = text.index(lower, offsetBy: last - first + 1)
            textIndex = lower
            textOffset = first

            var base: Range<Int>? = nil
            if let map = page.offsetMap {
                guard let span = baseSpan(start: first, length: last - first + 1, offsetMap: map) else {
                    cursor = advance
                    continue
                }
                base = span
            }
            if wholeWord {
                let isBoundaried: Bool
                if let baseChars = page.baseChars, let base {
                    isBoundaried = isWholeWordInBase(chars: baseChars, start: base.lowerBound, endExclusive: base.upperBound)
                } else {
                    isBoundaried = isWholeWord(lower..<upper, in: text)
                }
                if !isBoundaried {
                    cursor = advance
                    continue
                }
            }

            spans.append(MatchSpan(
                searchedRange: NSRange(lower..<upper, in: text),
                searchedIndices: lower..<upper,
                searchedCharacters: first ..< last + 1,
                base: base
            ))
            if let cap, spans.count >= cap { break }
            cursor = advance
        }
        return spans
    }
}

// The optional-space reading. On some typed pages the text layer reads the
// words of a tightly set line run together ("betweenHalvorsenMarineSupply,"),
// and where text recognition drops a space the same happens on a scan. The
// rule:
//
// A typed search of two or more words is compared a second time with some of
// its spaces free to match no character: a free space matches white space on
// the page, or nothing where the page's own Characters show a word edge at
// that place. A space beside a one-letter or one-digit word is never free,
// and a space at either end of the search is compared as today. White space
// on the page matches only a space of the search. Today's matches are kept
// unchanged; this reading only adds.
//
// A word edge, on the page's own Characters before any fold, with `a` the
// Character before the place, `b` the one after it and `c` the one after `b`:
// a small letter then a capital; two capitals then a small letter (a capital
// that starts a word, "IBMCorp"); a letter beside a digit; or a Character
// that is neither a letter nor a digit on either side ("Supply,Inc.").
// Between two small letters, inside a run of capitals and between two digits
// there is no edge, so those places are never closed up.
//
// - One pass: the search with its spaces removed is walked over the page
//   with its spaces removed, and each candidate is checked against the rule.
//   After a candidate the rule refuses the walk moves on by one Character;
//   after one it keeps, it steps past it as today's walk does.
// - Whole word is tested on the match's span in the page as read.
// - With closed-spelling hyphens on the page, the reading is also walked
//   with them dropped.
// - Under the digit-separator strip the search holds no space, so nothing is
//   added. A pattern is never read this way.
// - A prepared page that carries no page text (the recognised route's
//   skeleton reading) is not read this way.
extension SearchCore {

    /// A typed search as the optional-space reading sees it: its words, and
    /// per space between two of them whether it is free.
    struct SpacedQuery: Equatable {
        let words: [String]
        /// One entry per space between two words.
        let free: [Bool]
        /// A space before the first word, or after the last: compared as
        /// today, so it must meet white space on the page.
        let leadingSpace: Bool
        let trailingSpace: Bool
    }

    /// The search's words and free spaces, or nil when there is no second
    /// walk: fewer than two words, or no free space.
    static func spacedQuery(_ query: String) -> SpacedQuery? {
        let words = query.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return nil }
        let free = zip(words, words.dropFirst()).map { !isOneCharacterWord($0) && !isOneCharacterWord($1) }
        guard free.contains(true) else { return nil }
        return SpacedQuery(words: words, free: free,
                           leadingSpace: query.first == " ", trailingSpace: query.last == " ")
    }

    /// A word that is one Character, a letter or a number.
    static func isOneCharacterWord(_ word: String) -> Bool {
        guard word.count == 1, let only = word.first else { return false }
        return only.isLetter || only.isNumber
    }

    /// Whether the page's own Characters show a word edge between `a` and
    /// `b`; `c` is the Character after `b`, if any.
    static func isWordEdge(_ a: Character, _ b: Character, _ c: Character?) -> Bool {
        if a.isLowercase && b.isUppercase { return true }
        if a.isUppercase && b.isUppercase, let c, c.isLowercase { return true }
        if (a.isLetter && b.isNumber) || (a.isNumber && b.isLetter) { return true }
        return !(a.isLetter || a.isNumber) || !(b.isLetter || b.isNumber)
    }

    /// The optional-space walk over the page as read and, on a page with
    /// closed-spelling hyphens, over the page with them dropped. At most
    /// `cap` spans per reading (nil = unbounded); the caller merges them.
    static func optionalSpaceSpans(
        in page: PreparedPage,
        query: String,
        comparison: String.CompareOptions,
        wholeWord: Bool,
        cap: Int?
    ) -> [MatchSpan] {
        guard !page.pageText.isEmpty, let spaced = spacedQuery(query) else { return [] }
        var edges = PageEdges(page: page)
        var spans = optionalSpaceSpans(
            in: page, spaced: spaced, dropping: [], comparison: comparison, wholeWord: wholeWord, cap: cap,
            edges: &edges)
        if !page.closedSpellingHyphens.isEmpty {
            let more = optionalSpaceSpans(
                in: page, spaced: spaced, dropping: Set(page.closedSpellingHyphens), comparison: comparison,
                wholeWord: wholeWord, cap: cap, edges: &edges)
            let seen = Set(spans.map(\.searchedCharacters))
            spans += more.filter { !seen.contains($0.searchedCharacters) }
        }
        return spans
    }

    /// The page's own Characters, read once and only when a place is
    /// checked, and the route to them from a searched Character offset.
    struct PageEdges {
        let page: PreparedPage
        private var characters: [Character]? = nil

        init(page: PreparedPage) { self.page = page }

        /// The first and last raw Character a searched Character came from.
        func raw(_ searched: Int) -> (first: Int, last: Int)? {
            let base: Int
            if let map = page.offsetMap {
                guard searched < map.count else { return nil }
                base = map[searched]
            } else {
                base = searched
            }
            guard let rawMap = page.rawMap else { return (base, base) }
            guard base < rawMap.rawFirst.count else { return nil }
            return (rawMap.rawFirst[base], rawMap.rawLast[base])
        }

        /// Whether the place between searched Characters `before` and
        /// `after` is a word edge on the page's own Characters.
        mutating func isEdge(before: Int, after: Int) -> Bool {
            if characters == nil { characters = Array(page.pageText) }
            guard let characters, let a = raw(before), let b = raw(after),
                  a.last < characters.count, b.first < characters.count else { return false }
            let c = b.last + 1 < characters.count ? characters[b.last + 1] : nil
            return SearchCore.isWordEdge(characters[a.last], characters[b.first], c)
        }
    }

    /// One reading: the searched text with its spaces and the `dropping`
    /// Characters removed, walked for the search with its spaces removed.
    private static func optionalSpaceSpans(
        in page: PreparedPage,
        spaced: SpacedQuery,
        dropping: Set<Int>,
        comparison: String.CompareOptions,
        wholeWord: Bool,
        cap: Int?,
        edges: inout PageEdges
    ) -> [MatchSpan] {
        let text = page.searchText
        let closed = spaced.words.joined()
        // Every word of the search stands whole in the page as read, so a
        // page that lacks one holds no candidate. Not asked when hyphens are
        // dropped: a word may then stand across one.
        if dropping.isEmpty {
            for word in spaced.words where page.nsString.range(of: word, options: comparison).location == NSNotFound {
                return []
            }
        }

        var reading = ""
        reading.reserveCapacity(text.utf8.count)
        var searchedOffset: [Int] = []   // per Character of `reading`: its Character offset in `text`
        var spaceBefore: [Int] = []      // per Character of `reading`: the offset of a page space just before it, or -1
        var pendingSpace = -1
        for (offset, character) in text.enumerated() {
            if character == " " { pendingSpace = offset; continue }
            if dropping.contains(offset) { continue }
            reading.append(character)
            searchedOffset.append(offset)
            spaceBefore.append(pendingSpace)
            pendingSpace = -1
        }
        let spaceAtEnd = pendingSpace
        // A Character that re-formed where a space or a hyphen was removed
        // would shift the route back; refuse the reading rather than risk a
        // bad box.
        guard reading.count == searchedOffset.count else { return [] }

        // Per Character offset inside the closed search: the index of the
        // search's space before it, if any.
        var spaceAt: [Int: Int] = [:]
        var length = 0
        for (index, word) in spaced.words.dropLast().enumerated() {
            length += word.count
            spaceAt[length] = index
        }
        let closedLength = closed.count

        var spans: [MatchSpan] = []
        let nsReading = reading as NSString
        let nsLength = nsReading.length
        var cursor = 0
        var readingIndex = reading.startIndex
        var readingOffset = 0
        var textIndex = text.startIndex
        var textOffset = 0

        while cursor < nsLength {
            if Task.isCancelled { break }
            let matchRange = nsReading.range(
                of: closed, options: comparison, range: NSRange(location: cursor, length: nsLength - cursor), locale: nil)
            if matchRange.location == NSNotFound { break }
            guard let indices = Range(matchRange, in: reading) else { break }
            let past = matchRange.location + max(matchRange.length, 1)
            let oneOn = matchRange.location + max(nsReading.rangeOfComposedCharacterSequence(at: matchRange.location).length, 1)

            let start = readingOffset + reading.distance(from: readingIndex, to: indices.lowerBound)
            let count = reading.distance(from: indices.lowerBound, to: indices.upperBound)
            readingIndex = indices.lowerBound
            readingOffset = start
            guard count == closedLength, count > 0 else { cursor = oneOn; continue }

            // The check against the page with its spaces.
            var skipped = 0
            var refused = false
            for inner in 1..<max(count, 1) {
                let pageSpace = spaceBefore[start + inner] >= 0
                switch (spaceAt[inner], pageSpace) {
                case (nil, true):
                    refused = true
                case (let index?, false):
                    if spaced.free[index],
                       edges.isEdge(before: searchedOffset[start + inner - 1], after: searchedOffset[start + inner]) {
                        skipped += 1
                    } else {
                        refused = true
                    }
                default:
                    break
                }
                if refused { break }
            }
            var first = searchedOffset[start]
            var last = searchedOffset[start + count - 1]
            if spaced.leadingSpace {
                let space = spaceBefore[start]
                if space >= 0, space == first - 1 { first = space } else { refused = true }
            }
            if spaced.trailingSpace {
                let space = start + count < spaceBefore.count ? spaceBefore[start + count] : spaceAtEnd
                if space >= 0, space == last + 1 { last = space } else { refused = true }
            }
            // A candidate with no closed-up space is today's walk's own.
            guard !refused, skipped > 0, first >= textOffset else { cursor = oneOn; continue }

            let lower = text.index(textIndex, offsetBy: first - textOffset)
            let upper = text.index(lower, offsetBy: last - first + 1)
            textIndex = lower
            textOffset = first

            var base: Range<Int>? = nil
            if let map = page.offsetMap {
                guard let span = baseSpan(start: first, length: last - first + 1, offsetMap: map) else {
                    cursor = past
                    continue
                }
                base = span
            }
            if wholeWord {
                let isBoundaried: Bool
                if let baseChars = page.baseChars, let base {
                    isBoundaried = isWholeWordInBase(chars: baseChars, start: base.lowerBound, endExclusive: base.upperBound)
                } else {
                    isBoundaried = isWholeWord(lower..<upper, in: text)
                }
                if !isBoundaried {
                    cursor = past
                    continue
                }
            }

            spans.append(MatchSpan(
                searchedRange: NSRange(lower..<upper, in: text),
                searchedIndices: lower..<upper,
                searchedCharacters: first ..< last + 1,
                base: base
            ))
            if let cap, spans.count >= cap { break }
            cursor = past
        }
        return spans
    }
}
