import Testing
import Foundation
@testable import RedactionEngine

// The hyphen-break rule of the literal tiers' run fold, on both sides of a
// match. A line break right after a hard hyphen between two letters or
// digits is dropped, so a name or number a layout engine wraps at its own
// hyphen reads as typed ("Vance-" / "Oduya" → "vance-oduya"); a soft hyphen
// (U+00AD) marks a break inside one word and is dropped wherever it sits.
// Every other run keeps the whitespace fold (one space, or nothing when it
// is zero-width only). The page side folds under the raw-text map, so a
// match across the break still covers the raw text from its first to its
// last Character.
//
// Privacy rule (audit-lint M-1): locate/match/cover vocabulary.

@Suite("Hyphen-break fold", .tags(.search))
struct HyphenBreakFoldTests {

    /// The page side and the query side through the literal tier's own
    /// preparation (the smart-punctuation fold included).
    static func pageSide(_ text: String, _ options: SearchOptions = SearchOptions()) -> String {
        SearchCore.preparePage(text, options: options).searchText
    }

    static func querySide(_ text: String, _ options: SearchOptions = SearchOptions()) -> String {
        SearchCore.preparedQuery(normalized: SearchCore.normalizedText(text, options: options), options: options)
    }

    static let joined: [(String, String, String)] = [
        ("hyphen + line feed", "Vance-\nOduya", "vance-oduya"),
        ("hyphen + CR LF", "Vance-\r\nOduya", "vance-oduya"),
        ("HYPHEN U+2010 + line feed", "Vance\u{2010}\nOduya", "vance-oduya"),
        ("NON-BREAKING HYPHEN U+2011 + line feed", "Vance\u{2011}\nOduya", "vance-oduya"),
        ("hyphen, a space, then the line feed", "Vance- \nOduya", "vance-oduya"),
        ("hyphen + line separator", "Vance-\u{2028}Oduya", "vance-oduya"),
        ("a number broken at its hyphen", "Case No. 18-\n115", "case no. 18-115"),
        ("a soft hyphen at a line end", "Johan\u{00AD}\nson", "johanson"),
        ("a soft hyphen inside a word", "Jo\u{00AD}hanson", "johanson"),
    ]

    @Test("A break after a hard hyphen between word characters is dropped; a soft hyphen is dropped", arguments: joined)
    func hyphenBreakJoins(name: String, text: String, expected: String) {
        #expect(Self.pageSide(text) == expected, "\(name): page side")
        #expect(Self.querySide(text) == expected, "\(name): query side (one rule both sides)")
    }

    static let kept: [(String, String, String)] = [
        ("a dash after a space", "item -\nnext", "item - next"),
        ("a hyphen before spaces with no line break", "Vance-  Oduya", "vance- oduya"),
        ("an em dash at a line end", "pause\u{2014}\nthen", "pause- then"),
        ("a plain wrap", "Jane\nDoe", "jane doe"),
        ("a hyphen at a line end before a non-word character", "Vance-\n(Oduya)", "vance- (oduya)"),
        ("a hyphen at the start of a line", "-\nOduya", "- oduya"),
    ]

    @Test("Every other run keeps the whitespace fold", arguments: kept)
    func otherRunsKeepTheSpace(name: String, text: String, expected: String) {
        #expect(Self.pageSide(text) == expected, "\(name): page side")
        #expect(Self.querySide(text) == expected, "\(name): query side")
    }

    @Test("The typed query is unchanged by the rule")
    func typedQueryUnchanged() {
        #expect(Self.querySide("Vance-Oduya") == "vance-oduya")
        #expect(Self.querySide("Marisol Vance-Oduya") == "marisol vance-oduya")
    }

    @Test("A dropped break leaves the ASCII fast path and the map spans the raw text across it")
    func mapSpansTheBreak() throws {
        let raw = "Signed Vance-\nOduya today"
        let page = SearchCore.preparePage(raw, options: SearchOptions())
        #expect(page.searchText == "signed vance-oduya today")
        #expect(page.rawMap != nil, "the dropped run changes the length, so the page takes the map path")
        let start = try #require(page.searchText.range(of: "vance-oduya"))
        let offset = page.searchText.distance(from: page.searchText.startIndex, to: start.lowerBound)
        let range = try #require(page.rawNSRange(baseStart: offset, length: 11))
        #expect((raw as NSString).substring(with: range) == "Vance-\nOduya", "the span covers the V to the a, the line feed inside")
    }

    @Test("A soft hyphen is dropped on the CR LF and combining-mark pages and the map still lands the match")
    func softHyphenUnderTheMap() throws {
        let raw = "Jo\u{00AD}hanson 123-45-6789"
        let page = SearchCore.preparePage(raw, options: SearchOptions())
        #expect(page.searchText == "johanson 123-45-6789")
        let start = try #require(page.searchText.range(of: "123-45-6789"))
        let offset = page.searchText.distance(from: page.searchText.startIndex, to: start.lowerBound)
        let range = try #require(page.rawNSRange(baseStart: offset, length: 11))
        #expect((raw as NSString).substring(with: range) == "123-45-6789")
    }

    @Test("The rule holds with every option flipped")
    func optionsFlipped() {
        let vectors: [SearchOptions] = [
            SearchOptions(caseSensitive: true),
            SearchOptions(normalizeUnicode: false),
            SearchOptions(normalizeSmartPunctuation: false),
        ]
        for options in vectors {
            #expect(Self.pageSide("Vance-\nOduya", options).lowercased() == "vance-oduya", "\(options)")
            #expect(Self.querySide("Vance-\nOduya", options).lowercased() == "vance-oduya", "\(options)")
            #expect(Self.pageSide("Jo\u{00AD}hanson", options).lowercased() == "johanson", "\(options)")
        }
    }

    @Test("A page with no hyphen break or soft hyphen keeps the whitespace fold's output")
    func noBreakUnchanged() {
        let pages = ["Jane  Doe", "Jane\nDoe", "a - b", "state-of-the-art\ttext", "x \u{200B}y", "18-115 and 42"]
        for text in pages {
            #expect(Self.pageSide(text) == TextNormalizer.normalizeSmartPunctuation(TextNormalizer.foldWhitespaceRuns(text.lowercased())), "\(text)")
        }
    }
}
