import Testing
@testable import ResectaApp

// The two provisional lines, not yet approved: the
// words for one page and for several, pages named one-based, each once, in
// order; no line for no pages.

@Suite("Search statement: the provisional words")
struct SearchStatementProvisionalWordsTests {

    typealias Words = SearchStatement.ProvisionalWords

    @Test("No report: one page, then several")
    func noReport() {
        #expect(Words.noReport(pages: [2]) == "Page 3 has no record of being searched. Check it by eye.")
        #expect(Words.noReport(pages: [6, 2, 2]) == "Pages 3 and 7 have no record of being searched. Check them by eye.")
        #expect(Words.noReport(pages: [0, 4, 9]) == "Pages 1, 5, and 10 have no record of being searched. Check them by eye.")
        #expect(Words.noReport(pages: []) == nil)
    }

    @Test("Pictures not read with no cause given: one page, then several")
    func picturesNotReported() {
        #expect(Words.picturesNotReported(pages: [0]) == "The pictures on page 1 were not read. Check it by eye.")
        #expect(Words.picturesNotReported(pages: [3, 1]) == "The pictures on pages 2 and 4 were not read. Check them by eye.")
        #expect(Words.picturesNotReported(pages: []) == nil)
    }
}
