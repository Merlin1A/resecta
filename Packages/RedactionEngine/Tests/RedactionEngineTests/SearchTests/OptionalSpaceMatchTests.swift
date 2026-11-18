import Testing
import Foundation
@testable import RedactionEngine

// The optional-space reading of the literal matcher, at the string level. On
// some typed pages the text layer reads a tightly set line with its words
// run together: "betweenHalvorsenMarineSupply,Inc.". A typed search of two or
// more words is compared a second time with its free spaces able to match
// nothing where the page's own Characters show a word edge: a small letter
// then a capital, two capitals then a small letter, a letter beside a digit,
// or a mark that is neither on either side. A space beside a one-letter or
// one-digit word is never free; a space at either end of the search is
// compared as today; white space on the page matches only a space of the
// search. Each row prepares a page string and walks it; "found" lists the
// raw page text each span covers, in page order.
//
// Privacy rule (audit-lint M-1): locate/match/cover vocabulary.

@Suite("Optional space: the second walk", .tags(.search))
struct OptionalSpaceMatchTests {

    struct Row: CustomTestStringConvertible, Sendable {
        let name: String
        let page: String
        let search: String
        var options: SearchOptions = SearchOptions()
        /// The raw page text of each span, in page order; empty when nothing is found.
        let found: [String]
        var cap: Int? = nil
        var stoppedAtCap: Bool = false
        /// The spans equal the walk without the optional-space reading.
        var sameAsToday: Bool = false
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

    static let value = "Halvorsen Marine Supply, Inc."
    static let rows: [Row] = [
        Row(name: "a phrase printed with its spaces is found once, as today",
            page: "between Halvorsen Marine Supply, Inc. and", search: value,
            found: ["Halvorsen Marine Supply, Inc."], sameAsToday: true),
        Row(name: "a phrase read with its words run together is found",
            page: "betweenHalvorsenMarineSupply,Inc.and", search: value, found: ["HalvorsenMarineSupply,Inc."]),
        Row(name: "a phrase with one space read and one run together is found",
            page: "between Halvorsen MarineSupply, Inc.", search: value, found: ["Halvorsen MarineSupply, Inc."]),
        Row(name: "a space on the page needs a space in the search: 'there' is not found in 'the red'",
            page: "the red", search: "there", found: []),
        Row(name: "a space on the page needs a space in the search: 'HalvorsenMarine' is not found",
            page: "Halvorsen Marine", search: "HalvorsenMarine", found: []),
        Row(name: "between two small letters no space is closed up: 'to day' is not found in 'today'",
            page: "today", search: "to day", found: []),
        Row(name: "between two small letters no space is closed up: 'may be' is not found in 'maybe'",
            page: "maybe", search: "may be", found: []),
        Row(name: "a closed-up match and an overlapping spaced one are both found",
            page: "AbcdefAbcdef Abcdef", search: "Abcdef Abcdef", found: ["AbcdefAbcdef", "Abcdef Abcdef"]),
        Row(name: "whole word: a run-together phrase inside a longer run is not found",
            page: "betweenHalvorsenMarine", search: "Halvorsen Marine", options: options(wholeWord: true), found: []),
        Row(name: "whole word: one word inside a run is not found, as today",
            page: "betweenHalvorsenMarine", search: "Halvorsen", options: options(wholeWord: true), found: []),
        Row(name: "whole word: a run-together pair that stands alone is found",
            page: "see NorthWestern now", search: "North Western", options: options(wholeWord: true),
            found: ["NorthWestern"]),
        Row(name: "accents on: a run-together name with an accent is found, its raw range whole",
            page: "Attention: TobiasGr\u{00FC}newald,VicePresident", search: "Tobias Grunewald",
            options: options(accents: true), found: ["TobiasGr\u{00FC}newald"]),
        Row(name: "a ligature before a run-together phrase: the raw range is the phrase's own Characters",
            page: "\u{FB01}le: betweenHalvorsenMarineSupply", search: "Halvorsen Marine Supply",
            found: ["HalvorsenMarineSupply"]),
        Row(name: "a run-together phrase broken across a line is found as one span",
            page: "betweenHalvorsenMarine\nSupply,Inc.", search: value, found: ["HalvorsenMarine\nSupply,Inc."]),
        Row(name: "case-sensitive: the run-together phrase is found with its capitals",
            page: "HalvorsenMarine", search: "Halvorsen Marine", options: options(caseSensitive: true),
            found: ["HalvorsenMarine"]),
        Row(name: "case-sensitive: small letters do not match the run-together capitals",
            page: "HalvorsenMarine", search: "halvorsen marine", options: options(caseSensitive: true), found: []),
        Row(name: "cap 2 over a spaced, a closed-up and a spaced match: the first two in page order",
            page: "Halvorsen Marine Supply, then HalvorsenMarineSupply, then Halvorsen Marine Supply",
            search: "Halvorsen Marine Supply", found: ["Halvorsen Marine Supply", "HalvorsenMarineSupply"],
            cap: 2, stoppedAtCap: true),
        Row(name: "with a line-end hyphen dropped, a run-together phrase broken at it is found",
            page: "HalvorsenMa-\nrineSupply", search: "Halvorsen Marine Supply", found: ["HalvorsenMa-\nrineSupply"]),
        Row(name: "two one-letter words: only the spaced match, none inside 'about' or 'table'",
            page: "about a b table", search: "a b", found: ["a b"]),
        Row(name: "a one-symbol word is not a one-letter word: 'Corliss & Pemberton' is found run together",
            page: "Corliss&Pemberton", search: "Corliss & Pemberton", found: ["Corliss&Pemberton"]),
        Row(name: "a phrase holding a one-letter word is not found run together",
            page: "PlanAsummary", search: "Plan A summary", found: []),
        Row(name: "initials with their spaces are found as today",
            page: "J R Smith", search: "J R Smith", found: ["J R Smith"]),
        Row(name: "initials run together are not found",
            page: "JRSmith", search: "J R Smith", found: []),
        Row(name: "a space at the end of the search is compared as today: none",
            page: "see annual plan", search: "ann ", found: []),
        Row(name: "a space at the start of the search is compared as today: the one before 'annual'",
            page: "see annual plan", search: " ann", found: [" ann"]),
        Row(name: "a short pair is not found closed up inside a word: 'In Su' in 'insurance'",
            page: "insurance", search: "In Su", found: []),
        Row(name: "a short pair is not found closed up inside a word: 'Mi Ni' in 'administrator'",
            page: "administrator", search: "Mi Ni", found: []),
        Row(name: "a short pair is not found closed up inside a word: 'Mi Ni' in 'minimum'",
            page: "minimum", search: "Mi Ni", found: []),
        Row(name: "cap 3 over five words that hold a short pair closed up: the spaced match alone",
            page: "insurance insure insured insurer insures In Su", search: "In Su", found: ["In Su"], cap: 3),
        Row(name: "a phrase in small letters run together is not found",
            page: "betweenhalvorsenmarinesupply", search: "halvorsen marine supply", found: []),
        Row(name: "a short name run together between other words is found",
            page: "betweenJohnDoeand", search: "John Doe", found: ["JohnDoe"]),
        Row(name: "a capital that starts a word after capitals is an edge: 'IBM Corp' is found",
            page: "IBMCorp", search: "IBM Corp", found: ["IBMCorp"]),
        Row(name: "a small word between names is not found run together",
            page: "BankofAmerica", search: "Bank of America", found: []),
        Row(name: "a small word between names inside a run of 40 Characters is not found",
            page: "WireDeskBankofAmericaPaymentsCenterUnitX", search: "Bank of America", found: []),
        Row(name: "after a refused candidate the walk moves on by one Character and the later match is found",
            page: "Abc defAbcdefAbcdef", search: "Abcdef Abcdef", found: ["AbcdefAbcdef"]),
        Row(name: "a name printed in capitals run together is not found",
            page: "JOHNDOE", search: "John Doe", found: []),
        Row(name: "a phrase printed in capitals run together is not found",
            page: "HALVORSENMARINESUPPLY,INC.", search: value, found: []),
        Row(name: "a number with its groups run together is not found",
            page: "6125550142", search: "612 555 0142", found: []),
        Row(name: "a name with an initial run together is not found",
            page: "JohnQPublic", search: "John Q Public", found: []),
        Row(name: "a space at the end of the search is never closed up, even at a word edge",
            page: "see AnnLee now", search: "Ann ", found: []),
    ]

    static func query(_ search: String, _ options: SearchOptions) -> String {
        SearchCore.preparedQuery(normalized: SearchCore.normalizedText(search, options: options), options: options)
    }

    static func raw(_ span: SearchCore.MatchSpan, _ prepared: SearchCore.PreparedPage, _ page: String) -> String? {
        prepared.rawNSRange(of: span).map { (page as NSString).substring(with: $0) }
    }

    @Test("Each row's search over its page", arguments: rows)
    func row(_ row: Row) throws {
        #expect(Self.rows.count == 40, "the table holds its 40 rows")
        let prepared = SearchCore.preparePage(row.page, options: row.options)
        let query = Self.query(row.search, row.options)
        let (spans, stopped) = SearchCore.literalSpans(
            in: prepared, query: query, comparison: [], wholeWord: row.options.wholeWord, cap: row.cap)
        #expect(stopped == row.stoppedAtCap, "\(row.name)")
        #expect(spans.map { Self.raw($0, prepared, row.page) ?? "?" } == row.found, "\(row.name)")
        let starts = spans.map(\.searchedRange.location)
        #expect(starts == starts.sorted(), "\(row.name): spans in page order")
        if row.sameAsToday {
            let today = SearchCore.literalSpans(
                in: prepared, query: query, comparison: [], wholeWord: row.options.wholeWord, cap: row.cap,
                spacesMayMatchNothing: false)
            #expect(spans == today.spans, "\(row.name)")
        }
    }

    @Test("A twelve-word search is found spaced and with three of its spaces closed up")
    func twelveWords() throws {
        let search = "Brightwater Benefit Services Holding Company Northern Regional Office Claims Review Panel Secretary"
        #expect(search.split(separator: " ").count == 12)
        let pages = [search,
                     "BrightwaterBenefit Services HoldingCompany Northern Regional OfficeClaims Review Panel Secretary"]
        for page in pages {
            let prepared = SearchCore.preparePage("to " + page + " today", options: SearchOptions())
            let spans = SearchCore.literalSpans(
                in: prepared, query: Self.query(search, SearchOptions()), comparison: [], wholeWord: false, cap: nil).spans
            #expect(spans.map { Self.raw($0, prepared, "to " + page + " today") ?? "?" } == [page], "\(page)")
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

    static let words = ["Halvorsen", "Marine", "Supply,", "Inc.", "between", "today", "to", "day", "IBM", "Corp",
                        "612", "555", "0142", "a", "b", "Ann", "Lee", "insurance", "In", "Su", "Gr\u{00FC}newald",
                        "Tobias", "MN", "55405", "Suite", "210"]

    /// 200 pages of these words; about one join in four has no space, and
    /// about one line end in five is a hyphen break.
    static func seededPages() -> [String] {
        var random = Seeded(state: 0x0B7_5BACE)
        return (0..<200).map { _ in
            var page = ""
            for _ in 0..<(6 + Int(random.next() % 10)) {
                for index in 0..<(2 + Int(random.next() % 6)) {
                    if index > 0 { page += random.next() % 4 == 0 ? "" : " " }
                    page += words[Int(random.next() % UInt64(words.count))]
                }
                page += random.next() % 5 == 0 ? "-\n" : "\n"
            }
            return page
        }
    }

    @Test("200 seeded pages, 50 one-word searches: every span list equal to the one without the second walk")
    func oneWordSearchesUnchanged() {
        let pages = Self.seededPages()
        #expect(pages.count == 200)
        var searches = Self.words + Self.words.map { String($0.prefix(3)) }
        var seen = Set<String>()
        searches = searches.filter { seen.insert($0).inserted }
        searches += ["e", "nn", "ce,", "0", "xyz", "ma", "upp", "IBMCorp", "AnnLee", "HalvorsenMarine",
                     "todayto", "a-", "rine", "2105", "Lee,", "s"]
        searches = Array(searches.prefix(50))
        #expect(searches.count == 50)
        var walks = 0
        for page in pages {
            let prepared = SearchCore.preparePage(page, options: SearchOptions())
            for search in searches {
                let query = Self.query(search, SearchOptions())
                let after = SearchCore.literalSpans(in: prepared, query: query, comparison: [], wholeWord: false, cap: nil)
                let before = SearchCore.literalSpans(
                    in: prepared, query: query, comparison: [], wholeWord: false, cap: nil, spacesMayMatchNothing: false)
                #expect(after.spans == before.spans, "\(search) on \(page.debugDescription)")
                walks += 1
            }
        }
        #expect(walks == 200 * 50)
    }

    @Test("Digit separators on, the seeded pages and a fixed list: every span list equal to the one before")
    func digitSeparatorsUnchanged() {
        let options = Self.options(digitSeparators: true)
        let searches = ["Halvorsen Marine", "Marine Supply, Inc.", "IBM Corp", "612 555 0142", "Ann Lee", "to day",
                        "In Su", "MN 55405", "Suite 210", "Tobias Grunewald"]
        var walks = 0
        var found = 0
        for page in Self.seededPages() {
            let prepared = SearchCore.preparePage(page, options: options)
            for search in searches {
                let query = Self.query(search, options)
                guard !query.isEmpty else { continue }
                let after = SearchCore.literalSpans(in: prepared, query: query, comparison: [], wholeWord: false, cap: nil)
                let before = SearchCore.literalSpans(
                    in: prepared, query: query, comparison: [], wholeWord: false, cap: nil, spacesMayMatchNothing: false)
                #expect(after.spans == before.spans, "\(search) on \(page.debugDescription)")
                walks += 1
                found += after.spans.count
            }
        }
        #expect(walks == 200 * searches.count)
        #expect(found > 0, "the seeded pages hold matches under the strip")
    }
}
