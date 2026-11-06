import Testing
import Foundation
import CoreGraphics
@testable import RedactionEngine

// The ink strip plan, as a pure function of the boxes and the candidate hidden
// words: a box strips every hidden word whose printed ink it covers, wherever
// the word's hidden glyphs sit; a word whose print could not be placed with
// confidence is stripped when its drift envelope meets the box, and not named;
// a word with no fit at all leaves the page unsure (it is written as an image
// only); the plan covers a page only for the boxes it was made for.

@Suite("Ink strip plan")
struct InkStripPlanTests {

    static let size = CGSize(width: 612, height: 792)
    /// Points to page-normalized, bottom-left origin.
    static func n(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x / 612, y: y / 792, width: w / 612, height: h / 792)
    }
    static func box(_ rect: CGRect, _ source: RedactionRegion.Source = .manual) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: rect, source: source)
    }
    /// A word printed at `x`, its hidden glyphs drifted `drift` points along the line.
    /// `sure: false` gives the fit's envelope instead of the ink: 36 pt along the
    /// line and 21 pt across around the hidden glyphs; `fitted: false` gives no fit.
    static func word(_ location: Int, x: CGFloat, width: CGFloat, y: CGFloat = 400, drift: CGFloat = 30,
                     sure: Bool = true, fitted: Bool = true) -> HiddenWordInk {
        let hidden = n(x + drift, y, width, 14)
        return HiddenWordInk(range: NSRange(location: location, length: 4), strip: [hidden],
                             ink: sure && fitted ? [n(x, y, width, 14)] : nil,
                             envelope: !sure && fitted ? [n(x + drift - 36, y - 21, width + 72, 56)] : nil)
    }
    static func plan(_ regions: [RedactionRegion], _ words: [HiddenWordInk]) -> InkStripPlan {
        DocumentSearcher.inkStripPlan(regions: regions, words: words, pageSize: size)
    }

    @Test("a box over a word's print strips its hidden copy, wherever it drifted")
    func stripsDriftedCopy() {
        let name = Self.word(10, x: 124, width: 135)
        let neighbour = Self.word(0, x: 72, width: 48)
        let b = Self.box(Self.n(124, 400, 135, 14))
        let p = Self.plan([b], [neighbour, name])
        #expect(p.strips[b.id] == name.strip, "the name's hidden copy, not the neighbour's that drifted under the box")
        #expect(p.words[b.id] == [name.range])
        #expect(!p.unsure)
    }

    @Test("a short word whose whole copy lies past the box and its margin is stripped")
    func shortWordPastTheBox() {
        let lee = Self.word(20, x: 138, width: 23)
        let b = Self.box(Self.n(138, 400, 23, 14))
        #expect(Self.plan([b], [lee]).strips[b.id] == lee.strip)
    }

    @Test("a box widened over a second word strips both words' copies, whatever the box's source")
    func widenedBoxStripsBoth() {
        let signed = Self.word(0, x: 72, width: 44), by = Self.word(7, x: 120, width: 15), lee = Self.word(10, x: 139, width: 23)
        let b = Self.box(Self.n(72, 400, 90, 14), .searchMatch(term: "signed"))
        let p = Self.plan([b], [signed, by, lee])
        #expect(p.words[b.id] == [signed.range, by.range, lee.range])
    }

    @Test("a Duplicate moved onto other text and a box from the page's picture strip by ink too")
    func anyRegionStripsByInk() {
        let w = Self.word(30, x: 300, width: 60)
        for source: RedactionRegion.Source in [.manual, .searchMatch(term: "x"), .detectedFace] {
            let b = Self.box(Self.n(300, 400, 60, 14), source)
            #expect(Self.plan([b], [w]).strips[b.id] == w.strip, "\(source)")
        }
    }

    @Test("a word whose print could not be placed is stripped when its envelope meets the box, and not named")
    func uncertainWordStrippedByEnvelope() {
        let b = Self.box(Self.n(124, 400, 135, 14))
        let unsure = Self.word(10, x: 124, width: 135, sure: false)
        let p = Self.plan([b], [unsure])
        #expect(p.strips[b.id] == unsure.strip)
        #expect((p.words[b.id] ?? []).isEmpty, "a word not placed with confidence is not captured")
        #expect(!p.unsure)
        #expect(p.covers([b]))
    }

    @Test("a word whose print could not be placed and whose envelope misses the box is left")
    func uncertainWordAwayFromTheBox() {
        let b = Self.box(Self.n(124, 400, 40, 14))
        let along = Self.word(10, x: 400, width: 40, sure: false)
        let p = Self.plan([b], [along])
        #expect(p.strips[b.id] == nil)
        #expect(!p.unsure)
    }

    @Test("a candidate word with no fit at all leaves the page unsure")
    func unfittedWordNearTheBox() {
        let b = Self.box(Self.n(124, 400, 135, 14))
        let p = Self.plan([b], [Self.word(10, x: 124, width: 135, fitted: false)])
        #expect(p.unsure)
        #expect(!p.covers([b]))
    }

    @Test("a word with no fit on another line, beyond the band across the line, changes nothing")
    func unfittedWordFarAway() {
        let b = Self.box(Self.n(124, 400, 135, 14))
        let p = Self.plan([b], [Self.word(50, x: 124, width: 135, y: 300, fitted: false)])
        #expect(!p.unsure)
        #expect(p.covers([b]))
    }

    @Test("ink that only touches the box's edge with no area is not stripped; the box is the pre-growth paint")
    func edgeTouchIsNotStripped() {
        let touching = Self.word(40, x: 259, width: 30)
        let b = Self.box(Self.n(124, 400, 135, 14))
        #expect(Self.plan([b], [touching]).strips[b.id] == nil)
    }

    @Test("a box over no word strips nothing and keeps the page")
    func boxOverNoWord() {
        let b = Self.box(Self.n(400, 100, 50, 14))
        let p = Self.plan([b], [Self.word(0, x: 72, width: 48)])
        #expect(p.strips.isEmpty)
        #expect(p.covers([b]))
    }

    @Test("the plan covers only the boxes it was made for, with the paint it was made for")
    func coversOnlyPlannedBoxes() {
        let b = Self.box(Self.n(124, 400, 135, 14))
        let p = Self.plan([b], [Self.word(10, x: 124, width: 135)])
        #expect(p.covers([b]))
        var moved = b
        moved.normalizedRect = Self.n(130, 400, 135, 14)
        #expect(!p.covers([moved]), "a box moved after the plan")
        #expect(!p.covers([b, Self.box(Self.n(300, 300, 40, 14))]), "a box drawn after the plan")
        #expect(p.covers([b, Self.box(CGRect(x: 0, y: 0, width: 1, height: 1))]), "a whole-page box needs no plan")
    }

}
