import CoreGraphics
import Foundation
import RedactionEngine

// The first move or resize of a box placed from the page's text starts from
// where the page's plan already paints it, not from the word's own extent:
// the plan works each such box's start out when it is made
// (`DrawnPlan.firstEditStart(for:)`), and the canvas reads it here. One
// guard and one reader, so every gesture that edits a box asks the same
// question and reads the same start.

nonisolated enum FirstEdit {

    /// Whether a region's first edit starts from its start rectangle: a box
    /// still anchored to the text it was placed from. A box drawn by hand, or
    /// one already edited, edits from its own rectangle.
    static func applies(to region: RedactionRegion) -> Bool {
        region.textAnchored
    }

    /// The start for a region by id, or nil when there is none: no plan for
    /// the page, a region the plan does not hold, or a plan made without the
    /// page's words. The box then edits from its own rectangle.
    typealias StartReader = (_ regionID: UUID) -> DrawnPlan.FirstEditStart?

    /// A reader of the plan `plan` gives at the time of each read.
    static func reading(_ plan: @escaping () -> DrawnPlan?) -> StartReader {
        { regionID in plan()?.firstEditStart(for: regionID) }
    }

    /// The plan a start is read from: the kept plan when it is of the page as
    /// it is now (made from the page's stored regions at the page's current
    /// version), else the plan `madeAtRead` makes from the stored regions.
    /// A kept plan of an older version can still hold a box that is gone,
    /// and a start read from it would be that older page's.
    static func currentPlan(kept: DrawnPlan?, pageVersion: Int,
                            madeAtRead: () -> DrawnPlan?) -> DrawnPlan? {
        if let kept, kept.pageVersion == pageVersion, kept.fromStoredRegions == true { return kept }
        return madeAtRead()
    }

    /// A share's edges in whole sixty-fourths of a point of the page as
    /// shown (`displayedSize`): each edge times the side in sixty-fourths,
    /// rounded to the nearest whole number. Two shares are the same place
    /// when these are equal; the canvas's conversions through its points do
    /// not keep every bit of a share.
    static func sixtyFourths(_ share: CGRect, displayedSize: CGSize) -> [Int] {
        let w = (displayedSize.width * 64).rounded(), h = (displayedSize.height * 64).rounded()
        return [share.minX * w, share.minY * h, share.maxX * w, share.maxY * h].map { Int($0.rounded()) }
    }

    /// Whether two shares are the same place in sixty-fourths of the page as
    /// shown.
    static func samePlace(_ a: CGRect, _ b: CGRect, displayedSize: CGSize) -> Bool {
        sixtyFourths(a, displayedSize: displayedSize) == sixtyFourths(b, displayedSize: displayedSize)
    }
}
