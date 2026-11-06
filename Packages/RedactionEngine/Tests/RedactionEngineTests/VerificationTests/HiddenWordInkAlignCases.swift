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
// - the window: a candidate's offset (the export word's leading edge minus
//   its first glyph's, along the axis) must lie within 1.5 × the word's own
//   cell (its width ÷ its character count) + 3.5 pt of zero, or within that
//   of the offset of the nearest aligned neighbour on either side on the same
//   export line (the chain: the writer's offsets build up along a group). An
//   absolute offset over 6 cells is unaligned (the cap). Across, it must lie
//   on a source line whose band overlaps the word's band. A unique match
//   outside the window is unaligned, not accepted;
// - rounds: each round judges the still-unaligned words against the
//   alignments as they stood at the round's start; a word ambiguous in any
//   round stays unaligned, an aligned word stays aligned; stop when a round
//   aligns nothing new. Ambiguity is judged over the whole window (zero and
//   chain). The result does not depend on the order the words are listed in;
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
// - no chain (the zero window only): (f), (f′);
// - no cap: (f⁗);
// - the words judged in list order, each seeing the alignments made before
//   it, instead of rounds: (f″), and (f-shuffle) for a single pass.
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

    // MARK: - The chained window

    /// A source line drawn from x 72, 7 pt a glyph, and its export: each word at `offsets[i]` from its own glyphs'
    /// start, 6 pt a character (cell 6: window 12.5, cap 36).
    static func chain(_ text: String, _ offsets: [CGFloat]) -> (glyphs: [InkCaseGlyph], export: [InkCaseWord], own: [CGRect]) {
        let line = Self.glyphs(text, 72, 7)
        let own = printWords(line).map { w in
            CGRect(x: w.rect.minX * size.width, y: w.rect.minY * size.height, width: w.rect.width * size.width,
                   height: w.rect.height * size.height)
        }
        let export = zip(printWords(line), zip(own, offsets)).map { w, p in Self.ew(w.key, p.0.minX + p.1, cell: 6) }
        return (line, export, own)
    }

    /// The writer's shape: one group in fixed cells, its offset growing 4.8 pt (0.8 cell) a word to −24 (4 cells).
    static let chainText = "amber birch cedar dune elm fern"
    static let chainOffsets: [CGFloat] = [0, -4.8, -9.6, -14.4, -19.2, -24]

    @Test("(f): a group whose offset grows 0.8 cell a word, to 4 cells, aligns every word to its own glyphs through the chain")
    func chainedGroup() throws {
        // Offsets 0, −4.8, −9.6 are inside the zero window (12.5): round 1. "dune" (−14.4) and "elm" (−19.2) are
        // within 12.5 of "cedar" (−9.6): round 2. "fern" (−24) is 14.4 from "cedar", 4.8 from "elm": round 3.
        let (line, export, own) = Self.chain(Self.chainText, Self.chainOffsets)
        let r = try Self.align(export, line)
        guard r.count == own.count else { return }
        for (i, box) in own.enumerated() { Self.expectBox(r[i], box.minX, box.maxX, "\(export[i].key)") }
    }

    @Test("(f-shuffle): the same group listed in another order aligns the same way")
    func chainedGroupShuffled() throws {
        let (line, export, own) = Self.chain(Self.chainText, Self.chainOffsets)
        // fern, cedar, amber, elm, birch, dune: a single pass in this order meets "fern" before any neighbour is aligned.
        let order = [5, 2, 0, 4, 1, 3]
        let r = try Self.align(order.map { export[$0] }, line)
        guard r.count == order.count else { return }
        for (k, i) in order.enumerated() { Self.expectBox(r[k], own[i].minX, own[i].maxX, "\(export[i].key)") }
    }

    @Test("(f″): a second run of a chained word's text, inside its chained window and outside the zero window, leaves it unaligned")
    func chainedAmbiguous() throws {
        // The group's last word is "000"; the export kept "00", which matches its glyphs at x 261 and at x 268.
        // Offsets: −23.2 and −30.2. Round 2 ("cedar", −9.6, window to −22.1) reaches neither; round 3 ("elm",
        // −19.2, window −31.7 … −6.7) reaches both: ambiguous. Words listed with "00" before "elm", so a pass that
        // reads alignments as it makes them takes "00" from "dune" (−14.4, window to −26.9) and only the run at 261.
        let base = Self.chain("amber birch cedar dune elm 000", [0, -4.8, -9.6, -14.4, -19.2, 0])
        let zeros = Self.ew("00", 261 - 23.2, cell: 6)
        let words = [base.export[0], base.export[1], base.export[2], base.export[3], zeros, base.export[4]]
        let r = try Self.align(words, base.glyphs)
        guard r.count == 6 else { return }
        for i in 0..<4 { Self.expectBox(r[i], base.own[i].minX, base.own[i].maxX, "\(words[i].key)") }
        #expect(r[4] == nil, "two runs in the window: unaligned")
        Self.expectBox(r[5], base.own[4].minX, base.own[4].maxX, "elm")
    }

    @Test("(f‴): a word 2.6 cells from its aligned neighbour and outside the zero window is unaligned")
    func chainStepTooFar() throws {
        // "dune" at −25.2: 15.6 from "cedar" (−9.6), past 12.5; |−25.2| is past the zero window.
        let (line, export, own) = Self.chain("amber birch cedar  dune", [0, -4.8, -9.6, -25.2])
        let r = try Self.align(export, line)
        guard r.count == 4 else { return }
        for i in 0..<3 { Self.expectBox(r[i], own[i].minX, own[i].maxX, "\(export[i].key)") }
        #expect(r[3] == nil)
    }

    @Test("(f⁗): a chain that would reach a candidate at 7 cells leaves it unaligned (the cap)")
    func chainCap() throws {
        // Offsets 0 … −33.6 in steps of 4.8 (5.6 cells); "ivy" at −42 (7 cells) is 8.4 from "heath": inside the chain,
        // past the cap of 36.
        let (line, export, own) = Self.chain("amber birch cedar dune elm fern grove heath ivy",
                                              [0, -4.8, -9.6, -14.4, -19.2, -24, -28.8, -33.6, -42])
        let r = try Self.align(export, line)
        guard r.count == 9 else { return }
        for i in 0..<8 { Self.expectBox(r[i], own[i].minX, own[i].maxX, "\(export[i].key)") }
        #expect(r[8] == nil, "an absolute offset over 6 cells is unaligned")
    }

    @Test("(f′): the chain's last word a surviving fragment of a boxed word at 4 cells, its ink under the box, is flagged on that box")
    func chainedFragmentFlagged() throws {
        // The layer drifted 30 pt: print = hidden − 30. A box over the print of "fernwood" (x 259–315) stripped the
        // hidden glyphs under it; "wood" (hidden 317–345) survives at offset −24, 4.8 from "elm" (−19.2): round 3.
        // Placed by the line's fit (−30), its ink is 287–315: centre 301, inside the box.
        let line = Self.glyphs("amber birch cedar dune elm     fernwood", 72, 7)
        let hidden = Self.printWords(line)
        let own = hidden.map { $0.rect.minX * Self.size.width }
        let export = (0..<5).map { Self.ew(hidden[$0].key, own[$0] + Self.chainOffsets[$0], cell: 6) }
            + [Self.ew("wood", 317 - 24, cell: 6)]
        let print = Self.printWords(line, shift: CGVector(dx: -30, dy: 0))
        let name = try #require(print.first { $0.key == "fernwood" })
        let box = RedactionRegion(id: UUID(), normalizedRect: name.rect, source: .manual)
        let v = try Self.pageVerdict(export: export, lines: [line], regions: [box], sourceInk: print)
        #expect(v.findings.map(\.regionID) == [box.id])
        if let mark = v.findings.first {
            #expect(abs(mark.inkRect.midX * Self.size.width - 301) < 6, "the flagged box is the fragment's ink")
        }
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
