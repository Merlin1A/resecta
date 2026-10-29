import Testing
import Foundation
@testable import RedactionEngine

// The OCR Check reads the words of a redacted search match that open the
// next line after a box as part of the match: a name that wraps
// ("…the claimant is Marisol" / "Vance-Oduya and her counsel.") with only
// the first line's box applied leaves the surname printed at the start of
// the line below — no box beside it on its own line, so the same-line
// fragment rule never read it. The mirror is the box opening the line below
// and the name's first word ending the line above. The arm reads whole
// words of a term of two or more words, beside a box a search placed.
//
// Privacy rule (audit-lint M-1): locate/match/cover vocabulary.

@Suite("OCR Check — a term's words on the line beside a box")
struct Layer2CrossLineFragmentTests {

    private let term = SensitiveTerm(text: "Marisol Vance-Oduya")
    private static let lineHeight: CGFloat = 0.02
    private static let upperY: CGFloat = 0.60
    private static let lowerY: CGFloat = 0.575

    private func hit(_ text: String, x: CGFloat, width: CGFloat, y: CGFloat) -> VerificationEngine.OCRHit {
        VerificationEngine.OCRHit(
            box: CGRect(x: x, y: y, width: width, height: Self.lineHeight), wordBoxes: [], text: text, confidence: 0.9)
    }

    private func box(x: CGFloat, width: CGFloat, y: CGFloat,
                     source: RedactionRegion.Source = .searchMatch(term: "Marisol Vance-Oduya")) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: CGRect(x: x, y: y, width: width, height: Self.lineHeight), source: source)
    }

    private func classify(_ hits: [VerificationEngine.OCRHit], _ regions: [RedactionRegion], _ terms: [SensitiveTerm]? = nil) -> VerificationEngine.PageOCRFinding {
        VerificationEngine.classifyPageOCR(hits: hits, pageRegions: regions, sensitiveTerms: terms ?? [term])
    }

    /// The first line's box applied: "The claimant is █████" / "Vance-Oduya and her counsel."
    private var firstLineBoxed: (hits: [VerificationEngine.OCRHit], regions: [RedactionRegion]) {
        ([hit("The claimant is", x: 0.10, width: 0.20, y: Self.upperY),
          hit("Vance-Oduya and her counsel.", x: 0.10, width: 0.35, y: Self.lowerY)],
         [box(x: 0.31, width: 0.12, y: Self.upperY)])
    }

    @Test("The term's last word opening the line below a box that ends the line above reads as a fragment, and the display names the term")
    func trailingWordsBelowABox() {
        let (hits, regions) = firstLineBoxed
        #expect(classify(hits, regions) == .sensitiveTermFragmentBesideRegion)
        #expect(VerificationEngine.fragmentTermTexts(hits: hits, pageRegions: regions, sensitiveTerms: [term]) == ["Marisol Vance-Oduya"])
    }

    @Test("The mirror: the term's first word ending the line above a box that opens the line below reads as a fragment")
    func leadingWordsAboveABox() {
        let hits = [hit("The claimant is Marisol", x: 0.10, width: 0.30, y: Self.upperY),
                    hit("and her counsel.", x: 0.27, width: 0.20, y: Self.lowerY)]
        let regions = [box(x: 0.10, width: 0.16, y: Self.lowerY)]
        #expect(classify(hits, regions) == .sensitiveTermFragmentBesideRegion)
        #expect(VerificationEngine.fragmentTermTexts(hits: hits, pageRegions: regions, sensitiveTerms: [term]) == ["Marisol Vance-Oduya"])
    }

    @Test("Every line of the match boxed: no fragment")
    func bothLinesBoxed() {
        let hits = [hit("The claimant is", x: 0.10, width: 0.20, y: Self.upperY),
                    hit("and her counsel.", x: 0.27, width: 0.20, y: Self.lowerY)]
        let regions = [box(x: 0.31, width: 0.12, y: Self.upperY), box(x: 0.10, width: 0.16, y: Self.lowerY)]
        #expect(classify(hits, regions) == .textOutsideRegionsOnly)
    }

    @Test("Not a fragment: a hand box, a box mid-line with words after it, a line two below, a residue that is not whole words of the term, a one-word term")
    func notAFragment() {
        let (hits, regions) = firstLineBoxed
        // A box drawn by hand vouches for no search.
        let manual = [box(x: 0.31, width: 0.12, y: Self.upperY, source: .manual)]
        #expect(classify(hits, manual) == .textOutsideRegionsOnly)
        // The box sits mid-line: the line above goes on past it, so the line below is not its continuation.
        let midLine = hits + [hit("today", x: 0.44, width: 0.08, y: Self.upperY)]
        #expect(classify(midLine, regions) == .textOutsideRegionsOnly)
        // Two lines below the box.
        let twoBelow = [hits[0], hit("Vance-Oduya and her counsel.", x: 0.10, width: 0.35, y: Self.upperY - 2.5 * Self.lineHeight)]
        #expect(classify(twoBelow, regions) == .textOutsideRegionsOnly)
        // The residue begins a longer word: "Andersonville" is not the term's word "Anderson".
        let ann = SensitiveTerm(text: "Ann Anderson")
        let longer = [hit("We met", x: 0.10, width: 0.20, y: Self.upperY),
                      hit("Andersonville is far.", x: 0.10, width: 0.30, y: Self.lowerY)]
        let annBox = [box(x: 0.31, width: 0.06, y: Self.upperY, source: .searchMatch(term: "Ann Anderson"))]
        #expect(classify(longer, annBox, [ann]) == .textOutsideRegionsOnly)
        // A one-word term has no words to wrap.
        let single = SensitiveTerm(text: "Marisol")
        let sol = [hit("The claimant is", x: 0.10, width: 0.20, y: Self.upperY),
                   hit("sol and her counsel.", x: 0.10, width: 0.30, y: Self.lowerY)]
        #expect(classify(sol, [box(x: 0.31, width: 0.12, y: Self.upperY, source: .searchMatch(term: "Marisol"))], [single]) == .textOutsideRegionsOnly)
    }
}
