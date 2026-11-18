import Testing
import Foundation
@testable import RedactionEngine

// The closed-spelling reading of the literal matcher, at the string level. A
// typesetter breaks "Brightwater" as "Bright-" at a line end and "water" on
// the next line. A hyphen that ends a line between two letters of the same
// case is read both ways, kept and dropped; a match found either way counts
// once and covers the hyphen. A hyphen between digits, between letters of
// different case, or after a space is only ever kept. Each row prepares a
// page string and walks it; "found" is one span whose raw range runs from
// the word's first Character to its last, the hyphen and the break inside.
//
// Privacy rule (audit-lint M-1): locate/match/cover vocabulary.

@Suite("Hyphen break: closed spelling", .tags(.search))
struct HyphenBreakClosedSpellingTests {

    struct Row: CustomTestStringConvertible, Sendable {
        let name: String
        let page: String
        let search: String
        let options: SearchOptions
        /// The raw page text the one span covers; nil when nothing is found.
        let found: String?
        /// The spans equal the walk over the page as read.
        var sameAsRead: Bool = false
        var testDescription: String { name }
    }

    static func options(wholeWord: Bool = false, caseSensitive: Bool = false,
                        digitSeparators: Bool = false, accents: Bool = false) -> SearchOptions {
        var options = SearchOptions()
        options.wholeWord = wholeWord
        options.caseSensitive = caseSensitive
        options.stripDigitSeparators = digitSeparators
        options.foldDiacritics = accents
        return options
    }

    static let broken = "Bright-\nwater"
    static let rows: [Row] = [
        Row(name: "a word broken at a line-end hyphen is found by its closed spelling",
            page: broken, search: "Brightwater", options: options(), found: broken),
        Row(name: "the same word is still found with its hyphen, one span",
            page: broken, search: "Bright-water", options: options(), found: broken),
        Row(name: "a phrase that opens with the broken word is found by its closed spelling",
            page: "Bright-\nwater Benefit Services", search: "Brightwater Benefit Services", options: options(),
            found: "Bright-\nwater Benefit Services"),
        Row(name: "upper case on both sides of the break: found with capitals ignored",
            page: "BRIGHT-\nWATER", search: "brightwater", options: options(), found: "BRIGHT-\nWATER"),
        Row(name: "a capital after the break keeps the hyphen: the closed spelling is not found",
            page: "Vance-\nOduya", search: "VanceOduya", options: options(), found: nil),
        Row(name: "a capital after the break: the hyphenated name is found",
            page: "Vance-\nOduya", search: "Vance-Oduya", options: options(), found: "Vance-\nOduya"),
        Row(name: "digits never drop the hyphen: the run-together number is not found",
            page: "18-\n115", search: "18115", options: options(), found: nil),
        Row(name: "digits keep the hyphen: the hyphenated number is found",
            page: "18-\n115", search: "18-115", options: options(), found: "18-\n115"),
        Row(name: "a compound broken at its own hyphen is also found by its closed spelling",
            page: "well-\nknown", search: "wellknown", options: options(), found: "well-\nknown"),
        Row(name: "a compound broken at its own hyphen is found with its hyphen",
            page: "well-\nknown", search: "well-known", options: options(), found: "well-\nknown"),
        Row(name: "a hyphen inside one line is never dropped",
            page: "Bright-water", search: "Brightwater", options: options(), found: nil),
        Row(name: "whole word: the second part of the broken word is one span",
            page: broken, search: "water", options: options(wholeWord: true), found: "water"),
        Row(name: "whole word: the first part of the broken word is one span",
            page: broken, search: "Bright", options: options(wholeWord: true), found: "Bright"),
        Row(name: "two breaks in a phrase, both dropped: found",
            page: "Bright-\nwater Bene-\nfit", search: "Brightwater Benefit", options: options(),
            found: "Bright-\nwater Bene-\nfit"),
        Row(name: "two breaks in a phrase, both kept: found",
            page: "Bright-\nwater Bene-\nfit", search: "Bright-water Bene-fit", options: options(),
            found: "Bright-\nwater Bene-\nfit"),
        Row(name: "two breaks in a phrase, one kept and one dropped: not found",
            page: "Bright-\nwater Bene-\nfit", search: "Bright-water Benefit", options: options(), found: nil),
        Row(name: "with digit separators on, the spans are those of the page as read",
            page: broken, search: "Brightwater", options: options(digitSeparators: true), found: broken,
            sameAsRead: true),
        Row(name: "case-sensitive: lower case does not match a word printed in capitals",
            page: "BRIGHT-\nWATER", search: "brightwater", options: options(caseSensitive: true), found: nil),
        Row(name: "case-sensitive: capitals match the closed spelling of a word printed in capitals",
            page: "BRIGHT-\nWATER", search: "BRIGHTWATER", options: options(caseSensitive: true),
            found: "BRIGHT-\nWATER"),
        Row(name: "a line-end HYPHEN (U+2010): found by the closed spelling",
            page: "Bright\u{2010}\nwater", search: "Brightwater", options: options(), found: "Bright\u{2010}\nwater"),
        Row(name: "a line-end NON-BREAKING HYPHEN (U+2011): found by the closed spelling",
            page: "Bright\u{2011}\nwater", search: "Brightwater", options: options(), found: "Bright\u{2011}\nwater"),
        Row(name: "a soft hyphen at a line end: found as before",
            page: "Johan\u{00AD}\nson", search: "Johanson", options: options(), found: "Johan\u{00AD}\nson"),
        Row(name: "accents on: a broken word with an accent is found, its raw range whole",
            page: "Gr\u{00FC}n-\nwald", search: "Grunwald", options: options(accents: true), found: "Gr\u{00FC}n-\nwald"),
        Row(name: "a dash after a space is never dropped: the run-together words are not found",
            page: "item -\nnext", search: "itemnext", options: options(), found: nil),
        Row(name: "a dash after a space is never dropped: the words with a space are not found",
            page: "item -\nnext", search: "item next", options: options(), found: nil),
    ]

    static func query(_ search: String, _ options: SearchOptions) -> String {
        SearchCore.preparedQuery(normalized: SearchCore.normalizedText(search, options: options), options: options)
    }

    static func raw(_ span: SearchCore.MatchSpan, _ prepared: SearchCore.PreparedPage, _ page: String) -> String? {
        prepared.rawNSRange(of: span).map { (page as NSString).substring(with: $0) }
    }

    @Test("Each row's search over its page", arguments: rows)
    func row(_ row: Row) throws {
        #expect(Self.rows.count == 25, "the table holds its 25 rows")
        let prepared = SearchCore.preparePage(row.page, options: row.options)
        let query = Self.query(row.search, row.options)
        let (spans, stopped) = SearchCore.literalSpans(
            in: prepared, query: query, comparison: [], wholeWord: row.options.wholeWord, cap: nil)
        #expect(!stopped)
        if let found = row.found {
            try #require(spans.count == 1, "\(row.name): \(spans.map { Self.raw($0, prepared, row.page) ?? "?" })")
            #expect(Self.raw(spans[0], prepared, row.page) == found, "\(row.name)")
        } else {
            #expect(spans.isEmpty, "\(row.name): \(spans.map { Self.raw($0, prepared, row.page) ?? "?" })")
        }
        if row.sameAsRead {
            let asRead = SearchCore.literalSpansAsRead(
                in: prepared, query: query, comparison: [], wholeWord: row.options.wholeWord, cap: nil)
            #expect(spans == asRead.spans, "\(row.name)")
        }
    }

    @Test("A page with one match by each reading, cap 1: one span, the earlier, and the walk reports the cap")
    func capTakesTheEarlierSpan() throws {
        for (page, earlier) in [("Brightwater, then Bright-\nwater", "Brightwater"),
                                ("Bright-\nwater, then Brightwater", "Bright-\nwater")] {
            let prepared = SearchCore.preparePage(page, options: SearchOptions())
            let query = Self.query("Brightwater", SearchOptions())
            let all = SearchCore.literalSpans(in: prepared, query: query, comparison: [], wholeWord: false, cap: nil)
            #expect(all.spans.count == 2 && !all.stoppedAtCap, "\(page)")
            let (spans, stopped) = SearchCore.literalSpans(in: prepared, query: query, comparison: [], wholeWord: false, cap: 1)
            try #require(spans.count == 1, "\(page)")
            #expect(stopped, "\(page)")
            #expect(Self.raw(spans[0], prepared, page) == earlier, "\(page)")
        }
    }

    /// A fixed, seeded generator (SplitMix64), so the pages are the same on
    /// every run.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// 200 pages of words and numbers, about one line end in three a hyphen
    /// break (lower, upper or mixed case, digits, a dash after a space).
    static func seededPages() -> [String] {
        var random = Seeded(state: 0x5EED_0F_11E5)
        let words = ["bright", "water", "Bright", "WATER", "bene", "fit", "well", "known", "Vance", "Oduya",
                     "gr\u{00FC}n", "wald", "item", "next", "18", "115", "a", "an", "ter", "Services", "LLC"]
        return (0..<200).map { _ in
            var page = ""
            for _ in 0..<(8 + Int(random.next() % 12)) {
                let line = (0..<(1 + Int(random.next() % 5))).map { _ in words[Int(random.next() % UInt64(words.count))] }
                page += line.joined(separator: " ")
                switch random.next() % 6 {
                case 0: page += "-\n"
                case 1: page += "\u{2010}\n"
                case 2: page += " -\n"
                default: page += "\n"
                }
            }
            return page
        }
    }

    @Test("200 seeded pages: every span found before is found after, and every added span covers a line-end hyphen")
    func seededPagesOnlyAdd() {
        let pages = Self.seededPages()
        #expect(pages.count == 200)
        let searches = ["brightwater", "bright-water", "water", "wellknown", "well-known", "benefit", "ter", "a",
                        "an", "waterbright", "18115", "18-115", "vanceoduya", "grunwald", "itemnext", "llc"]
        let optionSets = [Self.options(), Self.options(wholeWord: true), Self.options(caseSensitive: true),
                          Self.options(accents: true)]
        var added = 0
        var walks = 0
        for page in pages {
            for options in optionSets {
                let prepared = SearchCore.preparePage(page, options: options)
                for search in searches {
                    let query = Self.query(search, options)
                    let before = SearchCore.literalSpansAsRead(
                        in: prepared, query: query, comparison: [], wholeWord: options.wholeWord, cap: nil).spans
                    let after = SearchCore.literalSpans(
                        in: prepared, query: query, comparison: [], wholeWord: options.wholeWord, cap: nil).spans
                    walks += 1
                    #expect(before.allSatisfy { after.contains($0) }, "a span was lost: \(search) on \(page)")
                    for span in after where !before.contains(span) {
                        added += 1
                        let text = Self.raw(span, prepared, page) ?? ""
                        let holdsBreak = ["-\n", "\u{2010}\n"].contains { text.contains($0) }
                        #expect(holdsBreak, "an added span without a line-end hyphen: \(text.debugDescription)")
                    }
                    let starts = after.map(\.searchedRange.location)
                    #expect(starts == starts.sorted(), "spans in page order")
                }
            }
        }
        #expect(walks == 200 * 4 * 16)
        #expect(added > 0, "the seeded pages hold closed-spelling matches")
    }
}
