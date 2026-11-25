/// Where a person's first move or resize of a box placed for them starts:
/// a rectangle in whole sixty-fourths of a point, cut to the page, and the
/// clause of the rule that decided it.
///
/// The plan works it out when it is made, from values its maker already
/// holds, and paints nothing with it: computing it changes no run's output.
package struct PlannedStart: Hashable, Sendable {
    /// The start, cut to the page.
    package var rect: PageRect64
    /// Which clause decided it: 1 alone, 2 exactly held, 3 one line with its
    /// members level, 4 otherwise.
    package var clause: Int

    package init(rect: PageRect64, clause: Int) {
        self.rect = rect
        self.clause = clause
    }
}

/// The rule for a first edit's start, on whole sixty-fourths. Every
/// comparison is exact; no double is read.
package enum FirstEditStartRule {
    /// The start of a region whose box paints `paint`.
    ///
    /// - `own`: the region's rectangle as the plan holds it.
    /// - `neighbours`: the rectangles of the other regions the same box
    ///   covers, and `neighbourTights` their tight rectangles, in the same
    ///   order. A tight rectangle is the region's rectangle united with the
    ///   boxes of its own selected letters; `tight` is the region's own.
    /// - `oneLineBox`: whether the box stands on one line (`oneLineBox(rows:paint:pageLetters:)`).
    ///
    /// The first clause that matches decides:
    /// 1. no neighbour: the whole paint;
    /// 2. a neighbour's rectangle contains `own` and is not equal to it:
    ///    `own` itself (two equal rectangles do not hold each other);
    /// 3. a one-line box whose other members' tight rectangles have the
    ///    region's tight top and bottom exactly: the paint's top and bottom,
    ///    and along the line the paint's edge unless a neighbour reaches past
    ///    `own` on that side, then the nearest such neighbour's near edge,
    ///    never inside `own`;
    /// 4. otherwise: the whole paint.
    package static func start(own: PageRect64, paint: PageRect64, neighbours: [PageRect64],
                              tight: PageRect64, neighbourTights: [PageRect64], oneLineBox: Bool,
                              widthSixtyFourths: Int, heightSixtyFourths: Int) -> PlannedStart {
        let decided = decide(own: own, paint: paint, neighbours: neighbours, tight: tight,
                             neighbourTights: neighbourTights, oneLineBox: oneLineBox)
        return PlannedStart(rect: cut(decided.rect, widthSixtyFourths: widthSixtyFourths,
                                      heightSixtyFourths: heightSixtyFourths),
                            clause: decided.clause)
    }

    static func decide(own: PageRect64, paint: PageRect64, neighbours: [PageRect64], tight: PageRect64,
                       neighbourTights: [PageRect64], oneLineBox: Bool) -> (rect: PageRect64, clause: Int) {
        if neighbours.isEmpty { return (paint, 1) }
        if neighbours.contains(where: { $0.contains(own) && $0 != own }) { return (own, 2) }
        if oneLineBox, neighbourTights.allSatisfy({ $0.minY == tight.minY && $0.maxY == tight.maxY }) {
            var right = paint.maxX
            for n in neighbours where n.maxX > own.maxX { right = Swift.min(right, Swift.max(own.maxX, n.minX)) }
            var left = paint.minX
            for n in neighbours where n.minX < own.minX { left = Swift.max(left, Swift.min(own.minX, n.maxX)) }
            return (PageRect64(minX: left, minY: paint.minY, maxX: right, maxY: paint.maxY), 3)
        }
        return (paint, 4)
    }

    /// `rect` cut to the page: its part inside 0…W by 0…H. Never slid.
    static func cut(_ rect: PageRect64, widthSixtyFourths: Int, heightSixtyFourths: Int) -> PageRect64 {
        PageRect64(minX: Swift.max(rect.minX, 0), minY: Swift.max(rect.minY, 0),
                   maxX: Swift.min(rect.maxX, widthSixtyFourths), maxY: Swift.min(rect.maxY, heightSixtyFourths))
    }

    /// Whether a joined box stands on one line: its reading has exactly one
    /// row (`rows`, the box's selected letters joined as the page's lines are
    /// joined), and no letter of the page that shares no line with that row
    /// lies wholly inside `paint`, edges allowed to coincide. A letter the
    /// paint only cuts does not count. A box read as a scan or a picture, or
    /// by its direction, has no rows, so it is never on one line.
    package static func oneLineBox(rows: [PageRect64], paint: PageRect64, pageLetters: [PageRect64]) -> Bool {
        guard rows.count == 1, let row = rows.first else { return false }
        return !pageLetters.contains { !$0.sharesALine(with: row) && paint.contains($0) }
    }

    /// A start's share on one axis of a page S sixty-fourths long, from its
    /// edges k₀ and k₁: an origin x and a length w that read back, as
    /// `PageRect64(share:)` reads a rectangle (⌊x·S⌋, and ⌈(x + w)·S⌉ with
    /// the far edge as `CGRect` adds it), to k₀ and k₁ exactly. The plain
    /// quotients k/S do not always read back.
    ///
    /// 1. x = k₀/S; where ⌊x·S⌋ is not k₀, x steps one double up.
    /// 2. m = k₁/S; where ⌈m·S⌉ is not k₁, m steps one double toward k₁.
    /// 3. w = m − x.
    /// 4. Where ⌈(x + w)·S⌉ is still not k₁, m steps one more double toward
    ///    k₁, in the sum's direction, and w = m − x again.
    ///
    /// The steps are on the edge, never on the width: when w is far smaller
    /// than x a step of w can leave the sum unchanged, and a step of m always
    /// moves it.
    package static func share(minEdge k0: Int, maxEdge k1: Int, side: Int) -> (origin: Double, length: Double) {
        let s = Double(side), lo = Double(k0), hi = Double(k1)
        var x = lo / s
        if Int((x * s).rounded(.down)) != k0 { x = x.nextUp }
        var m = hi / s
        if Int((m * s).rounded(.up)) != k1 { m = m * s > hi ? m.nextDown : m.nextUp }
        var w = m - x
        let sum = (x + w) * s
        if Int(sum.rounded(.up)) != k1 {
            m = sum > hi ? m.nextDown : m.nextUp
            w = m - x
        }
        return (x, w)
    }
}
