import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The whitespace-run fold under the literal tiers' normalization: a run of
// whitespace, zero-width or control characters between two words reads as
// the one space a user types, on the page side (through the raw-text map,
// so a rect still lands on the raw characters) and on the query side. A
// text without a run keeps today's output.
//
// Privacy rule (audit-lint M-1): locate/match/cover vocabulary.

@Suite("Whitespace fold", .tags(.search))
struct WhitespaceFoldTests {

    static let runs: [(String, String)] = [
        ("two spaces", "Jane  Doe"),
        ("tab", "Jane\tDoe"),
        ("no-break space", "Jane\u{00A0}Doe"),
        ("zero-width space between words with a space", "Jane \u{200B}Doe"),
        ("line feed", "Jane\nDoe"),
        ("carriage return + line feed", "Jane\r\nDoe"),
        ("line separator", "Jane\u{2028}Doe"),
        ("a control character PDFKit emits for a tab byte", "Jane\u{0000}Doe"),
        ("a space, a joiner and a tab", "Jane \u{200D}\tDoe"),
    ]

    @Test("A run between two words normalizes to one space on the page and on the query side", arguments: runs)
    func runFoldsToOneSpace(name: String, text: String) {
        let options = SearchOptions()
        #expect(SearchCore.normalizedText(text, options: options) == "jane doe", "\(name)")
        let page = SearchCore.normalizedPage(text, options: options)
        #expect(page.text == "jane doe", "\(name)")
        // The map spans the raw text from the J to the e: the base range of
        // the whole normalized text is the whole raw text.
        let map = try? #require(page.rawMap, "\(name): the fold leaves the fast path")
        if let map {
            let whole = map.nsRange(baseStart: 0, length: page.text.count)
            #expect(whole == NSRange(location: 0, length: (text as NSString).length), "\(name)")
            // The one space covers the run's first and last raw characters.
            let space = map.nsRange(baseStart: 4, length: 1)
            let rawRun = (text as NSString).length - 7
            #expect(space == NSRange(location: 4, length: rawRun), "\(name): the space spans the run")
        }
    }

    @Test("A zero-width character inside a word is dropped, never spaced")
    func zeroWidthInsideAWordIsDropped() {
        let options = SearchOptions()
        #expect(SearchCore.normalizedText("Ja\u{200B}ne", options: options) == "jane")
        #expect(SearchCore.normalizedText("Ja\u{FEFF}ne Doe", options: options) == "jane doe")
        let page = SearchCore.normalizedPage("Ja\u{200B}ne Doe", options: options)
        #expect(page.text == "jane doe")
        let map = try? #require(page.rawMap)
        // "jane" spans the raw J…e including the dropped joiner.
        #expect(map?.nsRange(baseStart: 0, length: 4) == NSRange(location: 0, length: 5))
    }

    @Test("The fold composes with the case fold, Accents and Digit separators in the existing order")
    func foldComposesWithTheExtensions() {
        var options = SearchOptions()
        options.foldDiacritics = true
        options.stripDigitSeparators = true
        let prepared = SearchCore.preparePage("Müller\n  García 970-72\t5518", options: options)
        let query = SearchCore.preparedQuery(normalized: SearchCore.normalizedText("muller garcia 970 72 5518", options: options), options: options)
        let (spans, _) = SearchCore.literalSpans(in: prepared, query: query, comparison: [], wholeWord: false, cap: nil)
        #expect(spans.count == 1, "the phrase matches across the run, the accents and the separators: \(prepared.searchText)")
        if let span = spans.first {
            let base = span.base ?? span.searchedCharacters
            let raw = prepared.rawNSRange(baseStart: base.lowerBound, length: base.count)
            #expect(raw == NSRange(location: 0, length: ("Müller\n  García 970-72\t5518" as NSString).length))
        }
    }

    @Test("A text without a run keeps the fast path and today's output")
    func noRunKeepsTodaysOutput() {
        let options = SearchOptions()
        let text = "Delia Hartwell, 4127 Wrenfield Place, Boise, ID 83702"
        let page = SearchCore.normalizedPage(text, options: options)
        #expect(page.rawMap == nil, "single-unit ASCII with no run: no map")
        #expect(page.text == text.lowercased())
        #expect(SearchCore.normalizedText(text, options: options) == text.lowercased())
    }

    @Test("Whole-word boundaries hold across a folded run")
    func wholeWordAcrossARun() {
        let options = SearchOptions()
        let prepared = SearchCore.preparePage("Jane\nDoe signed; Janet\nDoes did not", options: options)
        let (spans, _) = SearchCore.literalSpans(in: prepared, query: "jane doe", comparison: [], wholeWord: true, cap: nil)
        #expect(spans.count == 1)
    }
}
