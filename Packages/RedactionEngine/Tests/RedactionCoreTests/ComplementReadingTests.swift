import Foundation
import Testing
import RedactionCore

/// The complement's readings on hand-built pages: lines, runs, the stack, the room,
/// the column, the bridges, direction and trust. Every page is drawn on whole
/// sixty-fourths of a point, so turning a box into sixty-fourths moves
/// nothing. Letters are 6 pt wide and 10 pt tall, words 4 pt apart, lines
/// 14 pt apart (4 pt free between them) unless a case says otherwise.
@Suite struct ComplementReadingTests {
    static let constants = GeometryPolicy.release.provisional
    static let plain = PageTextFacts(showsInvisibleText: false, carriesPageScaleImage: false)

    /// A page drawn word by word.
    struct Sheet {
        var text = ""
        var boxes: [LetterBox] = []

        /// One word whose characters have the given boxes, one box for each
        /// character (every UTF-16 unit of a character gets its box).
        @discardableResult
        mutating func word(_ s: String, rects: [PointRect]) -> Set<Int> {
            precondition(s.count == rects.count)
            if !text.isEmpty { text += " " }
            var offsets: Set<Int> = []
            for (character, rect) in zip(s, rects) {
                let start = text.utf16.count
                text.append(character)
                for offset in start..<text.utf16.count {
                    boxes.append(LetterBox(offset: offset, rect: rect))
                    offsets.insert(offset)
                }
            }
            return offsets
        }

        /// One word of letters `width` by `height`, each next letter `dx`
        /// right (the width when nil) and `dy` up of the one before.
        @discardableResult
        mutating func word(_ s: String, x: Double, y: Double, width: Double = 6, height: Double = 10,
                           dx: Double? = nil, dy: Double = 0) -> Set<Int> {
            let step = dx ?? width
            return word(s, rects: (0..<s.count).map { i in
                PointRect(minX: x + step * Double(i), minY: y + dy * Double(i),
                          maxX: x + step * Double(i) + width, maxY: y + dy * Double(i) + height)
            })
        }

        /// A line of upright words, 4 pt apart, from `x`.
        @discardableResult
        mutating func line(_ words: String, x: Double, y: Double) -> [Set<Int>] {
            var at = x
            return words.split(separator: " ").map { w in
                defer { at += Double(w.count) * 6 + 4 }
                return word(String(w), x: at, y: y)
            }
        }

        /// `count` words of four letters from x = 72: they end at 72 + 28 × count − 4.
        @discardableResult
        mutating func line(count: Int, y: Double, x: Double = 72) -> [Set<Int>] {
            line(Array(repeating: "abcd", count: count).joined(separator: " "), x: x, y: y)
        }
    }

    struct Read {
        var page: PageComplement
        var box: BoxReading
        var row: RowReading { box.rows[0] }
        func line(at y: Double) -> Int? { page.lines.firstIndex { $0.box.minY == s(y) } }
    }

    static func read(_ sheet: Sheet, _ box: Set<Int>, alsoSelected: Set<Int> = [], facts: PageTextFacts = plain,
                     source: WordSource = .textLayer, constants: ProvisionalConstants = constants) throws -> Read {
        let words = PageWords(text: sheet.text, boxes: sheet.boxes, source: source)
        let page = Complement.page(words: words, text: sheet.text, selected: box.union(alsoSelected), constants: constants)
        let reading = try #require(Complement.reading(of: box, on: page, words: words, text: sheet.text,
                                                      facts: facts, constants: constants))
        return Read(page: page, box: reading)
    }

    static func page(_ sheet: Sheet) -> PageComplement {
        Complement.page(words: PageWords(text: sheet.text, boxes: sheet.boxes, source: .textLayer),
                        text: sheet.text, selected: [], constants: constants)
    }

    /// A paragraph of lines from y = 700 down, 14 pt apart; returns each line's words.
    static func paragraph(_ sheet: inout Sheet, counts: [Int], top: Double = 700, pitch: Double = 14) -> [[Set<Int>]] {
        counts.enumerated().map { k, n in sheet.line(count: n, y: top - pitch * Double(k)) }
    }

    /// The reading with each row's tight rectangle taken out, and the page's
    /// lines and runs by their boxes alone: what property 2 compares.
    static func withoutTight(_ read: Read) -> (BoxReading, [[PageRect64]]) {
        var box = read.box
        for i in box.rows.indices { box.rows[i].tight = PageRect64(minX: 0, minY: 0, maxX: 0, maxY: 0) }
        return (box, read.page.lines.map { [$0.box] + $0.runs.map(\.box) })
    }

    // MARK: - Lines, runs and the stack's spacing: each constant on both sides

    @Test("Two words are one line when their heights overlap by more than half the smaller, two lines at exactly half")
    func linesJoinPastHalfTheSmallerHeight() {
        var atHalf = Sheet()
        atHalf.word("abcd", x: 72, y: 700)
        atHalf.word("abcd", x: 200, y: 695)
        #expect(Self.page(atHalf).lines.count == 2)
        var past = Sheet()
        past.word("abcd", x: 72, y: 700)
        past.word("abcd", x: 200, y: 695 + 1.0 / 64)
        #expect(Self.page(past).lines.count == 1)
    }

    @Test("A gap of one line height keeps a run; one sixty-fourth more ends it")
    func runGapBoundary() {
        var at = Sheet()
        at.word("abcd", x: 72, y: 700)
        at.word("abcd", x: 106, y: 700)
        #expect(Self.page(at).lines[0].runs.count == 1)
        var past = Sheet()
        past.word("abcd", x: 72, y: 700)
        past.word("abcd", x: 106 + 1.0 / 64, y: 700)
        #expect(Self.page(past).lines[0].runs.count == 2)
        #expect(!Complement.breaksRun(gap: 640, height: 640, constants: Self.constants))
        #expect(Complement.breaksRun(gap: 641, height: 640, constants: Self.constants))
    }

    @Test("The ordinary gap needs four gaps; it is counted in half-point steps, a half step rounding up, the smaller on a tie")
    func ordinaryGapSteps() {
        func gaps(_ free: [Double]) -> Int? {
            var sheet = Sheet()
            var y = 700.0
            sheet.line(count: 3, y: y)
            for f in free { y -= 10 + f; sheet.line(count: 3, y: y) }
            return Self.page(sheet).ordinaryGap
        }
        #expect(gaps([4, 4, 4]) == nil)
        #expect(gaps([4, 4, 4, 4]) == 256)
        #expect(gaps([4 + 15.0 / 64, 4 + 15.0 / 64, 4 + 15.0 / 64, 4 + 15.0 / 64]) == 256)
        #expect(gaps([4.25, 4.25, 4.25, 4.25]) == 288)
        #expect(gaps([4, 4, 5, 5]) == 256)
        #expect(gaps([5, 4, 5, 4, 5]) == 320)
    }

    @Test("Two lines keep the stack's spacing up to the ordinary gap plus half the smaller height; with no ordinary gap, under one height")
    func spacingBoundary() {
        let c = Self.constants
        #expect(Complement.keepsSpacing(free: 256 + 320, height: 640, ordinaryGap: 256, constants: c))
        #expect(!Complement.keepsSpacing(free: 256 + 321, height: 640, ordinaryGap: 256, constants: c))
        #expect(Complement.keepsSpacing(free: 639, height: 640, ordinaryGap: nil, constants: c))
        #expect(!Complement.keepsSpacing(free: 640, height: 640, ordinaryGap: nil, constants: c))
    }

    @Test("A double-spaced paragraph is one stack: its gaps are the ordinary gap")
    func doubleSpacedParagraph() throws {
        var sheet = Sheet()
        let lines = Self.paragraph(&sheet, counts: [6, 5, 6, 6, 4, 5], pitch: 24)
        let r = try Self.read(sheet, lines[2][2])
        #expect(r.page.ordinaryGap == 14 * 64)
        #expect(r.box.stack.count == 5)
        #expect(r.box.outsideAbove == nil && r.box.outsideBelow == nil)
    }

    // MARK: - Part N's cases, on the readings

    @Test("A six-line paragraph, the value in mid-line: five lines bridge and the own run is the whole line")
    func sixLineParagraph() throws {
        var sheet = Sheet()
        let lines = Self.paragraph(&sheet, counts: [6, 5, 6, 6, 4, 5])
        let r = try Self.read(sheet, lines[2][2])
        #expect(r.box.reading == .column)
        #expect(r.box.stack.count == 5)
        #expect(r.row.roomLeft == Self.s(124) && r.row.roomRight == Self.s(156))
        #expect(r.row.bridges.count == 5)
        let line = try #require(r.row.line)
        #expect(r.row.ownRun == r.page.lines[line].box)
        // The room is closed on both sides: the column is read inside it.
        #expect(r.row.columnLeft == Self.s(124) && r.row.columnRight == Self.s(156))
    }

    @Test("A two-line paragraph standing alone, the value in mid-line 1: one bridge, no own run")
    func twoLineParagraphAlone() throws {
        var sheet = Sheet()
        let lines = Self.paragraph(&sheet, counts: [5, 5])
        let r = try Self.read(sheet, lines[0][2])
        #expect(r.box.reading == .column)
        #expect(r.box.stack.count == 1)
        #expect(r.row.bridges.count == 1)
        #expect(r.row.ownRun == nil)
    }

    @Test("A line alone on a page reads no column")
    func lineAlone() throws {
        var sheet = Sheet()
        let line = sheet.line(count: 3, y: 700)
        let r = try Self.read(sheet, line[1])
        #expect(r.box.reading == .noColumn)
        #expect(r.box.stack.isEmpty && r.box.outsideAbove == nil && r.box.outsideBelow == nil)
        #expect(r.row.bridges.isEmpty && r.row.ownRun == nil)
    }

    @Test("Two columns of one line each under a full-width title: the title is one bridge, not two")
    func twoColumnsUnderATitle() throws {
        var sheet = Sheet()
        sheet.line(count: 14, y: 700)
        let left = sheet.line(count: 2, y: 686)
        sheet.line(count: 2, y: 686, x: 300)
        let r = try Self.read(sheet, left[1])
        #expect(r.row.roomLeft == Self.s(96) && r.row.roomRight == Self.s(300))
        #expect(r.row.bridges.count == 1)
        #expect(r.row.ownRun == nil)
    }

    @Test("One table row under a merged header: the header is one bridge; no word beside the cell is the box's own")
    func tableRowUnderAMergedHeader() throws {
        var sheet = Sheet()
        sheet.line(count: 12, y: 700)
        sheet.word("abcd", x: 72, y: 686)
        let cell = sheet.word("abcd", x: 200, y: 686)
        sheet.word("abcd", x: 330, y: 686)
        let r = try Self.read(sheet, cell)
        #expect(r.row.bridges.count == 1)
        #expect(r.row.ownRun == nil)
        #expect(r.row.columnLeft == Self.s(96) && r.row.columnRight == Self.s(330))
    }

    /// Five label rows "Name: <ten letters>   Date: 12"; row 2's value is `value`.
    static func labelRows(value: String) -> (Sheet, Set<Int>) {
        var sheet = Sheet()
        var box: Set<Int> = []
        for k in 0..<5 {
            let y = 700 - 14 * Double(k)
            sheet.word("Name:", x: 72, y: y)
            let v = sheet.word(k == 2 ? value : "Abcdefghij", x: 108, y: y)
            if k == 2 { box = v }
            sheet.line("Date: 12", x: 300, y: y)
        }
        return (sheet, box)
    }

    @Test("A label row with a second field: a short value and a long one in the same room read the same")
    func shortAndLongValueReadTheSame() throws {
        let (short, s) = Self.labelRows(value: "Ann")
        let (long, l) = Self.labelRows(value: "Annabellexyz")
        let a = try Self.read(short, s), b = try Self.read(long, l)
        #expect(a.row.tight != b.row.tight)
        #expect(Self.withoutTight(a) == Self.withoutTight(b))
        #expect(a.row.roomLeft == Self.s(102) && a.row.roomRight == Self.s(300))
        #expect(a.row.bridges.isEmpty && a.row.ownRun == nil)
    }

    /// Three paragraph lines, a block of five label rows 16 pt below, three
    /// paragraph lines 16 pt below that. The value of row 2 is the longest.
    static func labelBlockBetweenParagraphs(noteOnRow: Int? = nil) -> (Sheet, Set<Int>) {
        var sheet = Sheet()
        for k in 0..<3 { sheet.line(count: 14, y: 700 - 14 * Double(k)) }
        var box: Set<Int> = []
        for k in 0..<5 {
            let y = 646 - 14 * Double(k)
            sheet.word("Abcd:", x: 72, y: y)
            let v = sheet.word(k == 2 ? "Abcdefghijklmnopqrst" : "Abcdefghij", x: 108, y: y)
            if k == 2 { box = v }
            if k == noteOnRow { sheet.word("Note", x: 380, y: y) }
        }
        for k in 0..<3 { sheet.line(count: 14, y: 564 - 14 * Double(k)) }
        return (sheet, box)
    }

    @Test("A block of label rows between two full-measure paragraphs, the value's row the longest: the column is the paragraphs' reach")
    func labelBlockReadsTheParagraphs() throws {
        let (sheet, box) = Self.labelBlockBetweenParagraphs()
        let r = try Self.read(sheet, box)
        #expect(r.box.stack.count == 4)
        #expect(r.box.outsideAbove == r.line(at: 672) && r.box.outsideBelow == r.line(at: 564))
        #expect(r.row.roomLeft == Self.s(102) && r.row.roomRight == nil)
        // Closed on the left by the label: the column is read no further left than it.
        #expect(r.row.columnLeft == Self.s(102))
        #expect(r.row.columnRight == Self.s(72 + 28 * 14 - 4))
        #expect(r.row.bridges.count == 6)
        #expect(r.row.ownRun == PageRect64(minX: Self.s(72), minY: Self.s(618), maxX: Self.s(102), maxY: Self.s(628)))
    }

    @Test("The same block with a note beside one row: the outside lines are not read on that side")
    func noteBesideARowKeepsTheOutsideLinesOut() throws {
        let (sheet, box) = Self.labelBlockBetweenParagraphs(noteOnRow: 0)
        let r = try Self.read(sheet, box)
        #expect(r.row.columnRight == Self.s(168))
        #expect(r.row.columnLeft == Self.s(102))
        #expect(r.row.bridges.isEmpty)
    }

    @Test("A left-column paragraph under a full-width title, the box ending its line: only the title bridges")
    func leftColumnUnderATitle() throws {
        var sheet = Sheet()
        sheet.line(count: 14, y: 700)
        var box: Set<Int> = []
        for k in 0..<4 {
            let y = 686 - 14 * Double(k)
            let left = sheet.line(count: 4, y: y)
            if k == 1 { box = left[3] }
            sheet.line(count: 4, y: y, x: 300)
        }
        let r = try Self.read(sheet, box)
        #expect(r.row.roomRight == Self.s(300))
        let title = try #require(r.line(at: 700))
        #expect(r.row.bridges == [title])
        #expect(r.row.ownRun == nil)
        #expect(try #require(r.row.columnRight) <= Self.s(300))
    }

    @Test("A one-line paragraph ending its line in the left column, the right column beside the lines above and below: no line bridges")
    func linesThatAreNotTheLastRunOfTheirLineDoNotBridge() throws {
        var sheet = Sheet()
        sheet.line(count: 4, y: 700)
        sheet.line(count: 3, y: 700, x: 300)
        let own = sheet.line(count: 3, y: 674)
        sheet.line(count: 4, y: 648)
        sheet.line(count: 3, y: 648, x: 300)
        let r = try Self.read(sheet, own[2])
        #expect(r.box.stack.isEmpty)
        #expect(r.box.outsideAbove != nil && r.box.outsideBelow != nil)
        #expect(r.row.roomRight == nil)
        #expect(r.row.bridges.isEmpty && r.row.ownRun == nil)
        // The outside lines' right-column runs do not meet the box's line.
        #expect(r.row.columnRight == Self.s(180))
    }

    @Test("Two columns, the right one a line shorter, the box ending the left column's last line: the column stops at the gutter")
    func shorterRightColumnKeepsTheBandInItsColumn() throws {
        var sheet = Sheet()
        var box: Set<Int> = []
        for k in 0..<6 {
            let y = 700 - 14 * Double(k)
            let left = sheet.line(count: k == 5 ? 3 : 6, y: y)
            if k == 5 { box = left[2] }
            if k < 5 { sheet.line(count: 6, y: y, x: 300) }
        }
        let r = try Self.read(sheet, box)
        #expect(r.box.stack.count == 5)
        #expect(r.row.roomRight == nil)
        #expect(r.row.columnRight == Self.s(72 + 28 * 6 - 4))
        #expect(r.row.bridges.isEmpty && r.row.ownRun == nil)
    }

    @Test("A fixed table, the value in a middle cell: the column is its own column's cells, never the row")
    func fixedTableReadsItsOwnColumn() throws {
        var sheet = Sheet()
        var box: Set<Int> = []
        for k in 0..<4 {
            let y = 700 - 14 * Double(k)
            sheet.word(k == 0 ? "abcdefghijkl" : "abcd", x: 72, y: y)
            let cell = sheet.word(k == 3 ? "abc" : "abcdef", x: 180, y: y)
            if k == 2 { box = cell }
            sheet.word("abcd", x: 300, y: y)
        }
        let r = try Self.read(sheet, box)
        #expect(r.row.roomLeft == Self.s(96) && r.row.roomRight == Self.s(300))
        #expect(r.row.columnLeft == Self.s(180) && r.row.columnRight == Self.s(216))
        #expect(r.row.bridges.isEmpty)
    }

    @Test("An address boxed line by line between two paragraphs: each box reads the paragraphs' column")
    func addressBoxedLineByLine() throws {
        var sheet = Sheet()
        for k in 0..<3 { sheet.line(count: 14, y: 700 - 14 * Double(k)) }
        let address = (0..<3).map { k in sheet.line(count: 3, y: 646 - 14 * Double(k)).reduce(into: Set<Int>()) { $0.formUnion($1) } }
        for k in 0..<3 { sheet.line(count: 14, y: 592 - 14 * Double(k)) }
        let r = try Self.read(sheet, address[1], alsoSelected: address[0].union(address[2]))
        #expect(r.box.reading == .column)
        #expect(r.box.stack.isEmpty)
        #expect(r.box.outsideAbove == r.line(at: 672) && r.box.outsideBelow == r.line(at: 592))
        #expect(r.row.line == nil)
        #expect(r.row.columnRight == Self.s(72 + 28 * 14 - 4))
    }

    @Test("Six label rows: row 3's column is the other five rows' reach")
    func sixLabelRows() throws {
        var sheet = Sheet()
        var box: Set<Int> = []
        let lengths = [10, 14, 8, 6, 12, 9]
        for (k, n) in lengths.enumerated() {
            let y = 700 - 14 * Double(k)
            sheet.word("Abcd:", x: 72, y: y)
            let v = sheet.word(String(repeating: "a", count: n), x: 108, y: y)
            if k == 3 { box = v }
        }
        let r = try Self.read(sheet, box)
        #expect(r.box.stack.count == 5)
        #expect(r.row.columnLeft == Self.s(102))
        #expect(r.row.columnRight == Self.s(108 + 6 * 14))
    }

    @Test("A neighbouring line wholly selected gives nothing: the stack stops where it stood")
    func whollySelectedNeighbourGivesNothing() throws {
        var sheet = Sheet()
        let lines = Self.paragraph(&sheet, counts: [6, 5, 6, 6, 4, 5])
        let r = try Self.read(sheet, lines[2][2], alsoSelected: lines[1].reduce(into: Set<Int>()) { $0.formUnion($1) })
        #expect(r.line(at: 686) == nil)
        #expect(r.box.stack.count == 3)
        #expect(r.box.outsideAbove == r.line(at: 700))
    }

    @Test("Bridging a room open on the right: a run past the word before by one line height bridges, one sixty-fourth less does not")
    func bridgeRunsOnByOneLineHeight() throws {
        func bridges(past: Double) throws -> Int {
            var sheet = Sheet()
            // The box's line: two words and the value; the room opens after "abcd abcd" (ends at 124).
            // The lines above and below: one word from 72 to 124 + `past`.
            func reaching(_ y: Double) -> [PointRect] {
                (0..<9).map { i in PointRect(minX: 72 + 6 * Double(i), minY: y, maxX: 78 + 6 * Double(i), maxY: y + 10) }
                    + [PointRect(minX: 126, minY: y, maxX: 124 + past, maxY: y + 10)]
            }
            sheet.word("abcdefghij", rects: reaching(700))
            let own = sheet.line(count: 3, y: 686)
            sheet.word("abcdefghij", rects: reaching(672))
            return try Self.read(sheet, own[2]).row.bridges.count
        }
        #expect(try bridges(past: 10) == 2)
        #expect(try bridges(past: 10 - 1.0 / 64) == 0)
    }

    // MARK: - Property 2

    @Test("Property 2: pages that differ only in the selected characters read the same, apart from the tight rectangle")
    func selectedTextChangesNothingButTheTightRectangle() throws {
        // A paragraph, the value in mid-line (a room 32 pt wide).
        func paragraph(_ value: String) throws -> Read {
            var sheet = Sheet()
            var box: Set<Int> = []
            for (k, n) in [6, 5, 6, 6].enumerated() {
                let y = 700 - 14 * Double(k)
                if k == 2 {
                    sheet.line(count: 2, y: y)
                    box = sheet.word(value, x: 128, y: y)
                    sheet.line(count: 3, y: y, x: 156)
                } else { sheet.line(count: n, y: y) }
            }
            return try Self.read(sheet, box)
        }
        #expect(Self.withoutTight(try paragraph("ab")) == Self.withoutTight(try paragraph("abcd")))
        // The left column's last line, the right column a line shorter.
        func columns(_ value: String) throws -> Read {
            var sheet = Sheet()
            var box: Set<Int> = []
            for k in 0..<4 {
                let y = 700 - 14 * Double(k)
                if k == 3 { sheet.line(count: 2, y: y); box = sheet.word(value, x: 128, y: y) }
                else { sheet.line(count: 6, y: y); sheet.line(count: 6, y: y, x: 300) }
            }
            return try Self.read(sheet, box)
        }
        #expect(Self.withoutTight(try columns("ab")) == Self.withoutTight(try columns("abcdefghijklmn")))
        let (a, sa) = Self.labelBlockBetweenParagraphs(), r1 = try Self.read(a, sa)
        // The same page with the value one letter shorter.
        var b = Sheet()
        for k in 0..<3 { b.line(count: 14, y: 700 - 14 * Double(k)) }
        var sb: Set<Int> = []
        for k in 0..<5 {
            let y = 646 - 14 * Double(k)
            b.word("Abcd:", x: 72, y: y)
            let v = b.word(k == 2 ? "Abcdefghijklmnopqrs" : "Abcdefghij", x: 108, y: y)
            if k == 2 { sb = v }
        }
        for k in 0..<3 { b.line(count: 14, y: 564 - 14 * Double(k)) }
        #expect(Self.withoutTight(r1) == Self.withoutTight(try Self.read(b, sb)))
        // A label row with a second field, its value short or long: the rows
        // beside it hold values that reach past the short one and not the long.
        let (short, ss) = Self.labelRows(value: "Ann"), (long, sl) = Self.labelRows(value: "Annabellexyz")
        #expect(Self.withoutTight(try Self.read(short, ss)) == Self.withoutTight(try Self.read(long, sl)))
    }

    // MARK: - Direction (K.3, AB.4)

    /// A three-line paragraph whose middle line holds `middle` (drawn by the
    /// closure from x = 72) and then two words; the box is the last word.
    static func block(middle: (inout Sheet, Double) -> Void) throws -> Read {
        var sheet = Sheet()
        sheet.line(count: 8, y: 700)
        middle(&sheet, 686)
        let own = sheet.line(count: 2, y: 686, x: 260)
        sheet.line(count: 8, y: 672)
        return try Self.read(sheet, own[1])
    }

    @Test("A raised mark in a level line is no evidence")
    func raisedMark() throws {
        let r = try Self.block { sheet, y in
            sheet.word("mc2", rects: [PointRect(minX: 72, minY: y, maxX: 78, maxY: y + 10),
                                      PointRect(minX: 78, minY: y, maxX: 84, maxY: y + 10),
                                      PointRect(minX: 84, minY: y + 6, maxX: 88, maxY: y + 12)])
        }
        #expect(r.box.reading == .column)
    }

    @Test("Small capitals are no evidence")
    func smallCapitals() throws {
        let r = try Self.block { sheet, y in
            sheet.word("SMITH", rects: [PointRect(minX: 72, minY: y, maxX: 78, maxY: y + 10)]
                + (0..<4).map { i in PointRect(minX: 78 + 5 * Double(i), minY: y, maxX: 83 + 5 * Double(i), maxY: y + 7) })
        }
        #expect(r.box.reading == .column)
    }

    @Test("Print turned a quarter each way, and a half turn, is direction")
    func turnedPrint() throws {
        for (dx, dy) in [(0.0, 6.0), (0.0, -6.0), (-6.0, 0.0)] {
            var sheet = Sheet()
            sheet.line(count: 8, y: 700)
            let turned = sheet.word("abcd", rects: (0..<4).map { i in
                let x = 200 + dx * Double(i), y = 640 + dy * Double(i)
                return dx == 0 ? PointRect(minX: x, minY: y, maxX: x + 10, maxY: y + 6)
                               : PointRect(minX: x, minY: y, maxX: x + 6, maxY: y + 10)
            })
            sheet.line(count: 8, y: 600)
            let r = try Self.read(sheet, turned)
            #expect(r.box.reading == .direction, "turned \(dx), \(dy)")
            #expect(r.box.rows.isEmpty && r.box.stack.isEmpty)
        }
    }

    @Test("A line slanted about half a degree reads level; about two degrees is direction")
    func slant() throws {
        func reading(rise: Double) throws -> LineReading {
            try Self.block { sheet, y in sheet.word("abcdefghij", x: 72, y: y, dy: rise) }.box.reading
        }
        #expect(try reading(rise: 3.0 / 64) == .column)
        #expect(try reading(rise: 13.0 / 64) == .direction)
    }

    @Test("The level test's edge: a rise of 17,455 millionths of the run is level, one sixty-fourth more is not")
    func levelSlopeBoundary() {
        // Run 200,000 sixty-fourths (3,125 pt); 17,455 millionths of it is 3,491 sixty-fourths.
        func usable(rise: Int) -> Bool {
            var sheet = Sheet()
            sheet.word("ab", rects: [PointRect(minX: 0, minY: 0, maxX: 6, maxY: 120),
                                     PointRect(minX: 3125, minY: Double(rise) / 64, maxX: 3131, maxY: Double(rise) / 64 + 120)])
            return Self.page(sheet).usable[0]
        }
        #expect(usable(rise: 3491))
        #expect(!usable(rise: 3492))
        #expect(!usable(rise: -3492))
    }

    @Test("A vertical column of upright letters is direction")
    func verticalColumn() throws {
        var sheet = Sheet()
        sheet.line(count: 8, y: 700)
        let column = sheet.word("abcd", x: 200, y: 660, dx: 0, dy: -12)
        sheet.line(count: 8, y: 580)
        #expect(try Self.read(sheet, column).box.reading == .direction)
    }

    @Test("A line with one right-to-left word is direction, though its letters advance to the right")
    func rightToLeftWord() throws {
        let r = try Self.block { sheet, y in sheet.word("\u{05E9}\u{05DC}\u{05D5}\u{05DD}", x: 72, y: y) }
        #expect(r.box.reading == .direction)
    }

    @Test("A boxed right-to-left word gives its own box the reason (the box's own line counts its selected words)")
    func selectedRightToLeftWordOnTheBoxsLine() throws {
        var sheet = Sheet()
        sheet.line(count: 8, y: 700)
        sheet.line(count: 2, y: 686)
        let hebrew = sheet.word("\u{05E9}\u{05DC}\u{05D5}\u{05DD}", x: 128, y: 686)
        sheet.line(count: 8, y: 672)
        #expect(try Self.read(sheet, hebrew).box.reading == .direction)
    }

    @Test("A line of single letters inside a level block is read as its block; the same line alone reads no column")
    func singleLetters() throws {
        var sheet = Sheet()
        sheet.line(count: 8, y: 700)
        let letters = sheet.line("a b c d e f", x: 72, y: 686)
        sheet.line(count: 8, y: 672)
        #expect(try Self.read(sheet, letters[2]).box.reading == .column)
        var alone = Sheet()
        let line = alone.line("a b c d e f", x: 72, y: 686)
        #expect(try Self.read(alone, line[2]).box.reading == .noColumn)
    }

    @Test("A letter with a combining mark, and a two-letter joined glyph, are no evidence")
    func markAndJoinedGlyph() throws {
        let mark = try Self.block { sheet, y in sheet.word("e\u{301}", x: 72, y: y) }
        #expect(mark.box.reading == .column)
        let glyph = try Self.block { sheet, y in
            let r = PointRect(minX: 72, minY: y, maxX: 80, maxY: y + 10)
            sheet.word("fi", rects: [r, r])
        }
        #expect(glyph.box.reading == .column)
    }

    @Test("A word whose letters lie on two printed rows 2.5 pt apart is evidence by its rows, though its first and last share a row")
    func wordOnTwoRows() throws {
        let r = try Self.block { sheet, y in
            // "OakOakfoarfor": the first and last letters on the upper row, the middle ones on the lower.
            let upper = (0..<3).map { i in PointRect(minX: 72 + 6 * Double(i), minY: y, maxX: 78 + 6 * Double(i), maxY: y + 10) }
            let lower = (0..<3).map { i in PointRect(minX: 72 + 6 * Double(i), minY: y - 12.5, maxX: 78 + 6 * Double(i), maxY: y - 2.5) }
            let tail = (0..<2).map { i in PointRect(minX: 90 + 6 * Double(i), minY: y, maxX: 96 + 6 * Double(i), maxY: y + 10) }
            sheet.word("OakOakfo", rects: upper + lower + tail)
        }
        #expect(r.box.reading == .direction)
    }

    @Test("Another line's evidence is not this box's: the line is left out of the stack, and the box still reads its column")
    func neighbourEvidenceStaysWithItsLine() throws {
        var sheet = Sheet()
        sheet.line(count: 6, y: 700)
        sheet.word("\u{05E9}\u{05DC}\u{05D5}\u{05DD}", x: 260, y: 700)
        let own = sheet.line(count: 6, y: 686)
        sheet.line(count: 6, y: 672)
        let r = try Self.read(sheet, own[2])
        #expect(r.box.reading == .column)
        let below = try #require(r.line(at: 672)), above = try #require(r.line(at: 700))
        #expect(r.box.stack == [below])
        #expect(r.page.usable[above] == false)
    }

    @Test("A neighbour line is judged from its unselected words: a boxed right-to-left word there leaves it usable")
    func neighbourJudgedFromItsUnselectedWords() throws {
        var sheet = Sheet()
        sheet.line(count: 6, y: 700)
        let hebrew = sheet.word("\u{05E9}\u{05DC}\u{05D5}\u{05DD}", x: 260, y: 700)
        let own = sheet.line(count: 6, y: 686)
        sheet.line(count: 6, y: 672)
        let r = try Self.read(sheet, own[2], alsoSelected: hebrew)
        #expect(r.box.stack.count == 2)
    }

    @Test("Arabic-Indic digits and a mark on a neighbour line are not letters: the line stays usable")
    func digitsAndMarksAreNotEvidence() throws {
        var sheet = Sheet()
        sheet.line(count: 6, y: 700)
        sheet.word("\u{0660}\u{0661}\u{0662}\u{064B}", x: 260, y: 700)
        let own = sheet.line(count: 6, y: 686)
        sheet.line(count: 6, y: 672)
        #expect(try Self.read(sheet, own[2]).box.stack.count == 2)
    }

    // MARK: - Trust

    @Test("Recognised words, invisible text and a page-scale picture read no layout; a sideways scan is scan, not direction")
    func trust() throws {
        var sheet = Sheet()
        let lines = Self.paragraph(&sheet, counts: [5, 5, 5])
        let box = lines[1][2]
        #expect(try Self.read(sheet, box).box.reading == .column)
        #expect(try Self.read(sheet, box, source: .recognised).box.reading == .scanOrPicture)
        #expect(try Self.read(sheet, box, source: .inkTokens).box.reading == .scanOrPicture)
        #expect(try Self.read(sheet, box, facts: PageTextFacts(showsInvisibleText: true, carriesPageScaleImage: false)).box.reading == .scanOrPicture)
        let picture = try Self.read(sheet, box, facts: PageTextFacts(showsInvisibleText: false, carriesPageScaleImage: true))
        #expect(picture.box.reading == .scanOrPicture && picture.box.rows.isEmpty && !picture.box.trusted)
        var sideways = Sheet()
        let turned = sideways.word("abcd", x: 200, y: 640, width: 10, height: 6, dx: 0, dy: 6)
        #expect(try Self.read(sideways, turned, source: .recognised).box.reading == .scanOrPicture)
    }

    @Test("No selected letter with a box gives no reading")
    func unboxedBoxGivesNoReading() {
        var sheet = Sheet()
        sheet.line(count: 3, y: 700)
        sheet.text += " abc"
        let words = PageWords(text: sheet.text, boxes: sheet.boxes, source: .textLayer)
        let unboxed = Set((sheet.text.utf16.count - 3)..<sheet.text.utf16.count)
        let page = Complement.page(words: words, text: sheet.text, selected: unboxed, constants: Self.constants)
        #expect(Complement.reading(of: unboxed, on: page, words: words, text: sheet.text, facts: Self.plain,
                                   constants: Self.constants) == nil)
    }
}

/// Whole sixty-fourths of `points`.
private func s(_ points: Double) -> Int { Int(points * 64) }

extension ComplementReadingTests {
    static func s(_ points: Double) -> Int { Int(points * 64) }
}
