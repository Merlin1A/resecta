import Testing
@testable import RedactionEngine

// Calibration design 03 §3.5 — classify(...) must be deterministic under
// exactly tied logits. Before the rawValue tie-break, ties fell to
// Dictionary iteration order, which is per-launch randomized: the same
// page could gate under a different doctype across launches.
//
// "diagnosis" appears only in the medical keyword list and "court" only
// in the court list, and no structural bonus matches the combined text
// (verified against DataPipeline's _keyword_data), so the two classes
// tie exactly. The tie-break picks the alphabetically least rawValue:
// court < medical.

@Suite("DoctypeClassifierDeterminism")
struct DoctypeClassifierDeterminismTests {

    private let tiedText = "diagnosis court"

    @Test("classifier data is bundle-loaded (suite precondition)")
    func classifierDataLoads() async {
        // Empty-data classify(...) returns .generic for everything, which
        // would let the tie tests pass vacuously. Pin a one-sided text to
        // its class so a missing/undecodable doctype-keywords.json fails
        // loud here instead.
        let classifier = DocumentTypeClassifier()
        let result = await classifier.classify(pageText: "diagnosis")
        #expect(result.primary == .medical,
                "doctype-keywords.json must load from the module bundle")
    }

    @Test("classify() is deterministic under tied logits")
    func classifyDeterministicUnderTiedLogits() async {
        let classifier = DocumentTypeClassifier()
        var primaries: Set<DoctypeClass> = []
        var runnerUps: Set<DoctypeClass> = []
        for _ in 0..<100 {
            let result = await classifier.classify(pageText: tiedText)
            primaries.insert(result.primary)
            if let runnerUp = result.runnerUp {
                runnerUps.insert(runnerUp)
            }
        }
        #expect(primaries.count == 1, "tied primary must not vary within a launch")
        #expect(runnerUps.count == 1, "tied runner-up must not vary within a launch")
    }

    @Test("tied logits break on rawValue (stable across launches)")
    func tieBreaksOnRawValue() async {
        // The within-launch set test above is blind to per-launch
        // Dictionary seeding; pinning the winner is not — court < medical
        // by rawValue, on every launch.
        let classifier = DocumentTypeClassifier()
        let result = await classifier.classify(pageText: tiedText)
        #expect(result.primary == .court)
        #expect(result.runnerUp == .medical)
    }

    @Test("explain() agrees with classify() on tied logits (W9)")
    func explainAgreesOnTies() async {
        let classifier = DocumentTypeClassifier()
        let classified = await classifier.classify(pageText: tiedText)
        let explained = await classifier.explain(pageText: tiedText)
        #expect(classified.primary == explained.primary,
                "classify/explain must share the tie-break, not just the kernel")
        #expect(explained.topProbabilities.first?.0 == .court)
    }
}
