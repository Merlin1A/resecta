import CoreGraphics
import Foundation
import Testing
@testable import RedactionEngine

// The plan the editor draws a page from, and keeps (G-06a): made by the one
// maker the run's entry uses, with the page's sides S read through the one
// function, so the two make the same plan from the same inputs; kept with the
// switch, the quality and the fill it was drawn under. Under "as placed" each
// box is one admitted region, and the rectangle drawn is the region.

@Suite("The plan the editor draws and keeps")
struct DrawnPlanTests {

    static let letter = CGSize(width: 612, height: 792)
    /// A4 in points: neither side a whole number of points.
    static let a4 = CGSize(width: 595.2756, height: 841.8898)

    static func hand(_ rect: CGRect) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: rect, source: .manual)
    }

    static func placed(_ rect: CGRect) -> RedactionRegion {
        RedactionRegion(placing: SearchResult(pageIndex: 0, normalizedRect: rect, matchedText: "Delia",
                                              contextSnippet: "Delia Hartwell", source: .textLayer, term: "delia"))
    }

    /// A drawn box, a placed one, one reaching past the right edge, and one
    /// too thin to paint (admission refuses it: no box).
    static func regions() -> [RedactionRegion] {
        [hand(CGRect(x: 0.10, y: 0.10, width: 0.20, height: 0.05)),
         placed(CGRect(x: 0.4031, y: 0.3017, width: 0.1523, height: 0.0191)),
         hand(CGRect(x: 0.90, y: 0.70, width: 0.20, height: 0.02)),
         hand(CGRect(x: 0.50, y: 0.80, width: 0.0005, height: 0.02))]
    }

    static func drawn(_ regions: [RedactionRegion], cropBox: CGSize = letter, rotation: Int = 0, switchOn: Bool = false,
                      dpi: Int = 300, fill: FillColor = .black) -> DrawnPlan {
        DrawnPlan(pageIndex: 0, regions: regions, cropBox: cropBox, rotation: rotation,
                  switchOn: switchOn, exportDPI: dpi, fillColor: fill)
    }

    @Test("Under as placed, each box is one admitted region and the rectangle drawn is that region")
    func asPlacedDrawsTheRegion() throws {
        let regions = Self.regions()
        let admitted = regions.filter { RedactionRegion.isAdmitted(normalizedRect: $0.normalizedRect) }
        #expect(admitted.count == 3)
        let page = Self.drawn(regions)
        let plan = try #require(page.plan)
        #expect(page.boxes.count == 3)
        for (box, region) in zip(page.boxes, admitted) {
            #expect(box.regionIDs == [region.id])
            let r = region.normalizedRect
            let share = PointRect(minX: Double(r.minX), minY: Double(r.minY), maxX: Double(r.maxX), maxY: Double(r.maxY))
            let placedRect = try #require(PageRect64(share: share, widthSixtyFourths: plan.widthSixtyFourths,
                                                     heightSixtyFourths: plan.heightSixtyFourths))
            let made = try #require(plan.boxes.first { $0.regionIDs == [region.id] })
            // paint == the region, as placed; nothing widened, nothing outlined apart.
            #expect(made.paint == placedRect)
            #expect(made.inner == placedRect && made.tight == placedRect)
            #expect(box.paint == box.outline)
            // Drawn as a share, the region to within the sixty-fourth it was rounded out to.
            let dx = 1 / Double(plan.widthSixtyFourths), dy = 1 / Double(plan.heightSixtyFourths)
            #expect(box.paint.minX <= r.minX && r.minX - box.paint.minX < dx)
            #expect(box.paint.maxX >= r.maxX && box.paint.maxX - r.maxX < dx)
            #expect(box.paint.minY <= r.minY && r.minY - box.paint.minY < dy)
            #expect(box.paint.maxY >= r.maxY && box.paint.maxY - r.maxY < dy)
        }
    }

    @Test("The editor and the run's entry make one plan from the same inputs, at every quarter turn",
          arguments: [0, 90, 180, 270, -90, 450])
    func onePlanForEditorAndRun(rotation: Int) throws {
        let regions = Self.regions()
        let page = Self.drawn(regions, cropBox: Self.a4, rotation: rotation)
        let run = RunRecord.Page(pageIndex: 0, regions: regions.map(RunRecord.DrawnRegion.init(region:)),
                                 cropBox: Self.a4, rotation: rotation, switchOn: false)
        let plan = try #require(page.plan)
        #expect(plan == run.plan)
        let turned = ((rotation % 360) + 360) % 180 != 0
        let across = try #require(PixelPlan.sixtyFourths(ofSide: Double(turned ? Self.a4.height : Self.a4.width)))
        let up = try #require(PixelPlan.sixtyFourths(ofSide: Double(turned ? Self.a4.width : Self.a4.height)))
        #expect(plan.widthSixtyFourths == across && plan.heightSixtyFourths == up)
    }

    @Test("The kept plan names the switch, the quality, the fill and the sides it was drawn under")
    func keptWithItsSettings() {
        let regions = Self.regions()
        let base = Self.drawn(regions)
        #expect(base == Self.drawn(regions))
        #expect(base.switchOn == false && base.exportDPI == 300 && base.fillColor == .black)
        #expect(base != Self.drawn(regions, switchOn: true))
        #expect(base != Self.drawn(regions, dpi: 150))
        #expect(base != Self.drawn(regions, fill: .white))
        // One sixty-fourth of a point on one side makes another plan.
        #expect(base != Self.drawn(regions, cropBox: CGSize(width: 612 + 1.0 / 64, height: 792)))
        #expect(base != Self.drawn(Array(regions.dropLast(2))))
    }

    @Test("A page whose side cannot be read has no plan and draws no box")
    func unreadableSide() {
        for side in [CGSize(width: 0, height: 792), CGSize(width: 612, height: -1), CGSize(width: CGFloat.nan, height: 792)] {
            let page = Self.drawn(Self.regions(), cropBox: side)
            #expect(page.plan == nil)
            #expect(page.boxes.isEmpty)
        }
    }
}
