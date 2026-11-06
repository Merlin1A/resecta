import Testing
import Foundation
import CoreGraphics
@testable import RedactionEngine

// Frozen cases for the hidden-word check's alignment step, written before the
// step. The export redraws its text layer on its own grid, so a surviving
// export word does not sit on the hidden glyphs it came from. The step locates
// those glyphs on the source page (its own text layer, read through PDFKit)
// and hands the predicate each surviving word or fragment at its source
// glyphs' box; the predicate then fits the hidden layer to the print as before.
//
// The rules the cases pin:
// - matching: each export line's characters, whitespace ignored, are an
//   ordered subsequence of one source line's glyphs; a word's characters
//   match consecutive glyphs of that line (a fragment matches its own
//   glyphs), and the line's words keep their order;
// - the window: a candidate's first glyph must sit within 1.5 × the export
//   word's own cell (its width ÷ its character count) + 3.5 pt of the word's
//   leading edge, along the axis; across, it must lie on a source line whose
//   band overlaps the word's band. A unique match outside the window is
//   unaligned, not accepted;
// - a word with two candidates that the order cannot decide between, or with
//   none, is unaligned (nil); text missing from the source is unaligned;
// - an unaligned word gives the page `unplaceableNearBox` if either reach
//   meets any box's paint: its window mapped through its line's accepted fit,
//   or the generic reach (its export box widened by its window, then 36 pt +
//   0.45 pt per pt from the farther line end along the line, and max(10 pt,
//   1.5 line heights) across). The union only adds "not inspected".
//   Otherwise it changes nothing;
// - the axis is the page's rotation's; each line's spread only cross-checks
//   it. A line whose spread disagrees with the axis, or has no clear axis, is
//   unplaceable;
// - `HiddenWordInkSeam.verdict` keeps its meaning, with the axis `.right`.
//
// Geometry is in points on a 612 × 792 page (V22: the turned page's visual
// frame, 792 × 612 for /Rotate 90 and 270, 612 × 792 for 180), converted to
// the normalized frame. A source line is one glyph per
// character, spaces included, `advance` apart.
//
// Mutants these cases are written to kill (run against the built step):
// - align by nearest position instead of by order: (c), (d);
// - an unaligned word read as absent: (d′), (e′); (e″) guards the other way;
// - no window, any ordered match accepted: (a′);
// - the generic reach alone, no fit-mapped window: (e‴);
// - the axis taken from the line's spread alone: V22's `.right` half.

@Suite("Hidden word check: the alignment step (frozen cases)")
struct HiddenWordInkAlignCases {

    static let size = CGSize(width: 612, height: 792)

    static func normalized(_ r: CGRect, _ size: CGSize = size) -> CGRect {
        CGRect(x: r.minX / size.width, y: r.minY / size.height, width: r.width / size.width, height: r.height / size.height)
    }

    /// A source line drawn left to right: one glyph per character, spaces included.
    static func glyphs(_ text: String, _ x0: CGFloat, _ advance: CGFloat, y: CGFloat = 400, h: CGFloat = 14,
                       line: Int = 0) -> [InkCaseGlyph] {
        text.enumerated().map { i, c in
            InkCaseGlyph(char: c, rect: normalized(CGRect(x: x0 + CGFloat(i) * advance, y: y, width: advance, height: h)),
                         line: line)
        }
    }

    /// The source line's printed words, where its glyphs are (the layer on the ink).
    static func printWords(_ line: [InkCaseGlyph], _ size: CGSize = size, shift: CGVector = .zero) -> [InkCaseWord] {
        var words: [InkCaseWord] = [], key = "", rect = CGRect.null
        func flush() {
            if !key.isEmpty, let first = line.first {
                let p = CGRect(x: rect.minX * size.width + shift.dx, y: rect.minY * size.height + shift.dy,
                               width: rect.width * size.width, height: rect.height * size.height)
                words.append(InkCaseWord(key: key, rect: normalized(p, size), line: first.line))
            }
            key = ""; rect = .null
        }
        for g in line {
            if g.char == " " { flush() } else { key.append(g.char); rect = rect.union(g.rect) }
        }
        flush()
        return words
    }

    /// An export word at x … x + count × cell (points), band y … y + h.
    static func ew(_ key: String, _ x: CGFloat, cell: CGFloat, y: CGFloat = 400, h: CGFloat = 14,
                   line: Int = 0) -> InkCaseWord {
        InkCaseWord(key: key, rect: normalized(CGRect(x: x, y: y, width: CGFloat(key.count) * cell, height: h)), line: line)
    }

    /// The export of a source line drawn on a grid of `cell`: each word 2 pt along from its glyphs, `dropping` stripped.
    static func export(of line: [InkCaseGlyph], cell: CGFloat = 6, dropping: Set<String> = []) -> [InkCaseWord] {
        printWords(line).filter { !dropping.contains($0.key) }.map {
            ew($0.key, $0.rect.minX * size.width + 2, cell: cell, y: $0.rect.minY * size.height,
               h: $0.rect.height * size.height, line: $0.line)
        }
    }

    static func box(_ x: CGFloat, _ width: CGFloat, y: CGFloat = 400, h: CGFloat = 14) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: normalized(CGRect(x: x, y: y, width: width, height: h)), source: .manual)
    }

    static func align(_ words: [InkCaseWord], _ glyphs: [InkCaseGlyph]) throws -> [CGRect?] {
        let result = try #require(HiddenWordInkSeam.align(words: words, glyphs: glyphs, pageSize: size, axis: .right),
                                  "the check is not built")
        #expect(result.count == words.count, "one entry per export word")
        return result
    }

    /// `r` is the box x0 … x1 on the line's band (y 400, 14 pt), within half a point.
    static func expectBox(_ r: CGRect?, _ x0: CGFloat, _ x1: CGFloat, _ comment: Comment,
                          y: CGFloat = 400, h: CGFloat = 14) {
        guard let r else { Issue.record("\(comment): unaligned, expected x \(x0)–\(x1)"); return }
        let p = CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width,
                       height: r.height * size.height)
        #expect(abs(p.minX - x0) <= 0.5 && abs(p.maxX - x1) <= 0.5, "\(comment): x \(p.minX)–\(p.maxX), expected \(x0)–\(x1)")
        #expect(abs(p.minY - y) <= 0.5 && abs(p.maxY - (y + h)) <= 0.5, "\(comment): y \(p.minY)–\(p.maxY)")
    }

    // MARK: - The step alone

    @Test("(a): a whole word drawn off the grid, within its window, aligns to its own glyphs")
    func wholeWord() throws {
        // "bravo" is glyphs 6–10, x 142–177; the export word starts 9 pt along (cell 6, window 12.5).
        let r = try Self.align([Self.ew("bravo", 151, cell: 6)], Self.glyphs("alpha bravo charlie", 100, 7))
        Self.expectBox(r.first ?? nil, 142, 177, "bravo")
    }

    @Test("(a′): the same word drawn 18 pt along (3 cells), past its window, is unaligned")
    func pastTheWindow() throws {
        let r = try Self.align([Self.ew("bravo", 160, cell: 6)], Self.glyphs("alpha bravo charlie", 100, 7))
        #expect(r == [nil], "a unique match outside the window is unaligned, not accepted")
    }

    @Test("(b): a fragment of a word aligns to its own glyphs")
    func fragment() throws {
        // "uya" is glyphs 24–26 of the line, x 268–289.
        let r = try Self.align([Self.ew("uya", 270, cell: 6)], Self.glyphs("Contact Marisol Vance-Oduya about", 100, 7))
        Self.expectBox(r.first ?? nil, 268, 289, "uya")
    }

    @Test("(c): both copies of a repeat survive: the order pairs them, never the nearest copy")
    func repeatByOrder() throws {
        // "the" #1 is x 115–130, #2 is 135–150. The first export "the" (cell 5, window 11) starts 10.5 pt from #1
        // and 9.5 pt from #2: both in its window, the nearer is #2, the order gives #1.
        let words = [Self.ew("to", 100, cell: 5), Self.ew("the", 125.5, cell: 5), Self.ew("the", 141, cell: 5),
                     Self.ew("end", 155, cell: 5)]
        let r = try Self.align(words, Self.glyphs("to the the end", 100, 5))
        guard r.count == 4 else { return }
        Self.expectBox(r[0], 100, 110, "to")
        Self.expectBox(r[1], 115, 130, "the first \"the\"")
        Self.expectBox(r[2], 135, 150, "the second \"the\"")
        Self.expectBox(r[3], 155, 170, "end")
    }

    @Test("(d): one copy of a repeat stripped, both copies inside the survivor's window: the survivor is unaligned")
    func repeatAmbiguous() throws {
        // The export "the" (cell 6, window 12.5) starts 9 pt from #1 and 11 pt from #2; either makes "to the end" a
        // subsequence of the line, so the order cannot decide.
        let words = [Self.ew("to", 100, cell: 6), Self.ew("the", 124, cell: 6), Self.ew("end", 155, cell: 6)]
        let r = try Self.align(words, Self.glyphs("to the the end", 100, 5))
        guard r.count == 3 else { return }
        Self.expectBox(r[0], 100, 110, "to")
        #expect(r[1] == nil, "two candidates the order cannot decide between: unaligned")
        Self.expectBox(r[2], 155, 170, "end")
    }

    @Test("(e): export text missing from the source is unaligned")
    func missingFromTheSource() throws {
        let r = try Self.align([Self.ew("zzz", 142, cell: 6)], Self.glyphs("alpha bravo charlie", 100, 7))
        #expect(r == [nil])
    }

    // MARK: - Through the page's verdict

    /// Three lines the export kept whole and the fit places (four anchors each, the layer on the ink).
    static func placedLines() -> [[InkCaseGlyph]] {
        [Self.glyphs("one two three four", 100, 7, y: 600, line: 10),
         Self.glyphs("five six seven eight", 100, 7, y: 570, line: 11),
         Self.glyphs("nine ten eleven twelve", 100, 7, y: 540, line: 12)]
    }

    static func pageVerdict(export: [InkCaseWord], lines: [[InkCaseGlyph]], regions: [RedactionRegion],
                            size: CGSize = size, axis: InkCaseAxis = .right,
                            sourceInk: [InkCaseWord]? = nil) throws -> InkCaseVerdict {
        try #require(HiddenWordInkSeam.pageVerdict(pageIndex: 0, exportWords: export, glyphs: lines.flatMap { $0 },
                                                   sourceInk: sourceInk ?? lines.flatMap { printWords($0) },
                                                   regions: regions, pageSize: size, kind: .textOverImage, axis: axis),
                     "the check is not built")
    }

    @Test("(d′): an unaligned repeat with a box 20 pt along from its start leaves the page not inspected")
    func ambiguousNearABox() throws {
        // (d)'s line, carried on so the fit has anchors well away from the box ("our", "long", "notes").
        let line = Self.glyphs("to the the end and all our long notes", 100, 5)
        let export = [Self.ew("to", 100, cell: 6), Self.ew("the", 124, cell: 6), Self.ew("end", 155, cell: 6),
                      Self.ew("and", 177, cell: 6), Self.ew("all", 197, cell: 6), Self.ew("our", 217, cell: 6),
                      Self.ew("long", 237, cell: 6), Self.ew("notes", 262, cell: 6)]
        let placed = Self.placedLines()
        // The box's paint is x 144–154: over the tail of the second copy's print, clear of "end" (155–170).
        let v = try Self.pageVerdict(export: placed.flatMap { Self.export(of: $0) } + export, lines: placed + [line],
                                     regions: [Self.box(144, 10)])
        #expect(v.unplaceableNearBox, "a word that could lie under the box and cannot be aligned is not inspected")
        #expect(v.findings.isEmpty)
    }

    @Test("(e′): export text missing from the source, 8 pt from a box, leaves the page not inspected")
    func missingNearABox() throws {
        let placed = Self.placedLines()
        let line = Self.glyphs("alpha bravo charlie", 100, 7, y: 500)
        let v = try Self.pageVerdict(export: placed.flatMap { Self.export(of: $0) } + [Self.ew("zzz", 250, cell: 6, y: 500)],
                                     lines: placed + [line], regions: [Self.box(276, 30, y: 500)])
        #expect(v.unplaceableNearBox, "an unaligned word is never read as absent")
        #expect(v.findings.isEmpty)
    }

    @Test("(e″): export text missing from the source, 120 pt along from every box and 100 pt across, changes nothing")
    func missingFarFromEveryBox() throws {
        let placed = Self.placedLines()
        let line = Self.glyphs("alpha bravo charlie", 100, 7, y: 500)
        // The box is over "four" (x 198–226 on the line at y 600), which the export stripped.
        let export = Self.export(of: placed[0], dropping: ["four"]) + Self.export(of: placed[1]) + Self.export(of: placed[2])
            + [Self.ew("zzz", 346, cell: 6, y: 500)]
        let v = try Self.pageVerdict(export: export, lines: placed + [line], regions: [Self.box(198, 28, y: 600)])
        #expect(v == InkCaseVerdict(), "an unaligned word far from every box leaves the page clean")
    }

    static let wide = CGSize(width: 792, height: 612)

    @Test("(e‴): export text missing from the source, near a box only through its line's fit, leaves the page not inspected")
    func missingNearABoxByTheFit() throws {
        // A landscape page (792 × 612), so the line is long enough for the fit to carry a word past the generic reach.
        // The hidden layer is set at 1/1.6 of its print from x 20: the line's fit is print = 20 + 1.6 × (hidden − 20),
        // scale 1.6, residual 0 on nine anchors.
        let line = "alpha bravo charlie delta echo foxtrot golf hotel india".enumerated().map { i, c in
            InkCaseGlyph(char: c, rect: Self.normalized(CGRect(x: 20 + 7 * CGFloat(i), y: 400, width: 7, height: 14), Self.wide),
                         line: 0)
        }
        func points(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * Self.wide.width, y: r.minY * Self.wide.height,
                   width: r.width * Self.wide.width, height: r.height * Self.wide.height)
        }
        let hidden = Self.printWords(line, Self.wide)
        let print = hidden.map { w -> InkCaseWord in
            let p = points(w.rect)
            return InkCaseWord(key: w.key, rect: Self.normalized(CGRect(x: 20 + 1.6 * (p.minX - 20), y: p.minY,
                                                                        width: 1.6 * p.width, height: p.height), Self.wide),
                               line: 0)
        }
        let kept = hidden.map { w -> InkCaseWord in
            let p = points(w.rect)
            return InkCaseWord(key: w.key, rect: Self.normalized(CGRect(x: p.minX + 2, y: 400, width: CGFloat(w.key.count) * 6,
                                                                        height: 14), Self.wide), line: 0)
        }
        // "zzz" at x 450–468 (cell 6, window 12.5), after "india" (hidden 370–405, print 580–636).
        let zzz = InkCaseWord(key: "zzz", rect: Self.normalized(CGRect(x: 450, y: 400, width: 18, height: 14), Self.wide), line: 0)
        // (i) Through the fit, its box maps to 708–736.8 and its window (437.5–480.5) to 688–756.8: either meets the
        //     paint at 728–746.
        // (ii) The generic reach ends at 468 + 12.5 + 36 + 0.45 × 448 = 718.1 along (d = 448, from its far edge to the
        //      line's start at x 20, the largest reading of d), short of 728. Across, the box is on the word's band.
        let box = RedactionRegion(id: UUID(), normalizedRect: Self.normalized(CGRect(x: 728, y: 400, width: 18, height: 14),
                                                                              Self.wide), source: .manual)
        let v = try Self.pageVerdict(export: kept + [zzz], lines: [line], regions: [box], size: Self.wide, sourceInk: print)
        #expect(v.unplaceableNearBox, "an unaligned word whose fitted window meets a box is not inspected, past the generic reach")
        #expect(v.findings.isEmpty)
    }

    // MARK: - The axis

    /// A page turned so its lines advance along `axis` (/Rotate 90: down, 180: left, 270: up), in its visual frame.
    /// One line of 7 pt glyphs in a 14 pt band at 400–414 across; five spaces before "the" keep the glyphs under its
    /// print box blank.
    struct Turned {
        let axis: InkCaseAxis
        static let text = "alpha bravo     the delta echo foxtrot golf hotel"

        var size: CGSize { axis == .left ? CGSize(width: 612, height: 792) : CGSize(width: 792, height: 612) }

        /// Glyph `i`'s box (points): down from y 560, left from x 560, up from y 50.
        func slot(_ i: Int) -> CGRect {
            let k = CGFloat(i)
            switch axis {
            case .left: return CGRect(x: 560 - 7 * (k + 1), y: 400, width: 7, height: 14)
            case .up: return CGRect(x: 400, y: 50 + 7 * k, width: 14, height: 7)
            default: return CGRect(x: 400, y: 560 - 7 * (k + 1), width: 14, height: 7)
            }
        }

        /// One step along the axis, as a vector in points.
        var along: CGVector {
            switch axis {
            case .left: return CGVector(dx: -1, dy: 0)
            case .up: return CGVector(dx: 0, dy: 1)
            case .right: return CGVector(dx: 1, dy: 0)
            case .down: return CGVector(dx: 0, dy: -1)
            }
        }

        var glyphs: [InkCaseGlyph] {
            Self.text.enumerated().map { i, c in
                InkCaseGlyph(char: c, rect: HiddenWordInkAlignCases.normalized(slot(i), size), line: 0)
            }
        }

        /// An export word 2 pt along from its glyphs' leading edge, 6 pt a character, in a 12 pt band at 401–413.
        func exportWord(_ w: InkCaseWord) -> InkCaseWord {
            let r = CGRect(x: w.rect.minX * size.width, y: w.rect.minY * size.height,
                           width: w.rect.width * size.width, height: w.rect.height * size.height)
            let length = CGFloat(w.key.count) * 6
            let e: CGRect
            switch axis {
            case .left: e = CGRect(x: r.maxX - 2 - length, y: 401, width: length, height: 12)
            case .up: e = CGRect(x: 401, y: r.minY + 2, width: 12, height: length)
            default: e = CGRect(x: 401, y: r.maxY - 2 - length, width: 12, height: length)
            }
            return InkCaseWord(key: w.key, rect: HiddenWordInkAlignCases.normalized(e, size), line: 0)
        }
    }

    /// The turned page with its layer drifted 30 pt along its lines, every word kept by the export ("the" included),
    /// and a box over the print of "the"; verified with `axis`.
    static func v22(_ page: Turned, axis: InkCaseAxis) throws -> (InkCaseVerdict, RedactionRegion, CGRect) {
        let line = page.glyphs
        // The print is 30 pt back along the axis from the hidden glyphs.
        let print = Self.printWords(line, page.size, shift: CGVector(dx: -30 * page.along.dx, dy: -30 * page.along.dy))
        let export = Self.printWords(line, page.size).map(page.exportWord)
        // On /Rotate 90 the box is x 400–414, y 457–478 (the hidden glyphs of "the" are 427–448).
        let the = try #require(print.first { $0.key == "the" })
        let box = RedactionRegion(id: UUID(), normalizedRect: the.rect, source: .manual)
        let v = try Self.pageVerdict(export: export, lines: [line], regions: [box], size: page.size, axis: axis,
                                     sourceInk: print)
        let ink = CGRect(x: the.rect.minX * page.size.width, y: the.rect.minY * page.size.height,
                         width: the.rect.width * page.size.width, height: the.rect.height * page.size.height)
        return (v, box, ink)
    }

    @Test("V22: on a page turned so its lines run down, left or up, a word drifted 30 pt along past a box over its print is flagged on that box",
          arguments: [InkCaseAxis.down, .left, .up])
    func axisFromTheRotation(axis: InkCaseAxis) throws {
        let page = Turned(axis: axis)
        let (v, box, ink) = try Self.v22(page, axis: axis)
        #expect(v.findings.map(\.regionID) == [box.id], "\(axis)")
        if let mark = v.findings.first {
            let midX = mark.inkRect.midX * page.size.width, midY = mark.inkRect.midY * page.size.height
            #expect(abs(midX - ink.midX) < 6 && abs(midY - ink.midY) < 6,
                    "\(axis): the flagged box is the word's ink (\(ink.midX), \(ink.midY)), not (\(midX), \(midY))")
        }
    }

    @Test("V22 (axis): the /Rotate 90 page given the axis .right, its lines running down, is not inspected: never flagged, never clean")
    func axisDisagreesWithTheSpread() throws {
        let (v, _, _) = try Self.v22(Turned(axis: .down), axis: .right)
        #expect(v.unplaceableNearBox, "a line whose spread disagrees with the axis is unplaceable")
        #expect(v.findings.isEmpty)
        #expect(v != InkCaseVerdict())
    }
}
