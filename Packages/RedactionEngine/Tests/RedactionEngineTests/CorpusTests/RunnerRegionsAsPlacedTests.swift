import CoreGraphics
import Foundation
import Testing
@testable import RedactionCore
@testable import RedactionEngine

// The corpus runner's regions under the run's plan source. The runner sets
// each region's anchored mark, but its source is a hand-drawn box, so its
// kind is drawn by hand, and the runner hands its page no read. Its box is
// then painted as drawn: the same rectangles and limits as the "as placed"
// box the runner was measured with, and never judged (the mark "as drawn"
// is read only to keep a box from the ink check).

@Suite("The corpus runner's regions under the run's plan source")
struct RunnerRegionsAsPlacedTests {
    static let letter = CGSize(width: 612, height: 792)

    /// Seeds as the corpus gives them: a word, a line, a tall cell, and one
    /// reaching past the page's right edge.
    static let seeds: [CGRect] = [
        CGRect(x: 0.12, y: 0.80, width: 0.08, height: 0.015),
        CGRect(x: 0.10, y: 0.50, width: 0.60, height: 0.02),
        CGRect(x: 0.30, y: 0.20, width: 0.10, height: 0.08),
        CGRect(x: 0.90, y: 0.60, width: 0.20, height: 0.02),
    ]

    @Test("Each runner region's box under the run's source is painted as drawn: its \"as placed\" rectangles and limits, and no judgement")
    func runnerRegionsPaintAsPlaced() throws {
        let regions = try Self.seeds.enumerated().map { i, rect in
            try #require(VerificationCorpusRunnerTests.region(
                from: .init(gtId: "g\(i)", value: "v", category: "name", page: 0, rect: rect), polygon: false))
        }
        #expect(regions.allSatisfy { RegionKind(of: $0) == .drawnByHand })
        let drawn = regions.map(RunRecord.DrawnRegion.init(region:))
        // As the runner makes it: the run's own page init, no read.
        let run = try #require(RunRecord.Page(pageIndex: 0, regions: drawn, cropBox: Self.letter, rotation: 0,
                                              switchOn: false).plan)
        let placed = try #require(RunRecord.Page(pageIndex: 0, regions: drawn, cropBox: Self.letter, rotation: 0,
                                                 switchOn: false, read: nil, source: .asPlaced).plan)
        #expect(run.boxes.count == placed.boxes.count && run.boxes.count == regions.count)
        for (a, b) in zip(run.boxes, placed.boxes) {
            #expect(a.regionIDs == b.regionIDs)
            #expect(a.inner == b.inner && a.paint == b.paint, "\(a.paint) vs \(b.paint)")
            #expect(a.limitAbove == b.limitAbove && a.limitBelow == b.limitBelow)
            #expect(a.exposure == b.exposure && a.bandMade == b.bandMade)
            #expect(a.asDrawn && !a.inkCheckable && a.treatment == .notAsked, "painted as drawn, never judged")
        }
        let page = RunRecord.Page(pageIndex: 0, regions: drawn, cropBox: Self.letter, rotation: 0, switchOn: false)
        #expect(page.inkCheckInputs.isEmpty && page.defaultFallbacks.isEmpty, "nothing to judge and no band to withdraw")
    }
}
