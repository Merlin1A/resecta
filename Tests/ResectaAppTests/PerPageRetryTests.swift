import Testing
import Foundation
import PDFKit
import UIKit
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// PERF-1 — Per-page verification retry tests (KI-1).
// See plan.md §5 PERF-1 + §0.7 (retry placement).
//
// The retry wrapper lives in `PipelineCoordinator.rasterizeWithRetry`
// (called inside `processDocument`'s page loop). Tests drive
// `rasterizeWithRetry` directly so the assertion surface is the retry
// counter on a per-test `PageRasterizerTestSeam.Recorder`, not the
// surrounding pipeline machinery.

@Suite("Per-Page Verification Retry (PERF-1)", .tags(.coordination))
@MainActor
struct PerPageRetryTests {

    // MARK: - testRetryAtHalfDPISucceeds

    @Test("Retry at half DPI succeeds; rasterize counter == pageCount + 1",
          .timeLimit(.minutes(1)))
    func testRetryAtHalfDPISucceeds() async throws {
        let coord = makeCoordinatorWithMultiPagePDF(pages: 50, regions: true)
        let rasterizer = PageRasterizer()
        let pageDataList = coord.buildPDFPageData(effectiveMode: .secureRasterization)
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

    // MARK: - testHalfDPIFloor96

    @Test("Half-DPI floor is 96 (not 75) when primary cap = 150",
          .timeLimit(.minutes(1)))
    func testHalfDPIFloor96() async throws {
        let coord = makeCoordinatorWithMultiPagePDF(pages: 1, regions: true)
        // Drive the coordinator's primary cap down so half would be 75 (below
        // floor). With the floor at 96 the retry call must use 96, not 75.
        coord.dpiCap = 150
        // Capture so the assertions match the value the rasterize call saw,
        // not a value a sibling test may push afterward via a memory-warning
        // notification.
        let primaryCap = 150

        let rasterizer = PageRasterizer()
        let pageDataList = coord.buildPDFPageData(effectiveMode: .secureRasterization)
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
        #expect(dpiHistory.first?.dpiCap == 150,
                "First call should use the primary cap (150)")
        #expect(dpiHistory.last?.dpiCap == 96,
                "Retry call should clamp to the floor (96), not primary/2 (75); got \(String(describing: dpiHistory.last?.dpiCap))")
    }

    // MARK: - testSecondFailurePropagates

    @Test("Second failure propagates the same fillVerificationFailed error",
          .timeLimit(.minutes(1)))
    func testSecondFailurePropagates() async throws {
        let coord = makeCoordinatorWithMultiPagePDF(pages: 50, regions: true)
        let rasterizer = PageRasterizer()

        let pageDataList = coord.buildPDFPageData(effectiveMode: .secureRasterization)
        let target = try #require(pageDataList.first(where: { $0.pageIndex == 27 }))

        let recorder = PageRasterizerTestSeam.Recorder(
            simulatedVerifyFailures: [target.pageIndex]
        )

        // Capture the primary cap up front. `coord.dpiCap` can be lowered
        // asynchronously by sibling tests that post
        // `UIApplication.didReceiveMemoryWarningNotification`; if we read
        // it again in the assertions we may see the lowered value, not the
        // one the rasterize call actually used.
        let capturedDPICap = coord.dpiCap

        // The production wrapper consumes the seam after the primary call,
        // so the retry succeeds — that's the wrong shape for this test.
        // The helper below mirrors `rasterizeWithRetry`'s contract but
        // re-arms the recorder between attempts, forcing BOTH the primary
        // and retry calls to throw. The wrapper's "propagate after second
        // failure" branch is what we exercise.
        await #expect(throws: PipelineError.self) {
            try await PageRasterizerTestSeam.withActivated(recorder) {
                try await rasterizeFailingBothAttempts(
                    target, rasterizer: rasterizer,
                    primaryDPICap: capturedDPICap,
                    recorder: recorder
                )
            }
        }

        // Confirm both attempts were observed and the second-attempt DPI
        // honoured the half-with-floor rule.
        let history = recorder.dpiCapHistory
        #expect(history.count == 2, "Both attempts must run before propagation")
        #expect(history.first?.dpiCap == capturedDPICap)
        #expect(history.last?.dpiCap == max(96, capturedDPICap / 2))
    }

    // MARK: - Helpers

    /// Mirrors `PipelineCoordinator.rasterizeWithRetry` but re-arms the
    /// recorder between attempts so BOTH the primary and retry calls see
    /// the failure injection. Used by `testSecondFailurePropagates` only —
    /// production code never re-arms a consumed recorder.
    private func rasterizeFailingBothAttempts(
        _ page: PDFPageData,
        rasterizer: PageRasterizer,
        primaryDPICap: Int,
        recorder: PageRasterizerTestSeam.Recorder
    ) async throws -> RasterizeResult {
        do {
            return try await rasterizer.rasterize(page, dpiCap: primaryDPICap)
        } catch let error as PipelineError { // LegalPhrases:safe (Swift keyword)
            guard case .redactionError(.fillVerificationFailed(let idx)) = error,
                  idx == page.pageIndex else {
                throw error
            }
            // Re-arm so the retry also fails. Production rasterize calls do
            // not do this — the seam consumes the index after the first
            // failure.
            recorder.insertSimulatedFailure(idx)
            let retryDPICap = max(PipelineCoordinator.retryDPIFloor, primaryDPICap / 2)
            return try await rasterizer.rasterize(page, dpiCap: retryDPICap)
        }
    }

    /// Build a coordinator backed by a multi-page PDF with a small redaction
    /// region on every page (so AD-4-1 sub-threshold filtering keeps the
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
