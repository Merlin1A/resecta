import Foundation

extension PaintPlan {
    /// A page's boxes as the regions were placed, made once at run entry for
    /// the run's record: one box for each region given, in the order given.
    ///
    /// - `inner`, `paint` and `tight` are the region's rectangle in whole
    ///   sixty-fourths, made from its share of the page by
    ///   `PageRect64(share:widthSixtyFourths:heightSixtyFourths:)`, the one
    ///   place a share becomes sixty-fourths. The box is not clipped to the
    ///   page: a region that reaches past an edge keeps the part past it.
    /// - No limit line; the exposure and the treatment are the as-placed rule
    ///   of `policy` (this release: "can show length", not asked); no band,
    ///   no enlargement, not marked as drawn.
    /// - The box names its one region.
    ///
    /// The caller passes only the regions admission lets through. A region
    /// whose rectangle cannot be written in sixty-fourths has no box.
    /// `widthSixtyFourths` and `heightSixtyFourths` are the page's sides S in
    /// the frame as the page is rasterised.
    package static func asPlaced(
        regions: [(id: UUID, share: PointRect)],
        widthSixtyFourths width: Int, heightSixtyFourths height: Int,
        policy: GeometryPolicy = .release
    ) -> PaintPlan {
        let boxes = regions.compactMap { region -> PaintedBox? in
            guard let rect = PageRect64(share: region.share, widthSixtyFourths: width, heightSixtyFourths: height)
            else { return nil }
            return PaintedBox(regionIDs: [region.id], inner: rect, paint: rect, tight: rect,
                              limitAbove: nil, limitBelow: nil, exposure: policy.asPlaced.exposure,
                              treatment: .notAsked, bandMade: false, inkEnlargedCovered: false,
                              inkEnlargedToCap: false, asDrawn: false)
        }
        return PaintPlan(widthSixtyFourths: width, heightSixtyFourths: height, boxes: boxes)
    }
}
