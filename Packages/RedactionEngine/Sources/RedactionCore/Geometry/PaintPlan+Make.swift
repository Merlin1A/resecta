import Foundation

/// A region as the plan reads it: as the editor holds it, before any clamp,
/// for a region that admission lets through.
package struct PlanRegion: Hashable, Sendable {
    package var id: UUID
    /// Its rectangle as a share of the page as displayed, in the page's frame
    /// as it is rasterised, origin bottom-left. A share may lie below 0 or
    /// above 1; nothing is clipped.
    package var share: PointRect
    package var kind: RegionKind
    /// The page's characters it was placed on, as UTF-16 offsets of the
    /// page's string; empty for a region drawn by hand. Read only for a region
    /// still anchored to its text.
    package var selected: Set<Int>

    package init(id: UUID, share: PointRect, kind: RegionKind, selected: Set<Int> = []) {
        self.id = id
        self.share = share
        self.kind = kind
        self.selected = selected
    }
}

/// What a page's plan says, counted by region: one region is one counted
/// box, and a region takes the state of the box that covers it.
package struct PlanFacts: Hashable, Sendable {
    package var boxes = 0
    package var widened = 0
    package var alreadyAsWide = 0
    package var couldNotWiden: [WidenReason: Int] = [:]
    package var fellBack = 0
    /// The page's unselected words whose box shares area with a box's paint.
    package var unselectedWordsInsidePaint = 0

    package init() {}
}

extension PageRect64 {
    /// A region's rectangle in whole sixty-fourths from its share of the
    /// page: left and bottom ⌊share × S⌋, right and top ⌈share × S⌉, with S
    /// the page's side in whole sixty-fourths. This is the one place a share
    /// becomes sixty-fourths. Nil when a product is not a finite number or
    /// lies 2³⁰ sixty-fourths or more from the origin.
    package init?(share: PointRect, widthSixtyFourths: Int, heightSixtyFourths: Int) {
        let w = Double(widthSixtyFourths), h = Double(heightSixtyFourths)
        let sides = [share.minX * w, share.minY * h, share.maxX * w, share.maxY * h]
        guard sides.allSatisfy({ $0.isFinite && abs($0) < 0x1p30 }) else { return nil }
        self.init(minX: Int(sides[0].rounded(.down)), minY: Int(sides[1].rounded(.down)),
                  maxX: Int(sides[2].rounded(.up)), maxY: Int(sides[3].rounded(.up)))
    }

    /// Whether every point of `other` lies in this rectangle.
    package func contains(_ other: PageRect64) -> Bool {
        minX <= other.minX && minY <= other.minY && other.maxX <= maxX && other.maxY <= maxY
    }

    /// Whether the two share area.
    package func sharesArea(with other: PageRect64) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }

    func outset(top: Int, bottom: Int, left: Int, right: Int) -> PageRect64 {
        PageRect64(minX: minX - left, minY: minY - bottom, maxX: maxX + right, maxY: maxY + top)
    }
}

extension PaintPlan {
    /// A page's plan: a pure function of its regions, its words and the
    /// policy, made a page at a time in whole sixty-fourths of a point.
    ///
    /// - With `source` as placed, one box for each region: `inner` and
    ///   `paint` its rectangle, no limit lines.
    /// - With the switch's policy, regions placed from the page's text on one
    ///   line with no unselected character between them are one box; a box's
    ///   `inner` holds its selected letters and every region it covers, and
    ///   its paint is worked out by its row of the table.
    ///
    /// `width` and `height` are the page's sides S in whole sixty-fourths;
    /// `facts` say whether the page's words are the text its print is drawn
    /// from. The plan never splits a region, and every region is in exactly
    /// one box.
    package static func make(
        regions: [PlanRegion], words: PageWords, text: String, facts pageFacts: PageTextFacts,
        widthSixtyFourths width: Int, heightSixtyFourths height: Int,
        policy: GeometryPolicy, source: PlanSource, switchOn: Bool
    ) -> (plan: PaintPlan, facts: PlanFacts) {
        let placed: [(region: PlanRegion, rect: PageRect64)] = regions.compactMap { region in
            PageRect64(share: region.share, widthSixtyFourths: width, heightSixtyFourths: height).map { (region, $0) }
        }
        let maker = Maker(placed: placed, words: words, text: text, pageFacts: pageFacts, policy: policy,
                          source: source, switchOn: switchOn)
        let boxes = maker.boxes()
        return (PaintPlan(widthSixtyFourths: width, heightSixtyFourths: height, boxes: boxes.map(\.box)),
                maker.facts(of: boxes))
    }
}

/// The plan's work for one page.
private struct Maker {
    let placed: [(region: PlanRegion, rect: PageRect64)]
    let words: PageWords
    let text: String
    let pageFacts: PageTextFacts
    let policy: GeometryPolicy
    let source: PlanSource
    let switchOn: Bool
    let complement: PageComplement

    /// A box and the regions it covers, in the order of the input.
    struct Made {
        var box: PaintedBox
        var regions: [Int]
    }

    init(placed: [(region: PlanRegion, rect: PageRect64)], words: PageWords, text: String, pageFacts: PageTextFacts,
         policy: GeometryPolicy, source: PlanSource, switchOn: Bool) {
        self.placed = placed
        self.words = words
        self.text = text
        self.pageFacts = pageFacts
        self.policy = policy
        self.source = source
        self.switchOn = switchOn
        // Every anchored region's characters are selected when the page's
        // complement is made, so no box's own text is read as a neighbour.
        let selected = placed.reduce(into: Set<Int>()) { set, p in
            if p.region.kind == .placedFromTextAnchored { set.formUnion(p.region.selected) }
        }
        complement = Complement.page(words: words, text: text, selected: selected, constants: policy.provisional)
    }

    // MARK: - The boxes

    func boxes() -> [Made] {
        if source == .asPlaced {
            return placed.indices.map { i in
                let rect = placed[i].rect
                return Made(box: PaintedBox(regionIDs: [placed[i].region.id], inner: rect, paint: rect, tight: rect,
                                            limitAbove: nil, limitBelow: nil, exposure: policy.asPlaced.exposure,
                                            treatment: .notAsked, bandMade: false, inkEnlargedCovered: false,
                                            inkEnlargedToCap: false, asDrawn: false),
                            regions: [i])
            }
        }
        return groups().map { group in make(group) }
    }

    /// The reading of a set of selected characters, or nil when none has a box.
    func reading(of selected: Set<Int>) -> BoxReading? {
        guard !selected.isEmpty else { return nil }
        return Complement.reading(of: selected, on: complement, words: words, text: text, facts: pageFacts,
                                  constants: policy.provisional)
    }

    /// Whether a region's selected extents are read from a layout: placed from
    /// the text, still anchored, on a line the plan can read.
    func readsALayout(_ i: Int) -> Bool {
        guard placed[i].region.kind == .placedFromTextAnchored, let r = reading(of: placed[i].region.selected)
        else { return false }
        return r.reading == .column || r.reading == .noColumn
    }

    /// The regions in groups: regions whose extents are read from a layout
    /// join when they stand on one line with no unselected character between
    /// them; every other region is a group of its own.
    func groups() -> [[Int]] {
        var parent = Array(placed.indices)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { i = parent[i] }; return i }
        let joinable = placed.indices.filter(readsALayout)
        let rows = Dictionary(uniqueKeysWithValues: joinable.map { ($0, selectedRows(placed[$0].region.selected)) })
        for (k, a) in joinable.enumerated() {
            for b in joinable[(k + 1)...] where root(a) != root(b) {
                if adjoin(rows[a] ?? [], rows[b] ?? []) { parent[root(b)] = root(a) }
            }
        }
        var order: [Int] = []
        var members: [Int: [Int]] = [:]
        for i in placed.indices {
            let r = root(i)
            if members[r] == nil { order.append(r) }
            members[r, default: []].append(i)
        }
        return order.map { members[$0]! }
    }

    /// A set of selected letters' rows, each as one rectangle.
    func selectedRows(_ selected: Set<Int>) -> [PageRect64] {
        let rects = letterRects(selected)
        var rows: [PageRect64] = []
        for rect in rects.sorted(by: { $0.minY + $0.maxY > $1.minY + $1.maxY }) {
            if let i = rows.firstIndex(where: { 2 * Self.heightOverlap($0, rect) > Swift.min($0.height, rect.height) }) {
                rows[i] = rows[i].union(rect)
            } else {
                rows.append(rect)
            }
        }
        return rows
    }

    /// Whether two boxes' rows share a line with no unselected letter between
    /// them along it.
    func adjoin(_ a: [PageRect64], _ b: [PageRect64]) -> Bool {
        for ra in a {
            for rb in b where 2 * Self.heightOverlap(ra, rb) > Swift.min(ra.height, rb.height) {
                let lo = Swift.min(ra.maxX, rb.maxX), hi = Swift.max(ra.minX, rb.minX)
                if hi <= lo { return true }
                let band = PageRect64(minX: lo, minY: Swift.min(ra.minY, rb.minY), maxX: hi, maxY: Swift.max(ra.maxY, rb.maxY))
                let between = complement.lines.contains { line in
                    line.words.contains { word in
                        word.letters.contains { letter in
                            letter.rect.minX < hi && letter.rect.maxX > lo
                                && 2 * Self.heightOverlap(letter.rect, band) > Swift.min(letter.rect.height, band.height)
                        }
                    }
                }
                if !between { return true }
            }
        }
        return false
    }

    static func heightOverlap(_ a: PageRect64, _ b: PageRect64) -> Int { Swift.min(a.maxY, b.maxY) - Swift.max(a.minY, b.minY) }

    /// The selected letters' boxes in whole sixty-fourths, rounded outward.
    func letterRects(_ selected: Set<Int>) -> [PageRect64] {
        words.words.flatMap { word in
            word.letterBoxes.filter { selected.contains($0.offset) }.compactMap { PageRect64(outward: $0.rect) }
        }
    }

    // MARK: - One box

    func make(_ group: [Int]) -> Made {
        let regions = group.map { placed[$0] }
        let ids = Set(regions.map(\.region.id))
        let placedRect = regions.dropFirst().reduce(regions[0].rect) { $0.union($1.rect) }
        let kind = regions[0].region.kind
        let anchored = kind == .placedFromTextAnchored
        let selected = anchored ? regions.reduce(into: Set<Int>()) { $0.formUnion($1.region.selected) } : []
        let read = anchored ? reading(of: selected) : nil
        let lineReading: LineReading = switch kind {
        case .placedFromTextAnchored: read?.reading ?? .scanOrPicture
        case .placedFromPicture: .scanOrPicture
        // Every row for a box by hand paints it as drawn, whatever its line.
        case .drawnByHand, .placedFromTextThenEdited: .column
        }
        let rule = policy.rule(for: PolicyKey(kind: kind, reading: lineReading, switchOn: switchOn), source: source)
            ?? policy.asPlaced
        let letters = letterRects(selected)
        let tight = letters.reduce(placedRect) { $0.union($1) }

        func box(inner: PageRect64, paint: PageRect64, tight: PageRect64, above: Int?, below: Int?,
                 treatment: SwitchTreatment, band: Bool, asDrawn: Bool) -> Made {
            Made(box: PaintedBox(regionIDs: ids, inner: inner, paint: paint, tight: tight, limitAbove: above,
                                 limitBelow: below, exposure: rule.exposure, treatment: treatment, bandMade: band,
                                 inkEnlargedCovered: false, inkEnlargedToCap: false, asDrawn: asDrawn,
                                 inkCheckable: anchored && !asDrawn
                                     && (lineReading == .column || lineReading == .noColumn)),
                 regions: group)
        }
        let outcome: SwitchTreatment = switch rule.outcome {
        case .notAsked: .notAsked
        case .couldNotWiden(let reason): .couldNotWiden(reason)
        case .byPaint: .notAsked
        }

        switch rule.paint {
        case .asPlaced:
            return box(inner: placedRect, paint: placedRect, tight: placedRect, above: nil, below: nil,
                       treatment: outcome, band: false, asDrawn: false)
        case .asDrawn:
            return box(inner: placedRect, paint: placedRect, tight: placedRect, above: nil, below: nil,
                       treatment: outcome, band: false, asDrawn: true)
        case .placedPlusFixedMargin:
            let m = policy.fixedMarginSixtyFourths
            return box(inner: placedRect, paint: placedRect.outset(top: m, bottom: m, left: m, right: m),
                       tight: placedRect, above: nil, below: nil, treatment: outcome, band: false, asDrawn: false)
        case .lineMargin:
            let margin = marginPaint(inner: tight, rows: read?.rows ?? [])
            return box(inner: tight, paint: margin.paint, tight: tight, above: margin.above, below: margin.below,
                       treatment: outcome, band: false, asDrawn: false)
        case .band:
            let rows = read?.rows ?? []
            let band = self.band(tight: tight, rows: rows)
            let off = marginPaint(inner: tight, rows: rows)
            // The one place a band is made: it must hold every covered region
            // and every selected letter, or the box falls back.
            let holds = regions.allSatisfy { band.contains($0.rect) } && letters.allSatisfy { band.contains($0) }
            guard holds else {
                if regions.allSatisfy({ tight.contains($0.rect) }) && letters.allSatisfy({ tight.contains($0) }) {
                    return box(inner: tight, paint: off.paint, tight: tight, above: off.above, below: off.below,
                               treatment: .fellBack, band: false, asDrawn: false)
                }
                return box(inner: placedRect, paint: placedRect, tight: placedRect, above: nil, below: nil,
                           treatment: .fellBack, band: false, asDrawn: false)
            }
            let on = marginPaint(inner: band, rows: rows)
            let treatment: SwitchTreatment
            if on.paint != off.paint {
                treatment = .widened
            } else if rows.allSatisfy({ $0.roomLeft == nil && $0.roomRight == nil }) || rows.contains(where: \.columnInsideRoom) {
                treatment = .alreadyAsWide
            } else {
                treatment = .couldNotWiden(.noColumn)
            }
            return box(inner: band, paint: on.paint, tight: tight, above: on.above, below: on.below,
                       treatment: treatment, band: true, asDrawn: false)
        }
    }

    /// A row's line's height, or the row's own when no unselected word stands on it.
    func lineHeight(_ row: RowReading) -> Int {
        row.line.map { complement.lines[$0].height } ?? row.tight.height
    }

    // MARK: - The band

    /// The band: on each line, the column, the box's own run and its tight
    /// rectangle across the line's height, each end then pulled back to stand
    /// the stop's distance short of the nearest word of the line that is not
    /// in the own run, never inside the tight rectangle. Over several lines,
    /// the least reach on each side, and the tight rectangle.
    func band(tight: PageRect64, rows: [RowReading]) -> PageRect64 {
        guard !rows.isEmpty else { return tight }
        var left = Int.min, right = Int.max
        var bottom = tight.minY, top = tight.maxY
        let c = policy.provisional
        for row in rows {
            let h = lineHeight(row)
            let stop = Swift.max(LineMargin.ceil(h, c.stopLineHeights), c.stopPixelsSixtyFourths)
            var lo = [row.tight.minX, row.columnLeft, row.ownRun?.minX].compactMap { $0 }.min()!
            var hi = [row.tight.maxX, row.columnRight, row.ownRun?.maxX].compactMap { $0 }.max()!
            let lineWords = row.line.map { complement.lines[$0].words } ?? []
            func inOwnRun(_ w: ComplementWord) -> Bool {
                guard let run = row.ownRun else { return false }
                return w.box.minX >= run.minX && w.box.maxX <= run.maxX
            }
            if let next = lineWords.filter({ $0.box.minX >= row.tight.maxX && !inOwnRun($0) }).map(\.box.minX).min() {
                hi = Swift.max(Swift.min(hi, next - stop), row.tight.maxX)
            }
            if let prev = lineWords.filter({ $0.box.maxX <= row.tight.minX && !inOwnRun($0) }).map(\.box.maxX).max() {
                lo = Swift.min(Swift.max(lo, prev + stop), row.tight.minX)
            }
            left = Swift.max(left, lo)
            right = Swift.min(right, hi)
            if let line = row.line {
                bottom = Swift.min(bottom, complement.lines[line].box.minY)
                top = Swift.max(top, complement.lines[line].box.maxY)
            }
        }
        return PageRect64(minX: Swift.min(left, tight.minX), minY: bottom, maxX: Swift.max(right, tight.maxX), maxY: top)
    }

    // MARK: - The margin and its limit

    /// `inner` plus the line margin, the end side held to half the gap to
    /// the next unselected character, then held at the limit lines of the
    /// nearest unselected lines above and below that it overlaps along the
    /// line. A limit never lies inside `inner`.
    func marginPaint(inner: PageRect64, rows: [RowReading]) -> (paint: PageRect64, above: Int?, below: Int?) {
        let heights = rows.map(lineHeight)
        let topH = heights.first ?? inner.height
        let bottomH = heights.last ?? inner.height
        let alongH = heights.max() ?? inner.height
        var sides = policy.margin.sides(topHeight: topH, bottomHeight: bottomH, alongHeight: alongH)
        let next = rows.compactMap { row -> Int? in
            let lineWords = row.line.map { complement.lines[$0].words } ?? []
            return lineWords.filter { $0.box.minX >= inner.maxX }.map(\.box.minX).min()
        }.min()
        if let next { sides.end = Swift.min(sides.end, Swift.max(0, (next - inner.maxX) / 2)) }
        var paint = inner.outset(top: sides.top, bottom: sides.bottom, left: sides.start, right: sides.end)

        let own = Set(rows.compactMap(\.line))
        let middle2 = inner.minY + inner.maxY
        var above: Int?
        var below: Int?
        let neighbours = complement.lines.indices.filter { !own.contains($0) && complement.lines[$0].box.overlapsAlongLine(paint) }
        if let n = neighbours.filter({ complement.lines[$0].box.minY + complement.lines[$0].box.maxY > middle2 })
            .min(by: { complement.lines[$0].box.minY < complement.lines[$1].box.minY }) {
            let line = complement.lines[n]
            let limit = Swift.max(line.box.minY + policy.margin.entry(letterSize: Self.letterSize(line)), inner.maxY)
            above = limit
            paint.maxY = Swift.min(paint.maxY, limit)
        }
        if let n = neighbours.filter({ complement.lines[$0].box.minY + complement.lines[$0].box.maxY < middle2 })
            .max(by: { complement.lines[$0].box.maxY < complement.lines[$1].box.maxY }) {
            let line = complement.lines[n]
            let limit = Swift.min(line.box.maxY - policy.margin.entry(letterSize: Self.letterSize(line)), inner.minY)
            below = limit
            paint.minY = Swift.max(paint.minY, limit)
        }
        return (paint, above, below)
    }

    /// A line's letter size: the most common height among its letters, the
    /// larger on a tie.
    static func letterSize(_ line: ComplementLine) -> Int {
        var counts: [Int: Int] = [:]
        for word in line.words { for letter in word.letters { counts[letter.height, default: 0] += 1 } }
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key < b.key }?.key ?? line.height
    }

    // MARK: - The facts

    func facts(of made: [Made]) -> PlanFacts {
        var facts = PlanFacts()
        for m in made {
            let n = m.regions.count
            facts.boxes += n
            switch m.box.treatment {
            case .widened: facts.widened += n
            case .alreadyAsWide: facts.alreadyAsWide += n
            case .couldNotWiden(let reason): facts.couldNotWiden[reason, default: 0] += n
            case .fellBack: facts.fellBack += n
            case .notAsked: break
            }
        }
        let paints = made.map(\.box.paint)
        facts.unselectedWordsInsidePaint = complement.lines.reduce(0) { sum, line in
            sum + line.words.filter { word in paints.contains { $0.sharesArea(with: word.box) } }.count
        }
        return facts
    }
}

private extension PageRect64 {
    func overlapsAlongLine(_ other: PageRect64) -> Bool { minX < other.maxX && other.minX < maxX }
}
