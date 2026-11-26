import CoreGraphics
import Foundation
import Testing
@testable import RedactionEngine

// A region the producer painted outside the page's plan has no rule that
// places its paint. The box check reads the record's set of such regions and
// lists each as its own unit it cannot judge, after the page's boxes, in the
// order the regions were drawn.

@Suite("The box check lists each region painted outside the plan")
struct BoxCheckOutsidePlanTests {
    typealias F = BoxCheckFixtures
    typealias Lines = PixelPaintRule.Lines

    @Test("Each region painted outside the plan is its own unit the check cannot judge, in drawn order")
    func regionsOutsideThePlanAreUnits() async throws {
        let (b, p) = BoxCheckTests.boxAt(Lines(left: 100, top: 100, right: 220, bottom: 140), dpi: 300, width: 600, height: 600)
        let (_, jpeg) = F.walk(F.picture(width: 600, height: 600, print: true, marks: [F.Mark(lines: p)]))
        let file = try await PageImageFixtures.export([jpeg], size: CGSize(width: 144, height: 144))
        let source = try #require(SystemPageImageSource(fileData: file))
        let (boxed, later, earlier) = (UUID(), UUID(), UUID())
        let share = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)
        let regions = [boxed, earlier, later].map { RunRecord.DrawnRegion(id: $0, normalizedRect: share, kind: .drawnByHand) }
        var produced = RunRecord.Produced(
            pageImageDigests: [0: PageImageFixtures.sha256(jpeg)],
            paintedRectangles: [.init(pageIndex: 0, box: 0): F.report(p, height: 600)], infoDictionary: nil)
        produced.regionsPaintedOutsideThePlan = [0: [later, earlier]]
        let record = RunRecord(
            confirmed: .init(fillColor: .black, exportDPI: 300, pages: [
                .init(pageIndex: 0, regions: regions,
                      plan: PaintPlan(widthSixtyFourths: 9216, heightSixtyFourths: 9216, boxes: [b])),
            ]),
            produced: produced)
        let input = try #require(BoxCheckInput(record: record))
        let report = try ExactFillCheck.run(fileData: file, source: source, input: input)
        let rule = ExactFillCheck.paintedOutsideThePlan
        #expect(report.outcomes.map(\.unit) == [.page(0), .box(page: 0, planIndex: 0),
                                                .region(page: 0, id: earlier), .region(page: 0, id: later)], "\(report.outcomes)")
        #expect(report.outcomes.map(\.kind) == [.completed, .completed, .inconclusive(rule), .inconclusive(rule)], "\(report.outcomes)")
        #expect(report.outcomes.suffix(2).allSatisfy { $0.kind.rowClass == .couldNotVerify })
    }
}
