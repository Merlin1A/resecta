import Testing
import Foundation
@testable import RedactionEngine

// W9 — performance guard. reverseRationale runs every detector against a
// bounded (≤500-char) context, so worst-case p95 should stay well under
// the 50 ms target on simulator.

@Suite("reverseRationale performance", .serialized)
struct ReverseRationalePerformanceTests {

    @Test("50-char snippet + 500-char context completes under 150 ms")
    func performanceIsReasonable() async {
        let detector = PIIDetector()
        let vector = PresetThresholdBundle.builtInDefaults.presets[.balanced]!
        let snippet = "Sample-Text-123-45-6789-With-Length"  // ~36 chars
        let context = String(repeating: "Patient chart MRN 12345678 SSN 123-45-6789 invoice due.", count: 9)
        let bounded = String(context.prefix(500))

        // Warm-up (compile regex caches)
        _ = await detector.reverseRationale(
            for: snippet,
            fullContext: bounded,
            doctype: nil,
            thresholdVector: vector
        )

        let clock = ContinuousClock()
        var durations: [Duration] = []
        for _ in 0..<20 {
            let start = clock.now
            _ = await detector.reverseRationale(
                for: snippet,
                fullContext: bounded,
                doctype: nil,
                thresholdVector: vector
            )
            durations.append(clock.now - start)
        }
        durations.sort()
        // CAT-248: index count-1 is the MAX, not the p95. The 95th percentile of
        // 20 sorted samples by floor interpolation is index 18
        // (Int((20-1) * 0.95) = 18); count-1 = 19 is the worst-case sample.
        // Renamed p95 → p95Latency so the variable is searchable.
        let p95Latency = durations[Int(Double(durations.count - 1) * 0.95)]
        // Generous ceiling for CI variability; tighten in Phase 3b once the
        // baseline is stable.
        #expect(p95Latency < .milliseconds(150),
                "p95 (index 18 of 20 sorted samples) = \(String(describing: p95Latency)) exceeded 150 ms ceiling")
    }
}
