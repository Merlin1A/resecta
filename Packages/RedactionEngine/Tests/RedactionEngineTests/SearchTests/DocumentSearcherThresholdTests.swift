import Testing
import PDFKit
@testable import RedactionEngine

// W4 — end-to-end threshold gating through DocumentSearcher.
//
// Verifies the vector set via `setThresholdVector(_:)` actually filters
// PIIMatches before they reach the SearchResult stream, and that
// survivors carry the appliedThreshold + presetThresholdPass signal
// in their rationale.

@Suite("DocumentSearcher threshold gating (W4)", .tags(.search))
struct DocumentSearcherThresholdTests {

    private func runPIIScan(
        text: String,
        categories: Set<PIICategory>,
        thresholdVector: PresetThresholdVector?
    ) async -> [SearchResult] {
        let data = TestFixtures.textLayerPDF(text: text)
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return []
        }
        let searcher = DocumentSearcher()
        await searcher.setThresholdVector(thresholdVector)
        let mode = SearchMode.piiScan(categories: categories, options: SearchOptions())
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode, progress: { _, _ in }
        )
        var results: [SearchResult] = []
        for await result in stream { results.append(result) }
        return results
    }

    @Test("Nil vector preserves pre-W4 behavior — all matches pass")
    func nilVectorBackCompat() async {
        let results = await runPIIScan(
            text: "Patient John Smith SSN 123-45-6789",
            categories: [.ssn, .name],
            thresholdVector: nil)
        #expect(results.contains(where: { $0.piiCategory == .ssn }),
                "SSN match must survive when no vector is set")
        // None of the survivors should carry appliedThreshold.
        for r in results {
            #expect(r.rationale?.appliedThreshold == nil)
        }
    }

    @Test("Vector with high SSN cutoff drops SSN match")
    func highSSNCutoffDropsSSN() async {
        // SSN detector confidence ceiling sits well below 0.99; setting the
        // cutoff there guarantees the hit is gated out.
        let vector = PresetThresholdVector(
            thresholdsByWireName: ["ssn": 0.99, "name": 0.50])
        let results = await runPIIScan(
            text: "Patient John Smith SSN 123-45-6789",
            categories: [.ssn, .name],
            thresholdVector: vector)
        #expect(!results.contains(where: { $0.piiCategory == .ssn }),
                "SSN with cutoff 0.99 must be dropped")
    }

    @Test("Surviving match carries appliedThreshold + presetThresholdPass signal")
    func survivorCarriesAnnotation() async {
        // SSN detector routinely scores ≥ 0.80 for a valid 123-45-6789 with
        // an "SSN" keyword in context. Cutoff 0.50 guarantees survival.
        let vector = PresetThresholdVector(thresholdsByWireName: ["ssn": 0.50])
        let results = await runPIIScan(
            text: "SSN 123-45-6789",
            categories: [.ssn],
            thresholdVector: vector)
        guard let ssn = results.first(where: { $0.piiCategory == .ssn }) else {
            Issue.record("expected at least one SSN hit")
            return
        }
        let rationale = try! #require(ssn.rationale)
        #expect(rationale.appliedThreshold == 0.50)
        #expect(rationale.signals.contains(where: {
            if case .presetThresholdPass(_, let cutoff) = $0 { return cutoff == 0.50 }
            return false
        }))
    }
}
