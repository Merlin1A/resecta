import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

/// The hidden-word check reads the source page's characters as alignment
/// candidates. A character wholly off the visible page (a crop box that
/// reaches past the media box) stays a candidate, its box clamped to the
/// page's edge, as before an off-page match was given no search box.
@Suite("Hidden word check: a source character off the visible page")
struct HiddenWordInkOffPageSourceTests {

    @Test("a source line wholly off the visible page stays among the candidates, clamped to the page's edge")
    func offPageSourceLineStaysACandidate() throws {
        let hidden = "PLANT-ENGCROP-01"
        let doc = try #require(PDFDocument(data: TestFixtures.offCropBoxTextPDF(hidden: hidden, cropBoxPastMediaBox: true)))
        let page = try #require(doc.page(at: 0))
        let text = try #require(page.string) as NSString
        let range = text.range(of: hidden)
        try #require(range.location != NSNotFound, "PDFKit extracts the line past the visible page")
        let selection = try #require(page.selection(for: range))
        // The premise: the line has no search box (wholly off the visible page).
        #expect(DocumentSearcher().normalizedRect(for: selection, page: page) == nil)
        let glyphs = VerificationEngine.hiddenWordInkSourceGlyphs(page)
        let candidates = String(glyphs.map(\.char))
        #expect(candidates.contains(hidden), "the off-page line's characters are candidates: \(candidates)")
        #expect(glyphs.allSatisfy { $0.rect.minY >= 0 && $0.rect.maxY <= 1 && $0.rect.minX >= 0 && $0.rect.maxX <= 1 },
                "every candidate's box lies on the page")
    }
}
