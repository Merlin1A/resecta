#if DEBUG
import Foundation
import PDFKit
import Testing
@testable import ResectaApp

// The Legal-size test document behind `--legalDoc`: the launch map names
// it, and the bundled file is two US Legal pages.
@Suite("The Legal-size test document")
struct LegalTestDocumentTests {

    @Test("The launch map gives the Legal document for --legalDoc, and the first fixture argument still wins")
    func launchMapNamesIt() {
        #expect(ResectaApp.testDocumentName(for: ["--uitesting", "--loadTestDocument", "--legalDoc"]) == "uitest_legal")
        #expect(ResectaApp.testDocumentName(for: ["--loadTestDocument", "--legalDoc", "--multipageDoc"]) == "uitest_legal")
        #expect(ResectaApp.testDocumentName(for: ["--loadTestDocument", "--multipageDoc", "--legalDoc"]) == "uitest_multipage")
        #expect(ResectaApp.testDocumentName(for: ["--loadTestDocument"]) == "test_sample")
    }

    @Test("The bundled Legal document is two pages of 612 by 1008 points, with text at each page's foot")
    func bundledFileIsTwoLegalPages() throws {
        let url = try #require(Bundle.main.url(forResource: "uitest_legal", withExtension: "pdf"))
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount == 2)
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index))
            let media = page.bounds(for: .mediaBox)
            #expect(abs(media.width - 612) <= 0.5 && abs(media.height - 1008) <= 0.5, "page \(index): \(media)")
            let text = try #require(page.string)
            let last = try #require((text as NSString).range(of: "The last line of page \(index + 1)").toOptional)
            let foot = try #require(page.selection(for: last)).bounds(for: page)
            #expect(foot.minY <= 30, "page \(index): last line's box starts \(foot.minY) pt above the foot")
        }
    }
}

private extension NSRange {
    var toOptional: NSRange? { location == NSNotFound ? nil : self }
}
#endif
