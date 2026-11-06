import Testing
import Foundation
import CoreGraphics
@testable import RedactionEngine

// The ink strip plan, as a pure function of the boxes and the candidate hidden
// words: a box strips every hidden word whose printed ink it covers, wherever
// the word's hidden glyphs sit; a word on the box's line whose print could not
// be placed with confidence, or at all, leaves the page unsure (it is written
// as an image only); the plan covers a page only for the boxes it was made for.

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
    /// `sure: false` is a fit placed without confidence and `fitted: false` no
    /// fit: either way the planner has no ink for the word.
    static func word(_ location: Int, x: CGFloat, width: CGFloat, y: CGFloat = 400, drift: CGFloat = 30,
                     sure: Bool = true, fitted: Bool = true) -> HiddenWordInk {
        let hidden = n(x + drift, y, width, 14)
        return HiddenWordInk(range: NSRange(location: location, length: 4), strip: [hidden],
                             ink: sure && fitted ? [n(x, y, width, 14)] : nil)
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

    @Test("a word on the box's line whose print could not be placed with confidence leaves the page unsure")
    func uncertainWordUnderTheBox() {
        let b = Self.box(Self.n(124, 400, 135, 14))
        let p = Self.plan([b], [Self.word(0, x: 72, width: 48), Self.word(10, x: 124, width: 135, sure: false)])
        #expect(p.unsure)
        #expect(!p.covers([b]))
        #expect((p.words[b.id] ?? []).isEmpty, "a word not placed with confidence is not captured")
    }

    @Test("an uncertain word far along the box's line leaves the page unsure too: drift along a line has no bound")
    func uncertainWordAlongTheLine() {
        let b = Self.box(Self.n(124, 400, 40, 14))
        let p = Self.plan([b], [Self.word(10, x: 400, width: 40, sure: false)])
        #expect(p.unsure)
        #expect(!p.covers([b]))
    }

    @Test("an uncertain word on another line, beyond the band across the line, changes nothing")
    func uncertainWordFarAway() {
        let b = Self.box(Self.n(124, 400, 135, 14))
        let p = Self.plan([b], [Self.word(50, x: 124, width: 135, y: 300, sure: false)])
        #expect(!p.unsure)
        #expect(p.covers([b]))
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

    // MARK: - Line direction

    static func tile(_ length: Int, w: CGFloat, h: CGFloat) -> (length: Int, box: CGRect) {
        (length, Self.n(100, 100, w, h))
    }

    @Test("a page's lines run across it when most longer words are wider than tall; a short tall word says nothing")
    func linesRunAcrossWithShortWords() {
        let words = [Self.tile(7, w: 50, h: 16), Self.tile(6, w: 44, h: 16), Self.tile(2, w: 11, h: 16),
                     Self.tile(2, w: 11, h: 16), Self.tile(2, w: 11, h: 16), Self.tile(5, w: 40, h: 16)]
        #expect(DocumentSearcher.linesRunAcross(words, pageSize: Self.size))
    }

    @Test("a page set down the page reads as vertical lines; one tall longer word on a horizontal page does not")
    func verticalPageAndStrayTallWord() {
        let down = [Self.tile(6, w: 16, h: 44), Self.tile(5, w: 16, h: 40), Self.tile(7, w: 16, h: 52)]
        #expect(!DocumentSearcher.linesRunAcross(down, pageSize: Self.size))
        let mostlyAcross = [Self.tile(6, w: 44, h: 16), Self.tile(5, w: 40, h: 16), Self.tile(4, w: 14, h: 30)]
        #expect(DocumentSearcher.linesRunAcross(mostlyAcross, pageSize: Self.size))
    }

    @Test("on a page whose lines run down it, a word in the box's column is a candidate")
    func verticalLine() {
        let tall = HiddenWordInk(range: NSRange(location: 0, length: 4), strip: [Self.n(300, 430, 14, 60)],
                                 ink: [Self.n(300, 400, 14, 60)])
        let b = Self.box(Self.n(300, 400, 14, 60))
        #expect(DocumentSearcher.inkStripPlan(regions: [b], words: [tall], pageSize: Self.size, horizontalLines: false)
            .strips[b.id] == tall.strip)
    }
}
