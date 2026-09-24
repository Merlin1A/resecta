import Testing
import Foundation
@testable import RedactionEngine

// One unit per matching primitive in `SearchCore` — the pure functions the
// live preview and the full search share. The tiers' own behavior (counts,
// highlights, yielded results) is pinned by the searcher suites; these pin
// the primitives' contracts directly.

@Suite("SearchCore primitives", .tags(.search))
struct SearchCoreTests {

    // MARK: - Text-layer routing

    @Test("Text-layer routing: unknown and rich stay on the layer, sparse and none leave it")
    func textLayerRouting() {
        #expect(SearchCore.textLayerIsSearchable(nil) == true)
        #expect(SearchCore.textLayerIsSearchable(.rich) == true)
        #expect(SearchCore.textLayerIsSearchable(.sparse) == false)
        #expect(SearchCore.textLayerIsSearchable(TextLayerStatus.none) == false)
    }

    // MARK: - Normalization

    @Test("normalizedText: case fold, case-preserving, and the NFKC path")
    func normalization() {
        var options = SearchOptions()
        options.normalizeUnicode = false
        #expect(SearchCore.normalizedText("Hartwell", options: options) == "hartwell")
        options.caseSensitive = true
        #expect(SearchCore.normalizedText("Hartwell", options: options) == "Hartwell")
        options = SearchOptions()   // normalizeUnicode on, case-insensitive
        #expect(SearchCore.normalizedText("O\u{FB03}ce", options: options) == "office")
    }

    @Test("effectiveOptions: CJK detection disables the boundary check only when asked")
    func cjkDetection() {
        var options = SearchOptions()
        options.wholeWord = true
        options.exactMatch = true
        let japanese = String(repeating: "東京都千代田区の契約書です。", count: 8)
        let english = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 8)

        let detected = SearchCore.effectiveOptions(options, pageText: japanese, detectCJK: true)
        #expect(detected.wholeWord == false)
        #expect(detected.exactMatch == false)

        let preview = SearchCore.effectiveOptions(options, pageText: japanese, detectCJK: false)
        #expect(preview == options)

        let latin = SearchCore.effectiveOptions(options, pageText: english, detectCJK: true)
        #expect(latin == options)
    }

    @Test("preparePage / preparedQuery: the length-changing extension yields a map; a separator-only query empties")
    func preparation() {
        var options = SearchOptions()
        options.stripDigitSeparators = true

        let page = SearchCore.preparePage("Acct 12-34-56 end", options: options)
        #expect(page.offsetMap != nil)
        #expect(page.baseChars != nil)
        #expect(page.searchText.contains("123456"))
        #expect(page.baseText.contains("12-34-56"))

        let query = SearchCore.preparedQuery(
            normalized: SearchCore.normalizedText("12-34", options: options), options: options)
        #expect(query == "1234")
        let separatorsOnly = SearchCore.preparedQuery(
            normalized: SearchCore.normalizedText("--", options: options), options: options)
        #expect(separatorsOnly.isEmpty)

        var plain = SearchOptions()
        plain.stripDigitSeparators = false
        plain.foldDiacritics = false
        let flat = SearchCore.preparePage("plain text", options: plain)
        #expect(flat.offsetMap == nil)
        #expect(flat.baseChars == nil)
    }

    // MARK: - The literal matcher

    @Test("literalSpans: the cursor walk, the cap, the whole-word check")
    func literalWalk() {
        let options = SearchOptions()
        let page = SearchCore.preparePage("cat concatenate cat catalog cat", options: options)

        let all = SearchCore.literalSpans(in: page, query: "cat", comparison: [.literal], wholeWord: false, cap: nil)
        #expect(all.spans.count == 5)
        #expect(all.stoppedAtCap == false)
        #expect(all.spans.map(\.searchedRange.location) == [0, 7, 16, 20, 28])
        #expect(all.spans.allSatisfy { $0.base == nil && $0.searchedCharacters.count == 3 })
        #expect(all.spans[1].searchedCharacters == 7..<10)

        let whole = SearchCore.literalSpans(in: page, query: "cat", comparison: [.literal], wholeWord: true, cap: nil)
        #expect(whole.spans.map(\.searchedRange.location) == [0, 16, 28])

        let capped = SearchCore.literalSpans(in: page, query: "cat", comparison: [.literal], wholeWord: false, cap: 2)
        #expect(capped.spans.count == 2)
        #expect(capped.stoppedAtCap == true)

        // Non-overlapping: the cursor advances past each match.
        let runs = SearchCore.preparePage("aaaa", options: options)
        #expect(SearchCore.literalSpans(in: runs, query: "aa", comparison: [.literal], wholeWord: false, cap: nil).spans.count == 2)
    }

    @Test("literalSpans: the comparison is a parameter — literal vs composed-sequence equivalence")
    func literalComparison() {
        var options = SearchOptions()
        options.normalizeUnicode = false   // keep the decomposed form on the page
        let page = SearchCore.preparePage("caf\u{0065}\u{0301} au lait", options: options)   // e + combining acute
        let precomposed = "caf\u{00E9}"
        let literal = SearchCore.literalSpans(in: page, query: precomposed, comparison: [.literal], wholeWord: false, cap: nil)
        let composed = SearchCore.literalSpans(in: page, query: precomposed, comparison: [], wholeWord: false, cap: nil)
        #expect(literal.spans.isEmpty)
        #expect(composed.spans.count == 1)
        #expect(composed.spans.first?.searchedRange == NSRange(location: 0, length: 5))
        #expect(composed.spans.first?.searchedCharacters == 0..<4)
    }

    @Test("literalSpans: the offset-map remap covers removed separators and checks boundaries in base coordinates")
    func literalRemap() {
        var options = SearchOptions()
        options.stripDigitSeparators = true
        let page = SearchCore.preparePage("id 12-34 x1234y", options: options)
        let query = SearchCore.preparedQuery(normalized: "12-34", options: options)
        #expect(query == "1234")

        let both = SearchCore.literalSpans(in: page, query: query, comparison: [.literal], wholeWord: false, cap: nil)
        #expect(both.spans.count == 2)
        // The first match spans the removed separator in base coordinates: "12-34".
        #expect(both.spans[0].base == 3..<8)
        #expect(both.spans[0].searchedCharacters == 2..<6)

        // Whole-word evaluates on the base text: "12-34" is bounded, "x1234y" is not.
        let bounded = SearchCore.literalSpans(in: page, query: query, comparison: [.literal], wholeWord: true, cap: nil)
        #expect(bounded.spans.count == 1)
        #expect(bounded.spans[0].base == 3..<8)
    }

    // MARK: - The regex enumeration

    @Test("enumerateRegexMatches: the cap counts accepted visits, the timeout fires once, whole-word filters")
    func regexEnumeration() throws {
        let regex = try NSRegularExpression(pattern: "\\d+")
        let text = "a1 b22 c333 d4444 e55555"
        let far = ContinuousClock.now
        let long: Duration = .seconds(60)

        var seen: [NSRange] = []
        let all = SearchCore.enumerateRegexMatches(
            in: text, regex: regex, wholeWord: false, unconvertibleRangePasses: false,
            cap: nil, timeout: long, startTime: far, onTimeout: { Issue.record("no timeout expected") }
        ) { range in seen.append(range); return true }
        #expect(all.accepted == 5)
        #expect(all.stoppedAtCap == false)
        #expect(seen.map(\.length) == [1, 2, 3, 4, 5])

        let capped = SearchCore.enumerateRegexMatches(
            in: text, regex: regex, wholeWord: false, unconvertibleRangePasses: false,
            cap: 2, timeout: long, startTime: far, onTimeout: {}
        ) { _ in true }
        #expect(capped.accepted == 2)
        #expect(capped.stoppedAtCap == true)

        // A visit that could not place the match does not count toward the cap.
        var visits = 0
        let refused = SearchCore.enumerateRegexMatches(
            in: text, regex: regex, wholeWord: false, unconvertibleRangePasses: false,
            cap: 2, timeout: long, startTime: far, onTimeout: {}
        ) { range in visits += 1; return range.length.isMultiple(of: 2) }
        #expect(refused.accepted == 2)
        #expect(visits == 4)   // 1, 22 (counted), 333, 4444 (counted) — then the cap stops the walk

        var timeouts = 0
        let timedOut = SearchCore.enumerateRegexMatches(
            in: text, regex: regex, wholeWord: false, unconvertibleRangePasses: false,
            cap: nil, timeout: .zero, startTime: far - .seconds(1), onTimeout: { timeouts += 1 }
        ) { _ in true }
        #expect(timedOut.accepted == 0)
        #expect(timeouts == 1)

        let words = try NSRegularExpression(pattern: "cat")
        let whole = SearchCore.enumerateRegexMatches(
            in: "cat concatenate cat", regex: words, wholeWord: true, unconvertibleRangePasses: false,
            cap: nil, timeout: long, startTime: far, onTimeout: {}
        ) { _ in true }
        #expect(whole.accepted == 2)
    }

    // MARK: - The remap

    @Test("baseSpan: identity without a map, the last matched character's base position with one, nil past the map")
    func remap() {
        #expect(SearchCore.baseSpan(start: 2, length: 3, offsetMap: nil) == 2..<5)
        #expect(SearchCore.baseSpan(start: 0, length: 0, offsetMap: nil) == nil)
        let map = [0, 1, 3, 4]   // searched "1234" over base "12-34"
        #expect(SearchCore.baseSpan(start: 0, length: 4, offsetMap: map) == 0..<5)
        #expect(SearchCore.baseSpan(start: 2, length: 2, offsetMap: map) == 3..<5)
        #expect(SearchCore.baseSpan(start: 3, length: 2, offsetMap: map) == nil)
    }
}
