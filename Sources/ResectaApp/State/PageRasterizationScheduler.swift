import Foundation
import os
import RedactionEngine

/// The page-parallel rasterization schedule `PipelineCoordinator.processDocument`
/// drives. Submits per-page rasterize work into a bounded
/// `withThrowingTaskGroup` and STREAMS each result to `onPageReady` as soon as
/// it is next-in-order. Out-of-order completions buffer in `pending`; ONE
/// residency gate (`canSubmit(bound:)`: `inFlight < bound` and
/// `inFlight + pending.count < bound * 2`) back-pressures new submissions so
/// peak full-res CGImage residency is page-count-INDEPENDENT (supersedes the
/// collect-then-drain mechanism; the 0..<count append-ORDER invariant is
/// preserved by construction — the in-order drain only fires `onPageReady`
/// for the contiguous next index, and the reconstructor's state model is
/// order-sensitive, locked decision).
///
/// Memory: the honest live-image bound is ≈ `(3·inFlight + pending + 1)`
/// pagefuls + ≤4 pool buffers ≈ `(4·bound + 5)` pagefuls — each running
/// task holds ~3 pagefuls of its own (render context + renderedImage +
/// pooled fill context + redactedImage; see `PageRasterizer`). The
/// `residentAccounting` value handed to `onProgress`
/// (`inFlight + pending.count + 1`) is an accounting bound on completed-result
/// residency, NOT this full census; the coordinator samples it into its
/// DEBUG-only `maxResidentResults`.
/// Liveness rests on the 10,000-pt pre-flight + finiteness of
/// `drawPDFPage` (NOT the 30 s render timeout — it cannot interrupt the
/// uninterruptible render child; see PageRasterizer's pre-flight comments).
///
/// Concurrency bound: `parallelismBound(remainingPages:dpiCap:parallelismOverride:)`
/// = `max(1, min(cores - 1, memoryBudgetPages))`, recomputed before EVERY
/// submission (so the bound shrinks under live memory pressure even before a
/// `didReceiveMemoryWarningNotification` fires); `parallelismOverride == 1`
/// (set on memory warning) collapses to sequential behavior until workspace
/// teardown. The DPI cap is likewise read FRESH per submission through the
/// `dpiCap` closure, NOT snapshotted once per run: `run` is MainActor-isolated,
/// so a read between `await` suspension points observes the latest value
/// written by the memory-warning handler (which lowers the cap to 150). A
/// stale run-level snapshot would pin every page to the pre-warning cap,
/// defeating the mid-run memory response.
///
/// Progress is reported as each task COMPLETES (`completed` counts finished
/// pages, not the most recently scheduled one) — monotonic under
/// out-of-order completion.
///
/// The state that was function-local in the coordinator now lives on the
/// struct so a test can read the drain position after a run; `run` resets it
/// at entry.
struct PageRasterizationScheduler {
    /// Completed-but-unappended results, keyed by page index.
    private(set) var pending: [Int: RasterizeResult] = [:]
    /// The next page index the in-order drain will hand to `onPageReady`.
    private(set) var nextAppendIndex = 0
    /// The next page index to submit.
    private(set) var nextSubmitIndex = 0
    /// Producers currently running in the group.
    private(set) var inFlight = 0
    /// Pages whose rasterize has finished (in any order).
    private(set) var completed = 0

    /// The residency gate, in ONE place. A new producer may be submitted only
    /// while fewer than `bound` are in flight AND the completed-but-unappended
    /// buffer plus the in-flight count stays below `2 × bound`, so
    /// out-of-order completions can't accumulate N full-res CGImages. In the
    /// prime loop `pending` is empty, so this reduces to `inFlight < bound`.
    func canSubmit(bound: Int) -> Bool {
        inFlight < bound && inFlight + pending.count < bound * 2
    }

    /// Run the schedule over `pages`.
    ///
    /// - `dpiCap`: the live DPI cap, read per submission (see the type doc).
    /// - `parallelismBound`: the bound for the remaining pages at that cap,
    ///   read per submission.
    /// - `rasterize`: the per-page producer (the coordinator's
    ///   `rasterizeWithRetry`, so the one half-DPI retry on
    ///   `fillVerificationFailed` happens inside the task).
    /// - `onPageReady`: receives every page in 0..<count order, one at a time,
    ///   and releases its full-res CGImage as it returns. An error here is
    ///   NOT swallowed: a suppressed throw would be a silent page drop the
    ///   post-run guard cannot distinguish from success.
    /// - `onProgress`: fires once per completion, BEFORE the drain, with
    ///   `(completed, total, residentAccounting)`.
    mutating func run(
        pages: [PDFPageData],
        rasterizer: PageRasterizer,
        dpiCap: () -> Int,
        parallelismBound: (ArraySlice<PDFPageData>, Int) -> Int,
        rasterize: @escaping @Sendable (PDFPageData, PageRasterizer, Int) async throws -> RasterizeResult,
        onPageReady: (Int, RasterizeResult) async throws -> Void,
        onProgress: (_ completed: Int, _ total: Int, _ residentAccounting: Int) -> Void
    ) async throws {
        guard !pages.isEmpty else { return }

        pending = [:]
        nextAppendIndex = 0
        nextSubmitIndex = 0
        inFlight = 0
        completed = 0
        let totalPages = pages.count

        try await withThrowingTaskGroup(of: (Int, RasterizeResult).self) { group in
            // Prime the group up to the initial bound. Bound is recomputed
            // before every submission so it can shrink under live memory
            // pressure (and after a memory warning collapses it to 1).
            while nextSubmitIndex < totalPages {
                // Capture the live cap per submission (read on the
                // MainActor) so a mid-run memory warning lowers DPI for this
                // page too. The captured `Int` is sendable into the child task.
                let cap = dpiCap()
                let bound = parallelismBound(pages[nextSubmitIndex...], cap)
                guard canSubmit(bound: bound) else { break }
                let page = pages[nextSubmitIndex]
                let idx = nextSubmitIndex
                group.addTask {
                    let result = try await rasterize(page, rasterizer, cap)
                    return (idx, result)
                }
                inFlight += 1
                nextSubmitIndex += 1
            }

            // Consume completions; drain in order; refill up to the
            // (re-evaluated) bound.
            while let (idx, result) = try await group.next() {
                pending[idx] = result
                inFlight -= 1
                completed += 1

                // Sample the residency accounting bound IMMEDIATELY after the
                // store, BEFORE the in-order drain, to capture the peak; the
                // progress UI update rides the same call.
                onProgress(completed, totalPages, inFlight + pending.count + 1)

                // Surface cancellation BETWEEN submissions. The group itself
                // already propagates cancellation into in-flight child tasks
                // via structured concurrency; this check lets us bail out
                // of the loop without scheduling more work.
                try Task.checkCancellation()

                // In-order drain: hand every now-contiguous page to
                // `onPageReady` and release its full-res CGImage at the end of
                // each iteration. `pending` retains only out-of-order
                // completions.
                while let next = pending.removeValue(forKey: nextAppendIndex) {
                    try await onPageReady(nextAppendIndex, next)
                    nextAppendIndex += 1
                }

                // Refill: submit as many new producers as the (current) bound
                // permits. The bound may have dropped to 1 if a memory
                // warning fired between iterations. Pages submitted after a
                // mid-run warning rasterize at the lowered cap; in-flight
                // pages plus at most one submission burst at the pre-warning
                // bound remain at the old cap (the one-page figure holds only
                // under parallelismOverride == 1).
                while nextSubmitIndex < totalPages {
                    let cap = dpiCap()
                    let bound = parallelismBound(pages[nextSubmitIndex...], cap)
                    guard canSubmit(bound: bound) else { break }
                    let page = pages[nextSubmitIndex]
                    let nextIdx = nextSubmitIndex
                    group.addTask {
                        let r = try await rasterize(page, rasterizer, cap)
                        return (nextIdx, r)
                    }
                    inFlight += 1
                    nextSubmitIndex += 1
                }
            }
        }

        // Defensive parity with the old second-pass `guard let result =
        // results[i]`: a correct run drains `pending` empty and appends every
        // page. Reachable only via a future logic bug; reuses the
        // existing error case (no PipelineError hierarchy change).
        guard nextAppendIndex == pages.count else {
            throw PipelineError.redactionError(.reconstructionFailed)
        }
    }

    // MARK: - The bound

    /// Compute the active rasterization parallelism bound. Locked formula:
    ///
    ///     max(1, min(cores - 1, memoryBudgetPages))
    ///
    /// where `memoryBudgetPages = available / per-page-bytes`. The
    /// per-page byte estimate is the worst-case bitmap footprint for the
    /// next page about to be submitted, multiplied by 3 to cover the pagefuls
    /// `PageRasterizer.rasterize` can hold concurrently — the render context,
    /// the pooled fill context, and the JPEG-encode buffer (corrected
    /// from 2× to a conservative 3×; intentionally tighter than `selectDPI`'s
    /// 2× factor, which counts only render + fill). `parallelismOverride`
    /// (set to 1 on `didReceiveMemoryWarningNotification`) clamps the result
    /// to 1 until workspace teardown.
    nonisolated static func parallelismBound(
        remainingPages: ArraySlice<PDFPageData>, dpiCap: Int, parallelismOverride: Int?
    ) -> Int {
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        let memoryPages = memoryBudgetPages(
            remainingPages: remainingPages, dpiCap: dpiCap
        )
        var bound = max(1, min(cores, memoryPages))
        if let override = parallelismOverride {
            bound = min(bound, max(1, override))
        }
        return bound
    }

    /// Estimate how many pages can be rasterized concurrently before the
    /// summed in-flight bitmap memory exceeds the live `os_proc_available_memory()`
    /// budget. Uses the size of the next page about to be submitted as a
    /// worst-case proxy (pages within a single document tend to share
    /// dimensions; mixed-size documents over-estimate per-page bytes from
    /// the leading page, which is conservative — we err on the side of
    /// fewer concurrent producers).
    nonisolated static func memoryBudgetPages(
        remainingPages: ArraySlice<PDFPageData>, dpiCap: Int
    ) -> Int {
        guard let head = remainingPages.first else { return 1 }
        // Use the pre-extracted cropBox bounds (same float as
        // `head.page.bounds(for: .cropBox)`, now read serially at build time) so
        // the bound estimate never touches the shared document concurrently. The
        // bound integer is unchanged.
        let rawBounds = head.cropBoxBounds
        let effectiveSize: CGSize = {
            switch head.rotation {
            case 90, 270:
                return CGSize(width: rawBounds.height, height: rawBounds.width)
            default:
                return rawBounds.size
            }
        }()
        let effectiveDPI = min(head.targetDPI, dpiCap)
        let scale = CGFloat(effectiveDPI) / 72.0
        let pixelW = Int(ceil(effectiveSize.width * scale))
        let pixelH = Int(ceil(effectiveSize.height * scale))
        // 4 bytes/pixel × 3: render context + pooled fill context + JPEG
        // encode buffer can be held concurrently inside rasterize()/append
        // (corrected from 2× to a conservative 3×; tighter than
        // selectDPI's 2× factor, which counts only render + fill).
        let perPageBytes = max(1, pixelW * pixelH * 4 * 3)
        let available = Int(os_proc_available_memory())
        // 150 MB headroom — same constant the engine's selectDPI reserves.
        let budget = max(0, available - 150_000_000)
        return max(1, budget / perPageBytes)
    }
}
