import Foundation
import PDFKit
import Vision
import os
import RedactionEngine

extension PipelineRunner {

    /// The detection run's product — written to `RedactionState` by the
    /// coordinator's adapter once every page succeeded, so intermediate
    /// state never leaks on cancellation.
    struct DetectionResults {
        let results: [Int: [DetectionResult]]
        let diagnostics: [Int: ClassificationDiagnostic]
        let ocrPixelCapSkippedPages: Set<Int>
        let ambiguousSurnameDetectionIDs: Set<UUID>
        let crossPageEntityGroups: [CrossPageEntityGroup]
    }

    // MARK: - Detection run

    /// Run PII and face detection across all pages: the detector load, the
    /// depth-2 lookahead loop over `renderPageForDetection` +
    /// `DetectionOrchestrator.detectPage`, and the two clustering passes.
    func runDetection(
        recognitionLevel: VNRequestTextRecognitionLevel,
        runSettings: PipelineCoordinator.RunSettings
    ) async throws -> PipelineRunOutcome {
        // The coordinator is `@unchecked Sendable`; the detached hint
        // closure below captures this reference.
        let coordinator = self.coordinator
        // Build the detector via the diagnostic-returning
        // loader so any gazetteer / context-keywords corpus failure
        // can surface as a one-time warning toast + a persistent
        // top banner in the triage sheet. Failed loaders degrade
        // into nil-gazetteer pass-through (non-gazetteer regex
        // detectors continue to fire). The flag is only flipped on
        // the first qualifying failure; subsequent runs that re-
        // discover the same failure do not re-toast because the
        // flag is already set.
        // PERF — both the corpus load and the orchestrator construction
        // perform synchronous bundled-resource I/O. This Task body is
        // MainActor-isolated (see the nonisolated(unsafe) note above) and
        // both are nonisolated *synchronous* calls, so invoking them
        // directly runs the whole load on the main thread and freezes the
        // UI at Auto-Detect kickoff. Two distinct costs:
        //
        //   1. `loadWithDiagnostics()` reads/parses the gazetteer corpus
        //      (two ~26 MB bloom filters). When the manifest signature
        //      fails it short-circuits to nil-gazetteer pass-through, so
        //      this cost is ONLY paid on the signature-valid path.
        //
        //   2. `DetectionOrchestrator(...)` is the offender on the
        //      signature-FAILURE path: its stored-property defaults decode
        //      bundled JSON in their initializers — notably the ~2.3 MB
        //      `address_components.json` via `AddressSpatialAssembler`'s
        //      `static let` cache. This load is NOT gated by signature
        //      verification, so it runs on (the first) Auto-Detect per
        //      process regardless of corpus state. The diagnostics enum
        //      classifies it as outside the manifest signature
        //      (`GazetteerLoadDiagnostics.outsideManifestSignature`),
        //      so a signature failure does not attribute it.
        //
        // Build both off the main actor — same remedy `firstPageText`
        // uses for synchronous PDFKit reads. `PIIDetector`,
        // `GazetteerLoadDiagnostics`, and `DetectionOrchestrator` are all
        // Sendable, so the results cross the detached boundary cleanly.
        let (orchestrator, gazetteerDiagnostics) =
            await Task.detached(priority: .userInitiated) {
                let (detector, diagnostics) =
                    PIIDetector.loadWithDiagnostics()
                let orchestrator = DetectionOrchestrator(
                    recognitionLevel: recognitionLevel,
                    detector: detector,
                    diagnostics: diagnostics
                )
                return (orchestrator, diagnostics)
            }.value
        // The diagnostics surface (a toast + the degraded banner) is the
        // coordinator's: reported as an event at the same point.
        sink(.gazetteerDiagnostics(gazetteerDiagnostics))

        // Snapshot priors + surface forms once pre-loop.
        // Sendable value types cross the @concurrent boundary safely.
        let priorsSnapshot = coordinator.redactionState.priors
        let surfaceFormsSnapshot = coordinator.redactionState.surfaceForms
        // Snapshot the USER-SELECTED preset's
        // vector once per run (was the fixed `.balanced` static).
        let thresholdVectorSnapshot: PresetThresholdVector? = coordinator.settingsState.activeThresholdVector
        // Snapshot the per-page text-
        // layer status once pre-loop so `buildOCRSkipHint` can run OFF
        // the MainActor. textLayerStatus is populated at doc-open and is
        // not mutated during a detection run, so the copy is a faithful
        // read; it removes the last MainActor-isolated access from the
        // hint, freeing the UI thread from EmbeddedTextSource.make's
        // per-word enumeration on searchable-redaction pages.
        let textLayerStatusSnapshot = coordinator.documentState.textLayerStatus

        // Accumulate results locally instead of writing to
        // redactionState.detectionResults during the loop. This avoids
        // intermediate state leakage on cancellation, so that
        // detectionResults is only written on success.
        var accumulatedResults: [Int: [DetectionResult]] = [:]
        var accumulatedDiagnostics: [Int: ClassificationDiagnostic] = [:]
        // Pages whose page-level provenance reports the
        // OCR pixel-cap skip; written to redactionState with the
        // other accumulators on success.
        var accumulatedOCRCapSkips: Set<Int> = []

        /// Detect one page and fold its results into the three
        /// accumulators — the body both detect branches share.
        /// Stamps the `detectPage` signpost interval so
        /// DetectionRasterizeOverlapTests can assert overlap with the
        /// lookahead rasterize; the trailing page (no overlapping
        /// rasterize counterpart) carries `trailing=true` so the
        /// overlap-rate metric omits it from the denominator.
        func detectOne(
            _ i: Int, image pageImage: CGImage,
            embeddedText embeddedSource: EmbeddedTextSource?,
            ocrSkipReason skipReason: DetectionResult.Provenance.OCRSkipReason?,
            trailing: Bool
        ) async throws {
            let detectSignpostID = detectionRasterizeSignposter
                .makeSignpostID()
            let detectSignpostState = trailing
                ? detectionRasterizeSignposter.beginInterval(
                    "detectPage", id: detectSignpostID,
                    "page=\(i) trailing=true"
                )
                : detectionRasterizeSignposter.beginInterval(
                    "detectPage", id: detectSignpostID,
                    "page=\(i)"
                )
            // Seed the doctype
            // window with the previous page's classification.
            // Detection is serial across pages, so the i-1
            // diagnostic is already recorded when page i
            // dispatches; missing diagnostic → nil context
            // (degrade, never race).
            let prevPrimary: DoctypeClass? =
                i > 0 ? accumulatedDiagnostics[i - 1]?.primary : nil
            let doctypeCtx = prevPrimary.map { prev in
                DoctypeWindow(primary: prev)
            }
            let pageResult: PageDetectionResult
            do {
                pageResult = try await orchestrator.detectPage(
                    image: pageImage,
                    pageIndex: i,
                    priors: priorsSnapshot,
                    surfaceForms: surfaceFormsSnapshot,
                    doctypeContext: doctypeCtx,
                    thresholdVector: thresholdVectorSnapshot,
                    embeddedText: embeddedSource,
                    ocrSkipReason: skipReason
                )
            } catch { // LegalPhrases:safe (Swift keyword)
                detectionRasterizeSignposter.endInterval(
                    "detectPage", detectSignpostState
                )
                throw error
            }
            detectionRasterizeSignposter.endInterval(
                "detectPage", detectSignpostState
            )
            accumulatedResults[i] = pageResult.detections
            if let diag = pageResult.classificationDiagnostic {
                accumulatedDiagnostics[i] = diag
            }
            // Record the page-level OCR pixel-cap
            // skip so the triage banner can surface it.
            if pageResult.ocrProvenance.ocrSkipReason == .pixelCapExceeded {
                accumulatedOCRCapSkips.insert(i)
            }
        }

        // Depth-2 lookahead via structured concurrency.
        //
        // Locked decision:
        // up to 2 pages in flight. While the orchestrator detects
        // page N, the next page's render-for-detection
        // (`renderPageForDetection`) runs concurrently via `async
        // let`. At the start of iteration N+1, the prefetched image
        // is awaited — by which point the rasterize work usually
        // completed alongside iteration N's detect.
        //
        // Why depth-2 (not deeper): the per-page CGImage at 150 DPI
        // can run several hundred MB on photo-sourced PDFs; the
        // memory model was sized for at most 2 in-flight pages
        // (current page's image kept for detect + lookahead image
        // settling). Depth is locked at 2.
        //
        // Cancellation correctness: `async let` is structured —
        // leaving the iteration's scope without awaiting cancels
        // and awaits the lookahead task. On a rasterize failure
        // mid-flight, `try await nextImage` throws and the outer
        // loop unwinds; the in-flight detect (this iteration's)
        // completes its current await suspension, observes
        // cancellation propagated from the enclosing Task, and
        // surfaces it through `try Task.checkCancellation()` at the
        // next iteration. Detected-PII parity vs. the no-overlap
        // path is preserved — overlap is a scheduling change, not
        // a correctness change.
        let totalPages = coordinator.documentState.pageCount
        if totalPages > 0 {
            // Bootstrap: render page 0's image. The lookahead loop
            // assumes "current image in hand" at iteration entry;
            // we satisfy that for iteration 0 by awaiting here.
            guard let bootstrapDoc = coordinator.documentState.sourceDocument,
                  let bootstrapPage = bootstrapDoc.page(at: 0) else {
                // Graceful degradation: the page-0 bootstrap could not
                // start. Return to a safe `.editing` state with a
                // mechanism-description toast instead of the illegal
                // `editing → failed` transition that previously crashed
                // here (the transition table has no editing→failed pair, and
                // none is added). The degrade (a toast + the run
                // record) is the coordinator's — an event here.
                sink(.detectionBootstrapFailed)
                return .detectionBootstrapFailed
            }
            var pendingImage: CGImage = try await
                coordinator.renderPageForDetection(
                    bootstrapPage, pageIndex: 0,
                    phase: .rasterizePreflight)
            var pendingPage: PDFPage = bootstrapPage

            for i in 0..<totalPages {
                try Task.checkCancellation()
                sink(.phase(.detecting(
                    progress: .init(
                        currentPage: i + 1,
                        totalPages: totalPages,
                        currentStep: recognitionLevel == .fast
                            ? "Scanning page \(i + 1)\u{2026}"
                            : "Thorough scan \u{2014} page \(i + 1)\u{2026}"
                    )
                )))

                let pageImage = pendingImage
                let pageForDetect = pendingPage

                // OCR confidence-based skip fast path
                // (decision recorded per-DetectionResult).
                // Route the pipelineMode read through
                // the run-entry snapshot.
                // Run the hint OFF the
                // MainActor. `buildOCRSkipHint` is now `nonisolated` and
                // reads only Sendable snapshots + the page, so its
                // per-word EmbeddedTextSource enumeration no longer
                // blocks the UI. Detached (no cancellation inheritance,
                // same as the loadWithDiagnostics detach above); the
                // per-iteration checkCancellation covers the loop.
                nonisolated(unsafe) let hintPage = pageForDetect
                let (embeddedSource, skipReason) =
                    await Task.detached(priority: .userInitiated) {
                        coordinator.buildOCRSkipHint(
                            for: hintPage,
                            pageIndex: i,
                            runSettings: runSettings,
                            textLayerStatus: textLayerStatusSnapshot)
                    }.value

                // Depth-2 lookahead. Per page, two paths:
                //   * If a next page exists: kick off its
                //     render-for-detection concurrently with the
                //     current page's detect via `async let`. Await
                //     the lookahead at the end of the iteration so
                //     iteration N+1 enters with `pendingImage`
                //     already loaded.
                //   * Last page: no lookahead; detect runs alone.
                if i + 1 < totalPages {
                    guard let doc = coordinator.documentState.sourceDocument,
                          let nextPage = doc.page(at: i + 1) else {
                        sink(.phase(.failed(
                            error: .detectionError(.visionError(pageIndex: i + 1)),
                            returnPhase: .editing
                        )))
                        return .detectionLookaheadPageMissing(pageIndex: i + 1)
                    }
                    // Structured-concurrency lookahead. The
                    // `nonisolated(unsafe)` capture is the same
                    // safety model the existing per-page render
                    // uses — `PDFPage` is touched single-threaded
                    // (this iteration's `renderPageForDetection`
                    // is the only in-flight reader of `nextPage`;
                    // detect runs against a separate CGImage).
                    nonisolated(unsafe) let lookaheadPage = nextPage
                    let lookaheadIndex = i + 1
                    // DPI seed for the lookahead render:
                    // the newest diagnostic recorded at dispatch time
                    // is page i-1's (page i's detect runs CONCURRENT
                    // with this render), so page i+1 renders with
                    // class(i-1) — a one-page lag behind the detect
                    // seeding below. Bootstrap and page 1 render
                    // unseeded (nil → policy default 150 DPI).
                    let lookaheadDoctype: DoctypeClass? =
                        i > 0 ? accumulatedDiagnostics[i - 1]?.primary : nil
                    async let nextImage: CGImage =
                        coordinator.renderPageForDetection(
                            lookaheadPage, pageIndex: lookaheadIndex,
                            phase: .rasterizeLookahead,
                            doctype: lookaheadDoctype)

                    // Doctype-aware, prior-scored
                    // detection. Runs CONCURRENT with the
                    // lookahead rasterize above (depth-2).
                    try await detectOne(
                        i, image: pageImage, embeddedText: embeddedSource,
                        ocrSkipReason: skipReason, trailing: false)

                    // Cooperative check between
                    // the just-completed detect await and the
                    // upcoming lookahead await. Without this a
                    // cancel arriving here would otherwise wait for
                    // the lookahead rasterize to complete before
                    // surrendering.
                    try Task.checkCancellation()

                    // Await the lookahead. If the rasterize threw
                    // mid-flight, this re-throws and exits the
                    // loop — `async let`'s structured scope has
                    // already awaited any cancellation cleanup.
                    pendingImage = try await nextImage
                    pendingPage = lookaheadPage
                } else {
                    // Last page — no lookahead to dispatch; the
                    // detect runs alone.
                    try await detectOne(
                        i, image: pageImage, embeddedText: embeddedSource,
                        ocrSkipReason: skipReason, trailing: true)
                }
            }
        }

        // Cooperative check between detect
        // loop completion and Jaro-Winkler / cross-page clustering.
        // Both clusterers are synchronous O(n²) in the worst case;
        // a cancel arriving here without this check would otherwise
        // wait for the entire clustering pass to complete.
        try Task.checkCancellation()

        // Document-level Stage 5: entity clustering on name detections.
        // Bare-surname clusters ≥15 get flagged for inline ambiguity hints.
        let clusterer = EntityClusterer()
        var clusterInputs: [EntityClusterer.ClusterInput] = []
        // Page order, not Dictionary order: two runs over the same
        // detections hand the clusterer the same input sequence.
        for page in accumulatedResults.keys.sorted() {
            for result in accumulatedResults[page] ?? [] {
                guard case .pii(let kind) = result.kind, kind == .name else { continue }
                guard let text = result.matchedText,
                      let input = EntityClusterer.clusterInput(
                        for: result.id, rawName: text
                      ) else { continue }
                clusterInputs.append(input)
            }
        }
        let clusterReport = clusterer.cluster(names: clusterInputs)

        // Second cooperative check between the
        // two clustering passes.
        try Task.checkCancellation()

        // Document-level Stage 5b: cross-page entity
        // linking across **all** PII categories using
        // normalize-and-exact-match. Peer to the name-only
        // clusterer above (which uses Jaro-Winkler over surname
        // blocks). Drives the "Grouped" view mode in the scan
        // review surface (`ScanReviewSection`).
        let crossPageGroups =
            CrossPageEntityGroup.clusters(from: accumulatedResults)

        // Hand the accumulators to the coordinator only after all pages
        // succeed: it writes them, then stages the review or records
        // that nothing was found.
        sink(.detectionFinished(DetectionResults(
            results: accumulatedResults,
            diagnostics: accumulatedDiagnostics,
            ocrPixelCapSkippedPages: accumulatedOCRCapSkips,
            ambiguousSurnameDetectionIDs: clusterReport.bareSurnameFlags,
            crossPageEntityGroups: crossPageGroups)))
        return .completed
    }
}
