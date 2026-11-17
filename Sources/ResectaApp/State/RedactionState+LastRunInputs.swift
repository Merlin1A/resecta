import Foundation
import RedactionEngine

extension RedactionState {
    struct LastRunInputs: Equatable, Sendable {
        let perPageModes: [PipelineMode]
        /// Sibling of `perPageModes` — why each page rasterized, not just
        /// that it did.
        let perPageFallbackReasons: [TextLayerDetector.FallbackReason?]
        let sensitiveTerms: SensitiveTermSet
        /// The output re-check requests the run was verified with, one per
        /// distinct applied query; the verify-only path re-feeds them so
        /// the artifact is re-checked against the searches it was built
        /// with even if regions changed since.
        let appliedSearches: [SearchRecheckRequest]
        /// The run-entry deselection snapshot
        /// (`runEntryDeselectionSnapshot()`); nil when neither source had
        /// one — the results screen then renders no deselection row.
        let deselection: DeselectionSnapshot?
        /// 0-indexed pages whose raster exceeded the OCR pixel caps in the
        /// session's detection, as read at run entry.
        let ocrSkippedPages: Set<Int>
        /// The degrade-failure list at run entry; nil when not degraded.
        let degradeFailures: [String]?
        var burnedRegionVersion: Int? = nil  // the run's redacted region version
    }
}
