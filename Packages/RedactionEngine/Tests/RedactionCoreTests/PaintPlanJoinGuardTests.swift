import Foundation
import Testing
import RedactionCore

/// The join guard. First, two columns: a page's words and found boxes as
/// drawn, in whole sixty-fourths. Two found words on a
/// left-column line and a found box over the right column's tall heading
/// word share one line by the page's line rule and adjoin across the gap.
/// Their joined rectangle holds the middle of each letter of the left
/// column's line above, but none of those letters whole. A letter blocks a
/// join when its middle lies inside the joined rectangle, unless its middle
/// lies inside a member's own tight rectangle (the letter is under that
/// member's own fill already). The second case is a found box held inside a
/// two-line found box whose rectangle cuts a word nobody selected: it joins.
@Suite struct PaintPlanJoinGuardTests {
    typealias Sheet = ComplementReadingTests.Sheet
    typealias T = PaintPlanMakeTests

    /// (line, minX, minY, maxX, maxY, letters), in sixty-fourths; each word's
    /// letters are equal columns of its box.
    static let words: [(Int, Int, Int, Int, Int, Int)] = [
        (0, 531, 16633, 1881, 17452, 3),
        (0, 2170, 16633, 5770, 17452, 8),
        (0, 6243, 16633, 9843, 17452, 8),
        (0, 10364, 16633, 11264, 17452, 2),
        (0, 11548, 16633, 13348, 17452, 4),
        (0, 13615, 16633, 15865, 17452, 5),
        (1, 21255, 15509, 22413, 17231, 3),
        (1, 22897, 16529, 25599, 17231, 7),
        (1, 26012, 16529, 27170, 17231, 3),
        (1, 27376, 16529, 29306, 17231, 5),
        (1, 29531, 16529, 30303, 17231, 2),
        (1, 30499, 16529, 33587, 17231, 8),
        (1, 34031, 16529, 35189, 17231, 3),
        (1, 35628, 16529, 36400, 17231, 2),
        (2, 579, 15613, 1929, 16432, 3),
        (2, 2263, 15613, 5413, 16432, 7),
        (2, 5924, 15613, 8174, 16432, 5),
        (2, 8489, 15613, 10739, 16432, 5),
        (2, 11050, 15613, 14650, 16432, 8),
        (2, 15053, 15613, 15953, 16432, 2),
        (3, 21012, 15509, 21784, 16211, 2),
        (3, 22128, 15509, 23672, 16211, 4),
        (3, 23835, 15509, 26923, 16211, 8),
        (3, 27191, 15509, 29507, 16211, 6),
        (3, 29701, 15509, 32017, 16211, 6),
        (3, 32447, 15509, 33991, 16211, 4),
        (3, 34355, 15509, 36285, 16211, 5),
        (4, 659, 14593, 4259, 15412, 8),
        (4, 4444, 14593, 6244, 15412, 4),
        (4, 6719, 14593, 9419, 15412, 6),
        (4, 9636, 14593, 11436, 15412, 4),
        (4, 11977, 14593, 15127, 15412, 7),
        (5, 21295, 14489, 24383, 15191, 8),
        (5, 24743, 14489, 25901, 15191, 3),
        (5, 26051, 14489, 27209, 15191, 3),
        (5, 27549, 14489, 30637, 15191, 8),
        (5, 30815, 14489, 32359, 15191, 4),
        (5, 32756, 14489, 34686, 15191, 5),
        (5, 35157, 14489, 36315, 15191, 3)
    ]

    /// The page, each word's letters, and the three found boxes.
    static func page() -> (sheet: Sheet, words: [[Set<Int>]], found: [PlanRegion]) {
        var sheet = Sheet()
        var byLine: [[Set<Int>]] = Array(repeating: [], count: 6)
        var boxes: [[(Int, Int, Int, Int)]] = Array(repeating: [], count: 6)
        for (line, x0, y0, x1, y1, k) in words {
            let w = (x1 - x0) / k
            byLine[line].append(sheet.word(String(repeating: "a", count: k), rects: (0..<k).map { i in
                PointRect(minX: Double(x0 + w * i) / 64, minY: Double(y0) / 64, maxX: Double(x0 + w * (i + 1)) / 64, maxY: Double(y1) / 64)
            }))
            boxes[line].append((x0, y0, x1, y1))
        }
        // The right-column box holds every word whose middle lies in the drawn
        // rectangle (21012, 15491)-(27170, 17238): the heading and the words
        // beside it on both of its rows.
        var right: Set<Int> = []
        for line in [1, 3] {
            for (k, b) in boxes[line].enumerated() {
                let mx = (b.0 + b.2) / 2, my = (b.1 + b.3) / 2
                if mx >= 21012 && mx <= 27170 && my >= 15491 && my <= 17238 { right.formUnion(byLine[line][k]) }
            }
        }
        let found = [T.matched(sheet, byLine[2][4]), T.matched(sheet, byLine[2][5]), T.matched(sheet, right)]
        return (sheet, byLine, found)
    }

    /// A region's own tight rectangle: its placed rectangle and its selected letters, outward.
    static func tight(_ sheet: Sheet, _ r: PlanRegion) -> PageRect64 {
        var u = T.placed(r)
        for b in sheet.boxes where r.selected.contains(b.offset) {
            let l = PageRect64(outward: b.rect)!
            u = PageRect64(minX: min(u.minX, l.minX), minY: min(u.minY, l.minY), maxX: max(u.maxX, l.maxX), maxY: max(u.maxY, l.maxY))
        }
        return u
    }

    static func holds(_ a: PageRect64, _ l: PageRect64) -> Bool {
        a.minX <= l.minX && l.maxX <= a.maxX && a.minY <= l.minY && l.maxY <= a.maxY
    }

    /// The middle of `l` inside `a`, kept whole: twice the middle against twice the sides.
    static func holdsMiddle(_ a: PageRect64, _ l: PageRect64) -> Bool {
        let cx = l.minX + l.maxX, cy = l.minY + l.maxY
        return 2 * a.minX <= cx && cx <= 2 * a.maxX && 2 * a.minY <= cy && cy <= 2 * a.maxY
    }

    /// The letters nobody selected that would block joining `regions`, by each
    /// form of the guard: whole (whole inside J, whole inside no member's
    /// own); middle with the whole excuse; middle with the middle excuse.
    static func blockers(_ sheet: Sheet, _ regions: [PlanRegion]) -> (j: PageRect64, whole: Int, middleWholeExcuse: Int, middle: Int) {
        let ts = regions.map { tight(sheet, $0) }
        let j = ts.dropFirst().reduce(ts[0]) {
            PageRect64(minX: min($0.minX, $1.minX), minY: min($0.minY, $1.minY), maxX: max($0.maxX, $1.maxX), maxY: max($0.maxY, $1.maxY))
        }
        let selected = regions.reduce(into: Set<Int>()) { $0.formUnion($1.selected) }
        var whole = 0, middleWholeExcuse = 0, middle = 0
        for b in sheet.boxes where !selected.contains(b.offset) {
            let l = PageRect64(outward: b.rect)!
            let ownWhole = ts.contains { holds($0, l) }, ownMiddle = ts.contains { holdsMiddle($0, l) }
            if holds(j, l) && !ownWhole { whole += 1 }
            if holdsMiddle(j, l) && !ownWhole { middleWholeExcuse += 1 }
            if holdsMiddle(j, l) && !ownMiddle { middle += 1 }
        }
        return (j, whole, middleWholeExcuse, middle)
    }

    @Test("Two columns: the found box over the tall heading does not join the left line's found words; the letters above hold their middles inside the joined rectangle")
    func headingBoxDoesNotJoinAcrossTheGap() {
        let (sheet, words, found) = Self.page()
        let made = T.plan(sheet, found)
        let g = Self.blockers(sheet, found)
        let lineAbove = words[0].reduce(into: Set<Int>()) { $0.formUnion($1) }
        let stickOut = sheet.boxes.filter { lineAbove.contains($0.offset) }.map { PageRect64(outward: $0.rect)!.maxY - g.j.maxY }.max() ?? 0
        #expect(stickOut > 0, "the line above stands out of the joined rectangle")
        let leftJoined = made.box(found[0]).regionIDs.contains(found[1].id)
        let crossJoined = made.box(found[1]).regionIDs.contains(found[2].id)
        #expect(g.whole == 0, "no unselected letter lies wholly inside the joined rectangle")
        #expect(g.middle == 9, "nine letters of the line above hold their middles inside it, under no member's own")
        #expect(leftJoined, "the left line's two found words are one box")
        #expect(!crossJoined, "the heading's box stays its own")
    }

    @Test("A found box held inside a two-line found box whose rectangle cuts a word nobody selected joins it: the cut letter's middle is under the container's own rectangle")
    func heldBoxInsideAContainerJoins() {
        var sheet = Sheet()
        let top = sheet.line(count: 3, y: 700)       // words at 72-96, 100-124, 128-152 (letters 6 pt)
        let low = sheet.line(count: 3, y: 686)
        // The container: the top line's first two words and the low line's
        // first, its rectangle 8 pt past their letters (to 132), so it cuts
        // the first letter of each line's third word (128 to 134) past its
        // middle (131).
        let container = T.matched(sheet, top[0].union(top[1]).union(low[0]), right: 8)
        let held = T.matched(sheet, top[1])
        let made = T.plan(sheet, [container, held])
        let g = Self.blockers(sheet, [container, held])
        let cut = PageRect64(outward: sheet.boxes.first { low[2].contains($0.offset) }!.rect)!
        let own = Self.tight(sheet, container)
        #expect(made.plan.boxes.count == 1)
        let joined = made.box(container).regionIDs.contains(held.id)
        #expect(Self.holdsMiddle(own, cut) && !Self.holds(own, cut), "the cut letter's middle is inside the container's own rectangle, the letter is not")
        #expect(g.middleWholeExcuse > 0, "with the whole-letter excuse the cut letter would block")
        #expect(g.middle == 0, "with the middle excuse nothing blocks")
        #expect(joined, "the held box joins its container")
    }

    /// No box's paint holds the middle of any of `letters`.
    static func noPaintHoldsTheMiddleOf(_ sheet: Sheet, _ letters: Set<Int>, in made: T.Made) -> Bool {
        let rects = sheet.boxes.filter { letters.contains($0.offset) }.map { PageRect64(outward: $0.rect)! }
        return !made.plan.boxes.contains { box in rects.contains { holdsMiddle(box.paint, $0) } }
    }

    @Test("Three adjoining found words on a line are one box; a two-line match beside them whose pair rectangle holds a word below stays its own")
    func lineOfFoundWordsStaysOneBox() {
        var sheet = Sheet()
        let top = sheet.line(count: 5, y: 700)
        let low = sheet.line(count: 5, y: 686)
        let words = (0..<3).map { T.matched(sheet, top[$0]) }
        let twoLine = T.matched(sheet, top[3].union(low[3]))
        let made = T.plan(sheet, words + [twoLine])
        #expect(made.box(words[0]).regionIDs == Set(words.map(\.id)), "the line's words are one box")
        #expect(made.box(twoLine).regionIDs == [twoLine.id], "the two-line match is its own box")
        #expect(Self.noPaintHoldsTheMiddleOf(sheet, low[2], in: made))
    }

    @Test("A chain whose pairs each pass but whose group holds a word below the first is split into single boxes")
    func groupHoldingAWordNoPairHoldsIsSplit() {
        var sheet = Sheet()
        let top = sheet.line(count: 3, y: 700)
        let below = sheet.word("abcd", x: 72, y: 686)
        let lowRight = sheet.word("abcd", x: 128, y: 686)
        let a = T.matched(sheet, top[0]), b = T.matched(sheet, top[1])
        let c = T.matched(sheet, top[2].union(lowRight))
        let made = T.plan(sheet, [a, b, c])
        #expect(made.plan.boxes.count == 3, "each region is its own box")
        #expect(Self.noPaintHoldsTheMiddleOf(sheet, below, in: made))
    }

    @Test("A found word and a two-line match that adjoin only across a word wholly under a hand box stay two boxes when their joined rectangle holds a word below")
    func joinAcrossAHandCoveredWordIsGuarded() {
        var sheet = Sheet()
        let top = sheet.line(count: 3, y: 700)
        let below = sheet.word("abcd", x: 72, y: 686)
        let lowRight = sheet.word("abcd", x: 128, y: 686)
        let found = T.matched(sheet, top[0])
        let twoLine = T.matched(sheet, top[2].union(lowRight))
        let hand = T.handAround(sheet, top[1])
        let made = T.plan(sheet, [found, twoLine, hand])
        #expect(!made.box(found).regionIDs.contains(twoLine.id), "two boxes")
        #expect(Self.noPaintHoldsTheMiddleOf(sheet, below, in: made), "no unselected word's middle inside a paint")
    }
}
