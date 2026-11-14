import Foundation

/// Per-scan coverage summary. Produced by `DetectionOrchestrator`
/// alongside the audit export and surfaced in the "Scan coverage" panel.
/// `deselectedCount` is the only field the UI layer fills in (from
/// `triageSelections`); the orchestrator leaves it at 0.
public struct CoverageReport: Sendable, Equatable {
    public let scannedPageCount: Int
    public let enabledCategories: Set<PIICategory>
    public let candidateCountByCategory: [PIICategory: Int]
    public let appliedCount: Int
    public let deselectedCount: Int
    public let belowThresholdSuppressedCount: Int
    public let overlapSuppressedCountByCategory: [PIICategory: Int]
    public let startedAt: Date
    public let completedAt: Date

    public init(
        scannedPageCount: Int,
        enabledCategories: Set<PIICategory>,
        candidateCountByCategory: [PIICategory: Int],
        appliedCount: Int,
        deselectedCount: Int,
        belowThresholdSuppressedCount: Int,
        overlapSuppressedCountByCategory: [PIICategory: Int],
        startedAt: Date,
        completedAt: Date
    ) {
        self.scannedPageCount = scannedPageCount
        self.enabledCategories = enabledCategories
        self.candidateCountByCategory = candidateCountByCategory
        self.appliedCount = appliedCount
        self.deselectedCount = deselectedCount
        self.belowThresholdSuppressedCount = belowThresholdSuppressedCount
        self.overlapSuppressedCountByCategory = overlapSuppressedCountByCategory
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    /// Return a copy with `deselectedCount` replaced. The UI layer uses
    /// this to fold in triage-sheet deselections after the scan completes.
    public func withDeselectedCount(_ count: Int) -> CoverageReport {
        CoverageReport(
            scannedPageCount: scannedPageCount,
            enabledCategories: enabledCategories,
            candidateCountByCategory: candidateCountByCategory,
            appliedCount: appliedCount,
            deselectedCount: count,
            belowThresholdSuppressedCount: belowThresholdSuppressedCount,
            overlapSuppressedCountByCategory: overlapSuppressedCountByCategory,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    /// Return a copy with `appliedCount`
    /// replaced. Pure value-type copy-with sibling to `withDeselectedCount`; the
    /// UI layer will fold in the applied-result count from view state. Added now
    /// so the panel/export wiring has the API; no call site yet.
    public func withAppliedCount(_ count: Int) -> CoverageReport {
        CoverageReport(
            scannedPageCount: scannedPageCount,
            enabledCategories: enabledCategories,
            candidateCountByCategory: candidateCountByCategory,
            appliedCount: count,
            deselectedCount: deselectedCount,
            belowThresholdSuppressedCount: belowThresholdSuppressedCount,
            overlapSuppressedCountByCategory: overlapSuppressedCountByCategory,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }
}
