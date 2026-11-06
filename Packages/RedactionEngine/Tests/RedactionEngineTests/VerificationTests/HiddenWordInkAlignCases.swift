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
// - an unaligned word gives the page `unplaceableNearBox` if its export box,
//   widened by its window plus the drift reach (36 pt along the line, growing
//   along the line as the fit's scale allows; 10 pt across), meets any box's
//   paint. Otherwise it changes nothing;
// - the axis is the page's rotation's; each line's spread only cross-checks
//   it. A line whose spread disagrees with the axis, or has no clear axis, is
//   unplaceable;
// - `HiddenWordInkSeam.verdict` keeps its meaning, with the axis `.right`.
//
// Geometry is in points on a 612 × 792 page (V22: its visual frame, 792 ×
// 612), converted to the normalized frame. A source line is one glyph per
// character, spaces included, `advance` apart.
//
// Mutants these cases are written to kill (run against the built step):
// - align by nearest position instead of by order: (c), (d);
// - an unaligned word read as absent: (d′), (e′); (e″) guards the other way;
// - no window, any ordered match accepted: (a′);
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

    // MARK: - The axis

    static let turned = CGSize(width: 792, height: 612)

    /// A line of a /Rotate 90 page in its visual frame: glyphs stepping down from y 560, 7 pt each, in a band at
    /// x 400–414. Five spaces before "the" keep the glyphs under its print box blank.
    static func downLine() -> [InkCaseGlyph] {
        "alpha bravo     the delta echo foxtrot golf hotel".enumerated().map { i, c in
            InkCaseGlyph(char: c, rect: normalized(CGRect(x: 400, y: 560 - 7 * CGFloat(i + 1), width: 14, height: 7), turned),
                         line: 0)
        }
    }

    static func v22(axis: InkCaseAxis) throws -> (InkCaseVerdict, RedactionRegion) {
        let line = Self.downLine()
        // The layer drifted 30 pt along the axis: the print is 30 pt up from the hidden glyphs.
        let print = Self.printWords(line, turned, shift: CGVector(dx: 0, dy: 30))
        // The export keeps every word, "the" included: each 2 pt along from its glyphs, 6 pt a character.
        let export = Self.printWords(line, turned).map { w -> InkCaseWord in
            let top = w.rect.maxY * turned.height - 2, length = CGFloat(w.key.count) * 6
            return InkCaseWord(key: w.key, rect: normalized(CGRect(x: 401, y: top - length, width: 12, height: length), turned),
                               line: 0)
        }
        // The box is over the print of "the": x 400–414, y 457–478 (its hidden glyphs are 427–448).
        let the = try #require(print.first { $0.key == "the" })
        let box = RedactionRegion(id: UUID(), normalizedRect: the.rect, source: .manual)
        let v = try Self.pageVerdict(export: export, lines: [line], regions: [box], size: turned, axis: axis,
                                     sourceInk: print)
        return (v, box)
    }

    @Test("V22: on a /Rotate 90 page, a word drifted 30 pt down past a box over its print is flagged on that box")
    func axisFromTheRotation() throws {
        let (v, box) = try Self.v22(axis: .down)
        #expect(v.findings.map(\.regionID) == [box.id])
        if let mark = v.findings.first {
            #expect(abs(mark.inkRect.midY * Self.turned.height - 467.5) < 6, "the flagged box is the word's ink")
        }
    }

    @Test("V22 (axis): the same page given the axis .right, its lines running down, is not inspected: never flagged, never clean")
    func axisDisagreesWithTheSpread() throws {
        let (v, _) = try Self.v22(axis: .right)
        #expect(v.unplaceableNearBox, "a line whose spread disagrees with the axis is unplaceable")
        #expect(v.findings.isEmpty)
        #expect(v != InkCaseVerdict())
    }
}
