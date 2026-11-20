import CoreGraphics
import Foundation

/// A page as the editor last drew it: the plan made from its regions by the
/// one maker the run's entry uses (`RunRecord.Page.makePlan`), so with the
/// same two sides S, and the switch, the quality and the fill colour it was
/// drawn under. It is kept so a run can be compared with it: a plan or a
/// setting that differs is a plan the user was not shown.
///
/// The editor keeps one for each page it has drawn since that page's last
/// change. Under "as placed" each box is one admitted region as placed.
public struct DrawnPlan: Equatable, Sendable {
    public let pageIndex: Int
    /// The switch the plan was made under (the plan reads it only under the
    /// switch's policy).
    public let switchOn: Bool
    /// The quality the page was drawn under, in dots per inch: the quality a
    /// run started now rasterizes it at (`runQuality`, the chosen quality
    /// under the run's cap), as the editor passes it.
    public let exportDPI: Int
    /// The fill colour the page was drawn under.
    public let fillColor: FillColor
    /// The plan as made: its boxes and the sides S it was made with. Nil when
    /// a side of the page cannot be read; the page then has no boxes.
    package let plan: PaintPlan?
    /// The rectangles the overlay draws, one for each box of the plan, in
    /// the plan's order.
    public let boxes: [Box]
    /// The pixels each admitted region is filled with on the page's raster
    /// at `exportDPI`, by region id, in the fill bitmap's frame (origin
    /// bottom-left). Made by the run's own fill rule, not a copy of it: the
    /// run's `applyRedactionFills` fills each region with
    /// `normalizedToFillPixels(_:content:)` on the content basis
    /// `PageRasterizer.rasterContentSize(bounds:rotation:dpi:)`, and these
    /// are the same two functions on the same clamped rectangle. Under "as
    /// placed" each box covers one region, so a box is filled with its
    /// region's rectangle. Empty when the plan was given whole.
    public let filledPixels: [UUID: CGRect]

    /// One box of the plan as the overlay draws it: rectangles as a share of
    /// the page (0 to 1, origin bottom-left) in the frame its regions are
    /// drawn in, each the box's whole sixty-fourths divided by the page's
    /// side S.
    public struct Box: Equatable, Sendable {
        /// The ids of the regions the box covers.
        public let regionIDs: Set<UUID>
        /// The rectangle painted: the box's `paint`.
        public let paint: CGRect
        /// The rectangle outlined: the box's `tight`, its selected letters
        /// and covered regions.
        public let outline: CGRect
    }

    /// The page's plan from `regions` as drawn, the page's crop box and
    /// rotation, and the settings it is drawn under.
    public init(pageIndex: Int, regions: [RedactionRegion], cropBox: CGSize, rotation: Int,
                switchOn: Bool, exportDPI: Int, fillColor: FillColor) {
        let plan = RunRecord.Page.makePlan(regions: regions.map(RunRecord.DrawnRegion.init(region:)),
                                           cropBox: cropBox, rotation: rotation, switchOn: switchOn)
        self.init(pageIndex: pageIndex, switchOn: switchOn, exportDPI: exportDPI, fillColor: fillColor, plan: plan,
                  filledPixels: Self.filledPixels(regions: regions, cropBox: cropBox, rotation: rotation,
                                                  dpi: exportDPI))
    }

    /// Each admitted region's fill on the page's raster at `dpi`, as the run
    /// fills it: admitted and clamped as the run's inputs admit and clamp it
    /// (`RunInputs`), then the run's fill rule on the run's content basis.
    static func filledPixels(regions: [RedactionRegion], cropBox: CGSize, rotation: Int,
                             dpi: Int) -> [UUID: CGRect] {
        guard let content = PageRasterizer.rasterContentSize(
            bounds: CGRect(origin: .zero, size: cropBox), rotation: rotation, dpi: CGFloat(dpi)) else { return [:] }
        var filled: [UUID: CGRect] = [:]
        for region in regions where RedactionRegion.isAdmitted(normalizedRect: region.normalizedRect) {
            filled[region.id] = normalizedToFillPixels(region.normalizedRect.clampedToNormalized(), content: content)
        }
        return filled
    }

    package init(pageIndex: Int, switchOn: Bool, exportDPI: Int, fillColor: FillColor, plan: PaintPlan?,
                 filledPixels: [UUID: CGRect] = [:]) {
        self.pageIndex = pageIndex
        self.switchOn = switchOn
        self.exportDPI = exportDPI
        self.fillColor = fillColor
        self.plan = plan
        self.filledPixels = filledPixels
        guard let plan else { boxes = []; return }
        let w = Double(plan.widthSixtyFourths), h = Double(plan.heightSixtyFourths)
        func share(_ r: PageRect64) -> CGRect {
            CGRect(x: Double(r.minX) / w, y: Double(r.minY) / h,
                   width: Double(r.maxX - r.minX) / w, height: Double(r.maxY - r.minY) / h)
        }
        boxes = plan.boxes.map { Box(regionIDs: $0.regionIDs, paint: share($0.paint), outline: share($0.tight)) }
    }
}
