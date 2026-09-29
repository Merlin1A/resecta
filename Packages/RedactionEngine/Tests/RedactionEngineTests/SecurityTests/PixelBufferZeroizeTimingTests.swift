import Testing
import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

// The zeroize wall-clock budget, split out of `PixelBufferZeroizeTests`
// so the batched runner's perf-alone list names this suite and the two
// correctness tests batch with every other `.critical` suite. Report-only
// where the runner lists it (`Scripts/test-batched.sh`
// `PERF_ALONE_RedactionEngine`; `engine-suite.yml` `HEAVY_SUITES`).
//
// What this tests: the zeroize cost on a 300-DPI letter page stays under
// the 5 ms p95 budget ("Per-page overhead recorded as a baseline." The
// 5 ms ceiling is the locked target; 25 ms is the CI ceiling).

@Suite("Pixel Buffer Zeroize Timing", .tags(.security, .performance), .serialized)
struct PixelBufferZeroizeTimingTests {

    // MARK: - testZeroizeOverheadUnder5msFor300DPILetter

    /// Run `zeroizeBitmapBuffer` in a 50-iteration loop against a 300-DPI
    /// US Letter bitmap. The target is ≤ 5 ms p95 in
    /// isolated benchmarking (memset of ~33 MB at typical bandwidth ≈
    /// 3.4 ms). When the engine test suite runs in parallel, memory and
    /// CPU pressure inflate the wall clock — we set a 25 ms CI ceiling
    /// (5x the spec target) to absorb that noise while still detecting
    /// pathological regressions (e.g., per-byte loop). The stress
    /// baseline records the steady-state number.
    @Test("zeroize p95 within CI budget on 300-DPI letter page (50 iterations)")
    func testZeroizeOverheadUnder5msFor300DPILetter() throws {
        let width = 2550
        let height = 3300
        guard let ctx = createBitmapContext(width: width, height: height) else {
            Issue.record("createBitmapContext failed")
            return
        }

        // Warm-up — first iteration includes page-fault cost the steady-
        // state loop should not pay.
        memset(ctx.data!, 0xFF, ctx.bytesPerRow * ctx.height)
        PixelOperations.zeroizeBitmapBuffer(ctx)

        // Measure.
        let clock = ContinuousClock()
        var samples: [Duration] = []
        samples.reserveCapacity(50)
        for _ in 0..<50 {
            // Re-fill with 0xFF every iteration so each call actually
            // wipes the same amount of data (otherwise the second call
            // onward would be wiping already-zero memory).
            memset(ctx.data!, 0xFF, ctx.bytesPerRow * ctx.height)

            let start = clock.now
            PixelOperations.zeroizeBitmapBuffer(ctx)
            let elapsed = clock.now - start
            samples.append(elapsed)
        }

        samples.sort()
        // p95 = sample at the 95th percentile index (47 out of 50, 0-based).
        let p95Index = Int(Double(samples.count) * 0.95) - 1
        let p95 = samples[max(0, min(samples.count - 1, p95Index))]
        // Spec target: ≤ 5 ms. CI ceiling: 25 ms to
        // absorb concurrent-suite pressure on the simulator. A real
        // regression (per-byte loop, accidental hashing) would land in
        // the 100+ ms range — well outside this budget.
        let ciCeiling: Duration = .milliseconds(25)

        #expect(
            p95 <= ciCeiling,
            "zeroize p95 on 300-DPI letter was \(p95) — CI ceiling is 25 ms (spec target 5 ms)"
        )
    }
}
