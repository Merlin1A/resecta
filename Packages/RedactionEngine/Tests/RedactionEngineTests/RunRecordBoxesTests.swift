import CoreGraphics
import Foundation
import Testing
@testable import RedactionEngine

// The run's record makes each page's boxes once, at run entry, as the regions
// were placed: one box per region that admission lets through, `inner` and
// `paint` both the region's rectangle in whole sixty-fourths, not clipped to
// the page, with the page's two sides S read in the frame as it is
// rasterised. The capture's half (the page data carries these boxes) is in
// the app's tests.

@Suite("The run's record: boxes as placed")
struct RunRecordBoxesTests {

    /// A US Letter page's crop box.
    static let letter = CGSize(width: 612, height: 792)
    /// Letter's sides in whole sixty-fourths, unturned: 612 × 64 and 792 × 64.
    static let letterS = (width: 39_168, height: 50_688)

    static func region(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> RunRecord.DrawnRegion {
        RunRecord.DrawnRegion(id: UUID(), normalizedRect: CGRect(x: x, y: y, width: w, height: h), kind: .drawnByHand)
    }

    static func plan(_ regions: [RunRecord.DrawnRegion], cropBox: CGSize = letter, rotation: Int = 0) throws -> PaintPlan {
        try #require(RunRecord.Page(pageIndex: 0, regions: regions, cropBox: cropBox, rotation: rotation, switchOn: false).plan)
    }

    /// Each case, with what it builds and expects.
    enum Case: String, CaseIterable {
        case inPastTheEdgeAndThin = "a region inside, one past the right edge and one 0.0005 high: two boxes, the second not clipped"
        case whollyOff = "four regions of full size wholly off the page, off the right, the top, the left and the bottom: no box"
        case idsAreTheAdmitted = "the boxes name exactly the regions admission lets through, in order"
        case quarterTurn = "a Letter page turned a quarter has its two sides swapped"
        case outwardRounding = "a region's edges become whole sixty-fourths, left and bottom down, right and top up"
        case noRegion = "a page with no region: no box, and its two sides"
    }

    @Test("Each case", arguments: Case.allCases)
    func each(_ c: Case) throws {
        #expect(Case.allCases.count == 6)
        switch c {
        case .inPastTheEdgeAndThin:
            let inside = Self.region(0.1, 0.1, 0.2, 0.1)
            let past = Self.region(0.9, 0.5, 0.2, 0.05)
            let thin = Self.region(0.3, 0.3, 0.2, 0.0005)
            let plan = try Self.plan([inside, past, thin])
            try #require(plan.boxes.count == 2)
            #expect(plan.boxes.map(\.regionIDs) == [[inside.id], [past.id]])
            #expect(plan.boxes[1].inner.maxX > Self.letterS.width, "the box past the edge is not clipped")
            for box in plan.boxes {
                #expect(box.inner == box.paint)
                #expect(box.tight == box.inner)
                #expect(box.limitAbove == nil && box.limitBelow == nil)
                #expect(box.exposure == .canShowLength)
                #expect(box.treatment == .notAsked)
                #expect(!box.bandMade && !box.asDrawn && !box.inkEnlargedCovered && !box.inkEnlargedToCap)
            }

        case .whollyOff:
            let offRight = Self.region(1.2, 0.2, 0.3, 0.2)
            let offTop = Self.region(0.2, 1.2, 0.3, 0.2)
            let offLeft = Self.region(-0.5, 0.2, 0.3, 0.2)
            let offBottom = Self.region(0.2, -0.5, 0.3, 0.2)
            let plan = try Self.plan([offRight, offTop, offLeft, offBottom])
            // Admission cuts a region to the page on all four sides, so one
            // wholly off the left or the bottom is refused like the others.
            #expect(plan.boxes.isEmpty, "\(plan.boxes.map(\.regionIDs))")
            for r in [offRight, offTop, offLeft, offBottom] {
                #expect(RedactionRegion.admission(normalizedRect: r.normalizedRect) == .offThePage)
            }

        case .idsAreTheAdmitted:
            let regions = [Self.region(0.1, 0.1, 0.2, 0.1), Self.region(0.3, 0.3, 0.0005, 0.2),
                           Self.region(1.2, 0.6, 0.1, 0.1), Self.region(0.95, 0.2, 0.1, 0.1),
                           Self.region(-0.5, 0.4, 0.3, 0.1), Self.region(0.4, 0.7, 0.2, 0.05)]
            let plan = try Self.plan(regions)
            let admitted = regions.filter { RedactionRegion.isAdmitted(normalizedRect: $0.normalizedRect) }
            #expect(admitted.count == 3)
            #expect(plan.boxes.map(\.regionIDs) == admitted.map { [$0.id] })

        case .quarterTurn:
            let turned = try Self.plan([], rotation: 90)
            #expect((turned.widthSixtyFourths, turned.heightSixtyFourths) == (50_688, 39_168))
            let unturned = try Self.plan([], rotation: 0)
            #expect((unturned.widthSixtyFourths, unturned.heightSixtyFourths) == (39_168, 50_688))

        case .outwardRounding:
            let r = RunRecord.DrawnRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.25, width: 0.2, height: 0.25), kind: .drawnByHand)
            let plan = try Self.plan([r])
            let inner = try #require(plan.boxes.first?.inner)
            // 0.1 × 39,168 = 3,916.8 and 0.3 × 39,168 = 11,750.4 are not whole
            // and are rounded outward; 0.25 × 50,688 and 0.5 × 50,688 are.
            #expect(inner.minX == 3_916)
            #expect(inner.minY == 12_672)
            #expect(inner.maxX == 11_751)
            #expect(inner.maxY == 25_344)

        case .noRegion:
            let plan = try Self.plan([])
            #expect(plan.boxes.isEmpty)
            #expect((plan.widthSixtyFourths, plan.heightSixtyFourths) == (Self.letterS.width, Self.letterS.height))
        }
    }
}
