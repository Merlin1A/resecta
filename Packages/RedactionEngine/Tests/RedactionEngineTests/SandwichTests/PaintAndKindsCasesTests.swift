import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import RedactionEngine

// Which letters leave for a box, by each rectangle's kind and by the paint.
// The text path is handed its rectangles directly: no plan exists here, so a
// plan's rectangle and the painted rectangles of each quality are written by
// hand for each page. Every page runs the shared assertion
// (`WholeWordAssertion`). The pages are lines of invented words, each letter
// a box of the type's advance by its size, drawn by nothing and never stored.

@Suite("Which letters leave for a box, by its kind and by the paint")
struct PaintAndKindsCasesTests {

    // MARK: - Pages

    /// A page of lines: each letter a box `advance` wide and `size` tall, the
    /// lines `leading` apart from a first baseline at `top`, a space
    /// `spaceWidth` wide. Words are numbered across the page at each run of
    /// white space.
    struct Page {
        var lines: [String]
        var size: CGFloat = 11
        var leading: CGFloat = 13
        var spaceWidth: CGFloat? = nil
        var sizes: [Int: CGFloat] = [:]
        var top: CGFloat = 700
        var left: CGFloat = 72
        var width: CGFloat = 612
        var height: CGFloat = 792

        func lineSize(_ line: Int) -> CGFloat { sizes[line] ?? size }

        var entries: [CharacterInfo] {
            var out: [CharacterInfo] = []
            var word = 0, index = 0
            var y = top
            for (lineIndex, text) in lines.enumerated() {
                if lineIndex > 0 { y -= leading }
                let size = lineSize(lineIndex), advance = 0.6 * size
                var x = left, inSpace = false
                for character in text {
                    let isSpace = character.isWhitespace
                    if isSpace && !inSpace { word += 1 }
                    if !isSpace && inSpace { word += 1 }
                    inSpace = isSpace
                    let w = isSpace ? (spaceWidth ?? advance) : advance
                    out.append(CharacterInfo(
                        character: String(character), bounds: CGRect(x: x, y: y, width: w, height: size),
                        stringIndex: index, lineIndex: lineIndex, wordIndex: word))
                    x += w; index += 1
                }
                word += 1
            }
            return out
        }

        var frame: PageFrame { PageFrame(rotation: 0, displayedSize: CGSize(width: width, height: height)) }

        /// The union of `word`'s letter boxes on `line` (its first match).
        func rect(_ word: String, line: Int) throws -> CGRect {
            let onLine = entries.filter { $0.lineIndex == line }
            let text = onLine.map(\.character).joined()
            let range = try #require(text.range(of: word), "\(word) on line \(line)")
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            return onLine[start..<(start + word.count)].map(\.bounds).reduce(onLine[start].bounds) { $0.union($1) }
        }
    }

    /// One case: a page, its rectangles, its paint, and the words written by
    /// hand that must stay and must leave.
    struct Case: Sendable, CustomTestStringConvertible {
        let number: Int
        let name: String
        let make: @Sendable () throws -> (page: Page, rectangles: [TextPathRectangle], painted: [CGRect])
        let boxed: [String]
        let stay: [String]
        let leave: [String]
        var testDescription: String { "\(number): \(name)" }
    }

    static func run(_ page: Page, _ rectangles: [TextPathRectangle], painted: [CGRect]) async throws
        -> (path: PageTextPath.Result, written: WholeWordAssertion.Written?) {
        let path = try await PageTextPath.run(
            entries: page.entries, frame: page.frame, textPathRectangles: rectangles,
            paintedRectangles: painted, pageIndex: 0)
        return (path, try WholeWordAssertion.write(path, frame: page.frame))
    }

    /// The source words no box listed and the path left out.
    static func unboxedLeftOut(_ page: Page, _ written: WholeWordAssertion.Written, boxed: [String]) -> Int {
        let kept = Set(written.entries.map(\.wordIndex))
        let words = Dictionary(grouping: page.entries.filter { !$0.character.allSatisfy(\.isWhitespace) }, by: \.wordIndex)
        return words.filter { index, letters in
            !kept.contains(index) && !boxed.contains(letters.map(\.character).joined())
        }.count
    }
}

extension PaintAndKindsCasesTests {

    static let threeLines = Page(lines: ["Alpha bravo charlie", "delta echo foxtrot", "golf hotel india"])

    /// A signature line with small print 0.5 pt below it. The small print's
    /// middle is 2.1 pt to 3.9 pt up its 6 pt box: 695.6 to 697.4.
    static let smallPrint = Page(lines: ["Signed by Morgan Reyes", "fine print below here"], leading: 6.5, sizes: [1: 6])

    /// The painted rectangles of the signature box, by hand: at 150 dpi the
    /// paint reaches 3 pt below the box, into the small print's middle; at
    /// 300 dpi 1.5 pt, short of it.
    static func signaturePaint(_ page: Page, below: CGFloat) throws -> CGRect {
        let box = try page.rect("Morgan Reyes", line: 0)
        return CGRect(x: box.minX - 1, y: box.minY - below, width: box.width + 2, height: box.height + below + 1)
    }

    static func ordinary(_ r: CGRect) -> TextPathRectangle { TextPathRectangle(rect: r, kind: .ordinary) }

    static let cases: [Case] = [
        Case(number: 1, name: "paint that reaches no middle on the lines above and below keeps them", make: {
            let page = threeLines
            let box = try page.rect("echo", line: 1)
            // 2.5 pt into each gap: 0.5 pt into the letter boxes above and below, short of their middles.
            return (page, [ordinary(box)], [box.insetBy(dx: -1, dy: -2.5)])
        }, boxed: ["echo"], stay: ["Alpha", "bravo", "charlie", "delta", "foxtrot", "golf", "hotel", "india"], leave: ["echo"]),
        Case(number: 2, name: "small print under the paint of 150 dpi leaves whole", make: {
            let page = smallPrint
            return (page, [ordinary(try page.rect("Morgan Reyes", line: 0))], [try signaturePaint(page, below: 3)])
        }, boxed: ["Morgan", "Reyes"], stay: ["Signed", "by", "fine", "print", "below"], leave: ["Morgan", "Reyes", "here"]),
        Case(number: 3, name: "two boxes merged into one painted rectangle take the word between them", make: {
            let page = Page(lines: ["alpha bravo charlie"])
            let a = try page.rect("alpha", line: 0), c = try page.rect("charlie", line: 0)
            return (page, [ordinary(a), ordinary(c)], [a.union(c)])
        }, boxed: ["alpha", "charlie"], stay: [], leave: ["alpha", "bravo", "charlie"]),
        Case(number: 5, name: "a hand box through the top third of a line takes every word it touches", make: {
            let page = threeLines
            // Line 1's letters are 687 to 698: from 694.4 up is their top
            // third, above their middles (690.85 to 694.15). The box stops
            // 0.5 pt short of the line above.
            return (page, [ordinary(CGRect(x: 115, y: 694.4, width: 35, height: 5.1))], [])
        }, boxed: ["echo", "foxtrot"], stay: ["Alpha", "bravo", "charlie", "delta", "golf", "hotel", "india"], leave: ["echo", "foxtrot"]),
        Case(number: 6, name: "a Search box on one word takes it and the words within 3 pt on its line", make: {
            let page = Page(lines: ["one two three four"], spaceWidth: 2)
            let two = try page.rect("two", line: 0)
            // The match's box and its hidden letters' box, both ordinary.
            return (page, [ordinary(two), ordinary(two.insetBy(dx: -0.5, dy: -0.5))], [])
        }, boxed: ["two"], stay: ["four"], leave: ["one", "two", "three"]),
        Case(number: 7, name: "a box at the page's edge with its paint clipped by the image", make: {
            var page = Page(lines: ["left middle edge"]); page.width = 200
            let edge = try page.rect("edge", line: 0)
            let box = CGRect(x: edge.minX, y: edge.minY, width: 200 - edge.minX, height: edge.height)
            let paint = box.insetBy(dx: -2, dy: -2).intersection(CGRect(x: 0, y: 0, width: 200, height: 792))
            return (page, [ordinary(box)], [paint])
        }, boxed: ["edge"], stay: ["left", "middle"], leave: ["edge"]),
        Case(number: 9, name: "the marks read the painted rectangles handed in, of a lower quality than planned", make: {
            let page = smallPrint
            return (page, [ordinary(try page.rect("Morgan Reyes", line: 0))], [try signaturePaint(page, below: 3)])
        }, boxed: ["Morgan", "Reyes"], stay: ["fine", "print", "below"], leave: ["here"]),
        Case(number: 17, name: "a word marked by paint leaves and the count of runs left out does not move", make: {
            let page = Page(lines: ["keep marked keep"])
            let marked = try page.rect("marked", line: 0)
            return (page, [], [marked.insetBy(dx: 8, dy: 2)])
        }, boxed: [], stay: ["keep"], leave: ["marked"]),
        Case(number: 18, name: "a page whose last words leave by a box and the paint is written with no text and no reason", make: {
            let page = Page(lines: ["boxed painted"])
            let boxed = try page.rect("boxed", line: 0), painted = try page.rect("painted", line: 0)
            return (page, [ordinary(boxed)], [painted.insetBy(dx: 10, dy: 3)])
        }, boxed: ["boxed"], stay: [], leave: ["boxed", "painted"]),
        Case(number: 19, name: "a widened box whose region has a hidden letters' box takes the letters under that box", make: {
            let page = Page(lines: ["Name Jordan Vale signed here"])
            let value = try page.rect("Jordan Vale", line: 0)
            let plan = value.insetBy(dx: -4, dy: -1)
            let hidden = try page.rect("signed", line: 0)
            return (page, [TextPathRectangle(rect: plan, kind: .plansRectangle),
                           TextPathRectangle(rect: value, kind: .underWidenedBox), ordinary(hidden)], [])
        }, boxed: ["Jordan", "Vale", "signed"], stay: ["Name", "here"], leave: ["Jordan", "Vale", "signed"]),
    ]

    @Test("Each case: the stated words stay and leave, and the shared assertion holds", arguments: cases)
    func caseRow(_ row: Case) async throws {
        let (page, rectangles, painted) = try row.make()
        let (path, written) = try await Self.run(page, rectangles, painted: painted)
        let page1 = try #require(written, "\(row): the page is written")
        WholeWordAssertion.holds(page1, boxedWords: row.boxed, rectangles: rectangles,
                                 painted: painted, frame: page.frame, "\(row)")
        let hidden = Set(WholeWordAssertion.words(page1.text))
        for word in row.stay { #expect(hidden.contains(word), "\(row): \(word) stays") }
        for word in row.leave { #expect(!hidden.contains(word), "\(row): \(word) leaves") }
        #expect(path.runsLeftOut == 0, "\(row): no mark of the paint or the box is a run left out")
        if row.number == 1 {
            // The count of unboxed words left out on the page, written by hand.
            #expect(Self.unboxedLeftOut(page, page1, boxed: row.boxed) == 0, "\(row): no unboxed word is left out")
        }
        if row.number == 19 {
            // The drawn-cell rule also reads the hidden letters' box, so the
            // word would leave by it anyway: the filter must take it first.
            #expect(path.drawnCellDropped == 0, "\(row): the filter takes the letters under the hidden letters' box")
        }
    }
}

// MARK: - Cases that compare two pages

extension PaintAndKindsCasesTests {

    /// `page` turned a quarter, as a page stored with /Rotate 90 is shown:
    /// a point (x, y) of the upright page is (y, width − x) on the turned
    /// one, and a rectangle turns with it.
    static func turned(_ r: CGRect, width: CGFloat) -> CGRect {
        CGRect(x: r.minY, y: width - r.maxX, width: r.height, height: r.width)
    }

    static func turned(_ page: Page) -> (entries: [CharacterInfo], frame: PageFrame) {
        let entries = page.entries.map {
            CharacterInfo(character: $0.character, bounds: Self.turned($0.bounds, width: page.width),
                          stringIndex: $0.stringIndex, lineIndex: $0.lineIndex, wordIndex: $0.wordIndex)
        }
        return (entries, PageFrame(rotation: 90, displayedSize: CGSize(width: page.height, height: page.width)))
    }

    static func leftOutWords(_ path: PageTextPath.Result, _ entries: [CharacterInfo]) -> Set<String> {
        guard case .written(let written, _, _) = path.outcome else { return ["(a picture)"] }
        let kept = Set(written.map(\.wordIndex))
        let words = Dictionary(grouping: entries.filter { !$0.character.allSatisfy(\.isWhitespace) }, by: \.wordIndex)
        return Set(words.filter { !kept.contains($0.key) }.map { $0.value.map(\.character).joined() })
    }

    @Test("8: a page stored with a quarter turn leaves the same words as its upright twin, at two depths of paint",
          arguments: [CGFloat(3), 2.5])
    func quarterTurn(below: CGFloat) async throws {
        let page = Self.smallPrint
        let box = try page.rect("Morgan Reyes", line: 0)
        let paint = try Self.signaturePaint(page, below: below)
        let upright = try await PageTextPath.run(
            entries: page.entries, frame: page.frame, textPathRectangles: [Self.ordinary(box)],
            paintedRectangles: [paint], pageIndex: 0)
        let (entries, frame) = Self.turned(page)
        let turnedPath = try await PageTextPath.run(
            entries: entries, frame: frame,
            textPathRectangles: [Self.ordinary(Self.turned(box, width: page.width))],
            paintedRectangles: [Self.turned(paint, width: page.width)], pageIndex: 0)
        let left = Self.leftOutWords(upright, page.entries)
        #expect(left == Self.leftOutWords(turnedPath, entries), "paint \(below) pt below")
        // At 3 pt the paint reaches the small print's middle; at 2.5 pt it stops
        // between the middle (35 % across) and where 25 % would put it.
        #expect(left.contains("here") == (below == 3), "paint \(below) pt below: \(left)")
        let written = try #require(try WholeWordAssertion.write(turnedPath, frame: frame))
        WholeWordAssertion.holds(written, boxedWords: ["Morgan", "Reyes"],
                                 rectangles: [Self.ordinary(Self.turned(box, width: page.width))],
                                 painted: [Self.turned(paint, width: page.width)], frame: frame, "8, turned, \(below) pt")
    }

    @Test("10: with no painted rectangle nothing is marked, and the page is what the commit before wrote")
    func noPaintIsTheCommitBefore() async throws {
        let page = Self.threeLines
        let box = try page.rect("echo", line: 1)
        let now = try await PageTextPath.run(
            entries: page.entries, frame: page.frame, textPathRectangles: [Self.ordinary(box)],
            paintedRectangles: [], pageIndex: 0)
        // The commit before: the filter by today's tests on every rectangle,
        // and no paint-mark step.
        var before = PageTextPath.Steps.live
        before.filter = { entries, rectangles, _ in
            try await filterCharacters(characters: entries, redactionRects: rectangles.map(\.rect))
        }
        before.paintMarks = { _, _, _ in [] }
        let then = try await PageTextPath.$steps.withValue(before) {
            try await PageTextPath.run(
                entries: page.entries, frame: page.frame, textPathRectangles: [Self.ordinary(box)],
                paintedRectangles: [], pageIndex: 0)
        }
        guard case .written(let a, let da, let ra) = now.outcome, case .written(let b, let db, let rb) = then.outcome else {
            Issue.record("both pages are written"); return
        }
        #expect(a.map(\.stringIndex) == b.map(\.stringIndex))
        #expect(a.map(\.bounds) == b.map(\.bounds))
        #expect(da.lineageHash == db.lineageHash && ra == rb)
        let la = try #require(now.hiddenTextLines), lb = try #require(then.hiddenTextLines)
        #expect(la.lines.map(\.line.text) == lb.lines.map(\.line.text))
        #expect(la.lines.map(\.line.origin) == lb.lines.map(\.line.origin))
    }

    /// A tight page (letter boxes 1 pt taller than the leading) with a value
    /// field from x 105 to 157.8 on its middle line. "late" on the line
    /// above lies over the field's right part only; the line below has a
    /// wide gap between two words.
    static func tightPage(value: String) -> Page {
        let field = 8
        let padded = value + String(repeating: " ", count: field - value.count)
        return Page(lines: ["Bill" + String(repeating: " ", count: 7) + "late",
                            "Paid " + padded + " today",
                            "Thank" + String(repeating: " ", count: 8) + "you"], leading: 10)
    }

    /// The plan's rectangle for the field: its line box, from x 104 to 159.
    static let fieldPlan = CGRect(x: 104, y: 690, width: 55, height: 11)

    static func fieldRun(_ value: String) async throws -> (page: Page, path: PageTextPath.Result, written: WholeWordAssertion.Written) {
        let page = Self.tightPage(value: value)
        let own = try page.rect(value, line: 1)
        let rectangles = [TextPathRectangle(rect: Self.fieldPlan, kind: .plansRectangle),
                          TextPathRectangle(rect: own, kind: .underWidenedBox)]
        let (path, written) = try await Self.run(page, rectangles, painted: [Self.fieldPlan])
        let w = try #require(written, "\(value): the page is written")
        WholeWordAssertion.holds(w, boxedWords: [value], rectangles: rectangles, painted: [Self.fieldPlan],
                                 frame: page.frame, "the field holding \(value)")
        return (page, path, w)
    }

    /// The read-back characters outside the plan's rectangle, with their boxes.
    static func outside(_ w: WholeWordAssertion.Written) -> [String] {
        w.readBack.filter { !Self.fieldPlan.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }
            .map { "\($0.character)@\(Int(($0.box.minX * 100).rounded())),\(Int(($0.box.minY * 100).rounded()))" }
    }

    @Test("12: two values of different width in one plan's rectangle on a tight page give equal hidden texts")
    func widthDoesNotShow() async throws {
        let wide = try await Self.fieldRun("1,200.00"), narrow = try await Self.fieldRun("98.00")
        #expect(wide.written.text == narrow.written.text, "\(wide.written.text.debugDescription) / \(narrow.written.text.debugDescription)")
        #expect(Self.outside(wide.written) == Self.outside(narrow.written))
        // Nothing is kept between the value's own rectangle and the plan's on
        // this page, so the written text cannot show which one the writer
        // breaks its lines by: read the rectangles it is handed instead.
        for field in [wide, narrow] {
            guard case .written(_, _, let removal) = field.path.outcome else { Issue.record("written"); continue }
            #expect(removal == [Self.fieldPlan], "the writer breaks its lines by the plan's rectangle: \(removal)")
        }
    }

    @Test("13: no letter a match selected has its middle outside its plan's rectangle")
    func selectedLettersInsideThePlan() async throws {
        var furthest: CGFloat = 0
        for value in ["1,200.00", "98.00"] {
            let page = Self.tightPage(value: value)
            let letters = page.entries.filter { $0.lineIndex == 1 }
            let own = try page.rect(value, line: 1)
            for entry in letters where entry.bounds.intersects(own) && !entry.character.allSatisfy(\.isWhitespace) {
                let middle = try #require(LetterBoxMiddle.middle(of: entry.bounds, rotation: 0))
                #expect(Self.fieldPlan.contains(middle), "\(value): \(entry.character)'s middle is in the plan's rectangle")
                let past = max(Self.fieldPlan.minX - entry.bounds.minX, entry.bounds.maxX - Self.fieldPlan.maxX,
                               Self.fieldPlan.minY - entry.bounds.minY, entry.bounds.maxY - Self.fieldPlan.maxY, 0)
                furthest = max(furthest, past)
            }
        }
        print("13: the furthest a selected letter's box passes its plan's rectangle: \(furthest) pt")
        #expect(furthest < 1, "a figure near the inset is reported")
    }

    @Test("15: on the tight page the line below is written whole, and its two words across a wide gap read as two")
    func lineBelowWhole() async throws {
        let field = try await Self.fieldRun("1,200.00")
        let words = WholeWordAssertion.words(field.written.text)
        #expect(words.contains("Thank") && words.contains("you"), "\(words)")
        #expect(!words.contains("Thankyou"))
        let below = field.page.entries.filter { $0.lineIndex == 2 && !$0.character.allSatisfy(\.isWhitespace) }
        guard case .written(let kept, _, _) = field.path.outcome else { Issue.record("written"); return }
        #expect(Set(below.map(\.stringIndex)).isSubset(of: Set(kept.map(\.stringIndex))), "every letter of the line below is kept")
    }
}

extension PaintAndKindsCasesTests {

    /// A tight three-line page whose middle line is `before`, then `value`
    /// padded to `field` characters, then `after`; the plan's rectangle is
    /// the field's cells on that line, 1 pt wider each side.
    static func fieldPage(above: String, before: String, value: String, field: Int, after: String, below: String)
        -> (page: Page, plan: CGRect) {
        let page = Page(lines: [above, before + value + String(repeating: " ", count: field - value.count) + after, below],
                        leading: 10)
        let advance = 0.6 * page.size
        let start = page.left + CGFloat(before.count) * advance
        return (page, CGRect(x: start - 1, y: page.top - page.leading, width: CGFloat(field) * advance + 2, height: page.size))
    }

    static func hiddenText(_ fixture: (page: Page, plan: CGRect), value: String) async throws -> WholeWordAssertion.Written {
        let own = try fixture.page.rect(value, line: 1)
        let rectangles = [TextPathRectangle(rect: fixture.plan, kind: .plansRectangle),
                          TextPathRectangle(rect: own, kind: .underWidenedBox)]
        let (_, written) = try await Self.run(fixture.page, rectangles, painted: [fixture.plan])
        let w = try #require(written, "\(value): the page is written")
        WholeWordAssertion.holds(w, boxedWords: [value], rectangles: rectangles, painted: [fixture.plan],
                                 frame: fixture.page.frame, "the field holding \(value)")
        return w
    }

    @Test("14: a value already as wide as its line, and one that ends where the other line ends, give the hidden text of a shorter value widened to the same room")
    func asWideAsItsLine() async throws {
        // The value alone on its line, filling it.
        let full = "1,234,567.89", short = "12.00"
        let alone = { (v: String) in Self.fieldPage(above: "Statement of account", before: "", value: v, field: full.count,
                                               after: "", below: "Balance carried over") }
        let a = try await Self.hiddenText(alone(full), value: full)
        let b = try await Self.hiddenText(alone(short), value: short)
        #expect(a.text == b.text, "\(a.text.debugDescription) / \(b.text.debugDescription)")
        // A value whose field ends where the one other line ends, with words
        // beside its room.
        let beside = { (v: String) in Self.fieldPage(above: "Net amount due", before: "Due ", value: v, field: 10,
                                                after: " by return", below: "Thank you") }
        let c = try await Self.hiddenText(beside("9,999.99"), value: "9,999.99")
        let d = try await Self.hiddenText(beside("5.00"), value: "5.00")
        #expect(c.text == d.text, "\(c.text.debugDescription) / \(d.text.debugDescription)")
    }
}

extension PaintAndKindsCasesTests {

    @Test("2, at 300 dpi: paint that stops 1.5 pt below the box keeps the small print")
    func smallPrintAt300() async throws {
        let page = Self.smallPrint
        let box = try page.rect("Morgan Reyes", line: 0)
        let paint = try Self.signaturePaint(page, below: 1.5)
        let (_, written) = try await Self.run(page, [Self.ordinary(box)], painted: [paint])
        let w = try #require(written)
        WholeWordAssertion.holds(w, boxedWords: ["Morgan", "Reyes"], rectangles: [Self.ordinary(box)],
                                 painted: [paint], frame: page.frame, "2 at 300 dpi")
        let words = Set(WholeWordAssertion.words(w.text))
        for word in ["fine", "print", "below", "here"] { #expect(words.contains(word), "\(word) stays") }
    }

    /// One line of three words of different letter widths and two boxes.
    /// The band's pitch is its letters' summed width over their count
    /// (quantized to half points of type): 4.5 pt with all three words,
    /// 6 pt once the narrow word X has left. X's last cells are drawn
    /// inside box B2 at the first pitch; Y's last cell is drawn just short
    /// of box B1 at the first pitch (centre 120.17, B1 from 124) and inside
    /// it at the second (124.22). Every source letter clears its box's
    /// 3 pt margin.
    static func reflowLine() -> (entries: [CharacterInfo], b1: CGRect, b2: CGRect) {
        var entries: [CharacterInfo] = []
        func word(_ text: String, x: CGFloat, width: CGFloat, word: Int) {
            for (i, ch) in text.enumerated() {
                entries.append(CharacterInfo(
                    character: String(ch), bounds: CGRect(x: x + CGFloat(i) * width, y: 500, width: width, height: 10),
                    stringIndex: entries.count, lineIndex: 0, wordIndex: word))
            }
        }
        word("yardarms", x: 100, width: 2.5, word: 0)   // Y: 100 to 120
        word("xxiiii", x: 200, width: 1, word: 1)       // X: 200 to 206
        word("WIDE", x: 400, width: 6, word: 2)          // W
        return (entries, CGRect(x: 124, y: 490, width: 26, height: 25), CGRect(x: 209.5, y: 490, width: 30, height: 25))
    }

    @Test("11: taking one word out moves another's drawn cell into a box, and that word leaves on the next pass")
    func nextPassTakesTheMovedWord() async throws {
        let (entries, b1, b2) = Self.reflowLine()
        let frame = PageFrame(rotation: 0, displayedSize: CGSize(width: 612, height: 792))
        let rectangles = [Self.ordinary(b1), Self.ordinary(b2)]
        // Neither box's filter takes a letter: the drawn-cell rule does all of it.
        let filtered = try await filterCharacters(characters: entries, redactionRects: [b1, b2])
        #expect(filtered.surviving.count == entries.count, "precondition: every source letter clears both boxes' margin")
        let path = try await PageTextPath.run(entries: entries, frame: frame, textPathRectangles: rectangles,
                                              paintedRectangles: [], pageIndex: 0)
        guard case .written(let written, _, _) = path.outcome else { Issue.record("the page is written"); return }
        #expect(written.map(\.character).joined() == "WIDE", "X leaves on the first pass, Y on the second")
        #expect(path.drawnCellDropped >= 2)
        let w = try #require(try WholeWordAssertion.write(path, frame: frame))
        WholeWordAssertion.holds(w, boxedWords: ["xxiiii", "yardarms"], rectangles: rectangles, painted: [],
                                 frame: frame, "11")
    }

    /// The case numbers this file holds: one to nineteen but four and
    /// sixteen, the two that would read the paint in the drawn-cell rule,
    /// which reads the text-path rectangles only.
    static let numbers: [Int] = Self.cases.map(\.number) + [2, 8, 10, 11, 12, 13, 14, 15]

    @Test("The cases are seventeen: one to nineteen but four and sixteen")
    func caseCount() {
        let held = Set(Self.numbers)
        #expect(held.count == 17)
        #expect(held == Set(1...19).subtracting([4, 16]))
    }
}
