import Testing
import Foundation
@testable import RedactionEngine

// W9 — scope contract. The same snippet scored against two different
// ≤500-char contexts can produce different scores because positive /
// negative context keywords are bounded to the buffer. This test
// documents that contract mechanically so the UI footer copy stays
// truthful.

@Suite("reverseRationale scope contract")
struct ReverseRationaleScopeContractTests {

    @Test("score differs when positive and negative context buffers differ")
    func scoreShiftsBetweenPositiveAndNegativeBuffers() async {
        let detector = PIIDetector()
        let snippet = "123-45-6789"
        let positive = "Patient SSN: 123-45-6789 — admitted yesterday."
        let negative = "Invoice no. 123-45-6789 outstanding balance due."

        let vector = PresetThresholdBundle.builtInDefaults.presets[.balanced]!

        let positiveResult = await detector.reverseRationale(
            for: snippet,
            fullContext: positive,
            doctype: nil,
            thresholdVector: vector
        )
        let negativeResult = await detector.reverseRationale(
            for: snippet,
            fullContext: negative,
            doctype: nil,
            thresholdVector: vector
        )

        let positiveSSN = positiveResult.considered.first { $0.category == .ssn }
        let negativeSSN = negativeResult.considered.first { $0.category == .ssn }

        #expect(positiveSSN?.finalScore != nil)
        #expect(negativeSSN?.finalScore != nil)
        if let p = positiveSSN?.finalScore, let n = negativeSSN?.finalScore {
            #expect(p > n,
                    "positive-context buffer must produce a higher score than negative-context buffer")
        }
    }
}
