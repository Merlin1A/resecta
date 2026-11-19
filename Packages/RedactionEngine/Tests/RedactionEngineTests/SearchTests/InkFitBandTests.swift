import CoreGraphics
import Foundation
import Testing
@testable import RedactionEngine

// The rows the ink box takes. Every run of inked rows that meets the text
// layer's box is the word's ink: a light row through a word splits it into two
// runs of like height, and the box takes both. A dot or an accent a small gap
// away joins as before, and the next line, outside the box's rows, does not.
// When the box with every run reaches past the fit's window (another line that
// meets the box by a row, carried to the window's edge), the fit paints the box
// of the tallest band alone, as before, and not the envelope.
// A paint that took more than the tallest band carries that band's box as the
// match's identity: a hybrid page tells an OCR result that repeats the match by
// it, never by the grown box.
// Bitmaps are drawn in render pixels from the bottom-left.
//
// Privacy rule (audit-lint M-1): locate/match/cover vocabulary.

@Suite("Ink box: the bands it takes", .tags(.search))
struct InkFitBandTests {
    static let s = DocumentSearcher.inkFitScale

    static func read(_ blocks: [(x: Range<Int>, y: Range<Int>)], box rows: Range<Int>, width: Int = 200, height: Int = 160)
        -> (box: CGRect?, outcome: DocumentSearcher.InkFitOutcome) {
        let map = PageImageInkFitTests.bitmap(width: width, height: height, blocks: blocks)
        let window = CGRect(x: 0, y: 0, width: CGFloat(width) / s, height: CGFloat(height) / s)
        let box = CGRect(x: 60 / s, y: CGFloat(rows.lowerBound) / s, width: 80 / s, height: CGFloat(rows.count) / s)
        let reading = DocumentSearcher.inkBox(in: map, box: box, window: window)
        return (reading.box, reading.outcome)
    }

    @Test("A light row through a word: the box takes the word's rows on both sides of it")
    func lightRowThroughTheWord() throws {
        // A word at rows 40..<80, a blank row band of 1 to 3 rows at every
        // place inside it; the text layer's box on the word's rows. Where
        // neither part fills half the box, the box is read as set between
        // lines (the guard before this change, unchanged) and is not fitted:
        // the fit then paints the read word's envelope. That is three places:
        // a blank band of 2 rows at row 59, and of 3 rows at rows 58 and 59.
        var places = 0
        var standing: [String] = []
        for blank in 1...3 {
            for cut in 42..<(78 - blank) {
                let reading = Self.read([(60..<140, 40..<cut), (60..<140, (cut + blank)..<80)], box: 40..<80)
                places += 1
                let taller = max(cut - 40, 80 - cut - blank)
                guard let ink = reading.box else {
                    #expect(reading.outcome == .otherLine && taller * 2 < 40,
                            "blank \(blank) at row \(cut): not fitted (\(reading.outcome)) though a part is \(taller) rows")
                    standing.append("\(blank)@\(cut)")
                    continue
                }
                #expect(reading.outcome == .fitted)
                #expect(ink.minY <= 40 / Self.s && ink.maxY >= 80 / Self.s,
                        "blank \(blank) at row \(cut): rows 40–80; got \(ink.minY * Self.s)…\(ink.maxY * Self.s)")
            }
        }
        #expect(places == 102)
        #expect(standing == ["2@59", "3@58", "3@59"], "not fitted: \(standing)")
    }

    @Test("A light row through a word with the box set low: the part above the box is taken too")
    func lightRowWithTheBoxLow() throws {
        let ink = try #require(Self.read([(60..<140, 40..<60), (60..<140, 61..<80)], box: 30..<70).box)
        #expect(ink.minY <= 40 / Self.s && ink.maxY >= 80 / Self.s, "rows 40–80; got \(ink.minY * Self.s)…\(ink.maxY * Self.s)")
    }

    @Test("A light row through a word with the box set a third of a line down: the part above, mostly outside the box, is taken")
    func lightRowWithTheBoxSetDown() throws {
        // A word at rows 40..<80, a blank row at row 62: the part above is
        // rows 63..<80. The text layer's box a line high, set 12 to 16 rows
        // (30 to 40 % of the line) down, holds 5 to 1 of those 17 rows.
        for shift in 12...16 {
            let reading = Self.read([(60..<140, 40..<62), (60..<140, 63..<80)], box: (40 - shift)..<(80 - shift))
            let ink = try #require(reading.box, "set \(shift) rows down: \(reading.outcome)")
            #expect(reading.outcome == .fitted)
            #expect(ink.minY <= 40 / Self.s && ink.maxY >= 80 / Self.s,
                    "set \(shift) rows down: rows 40–80; got \(ink.minY * Self.s)…\(ink.maxY * Self.s)")
        }
    }

    /// The paint the fit makes for a seed box on a page whose bottom-left
    /// corner is the bitmap's (so the window starts at its pixel 0, 0): the
    /// fit's own window, ink box and margin, and its window check.
    static func paint(_ blocks: [(x: Range<Int>, y: Range<Int>)], seedColumns: Range<Int>, seedRows: Range<Int>) -> CGRect? {
        let seed = CGRect(x: CGFloat(seedColumns.lowerBound) / s, y: CGFloat(seedRows.lowerBound) / s,
                          width: CGFloat(seedColumns.count) / s, height: CGFloat(seedRows.count) / s)
        let window = DocumentSearcher.inkFitWindow(seed: seed, box: seed, size: CGSize(width: 612, height: 792))
        let width = Int((window.width * s).rounded(.up)), height = Int((window.height * s).rounded(.up))
        let inside = blocks.map { (x: $0.x.clamped(to: 0..<width), y: $0.y.clamped(to: 0..<height)) }
        let map = PageImageInkFitTests.bitmap(width: width, height: height, blocks: inside)
        let reading = DocumentSearcher.inkBoxes(in: map, box: seed, window: window)
        guard let ink = reading.box else { return nil }
        return DocumentSearcher.inkPaint(ink: ink, band: reading.band, seed: seed, window: window, growLeft: true, growRight: true)
    }

    /// The paint the fit made before every band was taken, for a word whose
    /// ink is `columns` x `rows` and nothing joins it: one pixel out from the
    /// ink, then the margin (1 pt on each side, half of it above and below).
    static func formerPaint(columns: Range<Int>, rows: Range<Int>) -> CGRect {
        let m = DocumentSearcher.inkFitMargin
        return CGRect(x: CGFloat(columns.lowerBound - 1) / s - m, y: CGFloat(rows.lowerBound - 1) / s - m / 2,
                      width: CGFloat(columns.count + 2) / s + 2 * m, height: CGFloat(rows.count + 2) / s + m)
    }

    static func holds(_ outer: CGRect, _ inner: CGRect) -> Bool {
        outer.insetBy(dx: -1e-9, dy: -1e-9).contains(inner)
    }

    /// Print drawn as glyph stems: two inked columns in every four, from the
    /// first column (print is mostly paper; solid blocks of this size would
    /// ink over a third of the window, which the fit reads as a dark ground).
    static func stems(_ columns: Range<Int>, _ rows: Range<Int>) -> [(x: Range<Int>, y: Range<Int>)] {
        stride(from: columns.lowerBound, to: columns.upperBound, by: 4).map { (x: $0..<min($0 + 2, columns.upperBound), y: rows) }
    }

    /// The line above the word, across the window: words 10 pixels wide with
    /// 3-pixel gaps, in stems (not a rule: under nine tenths of each row is inked).
    static func lineAcross(rows: Range<Int>, width: Int) -> [(x: Range<Int>, y: Range<Int>)] {
        stride(from: 0, to: width, by: 13).flatMap { stems($0..<min($0 + 10, width), rows) }
    }

    @Test("A line meeting the box by a row runs to the window's edge: the fit paints the word's band, never less than before")
    func lineAcrossTheWindowKeepsTheBand() throws {
        // The word's ink at columns 20..<110, rows 40..<80; Vision's box
        // stops 10 columns short, at columns 20..<100, and reaches rows
        // 40..<83. The line above, rows 82..<120, runs across the window:
        // with it, the box reaches the window's edge. The band alone is the
        // box before this change, to the word's last column.
        let word = (x: 20..<110, y: 40..<80)
        let paint = try #require(Self.paint(Self.stems(word.x, word.y) + Self.lineAcross(rows: 82..<120, width: 140),
                                            seedColumns: 20..<100, seedRows: 40..<83),
                                 "the fit painted the envelope")
        let former = Self.formerPaint(columns: word.x, rows: word.y)
        #expect(Self.holds(paint, former), "paint \(paint) is narrower than before, \(former)")
        #expect(paint.maxX >= 110 / Self.s, "the word's ink to column 110; paint ends at \(paint.maxX * Self.s)")
    }

    @Test("A tight scan, the line above's descenders reaching 1 to 3 rows into the box: the paint holds the word and the box before")
    func descendersTouchingTheBox() throws {
        // The word at columns 20..<110, rows 40..<78; Vision's box at
        // columns 20..<100, rows 40..<82. The line above at rows 84..<120,
        // its descenders reaching down 1 to 3 rows into the box. Over the word
        // only, the box takes that line (more paint, never less); across the
        // window, the band alone.
        let word = (x: 20..<110, y: 40..<78)
        let former = Self.formerPaint(columns: word.x, rows: word.y)
        for reach in 1...3 {
            let descenders = [(x: 30..<34, y: (82 - reach)..<84), (x: 70..<74, y: (82 - reach)..<84)]
            for across in [false, true] {
                let line = across ? Self.lineAcross(rows: 84..<120, width: 140) : Self.stems(20..<110, 84..<120)
                let paint = try #require(Self.paint(Self.stems(word.x, word.y) + descenders + line, seedColumns: 20..<100, seedRows: 40..<82),
                                         "reach \(reach), across \(across): the fit painted the envelope")
                #expect(Self.holds(paint, former), "reach \(reach), across \(across): paint \(paint), before \(former)")
            }
        }
    }

    @Test("A hybrid page, the same term on the line above read by OCR alone: the merge tells the word by its band, and the line above keeps its OCR result")
    func neighbourLineKeepsItsOCRResult() throws {
        let s = Self.s
        // The word's ink at columns 32..<122, rows 42..<80; Vision's box for it
        // at rows 42..<84. The line above holds the same term, which the text
        // layer lacks: its lower-case letters at columns 36..<100, rows
        // 83..<112, meeting the box by a row, and its capital left of the box
        // at columns 12..<28, rows 83..<124. The paint takes both lines and
        // passes the window; the hybrid merge must still tell the word by the
        // box of its own band, so the line above's OCR result (listed first,
        // as Vision lists lines from the top) is not taken as its repeat.
        let word = (x: 32..<122, y: 42..<80)
        let capital = (x: 12..<28, y: 83..<124)
        let blocks = Self.stems(word.x, word.y) + Self.stems(36..<100, 83..<112) + Self.stems(capital.x, capital.y)
        let seed = CGRect(x: 32 / s, y: 42 / s, width: 90 / s, height: 42 / s)
        let window = DocumentSearcher.inkFitWindow(seed: seed, box: seed, size: CGSize(width: 612, height: 792))
        let width = Int((window.width * s).rounded(.up)), height = Int((window.height * s).rounded(.up))
        let map = PageImageInkFitTests.bitmap(width: width, height: height,
                                              blocks: blocks.map { (x: $0.x.clamped(to: 0..<width), y: $0.y.clamped(to: 0..<height)) })
        let reading = DocumentSearcher.inkBoxes(in: map, box: seed, window: window)
        let ink = try #require(reading.box, "no ink box: \(reading.outcome)")
        let painted = try #require(DocumentSearcher.inkPaintAndIdentity(ink: ink, band: reading.band, seed: seed, window: window,
                                                                        growLeft: true, growRight: true), "the fit painted the envelope")
        #expect(painted.paint.maxY > 100 / s, "the paint takes the line above (the case under test): \(painted.paint.maxY * s)")
        let identity = try #require(painted.identity, "a paint over two lines carries the box of the word's own band")
        #expect(identity == DocumentSearcher.inkPaint(ink: try #require(reading.band), band: nil, seed: seed, window: window,
                                                      growLeft: true, growRight: true),
                "the identity is the band's paint, the box before every band was taken")
        #expect(Self.holds(identity, Self.formerPaint(columns: word.x, rows: word.y)) && identity.maxY < 84 / s,
                "the identity holds the word and stops inside the line above's first row: \(identity.maxY * s)")
        // The text-layer result as the search sites make it, and the OCR leg's
        // two results, line above first.
        let textLayer = SearchResult(pageIndex: 0, normalizedRect: painted.paint, matchedText: "Delia", contextSnippet: "Delia",
                                     source: .textLayer, term: "delia").identified(by: painted.identity)
        func ocr(_ x: Range<Int>, _ y: Range<Int>) -> SearchResult {
            SearchResult(pageIndex: 0, normalizedRect: CGRect(x: CGFloat(x.lowerBound) / s, y: CGFloat(y.lowerBound) / s,
                                                              width: CGFloat(x.count) / s, height: CGFloat(y.count) / s),
                         matchedText: "Delia", contextSnippet: "Delia", source: .ocr(confidence: 1), term: "delia")
        }
        let above = ocr(10..<102, 80..<128), own = ocr(30..<124, 38..<84)
        #expect(DocumentSearcher.mergeHybridResults(textLayerRects: [painted.paint], ocr: [above, own]).map(\.normalizedRect)
                    == [own.normalizedRect],
                "told by the grown paint, the line above's result would be taken as the word's repeat (the case is live)")
        let kept = DocumentSearcher.mergeHybridResults(textLayerRects: [textLayer.mergeIdentity], ocr: [above, own])
        #expect(kept.map(\.normalizedRect) == [above.normalizedRect], "the line above keeps its OCR result; the word's own repeats")
        // Every ink pixel of the line above's capital is covered.
        let boxes = [textLayer.normalizedRect] + kept.map(\.normalizedRect)
        var outside = 0
        for block in Self.stems(capital.x, capital.y) { for y in block.y { for x in block.x {
            let centre = CGPoint(x: window.minX + (CGFloat(x) + 0.5) / s, y: window.minY + (CGFloat(y) + 0.5) / s)
            if !boxes.contains(where: { $0.contains(centre) }) { outside += 1 }
        } } }
        #expect(outside == 0, "\(outside) ink pixels of the capital outside every box")
    }

    @Test("A dot a small gap above the word: the box is as before")
    func dotIsUnchanged() throws {
        // The word at rows 40..<80, the dot at rows 84..<90, the box on rows
        // 20..<60: the word's band and the dot, one pixel out on every side.
        let ink = try #require(Self.read([(60..<140, 40..<80), (70..<76, 84..<90)], box: 20..<60).box)
        #expect(ink == CGRect(x: 59 / Self.s, y: 39 / Self.s, width: 82 / Self.s, height: 52 / Self.s), "got \(ink)")
    }

    @Test("The next line, outside the box's rows, is not taken")
    func nextLineIsNotTaken() throws {
        // The word at rows 40..<80; the next line at rows 100..<140, and a
        // short line of small type at rows 10..<22, both outside the box.
        let ink = try #require(Self.read([(60..<140, 40..<80), (60..<140, 100..<140), (60..<140, 10..<22)], box: 40..<80).box)
        #expect(ink.minY > 22 / Self.s && ink.maxY < 100 / Self.s, "rows 40–80 only; got \(ink.minY * Self.s)…\(ink.maxY * Self.s)")
    }
}
