import Foundation

// Plan §2 — the wrapper a single page's detection output threads through.
// Carries raw detections + the doctype that gated them + an optional
// classification diagnostic for the G5 triage panel. `priorsDelta` is the
// per-category Beta update this page contributes (merged back on MainActor
// when the coordinator yields). Phase 3 populates priorsDelta as an empty
// update — priors move on triage accept/reject, not during detection.

public struct PageDetectionResult: Sendable {
    public let pageIndex: Int
    public let detections: [DetectionResult]
    public let doctype: DoctypeResult
    public let priorsDelta: PerCategoryPriors
    public let classificationDiagnostic: ClassificationDiagnostic?
    /// W10 — per-category count of pre-threshold detections that lost
    /// an overlap group inside `DetectionOrchestrator.resolveOverlaps`.
    /// Aggregated across pages by the coordinator and surfaced on
    /// `CoverageReport.overlapSuppressedCountByCategory`.
    public let overlapSuppressedCountByCategory: [PIICategory: Int]
    /// ST-83 — PAGE-level OCR provenance. Per-detection provenance cannot
    /// carry the oversized-page skip on a page that produced zero
    /// detections (nothing to attach it to), so the page result records
    /// it directly. The coordinator reads `.pixelCapExceeded` pages and
    /// surfaces them on the triage banner. Defaulted so existing
    /// constructors stay valid.
    public let ocrProvenance: DetectionResult.Provenance

    public init(
        pageIndex: Int,
        detections: [DetectionResult],
        doctype: DoctypeResult,
        priorsDelta: PerCategoryPriors,
        classificationDiagnostic: ClassificationDiagnostic?,
        overlapSuppressedCountByCategory: [PIICategory: Int] = [:],
        ocrProvenance: DetectionResult.Provenance = .ocrRan
    ) {
        self.pageIndex = pageIndex
        self.detections = detections
        self.doctype = doctype
        self.priorsDelta = priorsDelta
        self.classificationDiagnostic = classificationDiagnostic
        self.overlapSuppressedCountByCategory = overlapSuppressedCountByCategory
        self.ocrProvenance = ocrProvenance
    }
}

// G5 "Why this classification?" diagnostic. In-memory only — never logged,
// never persisted (ARCHITECTURE.md §12.2). Released on `clearAll()`.

public struct ClassificationDiagnostic: Sendable, Equatable {
    public let primary: DoctypeClass
    public let runnerUp: DoctypeClass?
    public let softmaxSnapshot: [DoctypeClass: Double]
    public let topKeywords: [DoctypeResult.TopKeyword]

    public init(
        primary: DoctypeClass,
        runnerUp: DoctypeClass?,
        softmaxSnapshot: [DoctypeClass: Double],
        topKeywords: [DoctypeResult.TopKeyword]
    ) {
        self.primary = primary
        self.runnerUp = runnerUp
        self.softmaxSnapshot = softmaxSnapshot
        self.topKeywords = topKeywords
    }

    /// Build from a fresh DoctypeResult, trimming to top-5 keywords.
    public init(from result: DoctypeResult) {
        self.primary = result.primary
        self.runnerUp = result.runnerUp
        self.softmaxSnapshot = result.softmax
        self.topKeywords = Array(result.topKeywords.prefix(5))
    }
}
