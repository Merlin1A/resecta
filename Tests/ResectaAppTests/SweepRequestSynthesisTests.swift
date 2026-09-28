import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// Every redaction run carries ONE sweep request beside the applied
// searches: every detector category at the run-entry preset thresholds and
// user terms, nothing found and nothing applied (it is not an apply), the
// run's deselected items so the Detection Sweep can subtract them. The
// settings are snapshotted at run entry (MainActor) — a mid-run settings
// change cannot move what the sweep ran with.

@Suite("Sweep request synthesis", .tags(.coordination))
@MainActor
struct SweepRequestSynthesisTests {

    private func scanResult(_ index: Int) -> SearchResult {
        SearchResult(
            pageIndex: index,
            normalizedRect: CGRect(x: 0.1 * CGFloat(index), y: 0.2, width: 0.1, height: 0.03),
            matchedText: "match-\(index)", contextSnippet: "…match-\(index)…",
            source: .textLayer, term: "Name", isSelected: false,
            piiCategory: .name, piiConfidence: 0.9)
    }

    @Test("One .sweep request: every category, the run-entry configuration, nothing found or applied, the deselected items")
    func sweepRequestShape() {
        let terms = UserTermsBlob(
            alwaysFlag: [UserTerm(pattern: "ACME-4471", isRegex: false)], neverFlag: [UserTerm(pattern: "Sample", isRegex: false)])
        let deselected = [scanResult(0), scanResult(1)]

        let request = PipelineCoordinator.sweepRequest(
            thresholdVector: PresetThresholdVector(thresholdsByWireName: ["ssn": 0.5, "name": 0.7]), userTerms: terms,
            deselected: deselected)

        #expect(request.origin == .sweep)
        #expect(request.record.query.kind == .piiScan(categories: Set(PIICategory.allCases)))
        #expect(request.record.query.options == SearchOptions())
        #expect(request.record.scanConfiguration
                == ScanRunConfiguration(
                    thresholdVector: PresetThresholdVector(thresholdsByWireName: ["ssn": 0.5, "name": 0.7]),
                    alwaysFlag: terms.alwaysFlag, neverFlag: terms.neverFlag))
        #expect(request.record.foundCount == 0)
        #expect(request.record.foundHitCap == false)
        #expect(request.record.ocrSkippedPages.isEmpty)
        #expect(request.appliedCount == 0)
        #expect(request.appliedPages.isEmpty)
        #expect(request.deselected == deselected)
    }

    @Test("No preset and no user terms still synthesize the request — the searcher's own defaults")
    func sweepRequestWithDefaults() {
        let request = PipelineCoordinator.sweepRequest(
            thresholdVector: nil, userTerms: UserTermsBlob(alwaysFlag: [], neverFlag: []),
            deselected: [])
        #expect(request.origin == .sweep)
        #expect(request.record.scanConfiguration == ScanRunConfiguration(thresholdVector: nil))
        #expect(request.deselected.isEmpty)
    }

    @Test("Two syntheses over the same inputs are equal — the verify-only fallback relies on it")
    func synthesisIsStable() {
        let terms = UserTermsBlob(alwaysFlag: [], neverFlag: [UserTerm(pattern: "Sample", isRegex: false)])
        let a = PipelineCoordinator.sweepRequest(
            thresholdVector: nil, userTerms: terms, deselected: [scanResult(0)])
        let b = PipelineCoordinator.sweepRequest(
            thresholdVector: nil, userTerms: terms, deselected: [scanResult(0)])
        // Same page, category and rect; the ids differ, so compare the fields
        // the subtraction reads.
        #expect(a.record == b.record)
        #expect(a.origin == b.origin)
        #expect(a.deselected.map(\.pageIndex) == b.deselected.map(\.pageIndex))
    }
}
