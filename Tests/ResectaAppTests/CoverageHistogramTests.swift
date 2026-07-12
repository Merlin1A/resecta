import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// WU-36 / [D-34] OQ-07: pins the pure-function bin derivation that
// `CoverageReportView.perCategoryRow` uses to render the inline
// confidence histogram inside the per-category sub-disclosure.
// View-side derivation per [D-34] OQ-07; engine package untouched.

@Suite("Coverage histogram bin derivation (WU-36 / D-34 OQ-07)", .tags(.search))
@MainActor
struct CoverageHistogramTests {

    @Test("5-band partition distributes evenly when confidences are uniform")
    func bins5BandArithmetic() {
        // 10 synthetic SSN results at confidences 0.05, 0.15, ..., 0.95.
        // 5-band partition (bandWidth = 0.2): each band collects 2 results.
        let results = (0..<10).map { i in
            makeResult(category: .ssn, confidence: Double(i) * 0.1 + 0.05)
        }
        let bins = CoverageReportView.confidenceBinCounts(results: results, category: .ssn)
        #expect(bins == [2, 2, 2, 2, 2])
    }

    @Test("Last band is inclusive of 1.0 so the top score doesn't fall off")
    func lastBandInclusiveOf1() {
        let results = [makeResult(category: .ssn, confidence: 1.0)]
        let bins = CoverageReportView.confidenceBinCounts(results: results, category: .ssn)
        #expect(bins == [0, 0, 0, 0, 1])
    }

    @Test("Zero results returns all-zero bands of the expected count")
    func zeroResultsReturnsEmptyBands() {
        let bins = CoverageReportView.confidenceBinCounts(results: [], category: .ssn)
        #expect(bins == [0, 0, 0, 0, 0])
        #expect(bins.count == CoverageReportView.confidenceHistogramBandCount)
    }

    @Test("Cross-category isolation — SSN results do not leak into Email bins")
    func crossCategoryIsolation() {
        let mixed = [
            makeResult(category: .ssn, confidence: 0.5),
            makeResult(category: .ssn, confidence: 0.6),
            makeResult(category: .email, confidence: 0.9),
            makeResult(category: .ssn, confidence: 0.8)
        ]
        let ssnBins = CoverageReportView.confidenceBinCounts(results: mixed, category: .ssn)
        let emailBins = CoverageReportView.confidenceBinCounts(results: mixed, category: .email)
        #expect(ssnBins.reduce(0, +) == 3)
        #expect(emailBins.reduce(0, +) == 1)
        // Email's 0.9 lands in the top band of Email's bins only.
        #expect(emailBins == [0, 0, 0, 0, 1])
    }

    @Test("Results without piiConfidence are excluded from binning")
    func nilConfidenceExcluded() {
        let mixed = [
            makeResult(category: .ssn, confidence: 0.5),
            makeResult(category: .ssn, confidence: nil)
        ]
        let bins = CoverageReportView.confidenceBinCounts(results: mixed, category: .ssn)
        #expect(bins.reduce(0, +) == 1)
    }

    @Test("Confidence outside [0,1] is clamped before binning")
    func outOfRangeConfidenceClamps() {
        // Defensive: detector contract says piiConfidence ∈ [0, 1], but the
        // helper clamps so an upstream regression can't crash the renderer.
        let results = [
            makeResult(category: .ssn, confidence: -0.5),
            makeResult(category: .ssn, confidence: 1.5)
        ]
        let bins = CoverageReportView.confidenceBinCounts(results: results, category: .ssn)
        #expect(bins[0] == 1)
        #expect(bins[4] == 1)
        #expect(bins.reduce(0, +) == 2)
    }

    @Test("VoiceOver label names the category, total count, and band count")
    func accessibilityLabelShape() {
        let label = CoverageReportView.histogramAccessibilityLabel(
            category: "SSN",
            bins: [1, 2, 3, 4, 5]
        )
        #expect(label.contains("SSN"))
        #expect(label.contains("15 results"))
        #expect(label.contains("5 bands"))
    }

    @Test("Binning 10k synthetic results stays within the simulator perf budget")
    func binsTenThousandResultsUnderHundredMs() {
        let categories: [PIICategory] = [.ssn, .email, .phone, .name]
        let results: [SearchResult] = (0..<10_000).map { i in
            makeResult(
                category: categories[i % categories.count],
                confidence: Double(i % 100) / 100.0
            )
        }
        let start = Date()
        let bins = CoverageReportView.confidenceBinCounts(results: results, category: .ssn)
        let elapsed = Date().timeIntervalSince(start)
        // Acceptance bar per WORK_UNITS.md WU-36 is <50ms. Widened to 100ms
        // here per the flake-watch posture — simulator host
        // variance has produced timing-sensitive failures historically
        // (OQ-24 / OQ-25 / OQ-27 precedent). The helper itself is O(n) and
        // comfortably under the target in steady-state.
        #expect(elapsed < 0.1, "10k results binned in \(elapsed * 1000)ms")
        #expect(bins.count == CoverageReportView.confidenceHistogramBandCount)
        #expect(bins.reduce(0, +) > 0)
    }

    // MARK: - Fixture

    private func makeResult(category: PIICategory?, confidence: Double?) -> SearchResult {
        SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0, y: 0, width: 0.1, height: 0.02),
            matchedText: "x",
            contextSnippet: "x",
            source: .textLayer,
            term: "x",
            piiCategory: category,
            piiConfidence: confidence
        )
    }
}
