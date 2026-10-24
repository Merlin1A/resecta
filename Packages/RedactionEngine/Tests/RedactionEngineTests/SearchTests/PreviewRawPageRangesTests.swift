import Testing
import Foundation
@testable import RedactionEngine

// The preview's raw page ranges: each visible-page match as a range in the
// raw page text (`PDFPage.string`), through the map the full search places its
// boxes from. The preview's own ranges are in the searched text's coordinates,
// which shift on a page the search normalizes — a ligature expands, a wide
// character counts once — so a highlight drawn from them sits elsewhere than
// the box Apply places. Drawn from these, it sits on the box.

@Suite("Search preview: raw page ranges")
struct PreviewRawPageRangesTests {

    private func preview(_ mode: SearchMode, page: String) async -> SearchPreviewResult {
        await DocumentSearcher().previewMatches(
            mode: mode, scope: .currentPage(pageIndex: 0), currentPageIndex: 0,
            totalPageCount: 1, pageTextProvider: { _ in page })
    }

    private func raw(_ needle: String, in page: String) -> NSRange {
        (page as NSString).range(of: needle)
    }

    @Test("After a ligature, the raw range covers the match on the raw page; the searched range is shifted")
    func ligatureBeforeTheMatch() async {
        let page = "The \u{FB01}le number 123-45-6789 is on record."
        let text = await preview(.text("123-45-6789", options: SearchOptions()), page: page)
        #expect(text.currentPageRawRanges == [raw("123-45-6789", in: page)])
        #expect(text.currentPageMatches != text.currentPageRawRanges, "the searched range is shifted by the expansion")
        let regex = await preview(.regex(#"\d{3}-\d{2}-\d{4}"#, options: SearchOptions()), page: page)
        #expect(regex.currentPageRawRanges == [raw("123-45-6789", in: page)])
    }

    @Test("After a character wider than one UTF-16 unit, the raw range still covers the match")
    func wideCharacterBeforeTheMatch() async {
        let page = "Note \u{1F600} for Delia Hartwell, filed today."
        let text = await preview(.text("Delia Hartwell", options: SearchOptions()), page: page)
        #expect(text.currentPageRawRanges == [raw("Delia Hartwell", in: page)])
    }

    @Test("A digit-separator fold maps back to the separated number on the raw page")
    func separatorFoldMapsBack() async {
        let page = "\u{FB01}nal SSN 123-45-6789."
        var options = SearchOptions()
        options.stripDigitSeparators = true
        let text = await preview(.text("123456789", options: options), page: page)
        #expect(text.currentPageRawRanges == [raw("123-45-6789", in: page)])
    }

    @Test("On a plain ASCII page the raw ranges are the preview's ranges")
    func asciiPageRangesAgree() async {
        let page = "Delia Hartwell and Delia Moss signed."
        let text = await preview(.text("Delia", options: SearchOptions()), page: page)
        #expect(text.currentPageRawRanges.count == 2)
        #expect(text.currentPageRawRanges == text.currentPageMatches)
    }

    @Test("Every term of a multi-term preview has its raw range")
    func multiTermRawRanges() async {
        let page = "\u{FB01}rst: Delia Hartwell, SSN 123-45-6789."
        let result = await preview(.multiTerm(["Hartwell", "123-45-6789"], options: SearchOptions()), page: page)
        let ns = page as NSString
        #expect(Set(result.currentPageRawRanges.map { ns.substring(with: $0) }) == ["Hartwell", "123-45-6789"])
    }
}
