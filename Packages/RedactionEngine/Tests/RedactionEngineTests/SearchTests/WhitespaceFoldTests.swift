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

    /// How a page's base offsets reach its raw text: through its map, or,
    /// on single-unit ASCII the fold leaves at its length, as they are (such
    /// a page carries no map).
    enum Path: Sendable { case map, offsets }

    static let runs: [(String, String, Path)] = [
        ("two spaces", "Jane  Doe", .map),
        ("tab", "Jane\tDoe", .offsets),
        ("no-break space", "Jane\u{00A0}Doe", .map),
        ("zero-width space between words with a space", "Jane \u{200B}Doe", .map),
        ("line feed", "Jane\nDoe", .offsets),
        ("carriage return + line feed", "Jane\r\nDoe", .map),
        ("line separator", "Jane\u{2028}Doe", .map),
        ("a control character PDFKit emits for a tab byte", "Jane\u{0000}Doe", .offsets),
        ("a space, a joiner and a tab", "Jane \u{200D}\tDoe", .map),
    ]

    @Test("A run between two words normalizes to one space on the page and on the query side", arguments: runs)
    func runFoldsToOneSpace(name: String, text: String, path: Path) throws {
        let options = SearchOptions()
        #expect(SearchCore.normalizedText(text, options: options) == "jane doe", "\(name)")
        let page = SearchCore.normalizedPage(text, options: options)
        #expect(page.text == "jane doe", "\(name)")
        // The base range of the whole normalized text is the whole raw text,
        // and the one space covers the run's first and last raw characters,
        // on the path the argument names.
        let rawLength = (text as NSString).length
        let whole: NSRange?
        let space: NSRange?
        switch path {
        case .map:
            let map = try #require(page.rawMap, "\(name): the fold changes the length or the text is not single-unit ASCII")
            whole = map.nsRange(baseStart: 0, length: page.text.count)
            space = map.nsRange(baseStart: 4, length: 1)
        case .offsets:
            #expect(page.rawMap == nil, "\(name): single-unit ASCII left at its length carries no map")
            #expect(text.utf8.count == rawLength && page.text.count == rawLength,
                    "\(name): the offsets are raw offsets only on single-unit ASCII of one length")
            whole = NSRange(location: 0, length: page.text.count)
            space = NSRange(location: 4, length: 1)
        }
        #expect(whole == NSRange(location: 0, length: rawLength), "\(name)")
        #expect(space == NSRange(location: 4, length: rawLength - 7), "\(name): the space spans the run")
    }

    @Test("A zero-width character inside a word is dropped, never spaced")
    func zeroWidthInsideAWordIsDropped() throws {
        let options = SearchOptions()
        #expect(SearchCore.normalizedText("Ja\u{200B}ne", options: options) == "jane")
        #expect(SearchCore.normalizedText("Ja\u{FEFF}ne Doe", options: options) == "jane doe")
        let page = SearchCore.normalizedPage("Ja\u{200B}ne Doe", options: options)
        #expect(page.text == "jane doe")
        let map = try #require(page.rawMap)
        // "jane" spans the raw J…e including the dropped joiner.
        #expect(map.nsRange(baseStart: 0, length: 4) == NSRange(location: 0, length: 5))
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
