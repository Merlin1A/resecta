import Foundation

/// One rectangle of a page's text path, in output-page points, with its kind.
///
/// The text path reads these to choose which letters of the page's own text
/// leave the hidden layer, where the layout breaks its lines, and which
/// rectangles the page output and its digest record. A position check reads
/// the same list to test where a kept letter stands.
package struct TextPathRectangle: Equatable, Sendable {

    /// What a rectangle is to the text path.
    package enum Kind: Hashable, Sendable {
        /// A region's own rectangle where no box with a band covers it, and
        /// every region's hidden letters' rectangle and ink strips.
        case ordinary
        /// The inner rectangle of a box for which the plan made a band.
        case plansRectangle
        /// A region's own rectangle under a box for which the plan made a
        /// band. The filter and the layout do not read it, and it is not in
        /// the page output's rectangles; a check tests a letter's centre
        /// against it.
        case underWidenedBox
    }

    package var rect: CGRect
    package var kind: Kind

    package init(rect: CGRect, kind: Kind) {
        self.rect = rect
        self.kind = kind
    }

    /// Equal when the kinds are equal and the rectangles' origins and sizes
    /// are equal. Written out because the core imports Foundation only, where
    /// a rectangle has no equality of its own.
    package static func == (lhs: TextPathRectangle, rhs: TextPathRectangle) -> Bool {
        lhs.kind == rhs.kind
            && lhs.rect.origin.x == rhs.rect.origin.x && lhs.rect.origin.y == rhs.rect.origin.y
            && lhs.rect.size.width == rhs.rect.size.width && lhs.rect.size.height == rhs.rect.size.height
    }
}

/// A region as the text path reads it: its id and its rectangles, each in
/// output-page points. The caller fills it from the page's region and
/// converts every rectangle to that one frame first.
package struct TextPathRegion: Sendable {
    package var id: UUID
    /// The region's own rectangle.
    package var rect: CGRect
    /// The hidden letters' rectangle, for a region placed from a match on a
    /// page whose text is a hidden layer over its picture; nil otherwise.
    package var hiddenLettersRect: CGRect?
    /// The hidden letters' rectangles of the words whose printed ink the
    /// region covers; empty outside a run.
    package var inkStrips: [CGRect]

    package init(id: UUID, rect: CGRect, hiddenLettersRect: CGRect? = nil, inkStrips: [CGRect] = []) {
        self.id = id
        self.rect = rect
        self.hiddenLettersRect = hiddenLettersRect
        self.inkStrips = inkStrips
    }
}

extension TextPathRectangle {

    /// A page's text-path rectangles, from its regions in the page's order and
    /// its plan's boxes. Region by region:
    /// 1. if a box for which a band was made covers the region: at the first
    ///    of that box's regions, the box's inner rectangle, of the kind
    ///    `plansRectangle`; then the region's own rectangle, of the kind
    ///    `underWidenedBox`;
    /// 2. otherwise the region's own rectangle, `ordinary`;
    /// 3. then, in every case, the region's hidden letters' rectangle and its
    ///    ink strips, `ordinary`.
    ///
    /// After the last region, the inner rectangle of every box for which a
    /// band was made and none of whose regions was in the list, as
    /// `plansRectangle`: it is given, never passed over.
    ///
    /// Only the box's `bandMade` is read, never the name of its treatment: a
    /// band is made for a box that was widened, one already as wide as its
    /// line, and one that could not widen for want of a column. With no box
    /// for which a band was made, every rectangle is `ordinary` and the list
    /// is each region's own rectangle, hidden letters' rectangle and ink
    /// strips, in that order. A region two such boxes cover is read under the
    /// first of them in the plan's order.
    ///
    /// No page size enters, and nothing is turned: the caller gives the
    /// regions in the frame the plan's boxes are in. The inner rectangle is
    /// whole sixty-fourths of a point, and dividing by 64 is exact.
    package static func forPage(regions: [TextPathRegion], boxes: [PaintedBox]) -> [TextPathRectangle] {
        let banded = boxes.filter(\.bandMade)
        var given = [Bool](repeating: false, count: banded.count)
        var list: [TextPathRectangle] = []
        for region in regions {
            if let index = banded.firstIndex(where: { $0.regionIDs.contains(region.id) }) {
                if !given[index] {
                    list.append(TextPathRectangle(rect: points(banded[index].inner), kind: .plansRectangle))
                    given[index] = true
                }
                list.append(TextPathRectangle(rect: region.rect, kind: .underWidenedBox))
            } else {
                list.append(TextPathRectangle(rect: region.rect, kind: .ordinary))
            }
            if let hidden = region.hiddenLettersRect {
                list.append(TextPathRectangle(rect: hidden, kind: .ordinary))
            }
            for strip in region.inkStrips {
                list.append(TextPathRectangle(rect: strip, kind: .ordinary))
            }
        }
        for (index, box) in banded.enumerated() where !given[index] {
            list.append(TextPathRectangle(rect: points(box.inner), kind: .plansRectangle))
        }
        return list
    }

    /// A rectangle of whole sixty-fourths in points. The core imports
    /// Foundation alone, so the rectangle is built from its origin and size.
    static func points(_ rect: PageRect64) -> CGRect {
        CGRect(origin: CGPoint(x: CGFloat(rect.minX) / 64, y: CGFloat(rect.minY) / 64),
               size: CGSize(width: CGFloat(rect.width) / 64, height: CGFloat(rect.height) / 64))
    }
}
