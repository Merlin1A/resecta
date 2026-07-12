import Testing
import Foundation
@testable import RedactionEngine

// W9 — CoverageReport value-type tests. The orchestrator aggregates these
// at the UI layer for v1 (no engine wiring), so the coverage here focuses
// on the struct's API: construction, withDeselectedCount, equality.

@Suite("CoverageReport")
struct CoverageReportTests {

    private func makeReport(deselected: Int = 0) -> CoverageReport {
        CoverageReport(
            scannedPageCount: 3,
            enabledCategories: [.ssn, .name, .email],
            candidateCountByCategory: [.ssn: 2, .name: 5, .email: 1],
            appliedCount: 4,
            deselectedCount: deselected,
            belowThresholdSuppressedCount: 1,
            overlapSuppressedCountByCategory: [:],
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 1)
        )
    }

    @Test("withDeselectedCount replaces only the deselected field")
    func withDeselectedReplacesField() {
        let base = makeReport(deselected: 0)
        let updated = base.withDeselectedCount(7)
        #expect(updated.deselectedCount == 7)
        #expect(updated.scannedPageCount == base.scannedPageCount)
        #expect(updated.enabledCategories == base.enabledCategories)
        #expect(updated.candidateCountByCategory == base.candidateCountByCategory)
        #expect(updated.appliedCount == base.appliedCount)
        #expect(updated.belowThresholdSuppressedCount == base.belowThresholdSuppressedCount)
    }

    @Test("withAppliedCount replaces only the applied field (D06-F2 Part 2 sibling)")
    func withAppliedReplacesField() {
        let base = makeReport(deselected: 0)
        let updated = base.withAppliedCount(9)
        #expect(updated.appliedCount == 9)
        // Every other field is preserved.
        #expect(updated.deselectedCount == base.deselectedCount)
        #expect(updated.scannedPageCount == base.scannedPageCount)
        #expect(updated.enabledCategories == base.enabledCategories)
        #expect(updated.candidateCountByCategory == base.candidateCountByCategory)
        #expect(updated.belowThresholdSuppressedCount == base.belowThresholdSuppressedCount)
        // Equatable holds: differs from base (base.appliedCount == 4), equal to a
        // sibling copy with the same applied value.
        #expect(updated != base)
        #expect(updated == base.withAppliedCount(9))
    }

    @Test("equal reports are Equatable")
    func equalityRoundTrip() {
        #expect(makeReport() == makeReport())
        #expect(makeReport(deselected: 1) != makeReport(deselected: 2))
    }

    @Test("empty report has zero candidate totals")
    func emptyReportHasZeroCandidates() {
        let empty = CoverageReport(
            scannedPageCount: 0,
            enabledCategories: [],
            candidateCountByCategory: [:],
            appliedCount: 0,
            deselectedCount: 0,
            belowThresholdSuppressedCount: 0,
            overlapSuppressedCountByCategory: [:],
            startedAt: Date(),
            completedAt: Date()
        )
        #expect(empty.candidateCountByCategory.isEmpty)
        #expect(empty.overlapSuppressedCountByCategory.isEmpty)
    }
}
