import Testing
import Foundation
import PDFKit
import UIKit
import CoreGraphics
import RedactionCore
@testable import ResectaApp
@testable import RedactionEngine

// Per-page verification retry tests (KNOWN_ISSUES.md KI-1).
//
// The retry wrapper lives in `PipelineCoordinator.rasterizeWithRetry`
// (called inside `processDocument`'s page loop). Tests drive
// `rasterizeWithRetry` directly so the assertion surface is the retry
// counter on a per-test `PageRasterizerTestSeam.Recorder`, not the
// surrounding pipeline machinery.

@Suite("Per-Page Verification Retry", .tags(.coordination))
@MainActor
struct PerPageRetryTests {

    // MARK: - testRetryAtHalfDPISucceeds

    @Test("Retry at half DPI succeeds; rasterize counter == pageCount + 1",
          .timeLimit(.minutes(1)))
    func testRetryAtHalfDPISucceeds() async throws {
        let coord = makeCoordinatorWithMultiPagePDF(pages: 50, regions: true)
        let rasterizer = PageRasterizer()
        let pageDataList = coord.buildPDFPageData(effectiveMode: .secureRasterization, record: nil)
        #expect(pageDataList.count == 50, "Test precondition — 50-page fixture")

        // Capture the primary cap up front (see testSecondFailurePropagates
        // for the cross-test memory-warning race rationale).
        let capturedDPICap = coord.dpiCap

        // Fail page 27 on the first attempt; the retry call for page 27 will
        // succeed because the recorder consumes the index on the first
        // failure.
        let recorder = PageRasterizerTestSeam.Recorder(simulatedVerifyFailures: [27])

        var produced: [RasterizeResult] = []
        try await PageRasterizerTestSeam.withActivated(recorder) {
            for pageData in pageDataList {
                let result = try await coord.rasterizeWithRetry(
                    pageData,
                    rasterizer: rasterizer,
                    primaryDPICap: capturedDPICap
                )
                produced.append(result)
            }
        }

        // 50 normal pages + 1 retry for page 27 = 51 rasterize calls.
        #expect(recorder.rasterizeCallCount == 51,
                "Expected 51 rasterize calls (50 pages + 1 retry), got \(recorder.rasterizeCallCount)")
        #expect(produced.count == 50,
                "Every page should produce one final RasterizeResult — no full re-run")

        // The retry for page 27 was the only second-attempt call. Validate
        // by counting (pageIndex==27) entries in the DPI history.
        let page27Calls = recorder.dpiCapHistory.filter { $0.pageIndex == 27 }
        #expect(page27Calls.count == 2,
                "Page 27 should have exactly two rasterize calls (1 fail + 1 retry)")
    }

    // MARK: - testRetryRendersAtTheLowestTier

    @Test("The one retry renders at the lowest DPI tier whatever the primary cap",
          .timeLimit(.minutes(1)), arguments: [150, 200, 300])
    func testRetryRendersAtTheLowestTier(primaryCap: Int) async throws {
        let coord = makeCoordinatorWithMultiPagePDF(pages: 1, regions: true)
        let rasterizer = PageRasterizer()
        let pageDataList = coord.buildPDFPageData(effectiveMode: .secureRasterization, record: nil)
        let pageData = try #require(pageDataList.first)

        let recorder = PageRasterizerTestSeam.Recorder(
            simulatedVerifyFailures: [pageData.pageIndex]
        )

        try await PageRasterizerTestSeam.withActivated(recorder) {
            _ = try await coord.rasterizeWithRetry(
                pageData, rasterizer: rasterizer, primaryDPICap: primaryCap
            )
        }

        let dpiHistory = recorder.dpiCapHistory
        #expect(dpiHistory.count == 2,
                "One primary + one retry — got \(dpiHistory.count) entries")
        #expect(dpiHistory.first?.dpiCap == primaryCap,
                "First call should use the primary cap")
        #expect(dpiHistory.last?.dpiCap == 150,
                "The retry's cap is the 150 tier — the raster it renders is the raster its memory check estimates; got \(String(describing: dpiHistory.last?.dpiCap))")
    }

    // MARK: - testSecondFailurePropagates

    @Test("Second failure propagates the same fillVerificationFailed error",
          .timeLimit(.minutes(1)))
    func testSecondFailurePropagates() async throws {
        let coord = makeCoordinatorWithMultiPagePDF(pages: 50, regions: true)
        let rasterizer = PageRasterizer()

        let pageDataList = coord.buildPDFPageData(effectiveMode: .secureRasterization, record: nil)
        let target = try #require(pageDataList.first(where: { $0.pageIndex == 27 }))

        // The page fails BOTH attempts: the production wrapper's
        // "propagate after second failure" branch is what we exercise.
        let recorder = PageRasterizerTestSeam.Recorder(
            simulatedVerifyFailures: [target.pageIndex], failingAttempts: 2
        )

        // Capture the primary cap up front. `coord.dpiCap` can be lowered
        // asynchronously by sibling tests that post
        // `UIApplication.didReceiveMemoryWarningNotification`; if we read
        // it again in the assertions we may see the lowered value, not the
        // one the rasterize call actually used.
        let capturedDPICap = coord.dpiCap

        await #expect(throws: PipelineError.self) {
            try await PageRasterizerTestSeam.withActivated(recorder) {
                try await coord.rasterizeWithRetry(
                    target, rasterizer: rasterizer, primaryDPICap: capturedDPICap
                )
            }
        }

        // Confirm both attempts were observed and the second ran at the
        // lowest tier.
        let history = recorder.dpiCapHistory
        #expect(history.count == 2, "Both attempts must run before propagation")
        #expect(history.first?.dpiCap == capturedDPICap)
        #expect(history.last?.dpiCap == 150)
    }

    // MARK: - retryKeepsTheJoin

    @Test("A page shown at 200 whose first render fails its fill check: the retry at 150 holds the join",
          .timeLimit(.minutes(1)))
    func retryKeepsTheJoin() async throws {
        let coord = makeCoordinatorWithMultiPagePDF(pages: 1, regions: false)
        let doc = try #require(coord.documentState.sourceDocument)
        let pdfPage = try #require(doc.page(at: 0))
        let cropBox = pdfPage.bounds(for: .cropBox).size
        // The first of a few boxes whose own fill at 150 falls short of what
        // 200 showed, so the retry's paint differs with the join and without.
        var chosen: (region: RedactionRegion, plan: PaintPlan)?
        for i in 0..<40 {
            let region = RedactionRegion(
                id: UUID(), normalizedRect: CGRect(x: 0.1 + 0.0137 * Double(i), y: 0.2 + 0.0113 * Double(i),
                                                   width: 0.2311, height: 0.0219),
                source: .manual)
            let page = RunRecord.Page(pageIndex: 0, regions: [RunRecord.DrawnRegion(region: region)],
                                      cropBox: cropBox, rotation: 0, switchOn: false, shownDPI: 200)
            guard let plan = page.plan, let box = plan.boxes.first,
                  let raster = PixelPlan.Raster(widthSixtyFourths: plan.widthSixtyFourths,
                                                heightSixtyFourths: plan.heightSixtyFourths, dpi: 150) else { continue }
            let content = CGSize(width: PageRasterizer.contentSpan(plan.widthSixtyFourths, dpi: 150),
                                 height: PageRasterizer.contentSpan(plan.heightSixtyFourths, dpi: 150))
            let own = PageRasterizer.boxFill(box: box, regions: [region.id: region], raster: raster, content: content)
            let joined = PageRasterizer.boxFill(box: box, regions: [region.id: region], raster: raster,
                                                content: content, shownDPI: 200)
            if own != joined { chosen = (region, plan); break }
        }
        let (region, plan) = try #require(chosen, "a box the join changes at 150 against 200")
        coord.redactionState.regions[0] = [region]
        let record = RunInputs.confirmedRecord(
            pageCount: 1, geometry: RunInputs.pageGeometry(of: doc), shownDPIs: [0: 200],
            regions: coord.redactionState.regions, reads: [:], settings: .snapshot(from: coord.settingsState))
        let pageData = try #require(
            coord.buildPDFPageData(effectiveMode: .secureRasterization, record: record).first)
        #expect(pageData.confirmedPage?.shownDPI == 200)

        let recorder = PageRasterizerTestSeam.Recorder(simulatedVerifyFailures: [pageData.pageIndex])
        var result: RasterizeResult?
        try await PageRasterizerTestSeam.withActivated(recorder) {
            result = try await coord.rasterizeWithRetry(pageData, rasterizer: PageRasterizer(), primaryDPICap: 300)
        }
        #expect(recorder.dpiCapHistory.last?.dpiCap == 150, "the retry ran at 150")
        let painted = try #require(result?.paintedBoxes[0], "the retry reports its box")
        let raster = try #require(PixelPlan.Raster(widthSixtyFourths: plan.widthSixtyFourths,
                                                   heightSixtyFourths: plan.heightSixtyFourths, dpi: 150))
        let content = CGSize(width: PageRasterizer.contentSpan(plan.widthSixtyFourths, dpi: 150),
                             height: PageRasterizer.contentSpan(plan.heightSixtyFourths, dpi: 150))
        let box = try #require(pageData.confirmedPage?.plan?.boxes.first)
        var byID: [UUID: RedactionRegion] = [:]
        for clamped in pageData.regions { byID[clamped.id] = clamped }
        let joined = try #require(PageRasterizer.boxFill(box: box, regions: byID, raster: raster, content: content,
                                                         shownDPI: 200))
        #expect(painted == RunRecord.PaintedPixels(firstColumn: joined.minX, firstRowFromBottom: joined.minY,
                                                   columns: joined.maxX - joined.minX,
                                                   rows: joined.maxY - joined.minY),
                "the retry's paint is the join: \(painted), joined \(joined)")
    }

    // MARK: - Helpers

    /// Build a coordinator backed by a multi-page PDF with a small redaction
    /// region on every page (so sub-threshold filtering keeps the
    /// page in `buildPDFPageData`).
    private func makeCoordinatorWithMultiPagePDF(pages: Int, regions: Bool) -> PipelineCoordinator {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeMultiPagePDFDocument(pages: pages)
        if regions {
            let region = RedactionRegion(
                id: UUID(),
                normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05),
                source: .manual
            )
            for i in 0..<pages {
                coord.redactionState.regions[i] = [region]
            }
        }
        return coord
    }
}
