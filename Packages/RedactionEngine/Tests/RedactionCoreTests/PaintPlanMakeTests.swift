import Foundation
import Testing
import RedactionCore

/// The plan on hand-built pages: tight boxes, the merge, the line margin and
/// its limit, the band and its stop, the as-placed row, and the facts. Pages
/// are Letter (612 × 792 pt) and drawn as the readings' tests draw them:
/// letters 6 pt wide and 10 pt tall, words 4 pt apart, lines 14 pt apart,
/// unless a case says otherwise.
@Suite struct PaintPlanMakeTests {
    typealias Sheet = ComplementReadingTests.Sheet
    static let policy = GeometryPolicy.release
    static let plain = PageTextFacts(showsInvisibleText: false, carriesPageScaleImage: false)
    static let pageWidth = 612.0, pageHeight = 792.0
    static let W = 39_168, H = 50_688
    static func s(_ points: Double) -> Int { Int((points * 64).rounded()) }

    // MARK: - Pages, regions and plans

    static func share(_ r: PointRect) -> PointRect {
        PointRect(minX: r.minX / pageWidth, minY: r.minY / pageHeight, maxX: r.maxX / pageWidth, maxY: r.maxY / pageHeight)
    }

    /// The bounding rectangle in points of some offsets' letter boxes.
    static func rect(_ sheet: Sheet, _ offsets: Set<Int>) -> PointRect {
        let rects = sheet.boxes.filter { offsets.contains($0.offset) }.map(\.rect)
        return rects.dropFirst().reduce(rects[0]) { $0.union($1) }
    }

    /// The same rectangle in whole sixty-fourths, rounded outward.
    static func rect64(_ sheet: Sheet, _ offsets: Set<Int>) -> PageRect64 { PageRect64(outward: rect(sheet, offsets))! }

    /// A region placed by Search on `offsets`, its rectangle their letters'
    /// bounding rectangle grown by the given amounts in points.
    static func matched(_ sheet: Sheet, _ offsets: Set<Int>, kind: RegionKind = .placedFromTextAnchored,
                      left: Double = 0, right: Double = 0, up: Double = 0, id: UUID = UUID()) -> PlanRegion {
        let r = rect(sheet, offsets)
        return PlanRegion(id: id, share: share(PointRect(minX: r.minX - left, minY: r.minY, maxX: r.maxX + right, maxY: r.maxY + up)),
                          kind: kind, selected: offsets)
    }

    static func drawn(_ r: PointRect, kind: RegionKind = .drawnByHand) -> PlanRegion {
        PlanRegion(id: UUID(), share: share(r), kind: kind)
    }

    /// A region's rectangle by the plan's one formula.
    static func placed(_ region: PlanRegion) -> PageRect64 {
        PageRect64(share: region.share, widthSixtyFourths: W, heightSixtyFourths: H)!
    }

    struct Made {
        var plan: PaintPlan
        var facts: PlanFacts
        func box(_ region: PlanRegion) -> PaintedBox { plan.boxes.first { $0.regionIDs.contains(region.id) }! }
    }

    /// The plan of a page. Every plan any case makes is checked for the
    /// rules that hold of every plan: each region is in exactly one box,
    /// `inner` holds every covered region and selected letter, no box fell
    /// back, and every box can show length.
    static func plan(_ sheet: Sheet, _ regions: [PlanRegion], on: Bool = false, facts: PageTextFacts = plain,
                     source: PlanSource = .switchPolicy, words wordSource: WordSource = .textLayer,
                     sourceLocation: SourceLocation = #_sourceLocation) -> Made {
        let words = PageWords(text: sheet.text, boxes: sheet.boxes, source: wordSource)
        let made = PaintPlan.make(regions: regions, words: words, text: sheet.text, facts: facts,
                                  widthSixtyFourths: W, heightSixtyFourths: H, policy: policy, source: source, switchOn: on)
        checkContainment(made.plan, regions, sheet, sourceLocation: sourceLocation)
        #expect(!made.plan.boxes.contains { $0.treatment == .fellBack }, "no box falls back", sourceLocation: sourceLocation)
        #expect(made.plan.boxes.allSatisfy { $0.exposure == .canShowLength }, "every box can show length",
                sourceLocation: sourceLocation)
        return Made(plan: made.plan, facts: made.facts)
    }

    static func checkContainment(_ plan: PaintPlan, _ regions: [PlanRegion], _ sheet: Sheet,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        for region in regions {
            let holding = plan.boxes.filter { $0.regionIDs.contains(region.id) }
            #expect(holding.count == 1, "each region is in exactly one box", sourceLocation: sourceLocation)
            guard let box = holding.first else { continue }
            #expect(box.inner.contains(placed(region)), "inner holds the region's rectangle", sourceLocation: sourceLocation)
            if region.kind == .placedFromTextAnchored && box.treatment != .notAsked || box.bandMade {
                for letter in sheet.boxes where region.selected.contains(letter.offset) {
                    #expect(box.inner.contains(PageRect64(outward: letter.rect)!), "inner holds each selected letter",
                            sourceLocation: sourceLocation)
                }
            }
        }
        #expect(plan.boxes.reduce(0) { $0 + $1.regionIDs.count } == Set(regions.map(\.id)).count,
                "no box holds a region twice or a region not given", sourceLocation: sourceLocation)
    }

    /// The line margin's sides for a line of height `h` sixty-fourths, by
    /// the paper's own words (top 5/24 H; bottom max(0.5 pt, H/16); start
    /// max(0.5 pt, H/10); end max(0.5 pt, H/4); each rounded up, at most 8 pt).
    static func margins(_ h: Int) -> (top: Int, bottom: Int, start: Int, end: Int) {
        func up(_ n: Int, _ d: Int) -> Int { (n + d - 1) / d }
        return (min(512, up(h * 5, 24)), min(512, max(32, up(h, 16))), min(512, max(32, up(h, 10))), min(512, max(32, up(h, 4))))
    }

    /// A fifth of a letter size plus 0.3 pt, rounded down to a sixty-fourth.
    static func entry(letterSize: Int) -> Int { Int((Double(letterSize) / 5 + 0.3 * 64).rounded(.down)) }

    /// A letter box height in whole sixty-fourths, as a word's letter size counts it.
    static func letterSize(_ points: Double) -> Int { Int((points * 64).rounded()) }

    /// The stop's distance for a line of height `h`.
    static func stop(_ h: Int) -> Int { max((h + 1) / 2, 246) }

    // MARK: - Switch off: tight boxes, the margin and its limit

    @Test("\"by Jane Roe.\": the full stop lies outside inner and outside the paint")
    func fullStopStaysOut() {
        var sheet = Sheet()
        let w = sheet.line("by Jane Roe.", x: 72, y: 700)
        let roe = w[2].sorted()
        let region = Self.matched(sheet, w[1].union(roe.dropLast()))
        let made = Self.plan(sheet, [region])
        let box = made.box(region)
        let stop = Self.rect64(sheet, [roe.last!])
        #expect(box.inner.maxX <= stop.minX)
        #expect(!box.paint.sharesArea(with: stop))
        #expect(made.facts.unselectedWordsInsidePaint == 0)
        #expect(box.treatment == .notAsked && !box.bandMade)
    }

    @Test("A tight box is its letters with the line margin, the end held to half the gap to the next character")
    func tightBoxMargin() {
        var sheet = Sheet()
        let w = sheet.line(count: 3, y: 700)
        let region = Self.matched(sheet, w[1])
        let box = Self.plan(sheet, [region]).box(region)
        let tight = Self.rect64(sheet, w[1])
        #expect(box.inner == tight.union(Self.placed(region)))
        let m = Self.margins(Self.s(10))
        let halfGap = (Self.rect64(sheet, w[2]).minX - box.inner.maxX) / 2
        #expect(box.paint == PageRect64(minX: box.inner.minX - m.start, minY: box.inner.minY - m.bottom,
                                        maxX: box.inner.maxX + min(m.end, halfGap), maxY: box.inner.maxY + m.top))
        #expect(box.limitAbove == nil && box.limitBelow == nil, "no neighbouring line, no limit number")
    }

    @Test("Single-spaced Times-metric 11 pt: the limit does not bind")
    func timesLimitDoesNotBind() {
        // Letter boxes of 12.18 pt on a 12.65 pt pitch.
        var page = Sheet()
        let top = (0..<4).map { k in page.word("abcd", x: 72 + 28 * Double(k), y: 700, height: 12.18) }
        let line = (0..<4).map { k in page.word("abcd", x: 72 + 28 * Double(k), y: 700 - 12.65, height: 12.18) }
        let region = Self.matched(page, line[1])
        let box = Self.plan(page, [region]).box(region)
        let aboveBox = Self.rect64(page, top.reduce(into: Set<Int>()) { $0.formUnion($1) })
        let e = Self.entry(letterSize: Self.letterSize(12.18))
        #expect(abs(Double(e) / 64 - (12.18 / 5 + 0.3)) < 1.0 / 64, "the rule's own figure, about 2.74 pt")
        #expect(box.limitAbove == aboveBox.minY + e)
        let lineHeight = Self.rect64(page, line.reduce(into: Set<Int>()) { $0.formUnion($1) }).height
        #expect(box.paint.maxY == box.inner.maxY + Self.margins(lineHeight).top, "the top margin is whole")
        #expect(box.paint.maxY < box.limitAbove!)
    }

    @Test("A tight hand-built page (15.46 pt boxes on a 13.55 pt pitch): the top margin is cut to the limit")
    func tightPageCutsTheTopMargin() throws {
        var page = Sheet()
        let top = (0..<4).map { k in page.word("abcd", x: 72 + 28 * Double(k), y: 700, height: 15.46) }
        let line = (0..<4).map { k in page.word("abcd", x: 72 + 28 * Double(k), y: 700 - 13.55, height: 15.46) }
        let region = Self.matched(page, line[1])
        let box = Self.plan(page, [region]).box(region)
        let aboveBox = Self.rect64(page, top.reduce(into: Set<Int>()) { $0.formUnion($1) })
        let e = Self.entry(letterSize: Self.letterSize(15.46))
        let limit = try #require(box.limitAbove)
        #expect(limit == aboveBox.minY + e)
        let lineHeight = Self.rect64(page, line.reduce(into: Set<Int>()) { $0.formUnion($1) }).height
        let whole = Self.margins(lineHeight).top
        #expect(abs(Double(whole) / 64 - 15.46 * 5 / 24) < 1.0 / 64, "uncut, about 3.22 pt")
        #expect(box.paint.maxY == limit, "the limit binds")
        // The rule's own figure from the case's inputs: a fifth of 15.46 pt
        // plus 0.3 pt, less the 1.91 pt the rows overlap; about 1.48 pt.
        let cut = Double(box.paint.maxY - box.inner.maxY) / 64
        #expect(abs(cut - (15.46 / 5 + 0.3 - (15.46 - 13.55))) < 2.0 / 64)
        #expect(cut < Double(whole) / 64)
    }

    @Test("A neighbour in 8 pt type: the limit is a fifth of its letter size plus 0.3 pt")
    func smallTypeNeighbour() throws {
        var page = Sheet()
        let top = (0..<4).map { k in page.word("abcd", x: 72 + 28 * Double(k), y: 700, height: 8) }
        let line = page.line(count: 4, y: 690)
        let region = Self.matched(page, line[1])
        let box = Self.plan(page, [region]).box(region)
        let aboveBox = Self.rect64(page, top.reduce(into: Set<Int>()) { $0.formUnion($1) })
        let limit = try #require(box.limitAbove)
        #expect(limit == aboveBox.minY + Self.entry(letterSize: Self.letterSize(8)))
        #expect(box.paint.maxY == limit)
    }

    @Test("A neighbour of mixed letter heights: the limit comes from its most common letter height, not its line height or its tallest letter")
    func mixedHeightNeighbour() throws {
        var page = Sheet()
        let w = page.word("abcd", x: 72, y: 650, height: 20)
        // The line above: seven letters 8 pt tall (one of them 3 pt lower),
        // two 12 pt tall. Its box runs from 670.5 to 685.5: 15 pt.
        let rects: [PointRect] = (0..<9).map { i in
            let x = 72 + 6 * Double(i)
            let low = i == 8 ? 670.5 : 673.5
            let height = i == 6 || i == 7 ? 12.0 : 8.0
            return PointRect(minX: x, minY: low, maxX: x + 6, maxY: low + height)
        }
        let above = page.word("abcdefghi", rects: rects)
        let region = Self.matched(page, w)
        let box = Self.plan(page, [region]).box(region)
        let line = Self.rect64(page, above)
        let readings = [Self.letterSize(8), Self.letterSize(15), Self.letterSize(12)].map { line.minY + Self.entry(letterSize: $0) }
        // The three readings give three limits, each between inner's top and
        // the top margin's reach, so each would paint differently.
        #expect(Set(readings).count == 3)
        for limit in readings { #expect(box.inner.maxY < limit && limit < box.inner.maxY + Self.margins(box.inner.height).top) }
        let limit = try #require(box.limitAbove)
        #expect(limit == readings[0], "the most common letter height (8 pt), not the line height (15 pt) or the tallest letter (12 pt)")
        #expect(box.paint.maxY == limit)
    }

    @Test("A limit that would fall inside inner stops at inner's edge")
    func limitNeverInsideInner() {
        var page = Sheet()
        page.line(count: 4, y: 700)
        let line = page.line(count: 4, y: 693)
        page.line(count: 4, y: 686.5)
        let region = Self.matched(page, line[1])
        let box = Self.plan(page, [region]).box(region)
        #expect(box.limitAbove == box.inner.maxY)
        #expect(box.paint.maxY == box.inner.maxY)
        #expect(box.limitBelow == box.inner.minY)
        #expect(box.paint.minY == box.inner.minY)
    }

    @Test("Two regions on adjacent words, from different searches, are one box")
    func adjacentWordsMerge() {
        var sheet = Sheet()
        let w = sheet.line("by Jane Roe here", x: 72, y: 700)
        let jane = Self.matched(sheet, w[1]), roe = Self.matched(sheet, w[2])
        let made = Self.plan(sheet, [jane, roe])
        #expect(made.plan.boxes.count == 1)
        #expect(made.plan.boxes[0].regionIDs == [jane.id, roe.id])
        #expect(made.facts.boxes == 2, "a merged box counts both regions")
    }

    @Test("Two regions with a word between them stay two boxes")
    func wordBetweenKeepsTwoBoxes() {
        var sheet = Sheet()
        let w = sheet.line("Jane and Roe", x: 72, y: 700)
        let made = Self.plan(sheet, [Self.matched(sheet, w[0]), Self.matched(sheet, w[2])])
        #expect(made.plan.boxes.count == 2)
    }

    @Test("Two regions of different heights merged: inner holds both")
    func mergedHeights() {
        var sheet = Sheet()
        let w = sheet.line("by Jane Roe here", x: 72, y: 700)
        let jane = Self.matched(sheet, w[1], up: 1.5), roe = Self.matched(sheet, w[2])
        let made = Self.plan(sheet, [jane, roe])
        #expect(made.plan.boxes.count == 1)
        #expect(made.plan.boxes[0].inner.maxY == Self.placed(jane).maxY)
    }

    @Test("A match on two lines is one region and one box, never split")
    func twoLinesOneRegion() {
        var sheet = Sheet()
        let a = sheet.line(count: 4, y: 700)
        let b = sheet.line(count: 4, y: 686)
        let scan = Self.matched(sheet, a[3].union(b[0]))
        let made = Self.plan(sheet, [scan])
        #expect(made.plan.boxes.count == 1)
        let typed = [Self.matched(sheet, a[3]), Self.matched(sheet, b[0])]
        #expect(Self.plan(sheet, typed).plan.boxes.count == 2, "a typed search's box for each line stays two boxes")
    }

    @Test("An anchored region whose rectangle ends 0.3 pt past its letters: inner holds the rectangle")
    func regionPastItsLetters() {
        var sheet = Sheet()
        let w = sheet.line(count: 3, y: 700)
        let region = Self.matched(sheet, w[1], right: 0.3)
        let box = Self.plan(sheet, [region]).box(region)
        #expect(box.inner.maxX == Self.placed(region).maxX)
        #expect(box.inner.maxX > Self.rect64(sheet, w[1]).maxX)
    }

    @Test("A Search region resized by hand, and one dragged over two lines: as drawn, one box, no margin")
    func editedRegionsAreAsDrawn() {
        var sheet = Sheet()
        let a = sheet.line(count: 4, y: 700)
        sheet.line(count: 4, y: 686)
        let resized = Self.matched(sheet, a[1], kind: .placedFromTextThenEdited, right: 9)
        let dragged = PlanRegion(id: UUID(), share: Self.share(PointRect(minX: 120, minY: 684, maxX: 160, maxY: 706)),
                                 kind: .placedFromTextThenEdited, selected: a[2])
        for on in [false, true] {
            let made = Self.plan(sheet, [resized, dragged], on: on)
            #expect(made.plan.boxes.count == 2)
            for region in [resized, dragged] {
                let box = made.box(region)
                #expect(box.inner == Self.placed(region) && box.paint == box.inner && box.asDrawn)
                #expect(box.limitAbove == nil && box.limitBelow == nil)
                #expect(box.treatment == (on ? .couldNotWiden(.byHand) : .notAsked))
            }
        }
    }

    @Test("A region half off the page: inner and paint are not clipped")
    func halfOffThePage() {
        var sheet = Sheet()
        sheet.line(count: 3, y: 700)
        let region = Self.drawn(PointRect(minX: -40, minY: 600, maxX: 40, maxY: 620))
        let box = Self.plan(sheet, [region]).box(region)
        #expect(box.inner.minX < 0 && box.inner == Self.placed(region) && box.paint == box.inner)
    }

    @Test("A region's left edge a hair under a whole sixty-fourth by the side in points is on it by S")
    func shareTimesWholeSide() {
        var sheet = Sheet()
        sheet.line(count: 3, y: 700)
        // 0.5 of the page's width: by S (39,168) exactly 19,584; by a side
        // read a hair under 612 pt, 19,583.99…, whose floor is one less.
        let region = PlanRegion(id: UUID(), share: PointRect(minX: 0.5, minY: 0.5, maxX: 0.6, maxY: 0.52), kind: .drawnByHand)
        let box = Self.plan(sheet, [region]).box(region)
        #expect(box.inner.minX == 19_584)
        #expect(Int((0.5 * (611.999_999_9 * 64)).rounded(.down)) == 19_583, "the engine's reading would give one less")
    }

    @Test("A hand-drawn box touching an anchored Search box on the same line stays two boxes")
    func handBoxIsNeverMerged() {
        var sheet = Sheet()
        let w = sheet.line("by Jane Roe here", x: 72, y: 700)
        let jane = Self.matched(sheet, w[1])
        let r = Self.rect(sheet, w[2])
        let hand = Self.drawn(PointRect(minX: Self.rect(sheet, w[1]).maxX, minY: r.minY, maxX: r.maxX, maxY: r.maxY))
        for on in [false, true] {
            #expect(Self.plan(sheet, [jane, hand], on: on).plan.boxes.count == 2)
        }
    }

    // MARK: - The as-placed row

    @Test("With the as-placed row every box is its region: nothing merged, no limit, no band")
    func asPlacedRow() {
        var sheet = Sheet()
        let lines = ComplementReadingTests.paragraph(&sheet, counts: [6, 5, 6])
        let regions = [Self.matched(sheet, lines[1][1]), Self.matched(sheet, lines[1][2]),
                       Self.drawn(PointRect(minX: 300, minY: 500, maxX: 340, maxY: 520)),
                       Self.matched(sheet, lines[0][0], kind: .placedFromPicture)]
        for on in [false, true] {
            let made = Self.plan(sheet, regions, on: on, source: .asPlaced)
            #expect(made.plan.boxes.count == regions.count)
            for region in regions {
                let box = made.box(region)
                #expect(box.regionIDs == [region.id])
                #expect(box.inner == Self.placed(region) && box.paint == box.inner && box.tight == box.inner)
                #expect(box.limitAbove == nil && box.limitBelow == nil)
                #expect(box.treatment == .notAsked && !box.bandMade && !box.asDrawn)
                #expect(box.exposure == .canShowLength)
            }
        }
    }

    // MARK: - Rows where no layout is read

    @Test("A Search box on a scan, a box placed by recognition, and turned print: the placed rectangle plus 1.5 pt, unchanged by the switch")
    func noLayoutRows() {
        var sheet = Sheet()
        let lines = ComplementReadingTests.paragraph(&sheet, counts: [6, 6, 6])
        let picture = PageTextFacts(showsInvisibleText: false, carriesPageScaleImage: true)
        let onScan = Self.matched(sheet, lines[1][2])
        let recognised = Self.matched(sheet, lines[1][4], kind: .placedFromPicture)
        for on in [false, true] {
            let scan = Self.plan(sheet, [onScan], on: on, facts: picture).box(onScan)
            #expect(scan.paint == Self.placed(onScan).outset96 && scan.inner == Self.placed(onScan))
            #expect(scan.treatment == (on ? .couldNotWiden(.scanOrPicture) : .notAsked))
            let typed = Self.plan(sheet, [recognised], on: on).box(recognised)
            #expect(typed.paint == Self.placed(recognised).outset96)
            #expect(typed.treatment == (on ? .couldNotWiden(.scanOrPicture) : .notAsked), "recognition on a typed page's picture")
        }
        var turned = Sheet()
        turned.line(count: 6, y: 700)
        var box: Set<Int> = []
        for k in 0..<6 {
            let w = turned.word("abcd", x: 72 + 28 * Double(k), y: 680, dy: 1.5)
            if k == 2 { box = w }
        }
        turned.line(count: 6, y: 650)
        let region = Self.matched(turned, box)
        for on in [false, true] {
            let made = Self.plan(turned, [region], on: on).box(region)
            #expect(made.paint == Self.placed(region).outset96)
            #expect(made.treatment == (on ? .couldNotWiden(.direction) : .notAsked))
        }
    }

    @Test("Only a box placed from typed text and still anchored is marked for the ink check: never by hand, edited, on a scan, by recognition or on turned print")
    func inkCheckableOnlyOnTypedText() {
        var sheet = Sheet()
        let lines = ComplementReadingTests.paragraph(&sheet, counts: [6, 6, 6])
        let typed = Self.matched(sheet, lines[0][1])
        let edited = Self.matched(sheet, lines[0][4], kind: .placedFromTextThenEdited, right: 9)
        let hand = Self.drawn(PointRect(minX: 100, minY: 684, maxX: 150, maxY: 698))
        let recognised = Self.matched(sheet, lines[2][3], kind: .placedFromPicture)
        for on in [false, true] {
            let made = Self.plan(sheet, [typed, edited, hand, recognised], on: on)
            #expect(made.box(typed).inkCheckable, "a Search box on a typed line (switch \(on))")
            #expect(!made.box(edited).inkCheckable && !made.box(hand).inkCheckable)
            #expect(!made.box(recognised).inkCheckable, "a box placed from the page's picture")
            let picture = PageTextFacts(showsInvisibleText: false, carriesPageScaleImage: true)
            #expect(!Self.plan(sheet, [typed], on: on, facts: picture).box(typed).inkCheckable, "a Search box on a scan")
        }
        // As placed, no box is marked: the check runs only at the switch's policy.
        #expect(!Self.plan(sheet, [typed], source: .asPlaced).box(typed).inkCheckable)
        // Turned print reads no layout.
        var turned = Sheet()
        turned.line(count: 6, y: 700)
        var box: Set<Int> = []
        for k in 0..<6 {
            let w = turned.word("abcd", x: 72 + 28 * Double(k), y: 680, dy: 1.5)
            if k == 2 { box = w }
        }
        turned.line(count: 6, y: 650)
        let region = Self.matched(turned, box)
        #expect(!Self.plan(turned, [region], on: true).box(region).inkCheckable, "turned print")
    }

    @Test("A hand-drawn box with the switch on: as drawn, by hand")
    func handDrawnWithTheSwitch() {
        var sheet = Sheet()
        _ = ComplementReadingTests.paragraph(&sheet, counts: [6, 6, 6])
        let region = Self.drawn(PointRect(minX: 100, minY: 684, maxX: 150, maxY: 698))
        let box = Self.plan(sheet, [region], on: true).box(region)
        #expect(box.inner == Self.placed(region) && box.paint == box.inner && box.asDrawn && !box.bandMade)
        #expect(box.treatment == .couldNotWiden(.byHand))
    }

    @Test("The policy table, row by row: each kind and reading paints by its row")
    func tableRowByRow() {
        var column = Sheet()
        let para = ComplementReadingTests.paragraph(&column, counts: [6, 6, 6])
        var alone = Sheet()
        let line = alone.line(count: 3, y: 700)
        let picture = PageTextFacts(showsInvisibleText: true, carriesPageScaleImage: false)
        let cases: [(LineReading, Sheet, Set<Int>, PageTextFacts)] = [
            (.column, column, para[1][2], Self.plain), (.noColumn, alone, line[1], Self.plain),
            (.scanOrPicture, column, para[1][2], picture),
        ]
        for (reading, sheet, offsets, facts) in cases {
            for kind in RegionKind.allCases {
                for on in [false, true] {
                    let region = Self.matched(sheet, offsets, kind: kind)
                    let box = Self.plan(sheet, [region], on: on, facts: facts).box(region)
                    let key = PolicyKey(kind: kind, reading: kind == .placedFromTextAnchored ? reading : .column, switchOn: on)
                    let rule = Self.policy.rule(for: key, source: .switchPolicy)!
                    switch rule.paint {
                    case .asDrawn: #expect(box.asDrawn && box.paint == Self.placed(region), "\(key)")
                    case .placedPlusFixedMargin: #expect(box.paint == Self.placed(region).outset96, "\(key)")
                    case .lineMargin: #expect(!box.bandMade && box.paint.contains(box.inner) && box.paint != box.inner, "\(key)")
                    case .band: #expect(box.bandMade, "\(key)")
                    // No page drawing is given, so no default band is taken.
                    case .defaultBand:
                        #expect(!box.bandMade && box.paint.contains(box.inner) && box.paint != box.inner
                                    && box.defaultWidth == .notTaken(.drawingNotRead), "\(key)")
                    case .asPlaced: Issue.record("no row of the table paints as placed")
                    }
                    switch rule.outcome {
                    case .notAsked: #expect(box.treatment == .notAsked, "\(key)")
                    case .couldNotWiden(let reason): #expect(box.treatment == .couldNotWiden(reason), "\(key)")
                    case .byPaint:
                        #expect([.widened, .alreadyAsWide, .couldNotWiden(.noColumn)].contains(box.treatment), "\(key)")
                    }
                }
            }
        }
    }

    // MARK: - The facts

    @Test("The facts count regions: a merged box counts both, and each takes its box's state")
    func factsCountRegions() {
        var sheet = Sheet()
        let lines = ComplementReadingTests.paragraph(&sheet, counts: [6, 6, 6, 6])
        let regions = [Self.matched(sheet, lines[1][2]), Self.matched(sheet, lines[1][3]),
                       Self.drawn(PointRect(minX: 300, minY: 500, maxX: 340, maxY: 520)),
                       Self.matched(sheet, lines[3][0], kind: .placedFromPicture)]
        let on = Self.plan(sheet, regions, on: true).facts
        #expect(on.boxes == 4 && on.widened == 2 && on.alreadyAsWide == 0 && on.fellBack == 0)
        #expect(on.couldNotWiden == [.byHand: 1, .scanOrPicture: 1])
        let off = Self.plan(sheet, regions).facts
        #expect(off.boxes == 4 && off.widened == 0 && off.couldNotWiden.isEmpty)
    }

    // MARK: - Properties

    @Test("Property: over random regions of every kind and place, some off the page, containment holds and each region is in exactly one box")
    func randomContainment() {
        var sheet = Sheet()
        let lines = ComplementReadingTests.paragraph(&sheet, counts: [6, 5, 6, 6, 4, 5])
        let words = lines.flatMap { $0 }
        var rng = SplitMix(seed: 0x6E03A)
        for _ in 0..<60 {
            var regions: [PlanRegion] = []
            for _ in 0..<Int(rng.next() % 6 + 1) {
                let kind = RegionKind.allCases[Int(rng.next() % 4)]
                if kind == .placedFromTextAnchored || rng.next() % 2 == 0 {
                    let i = Int(rng.next() % UInt64(words.count))
                    let offsets = rng.next() % 3 == 0 && i + 1 < words.count ? words[i].union(words[i + 1]) : words[i]
                    regions.append(Self.matched(sheet, offsets, kind: kind, left: rng.unit() * 0.5, right: rng.unit() * 0.5,
                                              up: rng.unit() * 0.5))
                } else {
                    let x = rng.unit() * 800 - 100, y = rng.unit() * 900 - 50
                    regions.append(Self.drawn(PointRect(minX: x, minY: y, maxX: x + 5 + rng.unit() * 80, maxY: y + 5 + rng.unit() * 30),
                                              kind: kind))
                }
            }
            for on in [false, true] {
                for source in PlanSource.allCases {
                    _ = Self.plan(sheet, regions, on: on, source: source)
                }
            }
        }
    }

    @Test("A plan is a pure function of its inputs: the same inputs give equal plans")
    func samePlanTwice() {
        var sheet = Sheet()
        let lines = ComplementReadingTests.paragraph(&sheet, counts: [6, 5, 6])
        let regions = [Self.matched(sheet, lines[1][1]), Self.matched(sheet, lines[1][2])]
        for on in [false, true] {
            #expect(Self.plan(sheet, regions, on: on).plan == Self.plan(sheet, regions, on: on).plan)
        }
    }

    /// A match on the lines at 700 and 672, word 1 of each, with a line at
    /// `middle` between them that carries none of its rows (nil: none).
    static func skippedLineBox(middle: Double?) -> PaintedBox {
        var page = Sheet()
        let top = page.line(count: 4, y: 700)
        if let middle { page.line(count: 4, y: middle) }
        let bottom = page.line(count: 4, y: 672)
        let region = Self.matched(page, top[1].union(bottom[1]))
        return Self.plan(page, [region]).box(region)
    }

    @Test("A match on two lines with no line between its rows takes both margins whole")
    func noLineBetweenTheRows() {
        let box = Self.skippedLineBox(middle: nil)
        let m = Self.margins(Self.s(10))
        #expect(box.paint.maxY == box.inner.maxY + m.top)
        #expect(box.paint.minY == box.inner.minY - m.bottom)
    }

    @Test("A line inside a two-line match's rectangle, carrying none of its rows, limits neither margin",
          arguments: [688.0, 684.0])
    func lineInsideTheMatchIsNoNeighbour(middle: Double) {
        let box = Self.skippedLineBox(middle: middle)
        let m = Self.margins(Self.s(10))
        #expect(box.paint.maxY == box.inner.maxY + m.top, "top margin whole")
        #expect(box.paint.minY == box.inner.minY - m.bottom, "bottom margin whole")
        #expect(box.limitAbove == nil && box.limitBelow == nil, "no neighbour above or below")
        #expect(box.paint.contains(box.inner))
    }

    /// A hand box 1 pt around a set of letters.
    static func handAround(_ page: Sheet, _ offsets: Set<Int>) -> PlanRegion {
        let r = Self.rect(page, offsets)
        return Self.drawn(PointRect(minX: r.minX - 1, minY: r.minY - 1, maxX: r.maxX + 1, maxY: r.maxY + 1))
    }

    /// A found word on a tight pitch (15.46 pt letters on 13.55 pt lines),
    /// with or without a word on the line above, that word under a hand box
    /// or not; and the whole top margin of the line.
    static func tightPitchFound(wordAbove: Bool, handOverIt: Bool) -> (box: PaintedBox, top: Int) {
        var page = Sheet()
        var above: Set<Int> = []
        if wordAbove { above = page.word("abcd", x: 72 + 28, y: 700, height: 15.46) }
        let line = (0..<4).map { k in page.word("abcd", x: 72 + 28 * Double(k), y: 700 - 13.55, height: 15.46) }
        let found = Self.matched(page, line[1])
        var regions = [found]
        if handOverIt { regions.append(Self.handAround(page, above)) }
        let box = Self.plan(page, regions).box(found)
        let h = Self.rect64(page, line.reduce(into: Set<Int>()) { $0.formUnion($1) }).height
        return (box, Self.margins(h).top)
    }

    @Test("On a tight pitch an uncovered word above limits the top margin, and with no word above the margin is whole")
    func tightPitchControls() {
        let bare = Self.tightPitchFound(wordAbove: false, handOverIt: false)
        #expect(bare.box.paint.maxY == bare.box.inner.maxY + bare.top)
        let held = Self.tightPitchFound(wordAbove: true, handOverIt: false)
        #expect(held.box.paint.maxY < held.box.inner.maxY + held.top)
    }

    @Test("A word above wholly under a hand box is no neighbour: the top margin is whole")
    func wordUnderAHandBoxAboveIsNoNeighbour() {
        let r = Self.tightPitchFound(wordAbove: true, handOverIt: true)
        #expect(r.box.limitAbove == nil)
        #expect(r.box.paint.maxY == r.box.inner.maxY + r.top)
    }

    @Test("A word after a found word, wholly under a hand box: the end side is held by the next uncovered word")
    func wordUnderAHandBoxAfterIsNoStop() {
        var page = Sheet()
        let w = page.line(count: 4, y: 700)
        let found = Self.matched(page, w[0])
        let box = Self.plan(page, [found, Self.handAround(page, w[1])]).box(found)
        #expect(box.paint.maxX - box.inner.maxX == min(Self.margins(Self.s(10)).end, Self.s(32) / 2))
    }

    @Test("Two found words with a word between them wholly under a hand box are one box; the hand box stays its own")
    func foundWordsAcrossAHandCoveredWordJoin() {
        var page = Sheet()
        let w = page.line(count: 4, y: 700)
        let a = Self.matched(page, w[0]), c = Self.matched(page, w[2])
        let hand = Self.handAround(page, w[1])
        let made = Self.plan(page, [a, c, hand])
        #expect(made.box(a).regionIDs.contains(c.id))
        #expect(made.box(hand).regionIDs == [hand.id])
    }

    @Test("A word whose letters are each only partly under a hand box stays a neighbour")
    func wordPartlyUnderAHandBoxStays() {
        var page = Sheet()
        let w = page.line(count: 4, y: 700)
        let found = Self.matched(page, w[0])
        let r = Self.rect(page, w[1])
        let half = Self.drawn(PointRect(minX: r.minX - 1, minY: r.minY - 1, maxX: r.maxX + 1, maxY: (r.minY + r.maxY) / 2))
        let box = Self.plan(page, [found, half]).box(found)
        let bare = Self.plan(page, [found]).box(found)
        #expect(box.paint == bare.paint)
    }
}

extension PageRect64 {
    /// The rectangle with 1.5 pt more on every side.
    fileprivate var outset96: PageRect64 { PageRect64(minX: minX - 96, minY: minY - 96, maxX: maxX + 96, maxY: maxY + 96) }
}

/// A small seeded generator, so a property's regions are the same on every run.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
