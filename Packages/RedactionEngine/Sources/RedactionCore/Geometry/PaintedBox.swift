import Foundation

/// How much of a covered value a box can let a reader learn, ordered from
/// the least to the most. The worst of two exposures is the one that can show
/// more. Every box of this release can show the value's length; the other two
/// values are declared for rows a later release may add.
package enum Exposure: String, Hashable, Sendable, Codable, CaseIterable, Comparable {
    /// The box shows nothing of the covered value's length.
    case hidden
    /// The box shows the covered value's length only to within a range.
    case narrowed
    /// The box can show the covered value's length.
    case canShowLength

    private var rank: Int {
        switch self {
        case .hidden: 0
        case .narrowed: 1
        case .canShowLength: 2
        }
    }

    package static func < (lhs: Exposure, rhs: Exposure) -> Bool { lhs.rank < rhs.rank }

    /// The worse of the two: the one that can show more.
    package func worst(_ other: Exposure) -> Exposure { Swift.max(self, other) }

    /// The worst exposure of a list, or nil for an empty one.
    package static func worst(of exposures: some Sequence<Exposure>) -> Exposure? { exposures.max() }
}

/// Why the switch could not widen a box. The cases are listed in the fixed
/// order in which they are tried, and a box records the first that holds.
package enum WidenReason: String, Hashable, Sendable, Codable, CaseIterable, Comparable {
    /// The region was drawn by hand, or was placed from the page's text and
    /// then moved or resized.
    case byHand
    /// The page's words are not the text its visible print is drawn from: the
    /// box was placed by recognition or on ink, the page shows invisible
    /// text, or a picture covers half the page or more.
    case scanOrPicture
    /// The box's own line shows that its print does not run level, upright
    /// and left to right as the page is displayed.
    case direction
    /// Too little unselected text above and below the box to show its column.
    case noColumn

    private var rank: Int { Self.allCases.firstIndex(of: self)! }

    package static func < (lhs: WidenReason, rhs: WidenReason) -> Bool { lhs.rank < rhs.rank }

    /// The reason a box records when these hold: the first in the fixed
    /// order, or nil when none does.
    package static func first(of holding: some Sequence<WidenReason>) -> WidenReason? { holding.min() }
}

/// How the switch that widens boxes to their column treated one box.
package enum SwitchTreatment: Hashable, Sendable {
    /// The switch was off, or the plan was made from the regions as placed.
    case notAsked
    /// A column was read and the box's paint differs from the paint the same
    /// inputs give with the switch off.
    case widened
    /// A column was read and the two paints are equal.
    case alreadyAsWide
    /// No column could be used, for this reason.
    case couldNotWiden(WidenReason)
    /// The widened rectangle did not hold every covered region and selected
    /// letter, so the box was painted from its tight rectangle, or else as
    /// placed. A correct plan never gives it.
    case fellBack

    /// The two counts a run reports with the switch on.
    package enum Count: Hashable, Sendable {
        case widened
        case couldNotWiden(WidenReason)
    }

    /// The one count the box is in, or nil when it is in neither: a box
    /// already as wide as its line, one the switch did not ask about, and
    /// one that fell back are counted in neither.
    package var count: Count? {
        switch self {
        case .widened: .widened
        case .couldNotWiden(let reason): .couldNotWiden(reason)
        case .notAsked, .alreadyAsWide, .fellBack: nil
        }
    }
}

/// What the plan did with a box's default band: the paint a box placed from
/// the page's typed text, still anchored, on a line whose column is read,
/// takes with the switch off.
package enum DefaultWidth: Hashable, Sendable {
    /// The box's row has no default band.
    case notAsked
    /// The box is painted with its default band.
    case taken
    /// The default band was not taken, for this reason, and the box is
    /// painted with its line margin.
    case notTaken(DefaultHold)
    /// The default band did not hold every covered region and selected
    /// letter, so the box is painted with its line margin. A correct plan
    /// never gives it.
    case fellBack
}

/// Why a box's default band was not taken.
package enum DefaultHold: Hashable, Sendable {
    /// An unselected word's box or a drawn object's bounds lies in the band,
    /// under the box's own letters included.
    case wordOrDrawingInBand
    /// The page paints a path or a shading, whose bounds the plan is not given.
    case pageDrawsLinesOrShading
    /// The page's painting was not followed to its end.
    case drawingNotRead
}

/// The four kinds of region a plan tells apart, from how the region was
/// placed and whether it has been edited since.
package enum RegionKind: String, Hashable, Sendable, Codable, CaseIterable {
    /// Drawn by hand (a duplicate of a region is one).
    case drawnByHand
    /// Placed from the page's own text and neither moved nor resized since.
    case placedFromTextAnchored
    /// Placed from the page's own text, then moved or resized.
    case placedFromTextThenEdited
    /// Placed from the page's picture: by recognition, or on its ink.
    case placedFromPicture
}

/// One box of a page's plan: the regions it covers, the rectangles worked out
/// for it, and what was recorded about it. Every rectangle and limit line is
/// in whole sixty-fourths of a point in the page's frame as it is rasterised,
/// origin bottom-left, so two boxes are equal only when every field is, and
/// two plans made from the same inputs are equal.
package struct PaintedBox: Hashable, Sendable {
    /// The ids of the regions the box covers.
    package var regionIDs: Set<UUID>
    /// The rectangle the box must cover: it holds every covered region.
    package var inner: PageRect64
    /// The rectangle painted before the pixel step's rounding.
    package var paint: PageRect64
    /// The bounding rectangle of the selected letters' boxes and the covered
    /// regions. Equal to `inner` for a box that is not widened.
    package var tight: PageRect64
    /// The line above the box that its paint may not cross, if there is one.
    package var limitAbove: Int?
    /// The line below the box that its paint may not cross, if there is one.
    package var limitBelow: Int?
    package var exposure: Exposure
    package var treatment: SwitchTreatment
    /// Whether the plan made a band for the box across its column.
    package var bandMade: Bool
    /// The ink check enlarged a side and the box covers the ink it found.
    package var inkEnlargedCovered: Bool
    /// The ink check enlarged a side to its cap, and ink of the boxed text
    /// can still lie past the box.
    package var inkEnlargedToCap: Bool
    /// The box is painted as it was drawn: no margin, no limit.
    package var asDrawn: Bool
    /// The ink check may judge the box: it was placed from the page's own
    /// text, is still anchored to it, and stands on a typed line (one the plan
    /// reads as a column or as no column), and it is not painted as drawn.
    /// Never a box drawn by hand, edited since, or placed from the page's
    /// picture. The plan sets it; the producer reads it.
    package var inkCheckable: Bool
    /// What the plan did with the box's default band.
    package var defaultWidth: DefaultWidth

    package init(
        regionIDs: Set<UUID>, inner: PageRect64, paint: PageRect64, tight: PageRect64,
        limitAbove: Int?, limitBelow: Int?, exposure: Exposure, treatment: SwitchTreatment,
        bandMade: Bool, inkEnlargedCovered: Bool, inkEnlargedToCap: Bool, asDrawn: Bool,
        inkCheckable: Bool = false, defaultWidth: DefaultWidth = .notAsked
    ) {
        self.regionIDs = regionIDs
        self.inner = inner
        self.paint = paint
        self.tight = tight
        self.limitAbove = limitAbove
        self.limitBelow = limitBelow
        self.exposure = exposure
        self.treatment = treatment
        self.bandMade = bandMade
        self.inkEnlargedCovered = inkEnlargedCovered
        self.inkEnlargedToCap = inkEnlargedToCap
        self.asDrawn = asDrawn
        self.inkCheckable = inkCheckable
        self.defaultWidth = defaultWidth
    }

    /// A limit line above a box at `points`, in whole sixty-fourths rounded
    /// toward the box (down). Nil for a value that is not finite or lies
    /// 2³⁰ points or more from the origin.
    package static func limitAbove(points: Double) -> Int? { SixtyFourths.floor(points) }

    /// A limit line below a box at `points`, in whole sixty-fourths rounded
    /// toward the box (up). Nil as for `limitAbove(points:)`.
    package static func limitBelow(points: Double) -> Int? { SixtyFourths.ceil(points) }
}

/// A page's plan: its boxes, and the page's two sides in whole sixty-fourths
/// of a point that it was made with. Plans made with different sides are
/// different plans.
package struct PaintPlan: Hashable, Sendable {
    package var widthSixtyFourths: Int
    package var heightSixtyFourths: Int
    package var boxes: [PaintedBox]

    package init(widthSixtyFourths: Int, heightSixtyFourths: Int, boxes: [PaintedBox]) {
        self.widthSixtyFourths = widthSixtyFourths
        self.heightSixtyFourths = heightSixtyFourths
        self.boxes = boxes
    }
}

/// Points to whole sixty-fourths of a point. Multiplying by 64 only moves the
/// binary point, so each conversion is exact for any value under 2³⁰ points.
package enum SixtyFourths {
    /// ⌊64·p⌋, or nil for a value that is not finite or is 2³⁰ points or more
    /// from the origin.
    package static func floor(_ points: Double) -> Int? {
        guard points.isFinite, abs(points) < 0x1p30 else { return nil }
        return Int((64 * points).rounded(.down))
    }

    /// ⌈64·p⌉, or nil as for `floor`.
    package static func ceil(_ points: Double) -> Int? {
        guard points.isFinite, abs(points) < 0x1p30 else { return nil }
        return Int((64 * points).rounded(.up))
    }
}

extension PageRect64 {
    /// The smallest rectangle of whole sixty-fourths that holds the rectangle
    /// with these edges in points: the left and bottom edges rounded down,
    /// the right and top edges up. Nil when an edge cannot be converted.
    package init?(outwardFromPoints minX: Double, minY: Double, maxX: Double, maxY: Double) {
        guard let left = SixtyFourths.floor(minX), let bottom = SixtyFourths.floor(minY),
              let right = SixtyFourths.ceil(maxX), let top = SixtyFourths.ceil(maxY) else { return nil }
        self.init(minX: left, minY: bottom, maxX: right, maxY: top)
    }
}
