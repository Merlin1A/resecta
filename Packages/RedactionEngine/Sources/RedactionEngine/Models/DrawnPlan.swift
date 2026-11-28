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
    /// The page's two sides S in whole sixty-fourths, in the frame as it is
    /// rasterised, as the plan was made with them. Nil when a side cannot be
    /// read.
    public var widthSixtyFourths: Int? { plan?.widthSixtyFourths }
    public var heightSixtyFourths: Int? { plan?.heightSixtyFourths }
    /// The page's version when the editor kept this plan, and whether the
    /// regions it was made from were the page's stored regions then (not a
    /// working copy, as during a drag). Nil until the editor stamps it
    /// (`stamped(pageVersion:fromStoredRegions:)`); a reader treats a plan
    /// at another version than the page's as one made before the page last
    /// changed.
    public private(set) var pageVersion: Int?
    public private(set) var fromStoredRegions: Bool?
    /// Whether the plan was made with the page's words (its read). A plan
    /// made without them has no first-edit start: with no letters a region's
    /// tight rectangle is its own, so the level test would read the wrong
    /// rectangles.
    package let wordsGiven: Bool
    /// Each region's first-edit start, by region id.
    let starts: [UUID: FirstEditStart]

    /// The first edit's start for a region of this plan: nil for a region
    /// drawn or edited by hand, for a region the plan does not hold, and for
    /// every region of a plan made without the page's words.
    public func firstEditStart(for regionID: UUID) -> FirstEditStart? {
        wordsGiven ? starts[regionID] : nil
    }

    /// This plan as kept at a page version, from the stored regions or not.
    public func stamped(pageVersion: Int, fromStoredRegions: Bool) -> DrawnPlan {
        var kept = self
        kept.pageVersion = pageVersion
        kept.fromStoredRegions = fromStoredRegions
        return kept
    }

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
        /// The pixels a run fills the box with before ink growth, on the
        /// page's raster at `exportDPI`, in the fill bitmap's frame (origin
        /// bottom-left), when the run paints from the plan (a page with a
        /// record): one rectangle, the run's own `PageRasterizer.boxFill`;
        /// for a box that does not project, its regions' own fills, as the
        /// run fills them then. Empty when the plan was given whole.
        public let fill: [CGRect]
    }

    /// Where a person's first move or resize of a region placed for them
    /// starts, worked out when the plan is made.
    public struct FirstEditStart: Equatable, Sendable {
        /// The start as a share of the page (0 to 1, origin bottom-left) in
        /// the frame its regions are drawn in, cut to the page. It reads back
        /// to the start's whole sixty-fourths exactly.
        public let share: CGRect
        /// Which clause of the start rule decided it: 1 alone, 2 exactly held
        /// by another region of its box, 3 one line with its regions level,
        /// 4 otherwise.
        public let clause: Int
    }

    /// The page's plan from `regions` as drawn, the page's crop box and
    /// rotation, the page's read, and the settings it is drawn under. The
    /// read is the one the run's entry hands the same maker
    /// (`DocumentState.pageReads`), so the two make the same plan.
    public init(pageIndex: Int, regions: [RedactionRegion], cropBox: CGSize, rotation: Int,
                switchOn: Bool, exportDPI: Int, fillColor: FillColor, read: RunRecord.PageRead? = nil) {
        self.init(pageIndex: pageIndex, regions: regions, cropBox: cropBox, rotation: rotation, switchOn: switchOn,
                  exportDPI: exportDPI, fillColor: fillColor, read: read, source: RunRecord.planSource)
    }

    /// The same page under a plan source given here, as `RunRecord.Page`
    /// takes one: the editor passes the run's own; a test can name another.
    package init(pageIndex: Int, regions: [RedactionRegion], cropBox: CGSize, rotation: Int,
                 switchOn: Bool, exportDPI: Int, fillColor: FillColor, read: RunRecord.PageRead?, source: PlanSource) {
        let made = RunRecord.Page.makePlanAndInputs(regions: regions.map(RunRecord.DrawnRegion.init(region:)),
                                                    cropBox: cropBox, rotation: rotation, switchOn: switchOn,
                                                    read: read, source: source)
        let plan = made?.plan
        self.init(pageIndex: pageIndex, switchOn: switchOn, exportDPI: exportDPI, fillColor: fillColor, plan: plan,
                  filledPixels: Self.filledPixels(regions: regions, cropBox: cropBox, rotation: rotation,
                                                  dpi: exportDPI),
                  boxFills: plan.map { Self.boxFills(plan: $0, regions: regions, cropBox: cropBox,
                                                     rotation: rotation, dpi: exportDPI) } ?? [],
                  starts: made?.starts ?? [:], wordsGiven: read != nil)
    }

    /// A start as the plan holds it, as a share that reads back to its whole
    /// sixty-fourths exactly through `PageRect64(share:)`: each axis by the
    /// round trip of `FirstEditStartRule.share(minEdge:maxEdge:side:)`. The
    /// boxes' own shares stay plain quotients: nothing reads them back.
    static func firstEditStart(_ start: PlannedStart, plan: PaintPlan) -> FirstEditStart {
        let x = FirstEditStartRule.share(minEdge: start.rect.minX, maxEdge: start.rect.maxX,
                                         side: plan.widthSixtyFourths)
        let y = FirstEditStartRule.share(minEdge: start.rect.minY, maxEdge: start.rect.maxY,
                                         side: plan.heightSixtyFourths)
        return FirstEditStart(share: CGRect(x: x.origin, y: y.origin, width: x.length, height: y.length),
                              clause: start.clause)
    }

    /// Each box's fill as a run with a record paints it: the page's pixels
    /// by the run's own `PageRasterizer.pagePixels` (the plan's raster and
    /// the content span), the regions admitted and clamped as the run's
    /// inputs make them, then `PageRasterizer.boxFill`; a box that does not
    /// project gets its regions' own fills. Empty when the raster rule
    /// refuses the quality.
    static func boxFills(plan: PaintPlan, regions: [RedactionRegion], cropBox: CGSize, rotation: Int,
                         dpi: Int) -> [[CGRect]] {
        guard let pixels = PageRasterizer.pagePixels(
            cropBox: CGRect(origin: .zero, size: cropBox), rotation: rotation, hasRecord: true,
            recorded: (plan.widthSixtyFourths, plan.heightSixtyFourths), dpi: dpi),
            let raster = pixels.plan else { return [] }
        var byID: [UUID: RedactionRegion] = [:]
        for region in regions where RedactionRegion.isAdmitted(normalizedRect: region.normalizedRect) {
            var clamped = region
            clamped.normalizedRect = region.normalizedRect.clampedToNormalized()
            byID[region.id] = clamped
        }
        return plan.boxes.map { box in
            if let fill = PageRasterizer.boxFill(box: box, regions: byID, raster: raster, content: pixels.content) {
                return [fill.bitmapRect]
            }
            return box.regionIDs.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
                byID[id].map { normalizedToFillPixels($0.normalizedRect, content: pixels.content) }
            }
        }
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
                 filledPixels: [UUID: CGRect] = [:], boxFills: [[CGRect]] = [],
                 starts: [UUID: PlannedStart] = [:], wordsGiven: Bool = false) {
        self.pageIndex = pageIndex
        self.switchOn = switchOn
        self.exportDPI = exportDPI
        self.fillColor = fillColor
        self.plan = plan
        self.filledPixels = filledPixels
        self.wordsGiven = wordsGiven
        guard let plan else { boxes = []; self.starts = [:]; return }
        self.starts = starts.mapValues { Self.firstEditStart($0, plan: plan) }
        let w = Double(plan.widthSixtyFourths), h = Double(plan.heightSixtyFourths)
        func share(_ r: PageRect64) -> CGRect {
            CGRect(x: Double(r.minX) / w, y: Double(r.minY) / h,
                   width: Double(r.maxX - r.minX) / w, height: Double(r.maxY - r.minY) / h)
        }
        boxes = plan.boxes.enumerated().map { i, box in
            Box(regionIDs: box.regionIDs, paint: share(box.paint), outline: share(box.tight),
                fill: i < boxFills.count ? boxFills[i] : [])
        }
    }
}
