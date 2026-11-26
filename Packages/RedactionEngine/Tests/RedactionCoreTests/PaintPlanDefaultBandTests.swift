import Foundation
import Testing
import RedactionCore

/// The default band with the switch off: a box placed from the page's typed
/// text, still anchored, on a line whose column is read, grows along its line
/// to its column where nothing else lies, and keeps its line margin
/// otherwise. Pages are drawn as the readings' tests draw them: letters 6 pt
/// wide and 10 pt tall, words 4 pt apart, lines 14 pt apart.
@Suite struct PaintPlanDefaultBandTests {
    typealias Sheet = ComplementReadingTests.Sheet
    typealias T = PaintPlanMakeTests
    static let policy = GeometryPolicy.release

    /// A page whose painting was followed and that draws nothing else.
    static let clear = PageDrawing(read: true, drawsLinesOrShading: false, objects: [])

    static func plan(_ sheet: Sheet, _ regions: [PlanRegion], on: Bool = false,
                     drawing: PageDrawing = clear) -> (plan: PaintPlan, facts: PlanFacts) {
        let words = PageWords(text: sheet.text, boxes: sheet.boxes, source: .textLayer)
        return PaintPlan.make(regions: regions, words: words, text: sheet.text, facts: T.plain, drawing: drawing,
                              widthSixtyFourths: T.W, heightSixtyFourths: T.H, policy: policy,
                              source: .switchPolicy, switchOn: on)
    }

    static func box(_ sheet: Sheet, _ region: PlanRegion, on: Bool = false, drawing: PageDrawing = clear) -> PaintedBox {
        plan(sheet, [region], on: on, drawing: drawing).plan.boxes.first { $0.regionIDs.contains(region.id) }!
    }

    /// A label and a value ending its line, between two lines that run to
    /// 460 pt. The label "Name:" ends at 102 pt; the value starts `gap`
    /// points after it.
    static func labelRow(value: String, gap: Double = 4) -> (sheet: Sheet, label: Set<Int>, value: Set<Int>) {
        var sheet = Sheet()
        sheet.line(count: 14, y: 700)
        let label = sheet.word("Name:", x: 72, y: 686)
        let v = sheet.word(value, x: 102 + gap, y: 686)
        sheet.line(count: 14, y: 672)
        return (sheet, label, v)
    }

    // MARK: - Where the default is taken

    @Test("A value after a label, ending its line: grows to the column, starts at the label's end, the label untouched")
    func labelThenValueGrowsToTheColumn() {
        let (sheet, label, value) = Self.labelRow(value: "Smith")
        let region = T.matched(sheet, value)
        let made = Self.plan(sheet, [region])
        let box = made.plan.boxes[0]
        #expect(box.defaultWidth == .taken && box.bandMade && box.treatment == .notAsked)
        #expect(box.inner.minX == T.s(102) && box.inner.maxX == T.s(460))
        #expect(box.paint.minX == T.s(102), "the margin does not reach into the label")
        #expect(!box.paint.sharesArea(with: T.rect64(sheet, label)), "the word before shares no area with the paint")
        #expect(made.facts.unselectedWordsInsidePaint == 0)
    }

    @Test("The word before stays readable: no letter box of the label shares area with the paint, at any of three values")
    func theWordBeforeStaysReadable() {
        for value in ["Al", "Smith", "Abernathy-Smythe"] {
            let (sheet, label, v) = Self.labelRow(value: value)
            let box = Self.box(sheet, T.matched(sheet, v))
            for offset in label {
                let letter = PageRect64(outward: sheet.boxes.first { $0.offset == offset }!.rect)!
                #expect(!box.paint.sharesArea(with: letter), "\(value): label letter \(offset)")
            }
        }
    }

    @Test("The start does not move with the value's first letter: three spacings after the label give one start edge")
    func oneStartForThreeSpacings() {
        var starts: Set<Int> = [], paints: Set<PageRect64> = []
        for gap in [2.5, 3.25, 4.0] {
            let (sheet, _, value) = Self.labelRow(value: "Smith", gap: gap)
            let box = Self.box(sheet, T.matched(sheet, value))
            #expect(box.defaultWidth == .taken)
            starts.insert(box.inner.minX)
            paints.insert(box.paint)
        }
        #expect(starts == [T.s(102)])
        #expect(paints.count == 1, "the same paint whatever the space before the value")
    }

    @Test("A short value and a long one after the same label get the same paint")
    func shortAndLongValuesPaintTheSame() {
        let paints = ["Al", "Abernathy-Smythe"].map { value -> PageRect64 in
            let (sheet, _, v) = Self.labelRow(value: value)
            return Self.box(sheet, T.matched(sheet, v)).paint
        }
        #expect(paints[0] == paints[1])
    }

    @Test("A block of label rows: with the switch off the label is not taken in as the value's own run")
    func labelBlockLabelNotTaken() {
        let (sheet, value) = ComplementReadingTests.labelBlockBetweenParagraphs()
        let region = T.matched(sheet, value)
        let made = Self.plan(sheet, [region])
        let box = made.plan.boxes.first { $0.regionIDs.contains(region.id) }!
        #expect(box.defaultWidth == .taken)
        #expect(box.inner.minX == T.s(102) && box.inner.maxX == T.s(72 + 28 * 14 - 4))
        #expect(made.facts.unselectedWordsInsidePaint == 0, "the label is not painted over")
        #expect(Self.box(sheet, region, on: true).treatment == .widened, "the switch takes the label in: widened")
    }

    @Test("A value alone on its line grows to the column on both sides")
    func aloneOnItsLineGrowsBothSides() {
        var sheet = Sheet()
        sheet.word(String(repeating: "a", count: 18), x: 72, y: 700)
        let v = sheet.word("Smith", x: 110, y: 686)
        sheet.word(String(repeating: "a", count: 18), x: 72, y: 672)
        let box = Self.box(sheet, T.matched(sheet, v))
        #expect(box.defaultWidth == .taken)
        #expect(box.inner.minX == T.s(72) && box.inner.maxX == T.s(180))
    }

    // MARK: - Never less than the line margin

    /// The pixels a box is painted as, at `dpi`.
    static func pixels(_ b: PaintedBox, dpi: Int) throws -> PixelPlan.PixelRect {
        let raster = try #require(PixelPlan.Raster(widthSixtyFourths: T.W, heightSixtyFourths: T.H, dpi: dpi))
        return try #require(PixelPlan.project(inner: b.inner, paint: b.paint, limitAbove: b.limitAbove,
                                              limitBelow: b.limitBelow, raster: raster)).painted
    }

    /// The default band's box holds the line margin's, in page terms and in
    /// the pixels painted at three resolutions.
    static func expectHoldsTheLineMargin(_ box: PaintedBox, _ lineMargin: PaintedBox) throws {
        #expect(box.paint.contains(lineMargin.paint), "\(box.paint) holds \(lineMargin.paint)")
        for dpi in [72, 150, 300] {
            let a = try pixels(box, dpi: dpi), b = try pixels(lineMargin, dpi: dpi)
            #expect(a.minX <= b.minX && a.minY <= b.minY && a.maxX >= b.maxX && a.maxY >= b.maxY, "at \(dpi) dpi")
        }
    }

    @Test("A value 1 pt after its label: the default band's paint holds the line margin's, though the band starts at the label's end")
    func narrowGapHoldsTheLineMargin() throws {
        let (sheet, _, value) = Self.labelRow(value: "Smith", gap: 1)
        let region = T.matched(sheet, value)
        let box = Self.box(sheet, region)
        let lineMargin = Self.box(sheet, region, drawing: .notRead)
        #expect(box.defaultWidth == .taken && box.bandMade)
        #expect(lineMargin.paint.minX < T.s(102), "the line margin reaches past the label's end, so the case means something")
        try Self.expectHoldsTheLineMargin(box, lineMargin)
    }

    @Test("A line of small type above the band, closer than the line above the value: the default band's paint holds the line margin's")
    func closerSmallTypeNeighbourHoldsTheLineMargin() throws {
        var sheet = Sheet()
        sheet.line(count: 14, y: 704)
        sheet.word("x", x: 300, y: 698, width: 3, height: 4)
        sheet.word("Name:", x: 72, y: 686)
        let value = sheet.word("Smith", x: 106, y: 686)
        sheet.line(count: 14, y: 672)
        let region = T.matched(sheet, value)
        let box = Self.box(sheet, region)
        let lineMargin = Self.box(sheet, region, drawing: .notRead)
        #expect(box.defaultWidth == .taken && box.bandMade)
        #expect(T.s(698) + Self.policy.margin.entry(letterSize: T.s(4)) < lineMargin.paint.maxY,
                "the small line's limit lies below the line margin's top, so the case means something")
        try Self.expectHoldsTheLineMargin(box, lineMargin)
    }

    @Test("A value in mid-line: the paint is today's line margin")
    func midLineKeepsTheLineMargin() {
        var sheet = Sheet()
        let lines = ComplementReadingTests.paragraph(&sheet, counts: [6, 6, 6])
        let region = T.matched(sheet, lines[1][2])
        let box = Self.box(sheet, region)
        let today = Self.box(sheet, region, drawing: .notRead)
        #expect(box.paint == today.paint && box.inner == today.inner && !box.bandMade)
        #expect(box.defaultWidth == .taken)
    }

    @Test("A box painted with its default band carries its line margin for the picture's net; a box whose default adds nothing carries none")
    func defaultBandCarriesItsLineMargin() throws {
        let (sheet, _, value) = Self.labelRow(value: "Smith")
        let region = T.matched(sheet, value)
        let made = Self.plan(sheet, [region])
        let fallback = try #require(made.facts.defaultFallbacks[0])
        let lineMargin = Self.box(sheet, region, drawing: .notRead)
        #expect(fallback.inner == lineMargin.inner && fallback.paint == lineMargin.paint)
        #expect(fallback.limitAbove == lineMargin.limitAbove && fallback.limitBelow == lineMargin.limitBelow)
        #expect(fallback.defaultWidth == .notTaken(.inkInSlot) && !fallback.bandMade)
        #expect(fallback.regionIDs == made.plan.boxes[0].regionIDs)
        var mid = Sheet()
        let lines = ComplementReadingTests.paragraph(&mid, counts: [6, 6, 6])
        #expect(Self.plan(mid, [T.matched(mid, lines[1][2])]).facts.defaultFallbacks.isEmpty)
    }

    // MARK: - Where it is not taken

    @Test("Nothing of the page's drawing read: no default band, the line margin")
    func drawingNotRead() {
        let (sheet, _, value) = Self.labelRow(value: "Smith")
        let region = T.matched(sheet, value)
        let box = Self.box(sheet, region, drawing: .notRead)
        #expect(box.defaultWidth == .notTaken(.drawingNotRead) && !box.bandMade)
        #expect(box.inner == T.rect64(sheet, value).union(T.placed(region)))
    }

    @Test("A page that paints a path or a shading: no default band, for a short value and a long one alike")
    func pageDrawsLines() {
        let lines = PageDrawing(read: true, drawsLinesOrShading: true, objects: [])
        for value in ["Al", "Abernathy-Smythe"] {
            let (sheet, _, v) = Self.labelRow(value: value)
            let region = T.matched(sheet, v)
            let box = Self.box(sheet, region, drawing: lines)
            #expect(box.defaultWidth == .notTaken(.pageDrawsLinesOrShading) && !box.bandMade, "\(value)")
            #expect(box.paint == Self.box(sheet, region, drawing: .notRead).paint, "\(value)")
        }
    }

    @Test("A picture in the slot: no default band, whether it lies past a short value or under a long one")
    func pictureInTheSlot() {
        // The picture lies at 250 to 262 pt along the value's line: past the
        // end of "Al", under the letters of the long value.
        let picture = PageRect64(minX: T.s(250), minY: T.s(687), maxX: T.s(262), maxY: T.s(695))
        let drawing = PageDrawing(read: true, drawsLinesOrShading: false, objects: [picture])
        let long = "Abernathy-Smythe-Abernathy"
        var widths: [DefaultWidth] = []
        for value in ["Al", long] {
            let (sheet, _, v) = Self.labelRow(value: value)
            let region = T.matched(sheet, v)
            let box = Self.box(sheet, region, drawing: drawing)
            widths.append(box.defaultWidth)
            #expect(box.paint == Self.box(sheet, region, drawing: .notRead).paint, "\(value): the line margin")
        }
        #expect(widths == [.notTaken(.wordOrDrawingInBand), .notTaken(.wordOrDrawingInBand)])
        let (sheet, _, v) = Self.labelRow(value: long)
        #expect(T.rect64(sheet, v).sharesArea(with: picture), "the case's picture lies under the long value")
    }

    @Test("A word of another line in the slot (a raised mark): no default band")
    func wordInTheSlot() {
        var (sheet, _, value) = Self.labelRow(value: "Smith")
        sheet.word("x", x: 300, y: 694, width: 4, height: 5)
        let box = Self.box(sheet, T.matched(sheet, value))
        #expect(box.defaultWidth == .notTaken(.wordOrDrawingInBand) && !box.bandMade)
    }

    // MARK: - The switch, against the default

    @Test("With the switch on, a value alone on its line reads already as wide: the default already reaches the column")
    func aloneOnLineAlreadyAsWideAgainstTheDefault() {
        var sheet = Sheet()
        sheet.word(String(repeating: "a", count: 18), x: 72, y: 700)
        let v = sheet.word("Smith", x: 110, y: 686)
        sheet.word(String(repeating: "a", count: 18), x: 72, y: 672)
        let region = T.matched(sheet, v)
        #expect(Self.box(sheet, region, on: true).treatment == .alreadyAsWide)
        #expect(Self.box(sheet, region, on: true, drawing: .notRead).treatment == .widened,
                "against the line margin, the same box reads widened")
    }

    // MARK: - No branch on the selected text

    /// A Latin line with a covered word in the given script.
    static func scriptLine(_ covered: String, rest: String = "abcd") -> (Sheet, Set<Int>) {
        var sheet = Sheet()
        sheet.line(count: 14, y: 700)
        sheet.word(rest, x: 72, y: 686)
        let v = sheet.word(covered, x: 102, y: 686)
        sheet.line(count: 14, y: 672)
        return (sheet, v)
    }

    @Test("Two pages that differ only in the covered word's script paint the same with the switch off")
    func coveredScriptDoesNotTurnThePaint() {
        let (latin, a) = Self.scriptLine("abcde")
        let (hebrew, b) = Self.scriptLine("\u{05D0}\u{05D1}\u{05D2}\u{05D3}\u{05D4}")
        let pa = Self.box(latin, T.matched(latin, a)), pb = Self.box(hebrew, T.matched(hebrew, b))
        #expect(pa.paint == pb.paint && pa.defaultWidth == .taken && pb.defaultWidth == .taken)
    }

    @Test("A value alone on its line in a right-to-left script paints as a Latin one: its own letters are not read")
    func loneValueScriptNotRead() {
        func page(_ value: String) -> PaintedBox {
            var sheet = Sheet()
            sheet.word(String(repeating: "a", count: 18), x: 72, y: 700)
            let v = sheet.word(value, x: 110, y: 686)
            sheet.word(String(repeating: "a", count: 18), x: 72, y: 672)
            return Self.box(sheet, T.matched(sheet, v))
        }
        let latin = page("abcde"), hebrew = page("\u{05D0}\u{05D1}\u{05D2}\u{05D3}\u{05D4}")
        #expect(latin.paint == hebrew.paint && hebrew.defaultWidth == .taken)
    }

    @Test("A line whose unselected words are right to left reads its direction: the fixed margin, whatever is covered")
    func unselectedRightToLeftReadsDirection() {
        let (sheet, v) = Self.scriptLine("abcde", rest: "\u{05D0}\u{05D1}\u{05D2}\u{05D3}")
        let region = T.matched(sheet, v)
        let box = Self.box(sheet, region)
        let placed = T.placed(region), m = Self.policy.fixedMarginSixtyFourths
        #expect(box.paint == PageRect64(minX: placed.minX - m, minY: placed.minY - m, maxX: placed.maxX + m, maxY: placed.maxY + m))
        #expect(box.defaultWidth == .notAsked)
    }
}
