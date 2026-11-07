import Testing
import Foundation
import CoreGraphics
@testable import RedactionEngine

// Frozen cases for the hidden-word check's pure predicate, written before the
// check. Each page is given as the words the check reads: the surviving
// words of the export's text layer, and the words recognized on a fresh
// render of the source page, with the boxes as the run held them (their
// pre-growth paint). Geometry is in points on a 612 × 792 page, converted to
// the normalized frame.
//
// The rules the cases pin:
// - each output line's drift from its print is fitted from its anchors
//   (surviving words away from every box, matched to a source word of the
//   same key; a repeated word matched by its order on the line): with no
//   anchor or one, the line cannot be placed; with exactly two, an offset
//   alone, used only when both anchors lie within a few points of it; with
//   three or more, an offset plus a scale along the line, used only when the
//   scale is within 0.5–2 and every anchor lies within a few points of the
//   fit. No anchor is dropped to make a fit;
// - a surviving word whose placed ink has its centre inside a box's paint is
//   flagged on that box, whatever its key (a fragment counts); one whose
//   placed ink only crosses a box's edge is an edge note;
// - a surviving word that could lie under a box but cannot be placed makes
//   the page not inspected; far from every box, it changes nothing;
// - findings, edge notes and an unplaceable word near a box can hold on the
//   same page.

@Suite("Hidden word check: the predicate (frozen cases)")
struct HiddenWordInkPredicateCases {

    static let size = CGSize(width: 612, height: 792)

    /// A word at x … x + width (points), baseline band y … y + h.
    static func w(_ key: String, _ x: CGFloat, _ width: CGFloat, y: CGFloat = 400, h: CGFloat = 14,
                  line: Int = 0) -> InkCaseWord {
        InkCaseWord(key: key, rect: CGRect(x: x / 612, y: y / 792, width: width / 612, height: h / 792), line: line)
    }

    static func box(_ x: CGFloat, _ width: CGFloat, y: CGFloat = 400, h: CGFloat = 14) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: CGRect(x: x / 612, y: y / 792, width: width / 612, height: h / 792),
                        source: .manual)
    }

    static func verdict(output: [InkCaseWord], source: [InkCaseWord], regions: [RedactionRegion],
                        kind: InkCasePageKind = .textOverImage) throws -> InkCaseVerdict {
        try #require(HiddenWordInkSeam.verdict(pageIndex: 0, output: output, sourceInk: source, regions: regions,
                                               pageSize: size, kind: kind),
                     "the check is not built")
    }

    // MARK: - Findings

    @Test("V1 (predicate): a fragment of the boxed name, drifted past the box, is flagged on the box, though no source word has its key")
    func fragmentIsAFinding() throws {
        let source = [Self.w("Contact", 72, 53), Self.w("Marisol", 129, 53), Self.w("Vance-Oduya", 186, 72),
                      Self.w("about", 262, 38), Self.w("the", 304, 22), Self.w("file", 330, 22), Self.w("today.", 356, 40)]
        // The layer drifted 30 pt; the export stripped the glyphs under the box and left "Co" and "uya".
        let output = [Self.w("Co", 102, 14), Self.w("uya", 266, 15), Self.w("about", 292, 38), Self.w("the", 334, 22),
                      Self.w("file", 360, 22), Self.w("today.", 386, 40)]
        let name = Self.box(124, 134)
        let v = try Self.verdict(output: output, source: source, regions: [name])
        #expect(v.findings.map(\.regionID) == [name.id])
        #expect(!v.unplaceableNearBox, "a word placed by the line's drift is decided by where it is, not by its key")
        if let mark = v.findings.first {
            #expect(mark.pageIndex == 0)
            #expect(abs(mark.inkRect.midX * 612 - 243.5) < 6, "the flagged box is the word's ink, not its hidden glyphs")
        }
    }

    @Test("V5: a word drifted under box B whose ink is under box A is flagged on A, never on B")
    func neighbourAttribution() throws {
        let source = [Self.w("Alpha", 72, 40), Self.w("by", 116, 20), Self.w("Charlie", 170, 50),
                      Self.w("Delta", 280, 40), Self.w("Echo", 330, 36), Self.w("Foxtrot", 372, 48)]
        // Drift +30; Charlie's hidden copy (200–250) survives, its centre inside B.
        let output = [Self.w("Alpha", 102, 40), Self.w("by", 146, 20), Self.w("Charlie", 200, 50),
                      Self.w("Delta", 310, 40), Self.w("Echo", 360, 36), Self.w("Foxtrot", 402, 48)]
        let a = Self.box(170, 50), b = Self.box(215, 25)
        let v = try Self.verdict(output: output, source: source, regions: [a, b])
        #expect(v.findings.map(\.regionID) == [a.id])
        #expect(!v.findings.contains { $0.regionID == b.id }, "the flag belongs to the box over the word's ink")
    }

    @Test("V5b: a word flagged on box A and an unplaceable word near box B both hold on one page")
    func findingAndNotInspectedTogether() throws {
        let source = [Self.w("Alpha", 72, 40), Self.w("by", 116, 20), Self.w("Charlie", 170, 50),
                      Self.w("Delta", 280, 40), Self.w("Echo", 330, 36), Self.w("Foxtrot", 372, 48),
                      Self.w("Approved:", 72, 68, y: 300, line: 1), Self.w("Okafor", 146, 50, y: 300, line: 1)]
        let output = [Self.w("Alpha", 102, 40), Self.w("by", 146, 20), Self.w("Charlie", 200, 50),
                      Self.w("Delta", 310, 40), Self.w("Echo", 360, 36), Self.w("Foxtrot", 402, 48),
                      Self.w("Approved:", 76, 68, y: 300, line: 1)]
        let a = Self.box(170, 50), b = Self.box(146, 50, y: 300)
        let v = try Self.verdict(output: output, source: source, regions: [a, b])
        #expect(v.findings.map(\.regionID) == [a.id])
        #expect(v.unplaceableNearBox, "box B's line has one anchor: its box is not inspected, flagged or not")
    }

    @Test("V19 (b): a word far along a heading whose layer sits at 0.6 scale, drifted past 36 pt, is flagged")
    func scaledLayerLeakFarAlong() throws {
        let (source, hidden) = Self.heading()
        let report = Self.box(332, 60, y: 400, h: 22)
        // The export missed "Notes"' hidden copy (228–264): it survives.
        let v = try Self.verdict(output: hidden, source: source, regions: [report])
        #expect(v.findings.map(\.regionID) == [report.id], "the drift grows along the line: an offset alone misses this word")
    }

    @Test("V20: a word repeated on its line, one copy under a box, is flagged once, on that box")
    func repeatedWord() throws {
        let source = [Self.w("the", 72, 20), Self.w("cat", 130, 23), Self.w("and", 190, 25), Self.w("the", 250, 20),
                      Self.w("dog", 310, 25)]
        let output = [Self.w("the", 97, 20), Self.w("cat", 155, 23), Self.w("and", 215, 25), Self.w("the", 275, 20),
                      Self.w("dog", 335, 25)]
        let second = Self.box(250, 20)
        let v = try Self.verdict(output: output, source: source, regions: [second])
        #expect(v.findings.map(\.regionID) == [second.id])
        if let mark = v.findings.first {
            #expect(abs(mark.inkRect.midX * 612 - 260) < 6, "the second \"the\", not the first")
        }
    }

    // MARK: - Not inspected

    @Test("V8: a surviving word beside a box, on a line with one anchor, leaves the page not inspected")
    func oneAnchorNearABox() throws {
        let source = [Self.w("Approved:", 72, 68), Self.w("Okafor", 146, 50)]
        let output = [Self.w("Approved:", 76, 68)]
        let v = try Self.verdict(output: output, source: source, regions: [Self.box(146, 50)])
        #expect(v.unplaceableNearBox)
        #expect(v.findings.isEmpty)
    }

    @Test("V9: anchors whose offsets disagree by 40 pt, beside a box, leave the page not inspected")
    func anchorsSpreadPastTheBound() throws {
        let source = [Self.w("alpha", 72, 40), Self.w("bravo", 160, 40), Self.w("charlie", 248, 40),
                      Self.w("delta", 300, 40)]
        let output = [Self.w("alpha", 72, 40), Self.w("bravo", 200, 40), Self.w("charlie", 248, 40)]
        let v = try Self.verdict(output: output, source: source, regions: [Self.box(300, 40)])
        #expect(v.unplaceableNearBox)
        #expect(v.findings.isEmpty)
    }

    @Test("V18: anchors that disagree by 12 pt, past the residual slack and within 36 pt, beside a box, leave the page not inspected")
    func anchorsDisagreePastTheSlack() throws {
        let source = [Self.w("alpha", 72, 40), Self.w("bravo", 160, 40), Self.w("charlie", 248, 40),
                      Self.w("delta", 330, 40)]
        let output = [Self.w("alpha", 102, 40), Self.w("bravo", 202, 40), Self.w("charlie", 278, 40)]
        let v = try Self.verdict(output: output, source: source, regions: [Self.box(330, 40)])
        #expect(v.unplaceableNearBox, "agreement is judged by the residual slack, never by the 36 pt drift bound")
    }

    @Test("V18b: exactly two anchors whose offsets are 30 and 42 pt, a kept word beside a box, leave the page not inspected")
    func twoAnchorsDisagree() throws {
        let source = [Self.w("alpha", 72, 40), Self.w("bravo", 240, 40), Self.w("delta", 330, 40)]
        let output = [Self.w("alpha", 102, 40), Self.w("bravo", 282, 40)]
        let v = try Self.verdict(output: output, source: source, regions: [Self.box(330, 40)])
        #expect(v.unplaceableNearBox, "two anchors are fitted by an offset alone; a free scale would fit any pair exactly")
        #expect(v.findings.isEmpty)
    }

    @Test("V23: on an upright page (axis .right), a line whose words run down, across the axis, beside a box is not inspected: never flagged, never clean")
    func lineAcrossTheAxis() throws {
        // V22's /Rotate 90 line on an upright 612 × 792 page: 7 pt glyphs stepping down from y 560 in a band at
        // x 400–414, one line id, each word given as its hidden glyphs' box. "alpha bravo the delta echo" puts
        // alpha at y 525–560, bravo 483–518, the 455–476, delta 413–448, echo 378–406. The print is 30 pt up.
        let words: [(String, CGFloat, CGFloat)] = [("alpha", 525, 35), ("bravo", 483, 35), ("the", 455, 21),
                                                    ("delta", 413, 35), ("echo", 378, 28)]
        let output = words.map { Self.w($0.0, 400, 14, y: $0.1, h: $0.2) }
        let source = words.map { Self.w($0.0, 400, 14, y: $0.1 + 30, h: $0.2) }
        // The box over the print of "the": x 400–414, y 485–506.
        let the = Self.box(400, 14, y: 485, h: 21)
        // The axis is the rotation's (.right), and the words' centres spread 0 pt along it and 150.5 pt across it,
        // so the line is not placed. The hidden "the" lies 9 pt from the box, within the across reach of 1.5
        // median word heights (52.5 pt). Read along the line's own spread instead, alpha, delta and echo fit +30
        // at scale 1 and "the" maps onto the box.
        let v = try Self.verdict(output: output, source: source, regions: [the])
        #expect(v.unplaceableNearBox, "a line that runs across the page's axis is not placed")
        #expect(v.findings.isEmpty, "the axis comes from the rotation, never from the line's spread")
        #expect(v != InkCaseVerdict())
    }

    @Test("V18c: exactly two anchors that agree (30 and 31 pt) place the line: a fragment mapped inside a box is flagged")
    func twoAnchorsAgree() throws {
        let source = [Self.w("alpha", 72, 40), Self.w("bravo", 160, 40), Self.w("charlie", 250, 40)]
        let output = [Self.w("alpha", 102, 40), Self.w("bravo", 191, 40), Self.w("rlie", 300, 20)]
        let b = Self.box(250, 40)
        let v = try Self.verdict(output: output, source: source, regions: [b])
        #expect(v.findings.map(\.regionID) == [b.id], "two agreeing anchors are enough to place a line")
        #expect(!v.unplaceableNearBox)
    }

    // MARK: - Accepted (nothing flagged)

    @Test("V16: a kept neighbour whose ink crosses a box's edge, its centre outside, is an edge note, not flagged")
    func edgeNote() throws {
        let source = [Self.w("one", 72, 40), Self.w("two", 120, 40), Self.w("three", 168, 32), Self.w("four", 205, 40),
                      Self.w("five", 255, 40)]
        let output = [Self.w("one", 75, 40), Self.w("two", 123, 40), Self.w("four", 208, 40), Self.w("five", 258, 40)]
        let b = Self.box(168, 42)
        let v = try Self.verdict(output: output, source: source, regions: [b])
        #expect(v.findings.isEmpty)
        #expect(v.edgeNotes.map(\.regionID) == [b.id])
        #expect(!v.unplaceableNearBox)
    }

    @Test("V17: a line with one anchor, far from every box, changes nothing: the page is clean")
    func oneAnchorFarFromEveryBox() throws {
        let source = [Self.w("one", 72, 40), Self.w("two", 120, 40), Self.w("three", 168, 32), Self.w("four", 205, 40),
                      Self.w("five", 255, 40), Self.w("Approved:", 72, 68, y: 300, line: 1)]
        let output = [Self.w("one", 75, 40), Self.w("two", 123, 40), Self.w("four", 208, 40), Self.w("five", 258, 40),
                      Self.w("Approved:", 76, 68, y: 300, line: 1)]
        let v = try Self.verdict(output: output, source: source, regions: [Self.box(168, 32)])
        #expect(v == InkCaseVerdict())
    }

    @Test("V19 (a): a kept neighbour at the end of a heading whose layer sits at 0.6 scale, beside a box, is not flagged")
    func scaledLayerKeptNeighbour() throws {
        let (source, hidden) = Self.heading()
        let review = Self.box(267, 60, y: 400, h: 22)
        // A correct export: the boxed word's hidden copy (189–225) is gone; "Notes" (228–264) is kept.
        let output = hidden.filter { $0.key != "Report" }
        let v = try Self.verdict(output: output, source: source, regions: [review])
        #expect(v.findings.isEmpty, "one offset for the line would put the kept last word inside the box")
        #expect(!v.unplaceableNearBox)
    }

    @Test("V20b: a word repeated 24 pt apart on a line drifted 25 pt, both copies kept, is placed: nothing flagged, nothing unplaceable")
    func closeRepeatedWord() throws {
        let source = [Self.w("one", 72, 28), Self.w("the", 110, 20), Self.w("the", 134, 20), Self.w("two", 170, 28),
                      Self.w("three", 230, 32), Self.w("four", 300, 30), Self.w("five", 360, 30)]
        let output = [Self.w("one", 97, 28), Self.w("the", 135, 20), Self.w("the", 159, 20), Self.w("two", 195, 28),
                      Self.w("three", 255, 32), Self.w("four", 325, 30)]
        let v = try Self.verdict(output: output, source: source, regions: [Self.box(360, 30)])
        #expect(!v.unplaceableNearBox, "repeats are matched by their order on the line, never by the nearest copy")
        #expect(v.findings.isEmpty)
    }

    // MARK: - Not applicable

    @Test("an empty output page, a plain source page and a page with no boxes are not applicable, each with its reason")
    func notApplicableReasons() throws {
        let source = [Self.w("one", 72, 40), Self.w("two", 120, 40), Self.w("three", 168, 32)]
        let output = [Self.w("one", 75, 40), Self.w("two", 123, 40)]
        let b = Self.box(168, 32)
        #expect(try Self.verdict(output: [], source: source, regions: [b]).notApplicable == .noText)
        #expect(try Self.verdict(output: output, source: source, regions: [b], kind: .plain).notApplicable == .plainSource)
        #expect(try Self.verdict(output: output, source: source, regions: []).notApplicable == .noRegions)
    }

    // MARK: - The heading

    /// An 18 pt heading of five words, its layer at 0.6 scale from the line's
    /// start (the offset grows from −12 to −116 pt along the line): the
    /// source's words and the layer's words.
    static func heading() -> (source: [InkCaseWord], hidden: [InkCaseWord]) {
        let words: [(String, CGFloat)] = [("Quarterly", 72), ("Review", 137), ("Summary", 202), ("Report", 267), ("Notes", 332)]
        let source = words.map { Self.w($0.0, $0.1, 60, h: 22) }
        let hidden = words.map { Self.w($0.0, 72 + 0.6 * ($0.1 - 72), 36, h: 22) }
        return (source, hidden)
    }
}
