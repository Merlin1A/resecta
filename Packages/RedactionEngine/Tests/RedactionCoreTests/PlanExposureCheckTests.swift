import Foundation
import Testing
import RedactionCore

/// Every box of every plan carries the one value "can show length", and none
/// fell back. The sweep makes plans over a fixed
/// set of hand-built pages (a paragraph, two columns under a title, a table,
/// label rows, a line alone, and a page of boxes drawn by hand), with every
/// other word placed by Search, under both plan sources, with the switch off
/// and on, on a typed page and on a scan, and counts the boxes it checked.
/// The same check over the bench's made pages and the corpus runs outside the
/// repository.
@Suite struct PlanExposureCheckTests {
    typealias Sheet = ComplementReadingTests.Sheet
    typealias T = PaintPlanMakeTests

    /// A five-letter word's step: 5 letters 6 pt wide, then 4 pt.
    static let step = 34.0

    /// One line of `count` five-letter words from `x` at `y`.
    static func line(_ sheet: inout Sheet, count: Int, x: Double, y: Double) -> [Set<Int>] {
        (0..<count).map { i in sheet.word("words", x: x + step * Double(i), y: y) }
    }

    /// The hand-built pages, each with its words in reading order.
    static func pages() -> [(name: String, sheet: Sheet, words: [Set<Int>])] {
        var out: [(String, Sheet, [Set<Int>])] = []
        do { // a paragraph: 6 lines of 8 words
            var s = Sheet(); var w: [Set<Int>] = []
            for l in 0..<6 { w += line(&s, count: 8, x: 72, y: 600 - 14 * Double(l)) }
            out.append(("paragraph", s, w))
        }
        do { // two columns of 4 lines of 4 words under a full-width title of 14 words
            var s = Sheet(); var w = line(&s, count: 14, x: 72, y: 700)
            for l in 0..<4 {
                w += line(&s, count: 4, x: 72, y: 686 - 14 * Double(l))
                w += line(&s, count: 4, x: 330, y: 686 - 14 * Double(l))
            }
            out.append(("twoColumns", s, w))
        }
        do { // a table: 5 rows of 3 cells, one word each
            var s = Sheet(); var w: [Set<Int>] = []
            for r in 0..<5 { for c in [72.0, 250, 430] { w += line(&s, count: 1, x: c, y: 500 - 14 * Double(r)) } }
            out.append(("table", s, w))
        }
        do { // label rows: a label and a value on each of 5 rows
            var s = Sheet(); var w: [Set<Int>] = []
            for r in 0..<5 { w += line(&s, count: 1, x: 72, y: 300 - 14 * Double(r)); w += line(&s, count: 1, x: 150, y: 300 - 14 * Double(r)) }
            out.append(("labelRows", s, w))
        }
        do { // a line alone: 6 words
            var s = Sheet(); let w = line(&s, count: 6, x: 72, y: 400)
            out.append(("lineAlone", s, w))
        }
        return out.map { (name: $0.0, sheet: $0.1, words: $0.2) }
    }

    /// Twenty boxes drawn by hand on a page with no text: sixteen on a grid,
    /// one past the right edge, one off the left, one above the top, one thin.
    static func drawnByHand() -> [PlanRegion] {
        var rects: [PointRect] = (0..<16).map { i in
            let x = 60 + Double(i % 4) * 130, y = 100 + Double(i / 4) * 150
            return PointRect(minX: x, minY: y, maxX: x + 80, maxY: y + 12)
        }
        rects += [PointRect(minX: 580, minY: 700, maxX: 680, maxY: 712),
                  PointRect(minX: -120, minY: 650, maxX: -40, maxY: 662),
                  PointRect(minX: 200, minY: 800, maxX: 280, maxY: 812),
                  PointRect(minX: 300, minY: 40, maxX: 380, maxY: 40.5)]
        return rects.map { T.drawn($0) }
    }

    static let typed = T.plain
    static let scan = PageTextFacts(showsInvisibleText: true, carriesPageScaleImage: true)

    /// Boxes checked by the sweep: (24 + 23 + 8 + 5 + 3 matched + 20 drawn)
    /// boxes a plan, times 2 sources, 2 switch states and 2 kinds of page.
    static let boxesChecked = 664

    @Test("Every box of every plan in the sweep can show length, none fell back, and the count is the sweep's")
    func everyBoxCanShowLength() {
        var checked = 0
        let pages = Self.pages()
        let hand = Self.drawnByHand()
        for source in PlanSource.allCases {
            for on in [false, true] {
                for facts in [Self.typed, Self.scan] {
                    var plans: [(String, [PlanRegion], PaintPlan)] = pages.map { page in
                        let regions = page.words.indices.filter { $0 % 2 == 0 }.map { T.matched(page.sheet, page.words[$0]) }
                        return (page.name, regions, T.plan(page.sheet, regions, on: on, facts: facts, source: source).plan)
                    }
                    plans.append(("drawnByHand", hand, T.plan(Sheet(), hand, on: on, facts: facts, source: source).plan))
                    for (name, regions, plan) in plans {
                        #expect(plan.boxes.count == regions.count, "\(name) \(source) on=\(on): one box a region")
                        for box in plan.boxes {
                            #expect(box.exposure == .canShowLength, "\(name) \(source) on=\(on): \(box.exposure)")
                            #expect(box.treatment != .fellBack, "\(name) \(source) on=\(on): fell back")
                            checked += 1
                        }
                    }
                }
            }
        }
        #expect(checked > 0)
        #expect(checked == Self.boxesChecked, "boxes checked: \(checked)")
    }

    @Test("The sweep's pages hold the words it counts")
    func sweepIsAsCounted() {
        #expect(Self.pages().map { $0.words.count } == [48, 46, 15, 10, 6])
        #expect(Self.pages().map { ($0.words.count + 1) / 2 } == [24, 23, 8, 5, 3])
        #expect(Self.drawnByHand().count == 20)
        #expect(PlanSource.allCases.count == 2)
    }
}
