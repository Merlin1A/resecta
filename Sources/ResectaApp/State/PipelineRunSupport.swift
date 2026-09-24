import Foundation
import PDFKit
import UIKit
import RedactionEngine

// The pure run helpers of `PipelineCoordinator`, moved out of the class body
// in their own file: the failure-stage classifier, the off-MainActor output
// parsers, the abandoned-intermediate sweep, the sensitive-term and
// applied-search derivations, and the OCR-skip fast-path gate. Every member
// reads only its parameters (or an immutable constant) — no coordinator
// state — which is what made them the unit-testable seams the app suites
// pin. Same module, same type (an extension), same access: nothing here
// crosses into the engine package, and the app's `RunSettings` /
// `RegionMetadata` / `MatchAuditSnapshot` types and the one float compare
// (`buildOCRSkipHint`'s coverage threshold) stay in the app target.

extension PipelineCoordinator {

    /// Which pipeline stage a `runFullPipeline` throw is attributed to.
    /// Drives the generic error handler's recovery split: `.redaction`
    /// discards the never-promoted output and returns to the editor;
    /// `.verification` keeps the valid promoted output and returns to the
    /// skipped-report screen.
    enum PipelineFailureStage {
        case redaction
        case verification
    }

    /// Attribute a `runFullPipeline` throw to its failing stage.
    ///
    /// Typed `PipelineError`s classify by case: verification/export-stage
    /// errors mean redaction had already promoted a valid output;
    /// import/detection/redaction-stage errors mean it had not. Untyped
    /// throws fall back to `redactionSucceeded` — whether `processDocument`
    /// had returned when the error was thrown. The published
    /// `redactionState.outputURL` deliberately plays no part: it
    /// registers eagerly, before `processDocument` runs, so it is
    /// non-nil for every throw after run start.
    ///
    /// `nonisolated static` seam so the stage discrimination is
    /// unit-testable without driving a live pipeline run (same precedent
    /// as `loadOutputDocumentOffMainActor`).
    nonisolated static func classifyPipelineFailure(
        _ error: Error, redactionSucceeded: Bool
    ) -> PipelineFailureStage {
        guard let pipelineError = error as? PipelineError else {
            return redactionSucceeded ? .verification : .redaction
        }
        switch pipelineError {
        case .verificationError, .exportError:
            return .verification
        case .importError, .detectionError, .redactionError:
            return .redaction
        }
    }

    /// Off-MainActor PDF parse for the verification entry. Mirrors the
    /// `ImportService.validatePDFOffMainActor` shape: synchronous
    /// `nonisolated static` work invoked via `Task.detached` at the call
    /// site, so the CPU-bound `PDFDocument(url:)` parse on a 100-page
    /// output does not stall the `.verifying` progress UI on MainActor.
    /// `nonisolated`: explicitly opts out of SE-0466 MainActor default.
    /// Throws `PipelineError.verificationError(.engineCrash(layerIndex: 0))`
    /// on parse failure to match the prior in-place guard's failure shape.
    nonisolated static func loadOutputDocumentOffMainActor(
        _ url: URL
    ) throws -> SendablePDFDocument {
        guard let doc = PDFDocument(url: url) else {
            throw PipelineError.verificationError(.engineCrash(layerIndex: 0))
        }
        return SendablePDFDocument(doc)
    }

    /// Open one independent `PDFDocument(url:)` per parallel
    /// verification layer so concurrent `runLayer` calls never share a PDFKit
    /// object (a torn lazy read on a shared instance could otherwise produce a
    /// false `.pass`). Opens are serial against the OS-cached output file.
    /// Returns `nil` if ANY open fails — partial provisioning is not allowed;
    /// the caller then runs the layers sequentially on the shared instance.
    /// `nonisolated static`: invoked through `Task.detached` because the open
    /// is CPU-bound on large outputs (same rationale as
    /// `loadOutputDocumentOffMainActor`).
    nonisolated static func loadParallelLayerDocuments(
        _ url: URL, layers: [Int]
    ) -> [Int: SendablePDFDocument]? {
        loadParallelLayerDocuments(url, keys: layers)
    }

    /// Identity-keyed counterpart of the index form above.
    nonisolated static func loadParallelLayerDocuments(
        _ url: URL, layers: [VerificationLayer]
    ) -> [VerificationLayer: SendablePDFDocument]? {
        loadParallelLayerDocuments(url, keys: layers)
    }

    /// The identity form run through `Task.detached`: the per-layer opens
    /// are CPU-bound on large outputs and must not stall the MainActor
    /// progress UI. The one provisioning call site the runner and the
    /// parallel-batch seam share.
    nonisolated static func provisionLayerDocumentsOffMainActor(
        _ url: URL, layers: [VerificationLayer]
    ) async -> [VerificationLayer: SendablePDFDocument]? {
        await Task.detached {
            loadParallelLayerDocuments(url, layers: layers)
        }.value
    }

    private nonisolated static func loadParallelLayerDocuments<Key: Hashable>(
        _ url: URL, keys: [Key]
    ) -> [Key: SendablePDFDocument]? {
        var docs: [Key: SendablePDFDocument] = [:]
        docs.reserveCapacity(keys.count)
        for key in keys {
            guard let doc = PDFDocument(url: url) else { return nil }
            docs[key] = SendablePDFDocument(doc)
        }
        return docs
    }

    /// Remove every entry directly inside `directory` whose name carries
    /// the reconstructor's `recon_` intermediate prefix. Best-effort: a
    /// missing directory or an entry that cannot be removed is left for
    /// `cleanOrphanedTempFiles()`. Output files (`redacted_*`) and
    /// everything else are untouched.
    nonisolated static func removeAbandonedIntermediates(in directory: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("recon_") {
            try? fm.removeItem(at: entry)
        }
    }

    /// Pure core of `collectSensitiveTerms`: given the applied regions
    /// and their metadata, return the verifier's sensitive-term set. Split out as
    /// a `nonisolated static` seam so it is unit-testable without a live
    /// coordinator.
    ///
    /// Two contributions per region:
    /// - The region's search TERM, only when the region came from a typed
    ///   query (text / regex / multi-term row) — there the term IS the
    ///   sensitive text the user searched for. Detector and user-term rows
    ///   carry a placeholder there instead (a category label like "Name",
    ///   or "Custom"), which is not document content and would substring-hit
    ///   unrelated body text ("Name" inside "/FontName", "Custom" inside
    ///   "Customer"). Typed rows are the ones with no attached rationale and
    ///   no stamped PII category — both are nil for text/regex/multi-term
    ///   results by the `SearchResult` contract.
    /// - The region's MATCHED TEXT — the actual document content — for every
    ///   region that has one. A bare single-word name token (a lone surname /
    ///   given name from per-word NL tagging) is included WITH token-boundary
    ///   matching: byte layers count its hits only when the match is not
    ///   embedded in a longer alphanumeric run, which keeps a leaked
    ///   standalone name detectable while an unrelated word containing the
    ///   same letters ("pos" inside "Deposits") does not flag. Multi-word
    ///   names, non-name kinds, and typed queries keep plain substring
    ///   matching so embedded/partial leaks stay catchable.
    nonisolated static func sensitiveTerms(
        fromAppliedRegions regions: [Int: [RedactionRegion]],
        metadata: [UUID: RegionMetadata]
    ) -> [SensitiveTerm] {
        // Dedup by text; a text contributed with AND without the boundary
        // requirement keeps plain substring matching (the least restrictive
        // discipline any contributor asked for).
        var requiresBoundaryByText: [String: Bool] = [:]
        func insert(_ text: String, requiresTokenBoundary: Bool) {
            requiresBoundaryByText[text] =
                (requiresBoundaryByText[text] ?? true) && requiresTokenBoundary
        }
        for pageRegions in regions.values {
            for region in pageRegions {
                let meta = metadata[region.id]
                if case .searchMatch(let term, let rationale) = region.source,
                   rationale == nil,
                   meta.map({ if case .searchMatch = $0.piiKind { true } else { false } }) ?? true {
                    insert(term, requiresTokenBoundary: false)
                }
                guard let meta,
                      let text = meta.matchedText, !text.isEmpty else { continue }
                let isSingleTokenName: Bool =
                    if case .pii(.name) = meta.piiKind { isSingleToken(text) } else { false }
                insert(text, requiresTokenBoundary: isSingleTokenName)
            }
        }
        // Sorted by text: the Dictionary traversal order is unspecified and
        // would make the verifier's term order (and Layer 3's review-term
        // list) differ run to run; the corpus mirror sorts the same way.
        return requiresBoundaryByText.map {
            SensitiveTerm(text: $0.key, requiresTokenBoundary: $0.value)
        }.sorted { $0.text < $1.text }
    }

    /// True when `text` is a single whitespace-delimited token.
    nonisolated static func isSingleToken(_ text: String) -> Bool {
        text.split(whereSeparator: { $0.isWhitespace }).count <= 1
    }

    /// Pure core of `collectAppliedSearches`: join the PRESENT regions to
    /// the match audit and group the search-origin records by their stamped
    /// query. Split out as a `nonisolated static` seam so it is
    /// unit-testable without a live coordinator (the
    /// `sensitiveTerms(fromAppliedRegions:metadata:)` shape).
    ///
    /// Why the join, not the audit alone: `removeRegion` / `removeRegions`
    /// drop the region and its metadata but leave the audit entry, so an
    /// orphaned audit entry means "deleted" — and deletion is the user's
    /// intent. A query whose regions were all deleted is not re-checked.
    /// Out by construction: scan-origin records, `.piiScan` sessions and
    /// nudge-accepted regions (no stamped record), manual regions (no
    /// audit entry). Overlap-skipped results never wrote an audit entry,
    /// so they count in the record's `foundCount` but not in `appliedCount`.
    ///
    /// Per query: `appliedCount` = present regions citing it; `appliedPages`
    /// = the pages carrying them (the region dictionary's key is the page
    /// of record); the record itself — `foundCount` and the coverage facts
    /// — is the LATEST apply's by `appliedAt`, since a later run of the same
    /// query reports the newer result count. Requests come back in
    /// first-seen order over pages ascending, then region order within the
    /// page, so two derivations over the same state are equal.
    nonisolated static func appliedSearches(
        fromRegions regions: [Int: [RedactionRegion]],
        audit: [UUID: MatchAuditSnapshot]
    ) -> [SearchRecheckRequest] {
        struct Group {
            var record: AppliedSearchRecord
            var recordAppliedAt: Date
            var appliedCount: Int
            var appliedPages: Set<Int>
        }
        var groups: [AppliedSearchQuery: Group] = [:]
        var order: [AppliedSearchQuery] = []
        for (page, pageRegions) in regions.sorted(by: { $0.key < $1.key }) {
            for region in pageRegions {
                guard let snapshot = audit[region.id],
                      snapshot.origin == .search,
                      let record = snapshot.searchRecord else { continue }
                let query = record.query
                if var group = groups[query] {
                    group.appliedCount += 1
                    group.appliedPages.insert(page)
                    if snapshot.appliedAt > group.recordAppliedAt {
                        group.record = record
                        group.recordAppliedAt = snapshot.appliedAt
                    }
                    groups[query] = group
                } else {
                    groups[query] = Group(
                        record: record,
                        recordAppliedAt: snapshot.appliedAt,
                        appliedCount: 1,
                        appliedPages: [page])
                    order.append(query)
                }
            }
        }
        return order.compactMap { query in
            guard let group = groups[query] else { return nil }
            return SearchRecheckRequest(
                record: group.record,
                appliedCount: group.appliedCount,
                appliedPages: group.appliedPages)
        }
    }

    // MARK: - OCR skip fast path

    /// Locked coverage threshold. Selectable-text bounding-box area
    /// as a fraction of cropBox area must strictly exceed this value before
    /// Vision OCR is skipped for the page. Not tunable.
    /// `nonisolated` so the now-`nonisolated`
    /// `buildOCRSkipHint` can read it off the MainActor (mirrors
    /// `retryDPIFloor`); an immutable Sendable constant is safe to share.
    nonisolated static let ocrSkipCoverageThreshold: Double = 0.95

    /// Decide whether Vision OCR can be skipped for `page` and, if
    /// so, build the `EmbeddedTextSource` the orchestrator will consume in
    /// place of running OCR. Returns `(nil, nil)` when the page must take
    /// the OCR path.
    ///
    /// Locked gate (do not tune):
    ///   * Effective mode == `.searchableRedaction`
    ///   * Per-page text layer == `.rich`
    ///   * Selectable-text coverage > 0.95
    ///
    /// In `.secureRasterization` mode the embedded text is not used by the
    /// pipeline, so OCR always runs there regardless of settings.
    ///
    /// `runSettings` is the run-entry snapshot used by
    /// `runDetectionPipeline`.
    ///
    /// `nonisolated`, and both MainActor
    /// inputs are passed in as Sendable snapshots — `runSettings` (required)
    /// and `textLayerStatus` (the per-page status dict captured once pre-loop).
    /// The body reads no MainActor-isolated state, so `runDetectionPipeline`
    /// runs it off the MainActor via `Task.detached`; the per-word
    /// `EmbeddedTextSource.make` enumeration no longer occupies the UI thread.
    nonisolated func buildOCRSkipHint(
        for page: PDFPage, pageIndex: Int,
        runSettings: RunSettings,
        textLayerStatus: [Int: TextLayerStatus]
    ) -> (EmbeddedTextSource?, DetectionResult.Provenance.OCRSkipReason?) {
        // Condition 2 — mode gate. The user's current preference is what
        // would drive the next pipeline run; in `.secureRasterization` we
        // never trust embedded text, by design.
        guard runSettings.pipelineMode == .searchableRedaction else {
            return (nil, nil)
        }
        // Per-page text layer must be rich. Sparse/none layers go through
        // OCR even when the document is mostly text — the embedded text
        // is by definition not authoritative for those pages.
        if let status = textLayerStatus[pageIndex],
           status != .rich {
            return (nil, nil)
        }
        // Cheap pre-filter (task body): pages with <10 characters cannot
        // plausibly cover > 95% of the cropBox.
        guard let pageText = page.string, pageText.count >= 10 else {
            return (nil, nil)
        }

        // Condition 1 — coverage. The engine builder computes the union of
        // selectable-text word bounding boxes as a fraction of cropBox area.
        guard let source = EmbeddedTextSource.make(from: page),
              source.coverage > Self.ocrSkipCoverageThreshold else {
            return (nil, nil)
        }

        return (source, .coverageHighEnough)
    }
}
