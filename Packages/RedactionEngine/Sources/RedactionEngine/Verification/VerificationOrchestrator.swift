import Foundation
import PDFKit
import os

/// What a verification pass reports while it runs. The orchestrator hands
/// these to its caller at the points the app's progress UI and VoiceOver
/// announcements fire; a harness caller ignores them.
public enum VerificationRunEvent: Sendable {
    /// A layer is about to run. For the parallel base batch this fires once,
    /// for the batch's first layer, before the batch is dispatched.
    /// `completedLayers` is every result published so far, in publication
    /// order (canonical within the batch, then sequential).
    case layerStarted(
        layer: VerificationLayer, ordinal: Int, totalLayers: Int,
        completedLayers: [LayerResult])
    /// A layer's result was published (the parallel batch publishes its
    /// results in canonical order once the batch completes).
    case layerFinished(layer: VerificationLayer, ordinal: Int, result: LayerResult)
}

/// The verification schedule: the page-count integrity gate, the mode's
/// layer list grouped by execution phase, the parallel base batch on one
/// document instance per layer, the sequential phases in order, the
/// canonical assembly and the aggregate verdict.
///
/// This is the one schedule the product (`PipelineCoordinator`) and the
/// corpus harness (`VerificationCorpusRunnerTests`) run. Every parameter is
/// an engine type; the caller supplies the loaded output document, the
/// per-layer document provisioning (the app opens them off the main actor,
/// the harness inline) and an event sink. The function inherits its
/// caller's isolation (`NonisolatedNonsendingByDefault`): called from the
/// main actor it runs there between layer dispatches, so the sink may
/// touch main-actor state synchronously; the layers themselves run
/// `@concurrent` on the global executor as before.
public struct VerificationOrchestrator: Sendable {
    public let verifier: VerificationEngine

    public init(verifier: VerificationEngine = VerificationEngine()) {
        self.verifier = verifier
    }

    /// The page-count integrity gate, run BEFORE any layer. The redacted
    /// output must carry exactly one page per source page; a mismatch means
    /// reconstruction dropped or duplicated a page — possibly in a previous
    /// process on the verify-only resume path, where the in-process
    /// written-page-count postcondition cannot help. Returns one explicit
    /// FAIL-layer report when the counts differ, nil when they match. Page
    /// counts only — never document content.
    public static func pageCountMismatchReport(
        sourcePageCount: Int,
        outputPageCount: Int,
        perPageModes: [PipelineMode],
        perPageFallbackReasons: [TextLayerDetector.FallbackReason?]
    ) -> VerificationReport? {
        guard sourcePageCount != outputPageCount else { return nil }
        let failLayer = LayerResult(
            name: "Page Count Check",
            symbolName: "exclamationmark.triangle",
            status: .fail("Output has \(outputPageCount) \(outputPageCount == 1 ? "page" : "pages"); source has \(sourcePageCount)."),
            shortDescription: "Output page count does not match the source document.",
            detailDescription: "The redacted output has \(outputPageCount) \(outputPageCount == 1 ? "page" : "pages") but the source document has \(sourcePageCount). Verification stopped before the layer checks because the page counts must match.",
            pageReferences: nil,
            durationSeconds: 0
        )
        return VerificationReport(
            layers: [failLayer],
            overallStatus: .fail("Output page count does not match the source document."),
            durationSeconds: 0,
            perPageModes: perPageModes,
            perPageFallbackReasons: perPageFallbackReasons
        )
    }

    /// Run every verification layer of `pipelineMode` against
    /// `outputDocument` and return the report.
    ///
    /// The schedule is the mode's layer list grouped by execution phase
    /// (`VerificationLayer.phase`) — identity, never index arithmetic. The
    /// parallel base batch (Text Extraction, OCR, Binary String Search, and
    /// in Searchable mode Operator Re-Extraction) runs via a task group —
    /// independent reads against the output document with no shared mutable
    /// state, each layer on its own document instance from
    /// `provisionLayerDocuments` (nil ⇒ the batch runs sequentially on the
    /// shared instance). Structure and Metadata run sequentially after
    /// because both parse the `PDFDocument` catalog; concurrent
    /// CGPDFDictionary traversal would contend on the same catalog handle.
    /// The sandwich checks run sequentially — the inter-layer
    /// character-count baseline depends on Spatial Verification's extraction
    /// work and must remain ordered. The post-sequential checks (the Search
    /// Re-check) run last: page-parallel inside the layer at Layer 2's
    /// width, never overlapped with Layer 2's own Vision pass.
    ///
    /// The report lists every layer in canonical order: the results UI
    /// labels rows by ordinal position. A cancellation checkpoint precedes
    /// every dispatch and the final assembly, so a cancel landing after the
    /// last layer folded its `CancellationError` into a `.skipped` result
    /// still surfaces as a thrown `CancellationError` rather than a report.
    public func run(
        outputDocument: SendablePDFDocument,
        sourcePageCount: Int,
        regions: [Int: [RedactionRegion]],
        sensitiveTerms: [SensitiveTerm],
        pipelineMode: PipelineMode,
        filterDigests: [PageFilterDigest?],
        perPageModes: [PipelineMode],
        perPageFallbackReasons: [TextLayerDetector.FallbackReason?],
        appliedSearches: [SearchRecheckRequest],
        provisionLayerDocuments: ([VerificationLayer]) async -> [VerificationLayer: SendablePDFDocument]?,
        events: (VerificationRunEvent) -> Void
    ) async throws -> VerificationReport {
        if let gate = Self.pageCountMismatchReport(
            sourcePageCount: sourcePageCount,
            outputPageCount: outputDocument.document.pageCount,
            perPageModes: perPageModes,
            perPageFallbackReasons: perPageFallbackReasons
        ) {
            return gate
        }

        // `layers` is the canonical (report) order; the count is derived.
        let layers = verifier.layers(for: pipelineMode)
        let globalLayerCount = layers.count
        // Published progress: results in completion order (the progress UI
        // reads `completedLayers` incrementally). The REPORT is assembled in
        // canonical order from `resultsByLayer` once every phase has run, so
        // a layer that completes early in the parallel batch (Operator
        // Re-Extraction) still lands at its ordinal in the results list.
        var completedLayers: [LayerResult] = []
        var resultsByLayer: [VerificationLayer: LayerResult] = [:]
        let startTime = CFAbsoluteTimeGetCurrent()

        let parallelBaseLayers = layers.filter { $0.phase == .parallelBase }
        let catalogLayers = layers.filter { $0.phase == .catalogSequential }
        let sandwichLayers = layers.filter { $0.phase == .sandwichSequential }
        let postLayers = layers.filter { $0.phase == .postSequential }
        // 1-based ordinal in the mode's order (the progress and row label).
        func ordinal(_ layer: VerificationLayer) -> Int {
            (layers.firstIndex(of: layer) ?? 0) + 1
        }

        // --- Parallel base batch ---
        if let firstLayer = parallelBaseLayers.first {
            try Task.checkCancellation()
            // Surface the first parallel-batch layer before the parallel
            // dispatch so the progress indicator stays continuous; per-layer
            // completions still publish as each layer lands below.
            events(.layerStarted(
                layer: firstLayer, ordinal: ordinal(firstLayer),
                totalLayers: globalLayerCount, completedLayers: completedLayers))

            let perLayerDocs = await provisionLayerDocuments(parallelBaseLayers)
            let parallelResults = try await collectParallelBaseLayerResults(
                layers: parallelBaseLayers,
                shared: outputDocument,
                perLayerDocuments: perLayerDocs,
                sourcePageCount: sourcePageCount,
                regions: regions,
                sensitiveTerms: sensitiveTerms,
                pipelineMode: pipelineMode,
                filterDigests: filterDigests,
                perPageModes: perPageModes
            )

            // Canonical order within the batch so the announcements and the
            // published progress read ascending.
            let orderedParallel = parallelResults.sorted { ordinal($0.0) < ordinal($1.0) }
            for (layer, result) in orderedParallel {
                resultsByLayer[layer] = result
                completedLayers.append(result)
                events(.layerFinished(layer: layer, ordinal: ordinal(layer), result: result))
            }
        }

        // --- Sequential phases: catalog readers → sandwich checks → post checks ---
        for phaseLayers in [catalogLayers, sandwichLayers, postLayers] {
            for layer in phaseLayers {
                try Task.checkCancellation()
                events(.layerStarted(
                    layer: layer, ordinal: ordinal(layer),
                    totalLayers: globalLayerCount, completedLayers: completedLayers))

                let result = await verifier.runLayer(
                    layer,
                    outputDocument: outputDocument,
                    sourcePageCount: sourcePageCount,
                    regions: regions,
                    sensitiveTerms: sensitiveTerms,
                    pipelineMode: pipelineMode,
                    filterDigests: filterDigests,
                    perPageModes: perPageModes,
                    appliedSearches: appliedSearches
                )
                resultsByLayer[layer] = result
                completedLayers.append(result)
                events(.layerFinished(layer: layer, ordinal: ordinal(layer), result: result))
            }
        }

        // Final cancellation checkpoint before the report is constructed.
        try Task.checkCancellation()

        let orderedResults = layers.compactMap { resultsByLayer[$0] }
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        return VerificationReport(
            layers: orderedResults,
            overallStatus: verifier.aggregateStatus(orderedResults),
            durationSeconds: elapsed,
            perPageModes: perPageModes,
            perPageFallbackReasons: perPageFallbackReasons
        )
    }

    /// Run the parallel base-layer batch and return the `(layer, result)`
    /// pairs in completion order. Each parallel layer runs against its own
    /// instance from `perLayerDocuments`; `shared` is only a defensive
    /// fallback for an absent map entry (the map is complete whenever
    /// provisioning succeeded). A nil map means provisioning failed (e.g.
    /// the output file was purged mid-run): the same layers then run
    /// SEQUENTIALLY on the shared instance — sequential access on one
    /// document is the sound original contract (PDFPageData.swift). Never
    /// concurrent-shared.
    public func collectParallelBaseLayerResults(
        layers: [VerificationLayer],
        shared: SendablePDFDocument,
        perLayerDocuments: [VerificationLayer: SendablePDFDocument]?,
        sourcePageCount: Int,
        regions: [Int: [RedactionRegion]],
        sensitiveTerms: [SensitiveTerm],
        pipelineMode: PipelineMode,
        filterDigests: [PageFilterDigest?],
        perPageModes: [PipelineMode]
    ) async throws -> [(VerificationLayer, LayerResult)] {
        guard let perLayerDocuments else {
            // Debug-only diagnostic; no Phase change, no PipelineError, no
            // user string.
            #if DEBUG
            Logger(subsystem: "com.resecta.app", category: "verification").debug(
                "per-layer verification document provisioning failed; running base layers sequentially on the shared document"
            )
            #endif
            var collected: [(VerificationLayer, LayerResult)] = []
            for layer in layers {
                let result = await verifier.runLayer(
                    layer,
                    outputDocument: shared,
                    sourcePageCount: sourcePageCount,
                    regions: regions,
                    sensitiveTerms: sensitiveTerms,
                    pipelineMode: pipelineMode,
                    filterDigests: filterDigests,
                    perPageModes: perPageModes
                )
                collected.append((layer, result))
            }
            return collected
        }

        let verifier = self.verifier
        return try await withThrowingTaskGroup(of: (VerificationLayer, LayerResult).self) { group in
            for layer in layers {
                let layerDoc = perLayerDocuments[layer] ?? shared
                group.addTask {
                    let result = await verifier.runLayer(
                        layer,
                        outputDocument: layerDoc,
                        sourcePageCount: sourcePageCount,
                        regions: regions,
                        sensitiveTerms: sensitiveTerms,
                        pipelineMode: pipelineMode,
                        filterDigests: filterDigests,
                        perPageModes: perPageModes
                    )
                    return (layer, result)
                }
            }
            var collected: [(VerificationLayer, LayerResult)] = []
            for try await pair in group {
                collected.append(pair)
            }
            return collected
        }
    }
}
