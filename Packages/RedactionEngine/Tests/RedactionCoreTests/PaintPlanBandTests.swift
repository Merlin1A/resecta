import Foundation
import Testing
import RedactionCore

/// The band with the switch on: the column, the box's own run and the stop,
/// on the readings' own hand-built layouts (cases 1 to 14), with the stop's
/// property in sixty-fourths and in pixels, and Property 2.
@Suite struct PaintPlanBandTests {
    typealias Sheet = ComplementReadingTests.Sheet
    typealias T = PaintPlanMakeTests
    static let policy = GeometryPolicy.release
    static let plain = T.plain
    static let W = T.W, H = T.H

    // MARK: - The band (switch on)

    /// The unselected words of a page's lines that the box stands on, in
    /// sixty-fourths, and the box's own run on each, as the readings give them.
    static func lineWords(_ sheet: Sheet, _ regions: [PlanRegion], _ box: PaintedBox) -> [(word: PageRect64, own: Bool)] {
        let words = PageWords(text: sheet.text, boxes: sheet.boxes, source: .textLayer)
        let selected = regions.filter { $0.kind == .placedFromTextAnchored }.reduce(into: Set<Int>()) { $0.formUnion($1.selected) }
        let page = Complement.page(words: words, text: sheet.text, selected: selected, constants: policy.provisional)
        let mine = regions.filter { box.regionIDs.contains($0.id) }.reduce(into: Set<Int>()) { $0.formUnion($1.selected) }
        guard let reading = Complement.reading(of: mine, on: page, words: words, text: sheet.text, facts: plain,
                                               constants: policy.provisional) else { return [] }
        return reading.rows.flatMap { row -> [(word: PageRect64, own: Bool)] in
            guard let line = row.line else { return [] }
            return page.lines[line].words.map { w in
                (w.box, row.ownRun.map { $0.minX <= w.box.minX && w.box.maxX <= $0.maxX } ?? false)
            }
        }
    }

    /// Property 1: every unselected word on a widened box's lines whose box
    /// shares area with the paint is in the box's own run, or under its tight
    /// rectangle.
    static func checkTheStop(_ sheet: Sheet, _ regions: [PlanRegion], _ box: PaintedBox,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        for (word, own) in lineWords(sheet, regions, box) where box.paint.sharesArea(with: word) {
            #expect(own || box.tight.sharesArea(with: word), "a word not in the own run shares area with the paint",
                    sourceLocation: sourceLocation)
        }
    }

    /// Property 3: on each side where the band reaches past the tight
    /// rectangle, the painted rectangle shares no pixel with any word of the
    /// box's lines that is not in its own run, at 300, 200 and 150 dpi.
    static func checkThePixels(_ sheet: Sheet, _ regions: [PlanRegion], _ box: PaintedBox,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        func floorDiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : -((-a + b - 1) / b) }
        func ceilDiv(_ a: Int, _ b: Int) -> Int { -floorDiv(-a, b) }
        for dpi in [300, 200, 150] {
            let raster = PixelPlan.Raster(widthSixtyFourths: W, heightSixtyFourths: H, dpi: dpi)!
            guard let painted = PixelPlan.project(inner: box.inner, paint: box.paint, limitAbove: box.limitAbove,
                                                  limitBelow: box.limitBelow, raster: raster)?.painted else {
                Issue.record("the box projects", sourceLocation: sourceLocation); continue
            }
            for (word, own) in lineWords(sheet, regions, box) where !own {
                let right = word.minX >= box.tight.maxX && box.inner.maxX > box.tight.maxX
                let left = word.maxX <= box.tight.minX && box.inner.minX < box.tight.minX
                guard right || left else { continue }
                let pixels = PixelPlan.PixelRect(minX: floorDiv(word.minX * dpi, 4608), minY: floorDiv(word.minY * dpi, 4608),
                                                 maxX: ceilDiv(word.maxX * dpi, 4608), maxY: ceilDiv(word.maxY * dpi, 4608))
                let shares = painted.minX < pixels.maxX && pixels.minX < painted.maxX
                    && painted.minY < pixels.maxY && pixels.minY < painted.maxY
                #expect(!shares, "a pixel of another field's word is painted at \(dpi) dpi", sourceLocation: sourceLocation)
            }
        }
    }

    static func checkWidened(_ sheet: Sheet, _ regions: [PlanRegion], _ box: PaintedBox,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        checkTheStop(sheet, regions, box, sourceLocation: sourceLocation)
        checkThePixels(sheet, regions, box, sourceLocation: sourceLocation)
    }

    @Test("Case 4: a six-line paragraph, the value in mid-line: the band is the whole line")
    func paragraphLineBand() {
        var sheet = Sheet()
        let lines = ComplementReadingTests.paragraph(&sheet, counts: [6, 5, 6, 6, 4, 5])
        let region = T.matched(sheet, lines[2][2])
        let made = T.plan(sheet, [region], on: true)
        let box = made.box(region)
        let line = T.rect64(sheet, lines[2].reduce(into: Set<Int>()) { $0.formUnion($1) })
        #expect(box.bandMade && box.treatment == .widened)
        #expect(box.inner == line)
        #expect(made.facts.widened == 1)
        Self.checkWidened(sheet, [region], box)
        let off = T.plan(sheet, [region]).box(region)
        #expect(off.inner == T.rect64(sheet, lines[2][2]).union(T.placed(region)) && !off.bandMade)
    }

    @Test("Case 1: two columns of one line each under a full-width title: the band stops the stop short of the right column")
    func twoColumnsUnderATitle() {
        var sheet = Sheet()
        sheet.line(count: 14, y: 700)
        let left = sheet.line(count: 2, y: 686)
        let right = sheet.line(count: 2, y: 686, x: 300)
        let region = T.matched(sheet, left[1])
        let box = T.plan(sheet, [region], on: true).box(region)
        #expect(box.treatment == .widened)
        #expect(box.inner.maxX == T.s(300) - T.stop(T.s(10)))
        #expect(box.inner.minX == T.rect64(sheet, left[1]).minX, "the word before is not taken in: one bridge only")
        #expect(!box.paint.sharesArea(with: T.rect64(sheet, right[0])))
        Self.checkWidened(sheet, [region], box)
    }

    @Test("Case 2: one table row under a merged header: the box stops short of the next cell's words on both sides")
    func tableRowUnderAMergedHeader() {
        var sheet = Sheet()
        sheet.line(count: 12, y: 700)
        let before = sheet.word("abcd", x: 72, y: 686)
        let cell = sheet.word("abcd", x: 200, y: 686)
        let after = sheet.word("abcd", x: 330, y: 686)
        let region = T.matched(sheet, cell)
        let box = T.plan(sheet, [region], on: true).box(region)
        let stop = T.stop(T.s(10))
        #expect(box.treatment == .widened)
        #expect(box.inner.minX == T.s(96) + stop && box.inner.maxX == T.s(330) - stop)
        #expect(!box.paint.sharesArea(with: T.rect64(sheet, before)) && !box.paint.sharesArea(with: T.rect64(sheet, after)))
        Self.checkWidened(sheet, [region], box)
    }

    /// Three label rows: a long address row above, the value's row with a
    /// second field at 300 pt, and a short row below with its own second field.
    static func labelRowWithASecondField(value: String) -> (Sheet, Set<Int>, Set<Int>) {
        var sheet = Sheet()
        sheet.line("Address: " + String(repeating: "a", count: 31), x: 72, y: 700)
        sheet.word("Name:", x: 72, y: 686)
        let v = sheet.word(value, x: 106, y: 686)
        let date = sheet.word("Date:", x: 300, y: 686)
        sheet.word("2026", x: 334, y: 686)
        sheet.line("Name: abcd", x: 72, y: 672)
        sheet.line("Date: 2026", x: 300, y: 672)
        return (sheet, v, date)
    }

    @Test("Case 3: a label row with a second field: a short value and a long one get the same band and the same covered words")
    func labelRowShortAndLong() {
        var boxes: [PaintedBox] = []
        for value in ["Ann", "Annabellexyz", "Annabellexyzabcdefgh"] {
            let (sheet, v, date) = Self.labelRowWithASecondField(value: value)
            let region = T.matched(sheet, v)
            let made = T.plan(sheet, [region], on: true)
            let box = made.box(region)
            #expect(box.treatment == .widened)
            #expect(box.inner.maxX == T.s(300) - T.stop(T.s(10)), "the stop short of the second field")
            #expect(!box.paint.sharesArea(with: T.rect64(sheet, date)))
            #expect(made.facts.unselectedWordsInsidePaint == 0, "the label is not covered: no two rows bridge")
            Self.checkWidened(sheet, [region], box)
            boxes.append(box)
        }
        // Property 2: the pages differ only in the selected characters.
        for box in boxes.dropFirst() {
            #expect(box.inner == boxes[0].inner && box.paint == boxes[0].paint)
            #expect(box.limitAbove == boxes[0].limitAbove && box.limitBelow == boxes[0].limitBelow)
        }
    }

    @Test("Case 5: a block of label rows between two full-measure paragraphs: the band runs to the paragraphs' reach")
    func labelBlockReachesTheParagraphs() {
        let (sheet, value) = ComplementReadingTests.labelBlockBetweenParagraphs()
        let region = T.matched(sheet, value)
        let box = T.plan(sheet, [region], on: true).box(region)
        #expect(box.treatment == .widened)
        #expect(box.inner.maxX == T.s(72 + 28 * 14 - 4))
        #expect(box.inner.minX == T.s(72), "six lines bridge: the label is the box's own run")
        Self.checkWidened(sheet, [region], box)
    }

    @Test("Case 6: the same block with a note beside one row: the outside lines are not read on that side")
    func noteKeepsTheOutsideLinesOut() {
        let (sheet, value) = ComplementReadingTests.labelBlockBetweenParagraphs(noteOnRow: 0)
        let region = T.matched(sheet, value)
        let box = T.plan(sheet, [region], on: true).box(region)
        #expect(box.inner.maxX == T.rect64(sheet, value).maxX)
        #expect(box.inner.maxX < T.s(380))
        Self.checkWidened(sheet, [region], box)
    }

    @Test("Case 7: a left-column paragraph under a full-width title, the box ending its line: the band stays in its column")
    func leftColumnStaysInItsColumn() {
        // A one-line paragraph in the left column, the box ending its line,
        // between lines that run on into the right column: the lines above
        // and below are not the last runs of their lines, so they do not
        // bridge the room open on the box's right, and the words before the
        // box are not taken in.
        var sheet = Sheet()
        sheet.line(count: 14, y: 730)
        sheet.line(count: 4, y: 700)
        sheet.line(count: 3, y: 700, x: 300)
        let value = sheet.line(count: 3, y: 674)[2]
        sheet.line(count: 4, y: 648)
        sheet.line(count: 3, y: 648, x: 300)
        let region = T.matched(sheet, value)
        let box = T.plan(sheet, [region], on: true).box(region)
        #expect(box.inner.maxX <= T.s(300) - T.stop(T.s(10)))
        #expect(box.inner.minX == T.rect64(sheet, value).minX, "the words before are not taken in")
        Self.checkWidened(sheet, [region], box)
    }

    @Test("Case 8: a fixed table, the value in a middle cell: the band is the cell's column, not the row")
    func tableCellBand() {
        var sheet = Sheet()
        var value: Set<Int> = []
        for k in 0..<4 {
            let y = 700 - 14 * Double(k)
            sheet.word("abcd", x: 72, y: y)
            let cell = sheet.word(k == 2 ? "ab" : "abcdefgh", x: 200, y: y)
            if k == 2 { value = cell }
            sheet.word("abcd", x: 330, y: y)
        }
        let region = T.matched(sheet, value)
        let box = T.plan(sheet, [region], on: true).box(region)
        #expect(box.treatment == .widened)
        #expect(box.inner.minX == T.s(200) && box.inner.maxX == T.s(248))
        Self.checkWidened(sheet, [region], box)
    }

    @Test("Case 9: an address boxed line by line between two paragraphs: each box is widened to the paragraphs' column")
    func addressLineByLine() {
        var sheet = Sheet()
        for k in 0..<3 { sheet.line(count: 14, y: 700 - 14 * Double(k)) }
        let address = (0..<3).map { k in sheet.line(count: 3, y: 646 - 14 * Double(k)).reduce(into: Set<Int>()) { $0.formUnion($1) } }
        for k in 0..<3 { sheet.line(count: 14, y: 592 - 14 * Double(k)) }
        let regions = address.map { T.matched(sheet, $0) }
        let made = T.plan(sheet, regions, on: true)
        #expect(made.plan.boxes.count == 3)
        for region in regions {
            let box = made.box(region)
            #expect(box.treatment == .widened && box.inner.maxX == T.s(72 + 28 * 14 - 4))
            Self.checkWidened(sheet, regions, box)
        }
    }

    @Test("Case 10: a line alone on a page: could not widen, no column, and no band")
    func lineAloneCannotWiden() {
        var sheet = Sheet()
        let line = sheet.line(count: 3, y: 700)
        let region = T.matched(sheet, line[1])
        let on = T.plan(sheet, [region], on: true)
        let off = T.plan(sheet, [region])
        #expect(on.box(region).treatment == .couldNotWiden(.noColumn) && !on.box(region).bandMade)
        #expect(on.box(region).paint == off.box(region).paint)
        #expect(on.facts.couldNotWiden == [.noColumn: 1])
    }

    @Test("Case 11: a two-line paragraph standing alone, the value in mid-line 1: no word beside the box is taken in")
    func twoLineParagraphTakesNothingIn() {
        var sheet = Sheet()
        let lines = ComplementReadingTests.paragraph(&sheet, counts: [5, 5])
        let region = T.matched(sheet, lines[0][2])
        let made = T.plan(sheet, [region], on: true)
        let box = made.box(region)
        #expect(box.treatment == .couldNotWiden(.noColumn) && box.bandMade)
        #expect(box.inner == T.rect64(sheet, lines[0][2]).union(T.placed(region)))
        #expect(made.facts.unselectedWordsInsidePaint == 0)
    }

    @Test("Case 12: a form row in 6 pt print with a second field, at 150 dpi: no pixel of the field's first word is painted")
    func smallPrintStop() {
        // The second field moved a quarter point at a time across two blocks
        // of 150 dpi, so every phase of the 8-pixel grid is tried.
        for k in 0..<32 {
            var sheet = Sheet()
            sheet.line("abcd abcd abcd abcd abcd abcd abcd abcd abcd abcd abcd abcd", x: 72, y: 700)
            sheet.word("Name:", x: 72, y: 692, width: 4, height: 6)
            let value = sheet.word("abcd", x: 96, y: 692, width: 4, height: 6)
            let fieldX = 200 + 0.25 * Double(k)
            let field = sheet.word("Date:", x: fieldX, y: 692, width: 4, height: 6)
            let region = T.matched(sheet, value)
            let box = T.plan(sheet, [region], on: true).box(region)
            #expect(box.treatment == .widened)
            #expect(box.inner.maxX == T.rect64(sheet, field).minX - 246, "eight pixels at 150 dpi, not half a 6 pt line")
            Self.checkThePixels(sheet, [region], box)
        }
    }

    @Test("Case 13: a value alone on its line, exactly as wide as its column: already as wide, a band made, inner as a shorter value's")
    func alreadyAsWide() {
        func page(_ letters: Int) -> (Sheet, PlanRegion) {
            var sheet = Sheet()
            sheet.word(String(repeating: "a", count: 18), x: 72, y: 700)
            let v = sheet.word(String(repeating: "b", count: letters), x: 72, y: 686)
            sheet.word(String(repeating: "a", count: 18), x: 72, y: 672)
            return (sheet, T.matched(sheet, v))
        }
        let (full, a) = page(18), (short, b) = page(10)
        let wide = T.plan(full, [a], on: true).box(a), shorter = T.plan(short, [b], on: true).box(b)
        #expect(wide.treatment == .alreadyAsWide && wide.bandMade)
        #expect(shorter.treatment == .widened && shorter.bandMade)
        #expect(wide.inner == shorter.inner)
    }

    @Test("Case 14: a value ending its line where the one other line ends: could not widen, no column, a band made, inner as a shorter value's")
    func endsWhereTheOtherLineEnds() {
        func page(_ letters: Int) -> (Sheet, PlanRegion) {
            var sheet = Sheet()
            sheet.line("abcd abcd", x: 72, y: 700)
            let v = sheet.word(String(repeating: "b", count: letters), x: 128, y: 700)
            sheet.word(String(repeating: "a", count: 19), x: 74, y: 686)
            return (sheet, T.matched(sheet, v))
        }
        let (full, a) = page(10), (short, b) = page(4)
        let exact = T.plan(full, [a], on: true).box(a), shorter = T.plan(short, [b], on: true).box(b)
        #expect(exact.treatment == .couldNotWiden(.noColumn) && exact.bandMade)
        #expect(shorter.treatment == .widened && shorter.bandMade)
        #expect(exact.inner == shorter.inner)
    }

    @Test("A region in a table cell whose rectangle starts 0.3 pt before its letters: the band holds it")
    func bandHoldsTheRegion() {
        var sheet = Sheet()
        var value: Set<Int> = []
        for k in 0..<4 {
            let y = 700 - 14 * Double(k)
            sheet.word("abcd", x: 72, y: y)
            let cell = sheet.word(k == 2 ? "ab" : "abcdefgh", x: 200, y: y)
            if k == 2 { value = cell }
            sheet.word("abcd", x: 330, y: y)
        }
        let region = T.matched(sheet, value, left: 0.3)
        let box = T.plan(sheet, [region], on: true).box(region)
        #expect(box.bandMade && box.inner.minX == T.placed(region).minX)
    }

    // MARK: - Property 2

    @Test("Property 2: two pages that differ only in a value of equal height give the same plan with the switch on")
    func valueLengthMovesNothing() {
        var made: [PaintedBox] = []
        for n in 1...30 {
            let (sheet, v, _) = Self.labelRowWithASecondField(value: String(repeating: "b", count: n))
            let region = T.matched(sheet, v)
            made.append(T.plan(sheet, [region], on: true).box(region))
        }
        for box in made {
            #expect(box.inner == made[0].inner && box.paint == made[0].paint && box.treatment == made[0].treatment)
        }
    }
}
