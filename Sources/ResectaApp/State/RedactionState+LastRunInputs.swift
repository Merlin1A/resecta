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
        /// The regions the run burned, per page, as burned: clamped to the
        /// page, with the size floor applied and the run's ink strips. A
        /// re-check of this output hands these to the checks, not the
        /// editor's live regions. Nil only where the inputs were built by
        /// hand (the debug seed and tests).
        var burnedRegions: [Int: [RedactionRegion]]? = nil
        /// The run's record: what the user confirmed at the Redact tap and
        /// what the producer says it did. In memory only, cleared with the
        /// output. Nil only where the inputs were built by hand (the debug
        /// seed and tests): such an output's boxes cannot be checked.
        var record: RunRecord? = nil
        /// The pages the stop at Redact named across the document's closed
        /// runs, answered or not (`RedactStop.pagesNotSearchedInFull`), read
        /// at run entry. Empty where the inputs were built by hand.
        var pagesNotSearchedInFull: Set<Int> = []
        /// The pages whose only gap is small pictures in those runs
        /// (`RedactStop.smallPicturePages`), read at run entry.
        var smallPicturePages: Set<Int> = []
        /// The output's size in bytes, read from the promoted file when the
        /// run finished. Nil where the inputs were built by hand, or when the
        /// file's attributes could not be read.
        var outputBytes: Int64? = nil
    }
}
