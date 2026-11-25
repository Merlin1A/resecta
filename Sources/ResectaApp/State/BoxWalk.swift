import CoreGraphics
import Foundation
import RedactionEngine

/// Reading order for stepping through every box, and the steps through it.
///
/// The order is page by page, each page top to bottom, a row left to right.
/// It is taken once, when a walk starts, and does not change while the walk
/// lasts: a box moved or resized keeps its place, and a deleted one is skipped.
/// That is why `step` and `afterDelete` take `alive` and never a new order: a
/// box must not jump away from under the person who is mending it.
///
/// Every region's stored rectangle is a share of the page as displayed, so the
/// order is the reading order as shown, for drawn and found boxes alike.
///
/// `created` is a region's index in its page's stored array. Every maker
/// appends, and moves and resizes keep the index, but an Undo or a Redo that
/// puts a box back appends it again, so a restored box sorts as the newest of
/// its page. That reaches only exact ties (the same top, or the same left edge
/// within a row), and boxes restored together may come back in either order;
/// the order is still a reading order.
///
/// Pure: no state, no UIKit.
nonisolated enum BoxWalk {
    /// One box as the order reads it.
    nonisolated struct Box: Equatable, Sendable {
        var id: UUID
        /// The page index, as `RedactionState.regions` keys it.
        var page: Int
        /// The stored rectangle turned top-left: x = minX, y = 1 − maxY, the same
        /// width and height. Shares of the page from `boxes`; `order` reads any one
        /// unit per page the same way (it compares and scales, never converts).
        var rect: CGRect
        /// The region's index in `RedactionState.regions[page]`; unique per page.
        var created: Int
    }

    nonisolated enum Direction: Int, Sendable { case back = -1, forward = 1 }
    nonisolated enum Ends: Sendable { case wrap, stop }

    /// A box joins a row when its top is within this share of the smaller of its
    /// height and the row's first box's height (strictly).
    static let rowShare: CGFloat = 0.5

    /// The boxes of every page, from the stored regions.
    static func boxes(_ regions: [Int: [RedactionRegion]]) -> [Box] {
        var out: [Box] = []
        for page in regions.keys.sorted() {
            for (index, region) in (regions[page] ?? []).enumerated() {
                let stored = region.normalizedRect
                out.append(Box(
                    id: region.id,
                    page: page,
                    rect: CGRect(x: stored.minX, y: 1 - stored.maxY, width: stored.width, height: stored.height),
                    created: index
                ))
            }
        }
        return out
    }

    /// The ids in reading order.
    ///
    /// Pages ascend. On a page the boxes are sorted by top, then by `created`, and
    /// rows are made greedily down that list: a box joins the current row when its
    /// top is less than `rowShare` of the smaller of its height and the row's first
    /// box's height below that first box's top. The row anchors on its first box
    /// because a pairwise rule is not transitive and would not make rows. Within a
    /// row the boxes are sorted by left edge, then by `created`. Both tie-breaks are
    /// written, because `sort` is not stable.
    static func order(_ boxes: [Box]) -> [UUID] {
        let byPage = Dictionary(grouping: boxes, by: \.page)
        var out: [UUID] = []
        out.reserveCapacity(boxes.count)
        for page in byPage.keys.sorted() {
            let down = (byPage[page] ?? []).sorted { a, b in
                a.rect.minY != b.rect.minY ? a.rect.minY < b.rect.minY : a.created < b.created
            }
            var rows: [[Box]] = []
            for box in down {
                if let first = rows.last?.first,
                   box.rect.minY - first.rect.minY < rowShare * min(box.rect.height, first.rect.height) {
                    rows[rows.count - 1].append(box)
                } else {
                    rows.append([box])
                }
            }
            for row in rows {
                out += row.sorted { a, b in
                    a.rect.minX != b.rect.minX ? a.rect.minX < b.rect.minX : a.created < b.created
                }.map(\.id)
            }
        }
        return out
    }

    /// One step from `index`, skipping every id for which `alive` is false; nil when
    /// none is alive, the order is empty, or `index` is outside it.
    ///
    /// `.wrap`: forward from the last alive box goes to the first, and back from the
    /// first to the last; with one box alive, both directions return it. `.stop`: at
    /// an end the index stays if its box is alive, and otherwise the step goes the
    /// other way.
    static func step(_ order: [UUID], from index: Int, _ direction: Direction,
                     ends: Ends = .wrap, alive: (UUID) -> Bool) -> Int? {
        let n = order.count
        guard n > 0, order.indices.contains(index), order.contains(where: alive) else { return nil }
        var i = index
        for _ in 0..<n {
            var j = i + direction.rawValue
            if j < 0 || j >= n {
                guard ends == .wrap else {
                    if alive(order[index]) { return index }
                    return step(order, from: index, direction == .forward ? .back : .forward, ends: ends, alive: alive)
                }
                j = (j + n) % n
            }
            i = j
            if alive(order[i]) { return i }
        }
        return alive(order[index]) ? index : nil
    }

    /// After the box at `index` was deleted: the next alive box going forward,
    /// wrapping; nil when none is left or the order is empty.
    static func afterDelete(_ order: [UUID], at index: Int, alive: (UUID) -> Bool) -> Int? {
        let n = order.count
        guard n > 0 else { return nil }
        for k in 1...n {
            let j = ((index + k) % n + n) % n
            if alive(order[j]) { return j }
        }
        return nil
    }
}
