import Foundation
import PDFKit
import RedactionEngine

// The rasterization steps of a run: the page-parallel schedule bound to the
// coordinator's live caps, the one per-page retry, and the ordered append
// into the reconstructor. Moved here from the coordinator's body unchanged;
// the stored properties they read stay on the coordinator.

extension PipelineCoordinator {

    // MARK: - Rasterization + Reconstruction

    /// Process all pages: rasterize → fill → reconstruct PDF.
    /// Returns a PipelineRunContext with per-page digests and modes for verification.
    /// Reports progress through `onProgress` (the runner turns each tick
    /// into a `.redacting` self-transition).
    func processDocument(
        _ pages: [PDFPageData],
        outputURL: URL,
        sensitiveTerms: SensitiveTermSet,
        appliedSearches: [SearchRecheckRequest],
        onProgress: (DocumentState.RedactionProgress) -> Void
    ) async throws -> PipelineRunContext {
        let rasterizer = PageRasterizer()
        // Surface the active rasterizer to the memory-warning
        // observer so a mid-run iOS memory warning can flush the bitmap
        // pool. The weak property does not extend the rasterizer's
        // per-run lifetime; on return it deallocates naturally.
        self.activeRasterizer = rasterizer
        defer { self.activeRasterizer = nil }

        // Atomic temp file → output URL promotion.
        // Intermediate reconstruction file lives inside the
        // per-session subdir so it is excluded from backup and swept on
        // teardown along with the final output.
        let tempURL = try tempExportDirectory.childURL(
            named: "recon_\(UUID().uuidString).pdf")
        // Clean up partial temp file on failure/cancellation. On success,
        // replaceItemAt moves the file atomically so this is a no-op.
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let reconstructor = PDFStreamReconstructor(tempURL: tempURL)

        let firstSize = pages.first.map { page in
            // Single source of truth — the pre-extracted
            // cropBox bounds, not a live `page.page.bounds(for:)` read.
            let raw = page.cropBoxBounds
            switch page.rotation {
            case 90, 270: return CGSize(width: raw.height, height: raw.width)
            default: return raw.size
            }
        } ?? CGSize(width: 612, height: 792)

        try await reconstructor.begin(firstPageSize: firstSize)

        // Page-parallel rasterization with STREAMING ordered
        // append. The locked collect-then-drain MECHANISM (collect all
        // N RasterizeResults into a `[Int: RasterizeResult]`, then append in a
        // second pass) is SUPERSEDED: it held every full-res CGImage resident
        // at the end of the parallel phase (N × ~33.7 MB → the P0 jetsam cliff
        // on large documents). `rasterizePagesInParallel` now hands
        // each page to `onPageReady` as soon as it is next-in-order, with a
        // residency gate back-pressuring out-of-order completions, so peak
        // full-res residency is page-count-INDEPENDENT. The locked 0..<count
        // append-ORDER invariant (PDFStreamReconstructor is order-sensitive)
        // is RETAINED and promoted to a tested invariant.
        var filterDigests: [PageFilterDigest?] = []
        var perPageModes: [PipelineMode] = []
        var perPageFallbackReasons: [TextLayerDetector.FallbackReason?] = []
        lastReconstructorAppendOrder.removeAll()
        try await rasterizePagesInParallel(
            pages: pages, rasterizer: rasterizer, onProgress: onProgress
        ) { idx, result in
            // Appended in 0..<count callback order — identical inputs/order to
            // the old second pass, so the Layer-7 digest cross-check and
            // per-page mode bookkeeping are unchanged.
            filterDigests.append(result.filterDigest)
            perPageModes.append(
                result.filterDigest != nil ? .searchableRedaction : .secureRasterization
            )
            // Collected beside the mode so the two arrays stay
            // index-aligned by construction.
            perPageFallbackReasons.append(result.fallbackReason)
            try await reconstructor.appendPage(result.pageOutput)
            // Test seam: record append order at the same semantic
            // point as the old per-iteration append. Callback (= in-order
            // drain) order is 0..<count by construction.
            self.lastReconstructorAppendOrder.append(idx)
            // CGImage from `result` released as the callback returns.
        }

        await reconstructor.finalize()

        // Postcondition gate. finalize() has
        // three independent silent-exit paths (not-begun/empty guard, context-
        // creation guard, per-page decode guard). Comparing the count of pages
        // actually written against the count we appended covers all three —
        // and any future drop cause — with one check. It sits BEFORE the atomic
        // rename so a truncated temp file never replaces a good output.
        guard await reconstructor.writtenPageCount == pages.count else {
            throw PipelineError.redactionError(.reconstructionFailed)
        }

        #if DEBUG
        beforeOutputPromotionSeam?()
        #endif
        // A Stop that landed during the finalize: the run is no longer the
        // active one, so its reports are dropped and its recovery is
        // skipped — a promoted output would sit in the session directory
        // until the sweep. Not promoted; the temp file goes with the defer.
        try Task.checkCancellation()
        // Atomic rename: same APFS volume (both in temporaryDirectory)
        _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tempURL)
        // The same Stop, landed during the rename itself.
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: outputURL)
            throw CancellationError()
        }

        return PipelineRunContext(
            outputURL: outputURL,
            filterDigests: filterDigests,
            perPageModes: perPageModes,
            perPageFallbackReasons: perPageFallbackReasons,
            sensitiveTerms: sensitiveTerms,
            appliedSearches: appliedSearches,
            burnedRegions: Dictionary(uniqueKeysWithValues: pages.compactMap {
                $0.regions.isEmpty ? nil : ($0.pageIndex, $0.regions) })
        )
    }

    // MARK: - Per-Page Retry

    /// The one retry's DPI cap: the lowest tier `selectDPI` returns (150),
    /// so the raster the retry renders is the raster its memory pre-flight
    /// estimates. Never a number the tiers cannot return.
    // nonisolated: read by the `nonisolated rasterizeWithRetry` parallel TaskGroup body
    // (a @Sendable closure). A plain Int constant — opted out of the SE-0466
    // MainActor default so the off-actor retry path can read it directly.
    nonisolated static let retryDPICap: Int = 150

    /// Rasterize a single page; on `fillVerificationFailed`,
    /// re-rasterize once at `retryDPICap`: at most one retry, at the 150
    /// tier. A second failure propagates the original error type so the
    /// caller surfaces the page index unchanged.
    ///
    /// Placement note: the retry sits in the
    /// per-page loop, NOT in `runVerification`'s layer loop. `runVerification`
    /// iterates verification layers (Text Extraction, OCR, …) — it has no
    /// page-level retry semantics.
    ///
    /// `nonisolated` so the parallel TaskGroup body (a `@Sendable`
    /// closure) can call it directly without an actor hop. The function
    /// reads only static constants and the rasterizer/page args — no
    /// MainActor-isolated instance state is touched.
    ///
    /// `internal` visibility so `PerPageRetryTests` (`@testable import`) can
    /// drive the retry directly without standing up the full pipeline.
    nonisolated func rasterizeWithRetry(
        _ page: PDFPageData,
        rasterizer: PageRasterizer,
        primaryDPICap: Int
    ) async throws -> RasterizeResult {
        do {
            return try await rasterizer.rasterize(page, dpiCap: primaryDPICap)
        } catch let error as PipelineError { // LegalPhrases:safe (Swift keyword)
            // Only retry on the specific fill-verification failure for this
            // exact page. Any other redaction or system error propagates.
            guard case .redactionError(.fillVerificationFailed(let failedIndex)) = error,
                  failedIndex == page.pageIndex else {
                throw error
            }
            // At most one retry. A second failure throws the same error type
            // (carrying the page index) up the stack.
            return try await rasterizer.rasterize(page, dpiCap: Self.retryDPICap)
        }
    }

    // MARK: - Page-Parallel Rasterization

    /// Rasterize `pages` page-parallel with STREAMING ordered append: the
    /// schedule — the bounded submission, the index-tagged in-order drain,
    /// the residency gate — is `PageRasterizationScheduler`'s; this method
    /// binds it to the coordinator's live `dpiCap` / `parallelismOverride`
    /// reads, its `rasterizeWithRetry`, the `.redacting` progress transition
    /// and the DEBUG residency telemetry. Each parallel task wraps the
    /// rasterize call in `rasterizeWithRetry`, so the per-page retry at the
    /// 150 tier on `fillVerificationFailed` happens inside the task — preserving the
    /// per-page retry semantics under parallel execution.
    ///
    /// `internal` access (rather than `private`) so the page-parallel test suite
    /// can exercise the parallel orchestration without driving the full
    /// reconstructor / verify pipeline end-to-end.
    func rasterizePagesInParallel(
        pages: [PDFPageData], rasterizer: PageRasterizer,
        onPageReady: @MainActor (Int, RasterizeResult) async throws -> Void
    ) async throws {
        try await rasterizePagesInParallel(
            pages: pages, rasterizer: rasterizer,
            onProgress: { documentState.transition(to: .redacting(progress: $0)) },
            onPageReady: onPageReady)
    }

    /// The same schedule with the progress tick handed to `onProgress`
    /// instead of transitioned here — the runner's form (it reports the
    /// tick as an event; the coordinator transitions).
    func rasterizePagesInParallel(
        pages: [PDFPageData], rasterizer: PageRasterizer,
        onProgress: (DocumentState.RedactionProgress) -> Void,
        onPageReady: @MainActor (Int, RasterizeResult) async throws -> Void
    ) async throws {
        guard !pages.isEmpty else { return }

        #if DEBUG
        maxResidentResults = 0
        #endif

        var scheduler = PageRasterizationScheduler()
        try await scheduler.run(
            pages: pages,
            rasterizer: rasterizer,
            dpiCap: { dpiCap },
            parallelismBound: { remaining, cap in
                computeParallelismBound(remainingPages: remaining, dpiCap: cap)
            },
            rasterize: { [self] page, rasterizer, cap in
                try await self.rasterizeWithRetry(
                    page, rasterizer: rasterizer, primaryDPICap: cap)
            },
            onPageReady: onPageReady,
            onProgress: { completed, totalPages, residentAccounting in
                #if DEBUG
                // Accounting bound on completed-result residency, not a
                // live-CGImage census — see `maxResidentResults`.
                maxResidentResults = max(maxResidentResults, residentAccounting)
                #endif
                // Progress reflects completed pages. Out-of-order completion
                // is fine: `currentPage` is monotonic even though the page
                // index may skip around. The currentStep label uses
                // `completed` so it does not advertise a specific page index
                // that may already be past tense by the time the UI repaints.
                onProgress(.init(
                    currentPage: completed,
                    totalPages: totalPages,
                    currentStep: "Processing \(completed) of \(totalPages)\u{2026}"
                ))
            }
        )
    }

    /// The active rasterization parallelism bound for the coordinator's live
    /// `parallelismOverride` — the locked formula is
    /// `PageRasterizationScheduler.parallelismBound(remainingPages:dpiCap:parallelismOverride:)`.
    ///
    /// `internal` rather than `private` so the dedicated page-parallel test suite
    /// can assert the bound math directly without driving the full pipeline.
    func computeParallelismBound(
        remainingPages: ArraySlice<PDFPageData>, dpiCap: Int
    ) -> Int {
        PageRasterizationScheduler.parallelismBound(
            remainingPages: remainingPages, dpiCap: dpiCap,
            parallelismOverride: parallelismOverride
        )
    }
}
