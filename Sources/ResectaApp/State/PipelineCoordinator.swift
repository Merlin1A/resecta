import Foundation
import PDFKit
import UIKit
import Vision
import os
import RedactionEngine

/// Signpost emission for the detection-pipeline depth-2
/// lookahead. The rasterize-for-detection and detect-page intervals are
/// emitted to this category so they can be sampled in Instruments
/// without re-instrumenting every release; the in-process
/// `DetectionRasterizeProbe` (test-only) collects the same intervals
/// for unit-level overlap assertions. Both are cheap-when-idle.
// nonisolated: file-level OSSignposter (Sendable, immutable) read from both the
// MainActor detection-pipeline closures and the `nonisolated renderPageForDetection`
// rasterize path. Under the SE-0466 MainActor-default flip an unannotated global
// `let` becomes MainActor-isolated, which the nonisolated callers cannot touch; pin
// it nonisolated to restore the pre-flip cross-isolation access (signposting is
// thread-safe).
nonisolated private let detectionRasterizeSignposter = OSSignposter(
    subsystem: "com.resecta.app", category: "DetectionRasterize"
)

/// Test-only collector for `renderPageForDetection` and
/// `orchestrator.detectPage` intervals dispatched from
/// `PipelineCoordinator.runDetectionPipeline`. Production code passes
/// `nil` (the singleton is unset); `DetectionRasterizeOverlapTests`
/// installs a fresh instance per test via `DetectionRasterizeProbe.install`
/// and reads the recorded intervals to assert depth-2 overlap.
///
/// Synchronous, lock-protected append so tests can read `intervals`
/// immediately after the pipeline awaits its final result without
/// awaiting a pending MainActor hop. The lock is uncontended in
/// practice (depth-2 → at most one rasterize + one detect stamp per
/// page, never concurrently from different threads writing the same
/// instance simultaneously beyond what the OSAllocatedUnfairLock
/// already covers in microseconds).
// nonisolated: test-only, lock-protected (`@unchecked Sendable`) collector whose
// `record(_:)` is stamped from the rasterize thread inside the `nonisolated`
// renderPageForDetection path. The SE-0466 MainActor-default flip would otherwise
// make its methods MainActor-isolated; pin the type nonisolated to keep
// `record`/`intervals` callable from any isolation (the NSLock provides the
// serialization the annotation already asserts).
nonisolated final class DetectionRasterizeProbe: @unchecked Sendable {
    /// Single global handle; nil outside tests. Set via
    /// `DetectionRasterizeProbe.install()` in test setup and reset to
    /// nil at test teardown so suites do not leak state across runs.
    nonisolated(unsafe) static var shared: DetectionRasterizeProbe?

    struct Interval: Sendable {
        enum Kind: Sendable { case rasterize, detect }
        let pageIndex: Int
        let phase: PipelineCoordinator.DetectionRasterizePhase
        let kind: Kind
        let start: Date
        let end: Date
    }

    private let lock = NSLock()
    private var _intervals: [Interval] = []

    /// Install a fresh probe and return it. Idempotent — replaces any
    /// existing shared instance. Call from test setup; the matching
    /// `uninstall()` resets the global handle.
    @discardableResult
    static func install() -> DetectionRasterizeProbe {
        let probe = DetectionRasterizeProbe()
        shared = probe
        return probe
    }

    static func uninstall() {
        shared = nil
    }

    /// Snapshot the recorded intervals. Read under lock so writers
    /// completing on a background thread are observed in test code on
    /// MainActor without a stale-read.
    var intervals: [Interval] {
        lock.lock()
        defer { lock.unlock() }
        return _intervals
    }

    /// Append an interval. Safe to call from any thread; the lock
    /// serializes the append. Producers in `runDetectionPipeline`
    /// stamp on the thread the await suspension returned on (often a
    /// background thread for the lookahead rasterize, MainActor for
    /// detect), which is fine — the assertion only needs the
    /// (start,end) tuple per stamp.
    func record(_ interval: Interval) {
        lock.lock()
        _intervals.append(interval)
        lock.unlock()
    }
}

/// Orchestrates the redaction pipeline. MainActor by SE-0466 default.
/// Does NOT hold progress or status state — all UI-facing state lives
/// in DocumentState.phase (single source of truth).
///
/// @unchecked Sendable: MainActor isolation (SE-0466) serializes all mutation;
/// the @Observable macro generates storage that Swift 6 does not infer as
/// Sendable, so the annotation is opt-in to what the runtime already guarantees.
@Observable
final class PipelineCoordinator: @unchecked Sendable {
    // let: references never change after init. Avoids @Observable generating
    // redundant tracking for these properties (they point to the same objects
    // already in the SwiftUI environment).
    let documentState: DocumentState
    let redactionState: RedactionState
    let settingsState: SettingsState

    /// Toast manager for pipeline completion notifications. Set from the view layer.
    var toastManager: ToastQueueManager?
    /// UndoManager for detection result application. Set from the view layer.
    var undoManager: UndoManager?

    /// DPI ceiling honored by PageRasterizer. Dropped to 150 when
    /// UIApplication.didReceiveMemoryWarningNotification fires (observer
    /// owned by the coordinator; torn down in deinit). Default 300.
    var dpiCap: Int = defaultDPICap

    /// Hard cap on rasterization parallelism for the rest of the
    /// workspace's lifetime. Nil means "use the dynamic bound"; `1`
    /// collapses to sequential behavior. Set to `1` by the
    /// memory-warning observer below.
    /// CANCEL-010 — once raised to `1` we do NOT gradually re-raise: the
    /// cap holds until workspace teardown (by design). The cap
    /// survives cancel + restart inside the same workspace; only
    /// `RedactWorkspace.tearDown()` drops it.
    var parallelismOverride: Int? = nil

    /// Test seam: page indices in the exact order their outputs
    /// were handed to `PDFStreamReconstructor.appendPage` during the most
    /// recent `processDocument` run. The reconstructor is order-sensitive
    /// (by design), so
    /// `PageParallelRasterizationTests` asserts this equals `0..<pageCount`.
    /// Recorded by the streaming ordered-append callback;
    /// never read by production code.
    private(set) var lastReconstructorAppendOrder: [Int] = []

    #if DEBUG
    /// Test-only residency telemetry:
    /// the peak value of `inFlight + pending.count + 1` observed during the
    /// most recent `rasterizePagesInParallel` run, reset at function entry.
    /// This is an ACCOUNTING upper bound on completed-RESULT residency — NOT a
    /// census of live full-res CGImages: each in-flight rasterize task also
    /// holds up to ~3 pagefuls of its own (render context + renderedImage +
    /// pooled fill context + redactedImage; see `PageRasterizer`).
    /// `ApplyPhaseMemoryStressTests` asserts this stays within `2 * bound + 1`.
    /// Precedent: BitmapContextPool's test-only introspection. Never read by
    /// production code.
    @ObservationIgnored private(set) var maxResidentResults: Int = 0
    #endif

    /// Cancellable Task driving the memory-warning async sequence.
    /// Cancelled in deinit so the loop terminates and the weak-self capture
    /// is released.
    // nonisolated(unsafe): written once in `init` (on MainActor) and read only by
    // the nonisolated `deinit` to `cancel()`. `Task<Void, Never>` is Sendable with
    // no concurrent access, so opting it out of the SE-0466 MainActor default
    // keeps the deinit synchronous (mirrors ScreenCaptureMonitor's observer tasks).
    nonisolated(unsafe) private var memoryWarningTask: Task<Void, Never>?

    /// The active run's
    /// `PageRasterizer`, set by `processDocument` and cleared on return.
    /// `weak` so the rasterizer's per-run lifetime contract is preserved
    /// — the coordinator does not extend the rasterizer's lifetime past
    /// `processDocument`'s scope. `memoryWarningTask` reads this on
    /// MainActor and calls `flushBitmapPool()` to drop pool entries
    /// alongside the existing `dpiCap = 150` / `parallelismOverride = 1`.
    private weak var activeRasterizer: PageRasterizer?

    /// Per-session temp subdirectory. All pipeline temp writes for
    /// the workspace lifetime live under `redacted_session_<UUID>/`. The
    /// subdirectory is flagged with `isExcludedFromBackup = true` at the
    /// directory level on first use and removed by `tearDownTempDirectory()`,
    /// invoked from `RedactWorkspace.tearDown()`. Crash-orphaned subdirs are
    /// reaped by `cleanOrphanedTempFiles()` at next launch.
    let tempExportDirectory: TempExportDirectory = TempExportDirectory()

    /// Intermediate data produced by processDocument() and consumed by
    /// runVerification(). Scoped to a single pipeline run — not stored
    /// as coordinator state.
    private struct PipelineRunContext {
        let outputURL: URL
        let filterDigests: [PageFilterDigest?]
        let perPageModes: [PipelineMode]
        /// PD-5: sibling of `perPageModes` — the effective per-page fallback
        /// reason from each RasterizeResult (nil = kept searchable mode or
        /// secure-raster-mode run).
        let perPageFallbackReasons: [TextLayerDetector.FallbackReason?]
        let sensitiveTerms: [SensitiveTerm]
    }

    /// Snapshot of pipeline-affecting settings, captured once
    /// at `runFullPipeline` / `runDetectionPipeline` entry. Subsequent
    /// mid-run reads route through the snapshot so a settings toggle
    /// during `.detecting / .redacting / .verifying` cannot divert
    /// kickoff-time behavior from run-time behavior. Mirrors the
    /// existing `effectiveMode` snapshot pattern (see `runFullPipeline`).
    /// Pairs with the SettingsView in-progress banner that
    /// describes the same contract to the user.
    struct RunSettings: Sendable {
        let pipelineMode: PipelineMode
        let autoVerify: Bool
        let paranoidMode: Bool
        let fillColor: FillColor
        let exportDPI: Int

        /// Capture the current pipeline-affecting settings as an
        /// immutable snapshot. Callers are expected to be on MainActor
        /// (or otherwise serialized w.r.t. SettingsState mutation) — the
        /// PipelineCoordinator only invokes this from MainActor entry
        /// points (`runFullPipeline`, `runDetectionPipeline`,
        /// `buildPDFPageData`, `buildOCRSkipHint`). No explicit
        /// isolation annotation: matches the surrounding nonisolated
        /// method context the `@Observable @unchecked Sendable`
        /// coordinator already uses for synchronous `settingsState`
        /// reads at run entry.
        static func snapshot(from settingsState: SettingsState) -> RunSettings {
            RunSettings(
                pipelineMode: settingsState.pipelineMode,
                autoVerify: settingsState.autoVerify,
                paranoidMode: settingsState.paranoidMode,
                fillColor: settingsState.fillColor,
                exportDPI: settingsState.exportDPI
            )
        }
    }

    init(documentState: DocumentState, redactionState: RedactionState,
         settingsState: SettingsState) {
        self.documentState = documentState
        self.redactionState = redactionState
        self.settingsState = settingsState

        // Memory mitigation — on memory warning, both lower dpiCap and
        // collapse rasterization parallelism to 1 until workspace teardown.
        // @MainActor-isolated Task so the writes are in-actor and the
        // weak-self capture is region-safe under Swift 6.2 strict concurrency.
        // CANCEL-010 — once collapsed to 1 we do not re-raise: dpiCap +
        // parallelismOverride persist across cancel + restart within the
        // workspace, dropping only when `tearDown()` (called by
        // `RedactWorkspace.tearDown` / scene tear-down) deallocates the
        // coordinator.
        //
        // Also drop the
        // active rasterizer's bitmap-context pool so the up to ~135 MB of
        // held buffers (4 entries × a ~33.7 MB US-Letter raster: 2550×3300
        // px × 4 B at 300 DPI) are released alongside the dpiCap /
        // parallelism drop. The pool re-grows lazily on subsequent checkOut.
        self.memoryWarningTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.didReceiveMemoryWarningNotification
            ) {
                self?.dpiCap = 150
                self?.parallelismOverride = 1
                self?.activeRasterizer?.flushBitmapPool()
            }
        }
    }

    deinit {
        memoryWarningTask?.cancel()
        // Defensive belt-and-suspenders: if RedactWorkspace.tearDown() did
        // not run (e.g., scene tear-down during a crash recovery), remove
        // the session subdirectory here. cleanOrphanedTempFiles() at next
        // launch handles whatever survives this.
        tempExportDirectory.tearDown()
    }

    /// Remove the per-session temp subdirectory and all child files.
    /// Called from `RedactWorkspace.tearDown()`. Idempotent; safe to call
    /// multiple times.
    func tearDownTempDirectory() {
        tempExportDirectory.tearDown()
    }

    // MARK: - Polygon bridge

    /// Weak back-pointer to the active `PDFViewCoordinator`,
    /// set from `PDFDocumentView.makeCoordinator` / `updateUIView` so
    /// SwiftUI buttons rooted at `PipelineCoordinator` can drive the
    /// polygon commit / cancel hooks that live on the UIKit-side
    /// coordinator. Weak: `PDFDocumentView`'s representable owns the
    /// PDFView coordinator's lifetime; we only borrow the reference
    /// for the duration of a user gesture.
    weak var pdfViewCoordinator: PDFViewCoordinator?

    /// Forwards to `PDFViewCoordinator.commitInProgressPolygon`,
    /// which locates the visible-page overlay and routes the in-progress
    /// vertex list through `commitPolygonRegion`. Silent no-op when no
    /// PDF view coordinator is bound (e.g., editor not mounted) or when
    /// the active overlay has fewer than 3 vertices.
    @MainActor
    func commitInProgressPolygon() {
        pdfViewCoordinator?.commitInProgressPolygon()
    }

    /// Forwards to `PDFViewCoordinator.cancelInProgressPolygon`,
    /// which discards the in-progress vertex list on the visible-page
    /// overlay. Silent no-op when no PDF view coordinator is bound.
    @MainActor
    func cancelInProgressPolygon() {
        pdfViewCoordinator?.cancelInProgressPolygon()
    }

    // MARK: - Full Pipeline

    /// Run the complete Redact → Verify → Results pipeline.
    /// Stores the Task in documentState.activePipelineTask for cancellation.
    func runFullPipeline(documentOverride: PipelineMode?) {
        // Defensive entry-point guard. Mirrors the
        // Redact button's `.disabled` predicate so a stray invocation
        // (programmatic call, KI-4 re-run handler firing after the
        // user already kicked off a pipeline) does not corrupt state.
        // Covers the existing `activePipelineTask == nil` check plus
        // the triage-sheet check and phase-must-be-`.editing` rule.
        guard documentState.canStartPipeline(with: redactionState) else { return }

        // Snapshot pipeline-affecting settings once at run
        // entry. Subsequent reads (verify-for-run, fillColor, exportDPI,
        // etc.) route through `runSettings` instead of `settingsState`
        // so a mid-run toggle in SettingsView cannot divert behavior.
        // Mirrors the `effectiveMode` snapshot below — same lifetime.
        let runSettings = RunSettings.snapshot(from: settingsState)

        // Paranoid-mode override #1: paranoid mode
        // forces `.secureRasterization` for the run regardless of the
        // per-document override or the user's `pipelineMode` setting.
        // Mechanism-description: the rasterization
        // route is designed to drop vector text and image layers from
        // redacted regions.
        let effectiveMode: PipelineMode
        if runSettings.paranoidMode {
            effectiveMode = .secureRasterization
        } else {
            effectiveMode = documentOverride ?? runSettings.pipelineMode
        }
        // nonisolated(unsafe): @Observable prevents Sendable; Task captures self
        // implicitly. Safe because all access is on MainActor (UndoManager pattern).
        nonisolated(unsafe) let coordinator = self
        // Stamp this run with a UUID owned by the Task.
        // The defer / error-recovery guards below only mutate state when
        // the active run still matches — so an older Task's late error
        // recovery cannot clear a newer run's outputURL / activePipelineTask.
        let runId = UUID()
        documentState.activeRunId = runId
        documentState.activePipelineTask = Task {
            defer {
                // Only clear the active task/run if this Task still
                // owns the active run. A newer Task started by the user (via
                // Stop → Redact) has already overwritten activeRunId; in that
                // case leave its state alone.
                if coordinator.documentState.activeRunId == runId {
                    coordinator.documentState.activePipelineTask = nil
                    coordinator.documentState.activeRunId = nil
                }
            }

            // Stage marker for the generic error handler below: false until
            // `processDocument` returns, so a non-PipelineError throw can be
            // attributed to the redaction stage vs. the verification stage.
            // The published `outputURL` cannot serve as that discriminator —
            // CANCEL-008 registers it eagerly, BEFORE `processDocument` runs.
            var redactionSucceeded = false
            do {
                coordinator.documentState.lastUsedPipelineMode = effectiveMode
                let pages = coordinator.buildPDFPageData(
                    effectiveMode: effectiveMode, runSettings: runSettings)
                let sensitiveTerms = coordinator.collectSensitiveTerms()

                // Capture the live search session's deselection
                // facts at run entry, before any pipeline work. The value is
                // recorded onto RedactionState only after `processDocument`
                // returns (beside `recordLastRunInputs`), but reading it HERE
                // pins the counts the user saw when they pressed Redact — a
                // programmatic or user re-selection during `.redacting` /
                // `.verifying` cannot drift what the results screen reports.
                // Nil when no PII-scan session is live (sheet closed tears
                // down `activeSearch`, discarding its selection state).
                let deselectionSnapshot =
                    coordinator.redactionState.activeSearch?
                        .deselectionSnapshotForRun()

                // Sub-threshold guard — no pages with effective redactions
                guard !pages.allSatisfy({ $0.regions.isEmpty }) else { return }

                // Route all session temp writes through the
                // backup-excluded per-session subdirectory. childURL throws
                // on directory-creation failure (e.g., disk full); the
                // outer error path wraps unknown throws as .redactionError.
                let outputURL = try coordinator.tempExportDirectory.childURL(
                    named: "redacted_\(UUID().uuidString).pdf")

                // CANCEL-008 — register `outputURL` on `redactionState` BEFORE
                // the `processDocument` → `replaceItemAt` race window. If the
                // pipeline throws (cancellation, reconstruction failure) after
                // `replaceItemAt` has already promoted the file but before this
                // closure completes, the error-recovery blocks below call
                // `clearOutput()`, which reads the published `outputURL` and
                // removes the file from disk. Setting the URL eagerly closes
                // the leak where a post-rename failure would otherwise orphan
                // the file in the per-session temp subdirectory until
                // tear-down.
                //
                // Orphan hygiene: if a previous run's output is still
                // registered, clear it (which also removes its file from
                // disk) before registering this run's URL — a bare
                // re-assignment would overwrite the published URL and orphan
                // the prior file until the next-launch sweep.
                if coordinator.redactionState.outputURL != nil {
                    coordinator.redactionState.clearOutput()
                }
                coordinator.redactionState.outputURL = outputURL

                // --- Rasterization + Reconstruction ---
                coordinator.documentState.transition(to: .redacting(
                    progress: .init(currentPage: 0, totalPages: pages.count,
                                    currentStep: "Starting\u{2026}")
                ))

                let runContext = try await coordinator.processDocument(
                    pages, effectiveMode: effectiveMode, outputURL: outputURL,
                    sensitiveTerms: sensitiveTerms)
                redactionSucceeded = true

                // Re-apply `.complete` to the promoted output URL.
                // `replaceItemAt` rewrites the protection class of the
                // destination, so the engine-side `.complete` on the temp
                // file does not survive the rename. Best-effort: errors are
                // non-fatal — a failure here leaves the file at the
                // filesystem default, which is no worse than the prior
                // contract.
                try? TempFileHardening.applyProtection(outputURL, level: .complete)

                // CANCEL-008 — `outputURL` was already registered above. The
                // explicit re-assignment here is intentional: if a redactionState
                // mutation occurred between the eager register and `processDocument`
                // returning, we restore the canonical published value. Idempotent.
                coordinator.redactionState.outputURL = outputURL
                coordinator.redactionState.clearTextExtractionBuffer()
                // Retain the run's verification inputs beside the output so
                // a verify-only re-run (CANCEL-009) checks the terms the
                // artifact was built with and reports the true per-page
                // modes, instead of re-synthesizing both (see
                // RedactionState.lastRunPerPageModes).
                coordinator.redactionState.recordLastRunInputs(
                    perPageModes: runContext.perPageModes,
                    perPageFallbackReasons: runContext.perPageFallbackReasons,
                    sensitiveTerms: runContext.sensitiveTerms)
                // Record the run-entry deselection snapshot beside the run
                // inputs (nil clears a previous run's record). Cleared with
                // the output in `clearOutput()`.
                coordinator.redactionState.recordLastRunDeselection(
                    deselectionSnapshot)

                // --- Verification ---
                // Paranoid-mode override #2: paranoid
                // mode forces verification to run on every export. The
                // settings toggle is also UI-disabled while paranoid is on
                // (see SettingsView), so this branch is the runtime
                // counterpart of that constraint.
                //
                // Read from the run-entry snapshot so a mid-run
                // SettingsView toggle of `autoVerify` cannot divert the
                // verify-or-skip decision after the run is already in flight.
                let verifyForRun =
                    runSettings.paranoidMode
                    || runSettings.autoVerify
                if verifyForRun {
                    try await coordinator.runVerification(
                        runContext: runContext, effectiveMode: effectiveMode)
                } else {
                    coordinator.documentState.transition(to: .verified(report: .skipped))
                    coordinator.redactionState.markVerificationCurrent()
                }

            } catch is CancellationError { // LegalPhrases:safe (Swift keyword)
                // Only mutate cancellation state if this
                // Task still owns the active run. After Stop → restart, the
                // older Task's CancellationError must NOT clear the newer
                // run's outputURL or override its phase transition.
                //
                // Hop to the MainActor before touching
                // @Observable state. A thrown CancellationError can resume this
                // handler OFF the MainActor (a Task.detached intermediate breaks
                // the actor-inheritance chain — see the general-error handler
                // sibling's real-doc crash backtrace in runDetectionPipeline). The
                // run-ownership guard moves inside the hop so it, too, reads
                // MainActor state on the MainActor. `MainActor.assertIsolated()`
                // is the canary — a CI trap if the hop is ever removed.
                // Transition table unchanged (threading context only).
                await MainActor.run {
                    MainActor.assertIsolated()
                    guard coordinator.documentState.activeRunId == runId else { return }
                    // cancelActivePipeline() already handled cleanup and transition.
                    if coordinator.documentState.phaseKind != .editing
                        && coordinator.documentState.phaseKind != .verified {
                        coordinator.redactionState.clearOutput()
                        coordinator.documentState.transition(to: .editing)
                    }
                }
            } catch { // LegalPhrases:safe (Swift keyword)
                // Same UUID guard as the cancellation path —
                // a late recovery from a superseded run must not stomp the
                // newer run's state.
                guard coordinator.documentState.activeRunId == runId else { return }
                // Classify by the FAILING STAGE, not by outputURL presence.
                // CANCEL-008 registers `outputURL` eagerly (before
                // `processDocument`), so a non-nil URL no longer means
                // "redaction succeeded" — every throw after run start sees it
                // set. A redaction/import-stage error means the output was
                // never promoted (`replaceItemAt` never ran); discard the
                // dangling registration and return to the editor. A
                // verification-stage error leaves a valid promoted output;
                // keep it and return to the skipped-report screen.
                let stage = Self.classifyPipelineFailure(
                    error, redactionSucceeded: redactionSucceeded)
                if stage == .verification {
                    // Verification crashed, but redacted output is VALID.
                    coordinator.documentState.transition(to: .failed(
                        error: error as? PipelineError
                            ?? .verificationError(.engineCrash(layerIndex: 0)),
                        returnPhase: .verified(report: .skipped(reason: .error))
                    ))
                } else {
                    // Redaction failed — discard partial output
                    coordinator.redactionState.clearOutput()
                    coordinator.documentState.transition(to: .failed(
                        error: error as? PipelineError
                            ?? .redactionError(.reconstructionFailed),
                        returnPhase: .editing
                    ))
                }
            }
        }
    }

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
    /// `redactionState.outputURL` deliberately plays no part: CANCEL-008
    /// registers it eagerly, before `processDocument` runs, so it is
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

    // MARK: - Verify-Only Re-Run (CANCEL-009)

    /// Re-run verification against the existing `outputURL` without
    /// re-rasterizing. Used by the background-resume banner when the
    /// previously-redacted document is still valid (i.e., no region
    /// modifications since the interrupted verify). Per-page rasterize
    /// artifacts (`filterDigests`) cannot be reconstructed from the output
    /// PDF alone, so the layers that consume them (Layers 7 and 9 — the
    /// character-count and character-lineage cross-checks; Layer 8 is font
    /// verification and needs no digest) report `.skipped` rather than a
    /// silent `.pass`, and the overall verdict degrades to WARN
    /// rather than re-running the rasterize pipeline.
    func runVerifyOnly() {
        guard documentState.activePipelineTask == nil else { return }
        guard let outputURL = redactionState.outputURL else { return }

        let effectiveMode = documentState.lastUsedPipelineMode
            ?? (settingsState.paranoidMode
                ? .secureRasterization
                : settingsState.pipelineMode)

        // Drive the phase to .verifying up front so any downstream failure
        // path inside runVerification (e.g., PDFDocument load crash before
        // the first per-layer transition) lands on the legal
        // .verifying → .failed pair instead of the not-listed
        // .verified → .failed pair (see DocumentState.legalTransitions).
        // The initial layer count is taken from the verifier so the
        // progress UI shows the correct total from frame 0.
        let verifier = VerificationEngine()
        let totalLayers = verifier.layerCount(for: effectiveMode)
        documentState.transition(to: .verifying(
            progress: .init(
                currentLayer: 1,
                totalLayers: totalLayers,
                layerName: verifier.layerName(at: 0),
                completedLayers: []
            )
        ))

        // nonisolated(unsafe): @Observable prevents Sendable; Task captures self
        // implicitly. Safe because all access is on MainActor (same pattern as runFullPipeline).
        nonisolated(unsafe) let coordinator = self
        // Stamp this verify-only run with a UUID
        // owned by the Task, exactly as runFullPipeline / runDetectionPipeline
        // do. Without the stamp the defer below was unconditional and could
        // nil a SUCCESSOR run's activePipelineTask after a cancel → restart
        // (the older verify Task's late defer firing over the new run).
        let runId = UUID()
        documentState.activeRunId = runId
        documentState.activePipelineTask = Task {
            defer {
                // Only clear the active task/run if this Task still
                // owns the active run — a newer run (Stop → Redact) has
                // overwritten activeRunId and must be left intact.
                if coordinator.documentState.activeRunId == runId {
                    coordinator.documentState.activePipelineTask = nil
                    coordinator.documentState.activeRunId = nil
                }
            }

            do {
                // Prefer the retained inputs of the run that produced the
                // output (recorded beside `outputURL` when `processDocument`
                // returned): the terms snapshot keeps the re-verify checking
                // what the artifact was built with even if regions changed
                // since, and the retained mode array preserves a mixed run's
                // per-page fallback record in the report. Fall back to
                // re-synthesis when absent (resumed old session).
                let sensitiveTerms = coordinator.redactionState.lastRunSensitiveTerms
                    ?? coordinator.collectSensitiveTerms()
                let pageCount = coordinator.documentState.pageCount
                // Per-page rasterize artifacts are not available on this
                // path; sandwich layers detect missing entries and skip.
                // Digests stay all-nil even with retained inputs — they
                // cannot be rebuilt from the output PDF, by design.
                let filterDigests: [PageFilterDigest?] = Array(
                    repeating: nil, count: pageCount)
                let perPageModes: [PipelineMode] = coordinator.redactionState
                    .lastRunPerPageModes
                    ?? Array(repeating: effectiveMode, count: pageCount)
                // PD-5: same retention contract as the mode array — the
                // retained reasons preserve a mixed run's fallback record on
                // re-verify; the all-nil synthesis matches the digest
                // fallback (per-page rasterize artifacts are unavailable).
                let perPageFallbackReasons: [TextLayerDetector.FallbackReason?] =
                    coordinator.redactionState.lastRunPerPageFallbackReasons
                    ?? Array(repeating: nil, count: pageCount)

                let runContext = PipelineRunContext(
                    outputURL: outputURL,
                    filterDigests: filterDigests,
                    perPageModes: perPageModes,
                    perPageFallbackReasons: perPageFallbackReasons,
                    sensitiveTerms: sensitiveTerms
                )

                try await coordinator.runVerification(
                    runContext: runContext, effectiveMode: effectiveMode)
            } catch is CancellationError { // LegalPhrases:safe (Swift keyword)
                // cancelActivePipeline() already drove the transition.
                //
                // MainActor hop — see the runFullPipeline
                // CancellationError handler for the off-main-resume rationale.
                // `MainActor.assertIsolated()` is the canary. Transition
                // table unchanged (threading context only).
                await MainActor.run {
                    MainActor.assertIsolated()
                    // A superseded run must not drive a
                    // transition over a newer run's state.
                    guard coordinator.documentState.activeRunId == runId else { return }
                    if coordinator.documentState.phaseKind != .editing
                        && coordinator.documentState.phaseKind != .verified {
                        coordinator.documentState.transition(
                            to: .verified(report: .skipped(reason: .cancelled)))
                    }
                }
            } catch { // LegalPhrases:safe (Swift keyword)
                // Same UUID guard as the cancellation
                // path — a late recovery from a superseded run must not
                // stomp the newer run's state.
                guard coordinator.documentState.activeRunId == runId else { return }
                // Re-verify crashed, but the redacted
                // output remains valid. Surface as a failure that returns
                // the user to the skipped state (matching runFullPipeline).
                coordinator.documentState.transition(to: .failed(
                    error: error as? PipelineError
                        ?? .verificationError(.engineCrash(layerIndex: 0)),
                    returnPhase: .verified(report: .skipped(reason: .error))
                ))
            }
        }
    }

    // MARK: - Rasterization + Reconstruction

    /// Process all pages: rasterize → fill → reconstruct PDF.
    /// Returns a PipelineRunContext with per-page digests and modes for verification.
    /// Reports progress via documentState self-transitions.
    private func processDocument(
        _ pages: [PDFPageData],
        effectiveMode: PipelineMode,
        outputURL: URL,
        sensitiveTerms: [SensitiveTerm]
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
        try await rasterizePagesInParallel(pages: pages, rasterizer: rasterizer) { idx, result in
            // Appended in 0..<count callback order — identical inputs/order to
            // the old second pass, so the Layer-7 digest cross-check and
            // per-page mode bookkeeping are unchanged.
            filterDigests.append(result.filterDigest)
            perPageModes.append(
                result.filterDigest != nil ? .searchableRedaction : .secureRasterization
            )
            // PD-5: collected beside the mode so the two arrays stay
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

        // Atomic rename: same APFS volume (both in temporaryDirectory)
        _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tempURL)

        return PipelineRunContext(
            outputURL: outputURL,
            filterDigests: filterDigests,
            perPageModes: perPageModes,
            perPageFallbackReasons: perPageFallbackReasons,
            sensitiveTerms: sensitiveTerms
        )
    }

    // MARK: - Per-Page Retry

    /// Per-page DPI floor for the verification-retry fallback. Tuned to keep
    /// the second-attempt buffer small enough to fit under typical memory
    /// pressure while leaving enough resolution for Vision-level pixel
    /// verification. Locked at 96.
    // nonisolated: read by the `nonisolated rasterizeWithRetry` parallel TaskGroup body
    // (a @Sendable closure). A plain Int constant — opted out of the SE-0466
    // MainActor default so the off-actor retry path can read it directly.
    nonisolated static let retryDPIFloor: Int = 96

    /// Rasterize a single page; on `fillVerificationFailed`,
    /// re-rasterize once at `max(retryDPIFloor, primaryDPICap / 2)`. A second
    /// failure propagates the original error type so the caller surfaces the
    /// page index unchanged.
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
            let retryDPICap = max(Self.retryDPIFloor, primaryDPICap / 2)
            // At most one retry. A second failure throws the same error type
            // (carrying the page index) up the stack.
            return try await rasterizer.rasterize(page, dpiCap: retryDPICap)
        }
    }

    // MARK: - Page-Parallel Rasterization

    /// Submit per-page rasterize work into a bounded `withThrowingTaskGroup`
    /// and STREAM each result to `onPageReady` as soon as it is next-in-order.
    /// Out-of-order completions buffer in `pending`; a
    /// residency gate (`inFlight + pending.count < bound * 2`) back-pressures
    /// new submissions so peak full-res CGImage residency is page-count-
    /// INDEPENDENT (supersedes the collect-then-drain mechanism; the
    /// 0..<count append-ORDER invariant is preserved by construction — the
    /// in-order drain only fires `onPageReady` for the contiguous next index,
    /// and the reconstructor's state model is order-sensitive, locked
    /// decision).
    ///
    /// Memory: the honest live-image bound is ≈ `(3·inFlight + pending + 1)`
    /// pagefuls + ≤4 pool buffers ≈ `(4·bound + 5)` pagefuls — each running
    /// task holds ~3 pagefuls of its own (render context + renderedImage +
    /// pooled fill context + redactedImage; see `PageRasterizer`). The DEBUG
    /// `maxResidentResults` counter (`inFlight + pending.count + 1`) is an
    /// accounting bound on completed-result residency, NOT this full census.
    /// Liveness rests on the L-19 10,000-pt pre-flight + finiteness of
    /// `drawPDFPage` (NOT the 30 s render timeout — it cannot interrupt the
    /// uninterruptible render child; see PageRasterizer L-19 comments).
    ///
    /// Each parallel task wraps the rasterize call in
    /// `rasterizeWithRetry`, so the per-page half-DPI retry on
    /// `fillVerificationFailed` happens inside the task — preserving the
    /// per-page retry semantics under parallel execution.
    ///
    /// Concurrency bound: `max(1, min(cores - 1, dynamicMemoryBudgetPages))`
    /// where `dynamicMemoryBudgetPages` is recomputed each loop iteration
    /// from `os_proc_available_memory()` (so the bound shrinks under
    /// pressure even before a `didReceiveMemoryWarningNotification` fires).
    /// `parallelismOverride == 1` (set on memory warning) collapses to
    /// sequential behavior until workspace teardown (CANCEL-010).
    ///
    /// Progress UI is updated as each task COMPLETES (`currentPage` reflects
    /// the count of finished pages, not the most recently scheduled one) —
    /// this keeps progress monotonic under out-of-order completion.
    ///
    /// `internal` access (rather than `private`) so the page-parallel test suite
    /// can exercise the parallel orchestration without driving the full
    /// reconstructor / verify pipeline end-to-end.
    func rasterizePagesInParallel(
        pages: [PDFPageData], rasterizer: PageRasterizer,
        onPageReady: @MainActor (Int, RasterizeResult) async throws -> Void
    ) async throws {
        guard !pages.isEmpty else { return }

        // The DPI cap is read FRESH per submission (see the
        // `let cap = dpiCap` captures and the `computeParallelismBound` calls
        // below), NOT snapshotted once per run. `rasterizePagesInParallel` is
        // @MainActor, so a read between `await` suspension points observes the
        // latest value written by the memory-warning handler (which lowers
        // `dpiCap` to 150). A stale run-level snapshot would pin every page to
        // the pre-warning cap, defeating the mid-run memory response.

        var pending: [Int: RasterizeResult] = [:]
        var nextAppendIndex = 0
        var nextSubmitIndex = 0
        var inFlight = 0
        var completed = 0
        let totalPages = pages.count

        #if DEBUG
        maxResidentResults = 0
        #endif

        try await withThrowingTaskGroup(of: (Int, RasterizeResult).self) { group in
            // Prime the group up to the initial bound. Bound is recomputed
            // before every submission so it can shrink under live memory
            // pressure (and after a memory warning collapses it to 1).
            while nextSubmitIndex < totalPages {
                let bound = computeParallelismBound(
                    remainingPages: pages[nextSubmitIndex...], dpiCap: dpiCap
                )
                // Residency gate: block new submissions when the
                // completed-but-unappended buffer would reach 2× the bound, so
                // out-of-order completions can't accumulate N full-res
                // CGImages. `pending` is empty in the prime loop, so this
                // reduces to `inFlight < bound` here.
                let residentCap = bound * 2
                guard inFlight < bound && inFlight + pending.count < residentCap else { break }
                let page = pages[nextSubmitIndex]
                let idx = nextSubmitIndex
                // Capture the live cap per submission (read on the
                // MainActor) so a mid-run memory warning lowers DPI for this
                // page too. The captured `Int` is sendable into the child task.
                let cap = dpiCap
                group.addTask { [self] in
                    let result = try await self.rasterizeWithRetry(
                        page, rasterizer: rasterizer, primaryDPICap: cap)
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

                #if DEBUG
                // Sample the residency accounting bound IMMEDIATELY after the
                // store, BEFORE the in-order drain, to capture the peak.
                // Accounting bound on completed-result
                // residency, not a live-CGImage census — see
                // `maxResidentResults`.
                maxResidentResults = max(maxResidentResults, inFlight + pending.count + 1)
                #endif

                // Progress reflects completed pages. Out-of-order completion
                // is fine: `currentPage` is monotonic even though `idx` may
                // skip around. The currentStep label uses `completed` so it
                // does not advertise a specific page index that may already
                // be past tense by the time the UI repaints.
                documentState.transition(to: .redacting(
                    progress: .init(
                        currentPage: completed,
                        totalPages: totalPages,
                        currentStep: "Processing \(completed) of \(totalPages)\u{2026}"
                    )
                ))

                // Surface cancellation BETWEEN submissions. The group itself
                // already propagates cancellation into in-flight child tasks
                // via structured concurrency; this check lets us bail out
                // of the loop without scheduling more work.
                try Task.checkCancellation()

                // In-order drain: hand every now-contiguous page to
                // `onPageReady` and release its full-res CGImage at the end of
                // each iteration. `pending` retains only out-of-order
                // completions. Do NOT swallow an `onPageReady` error and
                // continue the drain: a suppressed throw here is a silent page
                // drop the post-group guard cannot distinguish from success.
                while let next = pending.removeValue(forKey: nextAppendIndex) {
                    try await onPageReady(nextAppendIndex, next)
                    nextAppendIndex += 1
                }

                // Refill: submit as many new producers as the (current) bound
                // permits. The bound may have dropped to 1 if a memory
                // warning fired between iterations.
                while nextSubmitIndex < totalPages {
                    let bound = computeParallelismBound(
                        remainingPages: pages[nextSubmitIndex...],
                        dpiCap: dpiCap
                    )
                    let residentCap = bound * 2
                    guard inFlight < bound && inFlight + pending.count < residentCap else { break }
                    let page = pages[nextSubmitIndex]
                    let nextIdx = nextSubmitIndex
                    // Per-submission live cap (see prime loop). Pages
                    // submitted after a mid-run warning rasterize at the lowered
                    // cap; in-flight pages plus at most one submission burst at
                    // the pre-warning bound remain at the old cap (the one-page
                    // figure holds only under parallelismOverride == 1).
                    let cap = dpiCap
                    group.addTask { [self] in
                        let r = try await self.rasterizeWithRetry(
                            page, rasterizer: rasterizer, primaryDPICap: cap)
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

    /// Compute the active rasterization parallelism bound. Locked formula:
    ///
    ///     max(1, min(cores - 1, dynamicMemoryBudgetPages))
    ///
    /// where `dynamicMemoryBudgetPages = available / per-page-bytes`. The
    /// per-page byte estimate is the worst-case bitmap footprint for the
    /// next page about to be submitted, multiplied by 3 to cover the pagefuls
    /// `PageRasterizer.rasterize` can hold concurrently — the render context,
    /// the pooled fill context, and the JPEG-encode buffer (corrected
    /// from 2× to a conservative 3×; intentionally tighter than `selectDPI`'s
    /// 2× factor, which counts only render + fill). `parallelismOverride`
    /// (set to 1 on `didReceiveMemoryWarningNotification`) clamps the result
    /// to 1 until workspace teardown (CANCEL-010).
    ///
    /// `internal` rather than `private` so the dedicated page-parallel test suite
    /// can assert the bound math directly without driving the full pipeline.
    func computeParallelismBound(
        remainingPages: ArraySlice<PDFPageData>, dpiCap: Int
    ) -> Int {
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        let memoryPages = dynamicMemoryBudgetPages(
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
    private func dynamicMemoryBudgetPages(
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

    // MARK: - Verification

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
        var docs: [Int: SendablePDFDocument] = [:]
        docs.reserveCapacity(layers.count)
        for layer in layers {
            guard let doc = PDFDocument(url: url) else { return nil }
            docs[layer] = SendablePDFDocument(doc)
        }
        return docs
    }

    /// Seam: run the parallel base-layer batch and return the
    /// `(layerIndex, LayerResult)` pairs in completion order. Extracted from
    /// `runVerification` so a guard test can drive the fan-out directly and
    /// assert each parallel layer receives its own `PDFDocument` instance
    /// (mirrors the deliberate `internal` precedent of `rasterizePagesInParallel`).
    /// `runVerification` keeps the `.verifying` transitions, result ordering,
    /// accessibility announcements, and the deferred-Layer-10 handling.
    ///
    /// `nonisolated`: the per-layer document provisioning (added below) is
    /// CPU-bound on large outputs and runs off MainActor; the layer fan-out is
    /// `@concurrent`. All parameters are `Sendable` value types.
    nonisolated func collectParallelBaseLayerResults(
        layers: [Int],
        outputURL: URL,
        shared: SendablePDFDocument,
        verifier: VerificationEngine,
        sourcePageCount: Int,
        regions: [Int: [RedactionRegion]],
        sensitiveTerms: [SensitiveTerm],
        pipelineMode: PipelineMode,
        filterDigests: [PageFilterDigest?],
        perPageModes: [PipelineMode]
    ) async throws -> [(Int, LayerResult)] {
        // Provision one PDFDocument instance per parallel layer off
        // MainActor. nil ⇒ at least one re-open failed.
        let perLayerDocs: [Int: SendablePDFDocument]? = await Task.detached {
            Self.loadParallelLayerDocuments(outputURL, layers: layers)
        }.value

        guard let perLayerDocs else {
            // Provisioning failed (e.g. the output file was purged mid-run):
            // run the same layers SEQUENTIALLY on the shared instance —
            // sequential access on one document is the sound original contract
            // (PDFPageData.swift). Never concurrent-shared. Debug-only
            // diagnostic; no Phase change, no PipelineError, no user string.
            #if DEBUG
            Logger(subsystem: "com.resecta.app", category: "verification").debug(
                "CAT-363: per-layer verification document provisioning failed; running base layers sequentially on the shared document"
            )
            #endif
            var collected: [(Int, LayerResult)] = []
            for layerIndex in layers {
                let result = await verifier.runLayer(
                    layerIndex,
                    outputDocument: shared,
                    sourcePageCount: sourcePageCount,
                    regions: regions,
                    sensitiveTerms: sensitiveTerms,
                    pipelineMode: pipelineMode,
                    filterDigests: filterDigests,
                    perPageModes: perPageModes
                )
                collected.append((layerIndex, result))
            }
            return collected
        }

        return try await withThrowingTaskGroup(of: (Int, LayerResult).self) { group in
            for layerIndex in layers {
                // Each parallel layer runs against its own instance; `shared`
                // is only a defensive fallback for an absent map entry (the
                // map is complete whenever provisioning succeeded).
                let layerDoc = perLayerDocs[layerIndex] ?? shared
                group.addTask {
                    let result = await verifier.runLayer(
                        layerIndex,
                        outputDocument: layerDoc,
                        sourcePageCount: sourcePageCount,
                        regions: regions,
                        sensitiveTerms: sensitiveTerms,
                        pipelineMode: pipelineMode,
                        filterDigests: filterDigests,
                        perPageModes: perPageModes
                    )
                    return (layerIndex, result)
                }
            }
            var collected: [(Int, LayerResult)] = []
            for try await pair in group {
                collected.append(pair)
            }
            return collected
        }
    }

    /// Run all verification layers and transition to .verified.
    private func runVerification(
        runContext: PipelineRunContext, effectiveMode: PipelineMode
    ) async throws {
        // `PDFDocument(url:)` is CPU-bound on large outputs; routing
        // through `Task.detached` keeps the MainActor-isolated
        // `runVerification` body free to drive the progress UI.
        let wrappedDoc: SendablePDFDocument
        do {
            wrappedDoc = try await Task.detached {
                try Self.loadOutputDocumentOffMainActor(runContext.outputURL)
            }.value
        } catch { // LegalPhrases:safe (Swift keyword)
            documentState.transition(to: .failed(
                error: .verificationError(.engineCrash(layerIndex: 0)),
                returnPhase: .verified(report: .skipped(reason: .error))
            ))
            return
        }

        // Page-count integrity gate,
        // run BEFORE any layer. The redacted output must carry exactly one page
        // per source page; a mismatch means reconstruction dropped or
        // duplicated a page — possibly in a previous process on the verify-only
        // resume path, where the in-process writtenPageCount postcondition
        // (part 1) cannot help. Surface one explicit FAIL layer and return,
        // rather than verifying a truncated document and reporting a misleading
        // PASS/WARN. Page counts only — never document content.
        // Both source phases here, (.redacting,.verified) and
        // (.verifying,.verified), are legal transitions (no table change).
        let expectedPageCount = documentState.pageCount
        let outputPageCount = wrappedDoc.document.pageCount
        if expectedPageCount != outputPageCount {
            let failLayer = LayerResult(
                name: "Page Count Check",
                symbolName: "exclamationmark.triangle",
                status: .fail("Output has \(outputPageCount) \(outputPageCount == 1 ? "page" : "pages"); source has \(expectedPageCount)."),
                shortDescription: "Output page count does not match the source document.",
                detailDescription: "The redacted output has \(outputPageCount) \(outputPageCount == 1 ? "page" : "pages") but the source document has \(expectedPageCount). Verification stopped before the layer checks because the page counts must match.",
                pageReferences: nil,
                durationSeconds: 0
            )
            let report = VerificationReport(
                layers: [failLayer],
                overallStatus: .fail("Output page count does not match the source document."),
                durationSeconds: 0,
                perPageModes: runContext.perPageModes,
                perPageFallbackReasons: runContext.perPageFallbackReasons
            )
            documentState.transition(to: .verified(report: report))
            redactionState.markVerificationCurrent()
            let overallAnnouncement = "Verification complete. \(report.overallStatus.accessibilityLabel)"
            await MainActor.run {
                UIAccessibility.post(notification: .announcement, argument: overallAnnouncement)
            }
            return
        }

        let verifier = VerificationEngine()
        // Layer count is mode-dependent, NEVER hardcoded
        let globalLayerCount = verifier.layerCount(for: effectiveMode)
        var completedLayers: [LayerResult] = []
        // Result for Layer 10 (Operator Re-Extraction),
        // dispatched in the parallel base batch but held back until the
        // sandwich loop finishes so completedLayers stays layer-index-
        // ascending. Nil in modes whose layerCount is < 10.
        var deferredLayer10Result: LayerResult? = nil
        let startTime = CFAbsoluteTimeGetCurrent()

        let sourcePageCount = documentState.pageCount

        // Base layers 0/1/2 (Text Extraction, OCR, Binary Search) run
        // in parallel via withTaskGroup — independent reads against the output
        // document with no shared mutable state. Layers 3, 4 (Structure,
        // Metadata) run sequentially after because both parse the
        // `PDFDocument` catalog; concurrent CGPDFDictionary traversal would
        // contend on the same catalog handle. Sandwich layers 5–8 also run
        // sequentially — the inter-layer character-count baseline (Layer 7)
        // depends on Layer 6's extraction work and must remain ordered.
        //
        // Searchable Layer 10 (operator
        // re-extraction, index 9) joins the base-parallel batch when the
        // mode's layer count reaches 10. The layer walks each output page's
        // content stream via `CGPDFContentStream` (a fresh stream object per
        // page), so it has no catalog-handle contention with layers 0/1/2
        // and no sequencing dependency on the sandwich-sequential layers
        // (5–8). Its result is held back from `completedLayers` until the
        // sandwich loop finishes so the slot-indexed layer list stays
        // layer-index-ascending for downstream consumers (Views iterate via
        // `report.layers.enumerated()` and label rows by ordinal position).
        let parallelBaseLayers: [Int]
        let sandwichLayers: [Int]
        let sequentialBaseLayers = Array(3..<min(5, globalLayerCount))
        if globalLayerCount >= 10 {
            parallelBaseLayers = [0, 1, 2, 9]
            sandwichLayers = Array(5..<9)
        } else if globalLayerCount > 5 {
            parallelBaseLayers = Array(0..<min(3, globalLayerCount))
            sandwichLayers = Array(5..<globalLayerCount)
        } else {
            parallelBaseLayers = Array(0..<min(3, globalLayerCount))
            sandwichLayers = []
        }

        // Snapshot MainActor-isolated inputs once so the @concurrent
        // runLayer calls inside withTaskGroup do not re-cross the actor
        // boundary on every fan-out.
        let regionsSnapshot = redactionState.regions
        let sensitiveTermsSnapshot = runContext.sensitiveTerms
        let filterDigestsSnapshot = runContext.filterDigests
        let perPageModesSnapshot = runContext.perPageModes

        // --- Base layers 0/1/2: parallel batch ---
        if let firstLayer = parallelBaseLayers.first {
            try Task.checkCancellation()
            // Surface the first parallel-batch layer in the progress UI.
            // The transition before the parallel dispatch keeps the
            // progress indicator continuous; per-layer announcements still
            // fire as each layer completes below.
            documentState.transition(to: .verifying(
                progress: .init(
                    currentLayer: firstLayer + 1,
                    totalLayers: globalLayerCount,
                    layerName: verifier.layerName(at: firstLayer),
                    completedLayers: completedLayers
                )
            ))

            let parallelResults = try await collectParallelBaseLayerResults(
                layers: parallelBaseLayers,
                outputURL: runContext.outputURL,
                shared: wrappedDoc,
                verifier: verifier,
                sourcePageCount: sourcePageCount,
                regions: regionsSnapshot,
                sensitiveTerms: sensitiveTermsSnapshot,
                pipelineMode: effectiveMode,
                filterDigests: filterDigestsSnapshot,
                perPageModes: perPageModesSnapshot
            )

            // Restore canonical (layer-index ascending) order so
            // `completedLayers` matches the historical sequential contract
            // — downstream consumers index by layer slot.
            let orderedParallel = parallelResults.sorted { $0.0 < $1.0 }
            for (layerIndex, result) in orderedParallel {
                if layerIndex == 9 {
                    // Layer 10 dispatched in the
                    // base-parallel batch for wall-clock reasons; appended
                    // after the sandwich loop so completedLayers stays
                    // layer-index-ascending.
                    deferredLayer10Result = result
                    continue
                }
                completedLayers.append(result)
                let layerAnnouncement = result.completionAnnouncement(layerNumber: layerIndex + 1)
                await MainActor.run {
                    UIAccessibility.post(notification: .announcement, argument: layerAnnouncement)
                }
            }
        }

        // --- Base layers 3, 4: sequential (shared CGPDFDocument catalog) ---
        for layerIndex in sequentialBaseLayers {
            try Task.checkCancellation()
            documentState.transition(to: .verifying(
                progress: .init(
                    currentLayer: layerIndex + 1,
                    totalLayers: globalLayerCount,
                    layerName: verifier.layerName(at: layerIndex),
                    completedLayers: completedLayers
                )
            ))

            let result = await verifier.runLayer(
                layerIndex,
                outputDocument: wrappedDoc,
                sourcePageCount: sourcePageCount,
                regions: regionsSnapshot,
                sensitiveTerms: sensitiveTermsSnapshot,
                pipelineMode: effectiveMode,
                filterDigests: filterDigestsSnapshot,
                perPageModes: perPageModesSnapshot
            )
            completedLayers.append(result)

            let layerAnnouncement = result.completionAnnouncement(layerNumber: layerIndex + 1)
            await MainActor.run {
                UIAccessibility.post(notification: .announcement, argument: layerAnnouncement)
            }
        }

        // --- Sandwich layers 5–8: sequential (inter-layer baselines) ---
        for layerIndex in sandwichLayers {
            try Task.checkCancellation()
            documentState.transition(to: .verifying(
                progress: .init(
                    currentLayer: layerIndex + 1,
                    totalLayers: globalLayerCount,
                    layerName: verifier.layerName(at: layerIndex),
                    completedLayers: completedLayers
                )
            ))

            let result = await verifier.runLayer(
                layerIndex,
                outputDocument: wrappedDoc,
                sourcePageCount: sourcePageCount,
                regions: regionsSnapshot,
                sensitiveTerms: sensitiveTermsSnapshot,
                pipelineMode: effectiveMode,
                filterDigests: filterDigestsSnapshot,
                perPageModes: perPageModesSnapshot
            )
            completedLayers.append(result)

            let layerAnnouncement = result.completionAnnouncement(layerNumber: layerIndex + 1)
            await MainActor.run {
                UIAccessibility.post(notification: .announcement, argument: layerAnnouncement)
            }
        }

        // --- Layer 10 (parallel base, deferred-append) ---
        // The result was computed in the parallel batch; appending here
        // keeps completedLayers layer-index-ascending so the slot-indexed
        // UI display (`report.layers.enumerated()`) labels each row by its
        // canonical layer ordinal.
        if let l10 = deferredLayer10Result {
            completedLayers.append(l10)
            let layerAnnouncement = l10.completionAnnouncement(layerNumber: 10)
            await MainActor.run {
                UIAccessibility.post(notification: .announcement, argument: layerAnnouncement)
            }
        }

        // Final cancellation checkpoint before
        // the report is constructed. A cancel landing after the last in-loop
        // checkpoint — once a layer has folded its CancellationError into a
        // .skipped result — could otherwise still build a .verified report with
        // a skipped layer. The throw propagates to the same CancellationError
        // handler as the in-loop checkpoints above; no new error handling.
        try Task.checkCancellation()

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let report = VerificationReport(
            layers: completedLayers,
            overallStatus: verifier.aggregateStatus(completedLayers),
            durationSeconds: elapsed,
            perPageModes: runContext.perPageModes,
            perPageFallbackReasons: runContext.perPageFallbackReasons
        )
        documentState.transition(to: .verified(report: report))
        redactionState.markVerificationCurrent()

        // VoiceOver overall announcement
        let overallAnnouncement = "Verification complete. \(report.overallStatus.accessibilityLabel)"
        await MainActor.run {
            UIAccessibility.post(notification: .announcement, argument: overallAnnouncement)
        }
    }

    // MARK: - Detection Pipeline

    /// Run PII and face detection across all pages.
    /// Adds DetectionOrchestrator and triage support.
    func runDetectionPipeline(recognitionLevel: VNRequestTextRecognitionLevel = .fast) {
        guard documentState.activePipelineTask == nil else { return }
        guard redactionState.pendingTriage == nil else { return }  // Block while triaging

        // Record the recognition level so an editing-phase
        // background-resume banner can re-run detection at the SAME level the
        // user originally chose (fallback .accurate when nil at resume time).
        documentState.lastUsedRecognitionLevel = recognitionLevel

        // Snapshot pipeline-affecting settings once at run entry.
        // With the auto-apply branch retired (every detection run now
        // stages for triage review unconditionally), the detection
        // path's only remaining snapshot reader is `buildOCRSkipHint`
        // (pipelineMode). Mirrors `effectiveMode`.
        let runSettings = RunSettings.snapshot(from: settingsState)

        // nonisolated(unsafe): @Observable prevents Sendable; Task captures self
        // implicitly. Safe because all access is on MainActor (same pattern as runFullPipeline).
        nonisolated(unsafe) let coordinator = self
        // Stamp this run with a UUID owned by the Task.
        // See runFullPipeline for the rationale; same pattern applies here.
        let runId = UUID()
        documentState.activeRunId = runId
        documentState.activePipelineTask = Task {
            defer {
                // Only clear active task/run if this Task still owns it.
                if coordinator.documentState.activeRunId == runId {
                    coordinator.documentState.activePipelineTask = nil
                    coordinator.documentState.activeRunId = nil
                }
            }
            do {
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
                //      process regardless of corpus state.
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
                // FREEZE FIX: the post-`await` continuation here may resume off the
                // MainActor — the continuation after
                // `await Task.detached { … }.value` can land on a cooperative
                // background thread, not the MainActor. On the signature-degrade path
                // `surfaceGazetteerLoadDiagnostics` mutates @Observable MainActor state
                // (`autoDetectionDegraded`) AND enqueues a warning toast whose
                // `withAnimation` + UIKit feedback generator + UIAccessibility post all
                // require the main thread; running them off-main deadlocks the SwiftUI
                // transaction lock and permanently hangs the UI at Auto-Detect kickoff.
                // Hop onto the MainActor first — the same remedy the error-handler and
                // page-0 bootstrap degrade paths already use.
                await MainActor.run {
                    coordinator.surfaceGazetteerLoadDiagnostics(gazetteerDiagnostics)
                }

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
                // intermediate state leakage on cancellation and ensures
                // detectionResults is only written on success.
                var accumulatedResults: [Int: [DetectionResult]] = [:]
                var accumulatedDiagnostics: [Int: ClassificationDiagnostic] = [:]
                // ST-83 — pages whose page-level provenance reports the
                // OCR pixel-cap skip; written to redactionState with the
                // other accumulators on success.
                var accumulatedOCRCapSkips: Set<Int> = []

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
                        // here (the transition table has no editing→failed pair; CLAUDE.md
                        // hard-stop forbids adding one). MainActor.run hop for
                        // the same reason as the error handler below — the
                        // degrade touches MainActor-isolated state + the toast
                        // queue and this Task can be off the MainActor.
                        await MainActor.run { coordinator.degradeDetectionToEditing() }
                        return
                    }
                    var pendingImage: CGImage = try await
                        coordinator.renderPageForDetection(
                            bootstrapPage, pageIndex: 0,
                            phase: .rasterizePreflight)
                    var pendingPage: PDFPage = bootstrapPage

                    for i in 0..<totalPages {
                        try Task.checkCancellation()
                        coordinator.documentState.transition(to: .detecting(
                            progress: .init(
                                currentPage: i + 1,
                                totalPages: totalPages,
                                currentStep: recognitionLevel == .fast
                                    ? "Scanning page \(i + 1)\u{2026}"
                                    : "Thorough scan \u{2014} page \(i + 1)\u{2026}"
                            )
                        ))

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
                                coordinator.documentState.transition(to: .failed(
                                    error: .detectionError(.visionError(pageIndex: i + 1)),
                                    returnPhase: .editing
                                ))
                                return
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
                            // Stamp the detect interval so
                            // DetectionRasterizeOverlapTests can assert
                            // overlap with the lookahead rasterize.
                            let detectSignpostID = detectionRasterizeSignposter
                                .makeSignpostID()
                            let detectSignpostState =
                                detectionRasterizeSignposter.beginInterval(
                                    "detectPage", id: detectSignpostID,
                                    "page=\(i)"
                                )
                            let detectStart = Date()
                            // Seed the doctype
                            // window with the previous page's classification.
                            // Detection is serial across pages, so the i-1
                            // diagnostic is already recorded when page i
                            // dispatches; missing diagnostic → nil context
                            // (degrade, never race).
                            let prevPrimary: DoctypeClass? =
                                i > 0 ? accumulatedDiagnostics[i - 1]?.primary : nil
                            let doctypeCtx = prevPrimary.map { prev in
                                DoctypeWindow(primary: prev, secondary: nil)
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
                                DetectionRasterizeProbe.shared?.record(
                                    .init(pageIndex: i,
                                          phase: .rasterizeLookahead,
                                          kind: .detect,
                                          start: detectStart, end: Date())
                                )
                                throw error
                            }
                            detectionRasterizeSignposter.endInterval(
                                "detectPage", detectSignpostState
                            )
                            DetectionRasterizeProbe.shared?.record(
                                .init(pageIndex: i,
                                      phase: .rasterizeLookahead,
                                      kind: .detect,
                                      start: detectStart, end: Date())
                            )
                            accumulatedResults[i] = pageResult.detections
                            if let diag = pageResult.classificationDiagnostic {
                                accumulatedDiagnostics[i] = diag
                            }
                            // ST-83 — record the page-level OCR pixel-cap
                            // skip so the triage banner can surface it.
                            if pageResult.ocrProvenance.ocrSkipReason == .pixelCapExceeded {
                                accumulatedOCRCapSkips.insert(i)
                            }

                            // CANCEL-007: cooperative check between
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
                            // Last page — no lookahead to dispatch.
                            // Still stamp the detect interval
                            // for the trailing page (it lacks an
                            // overlapping rasterize counterpart, so the
                            // overlap-rate metric in
                            // DetectionRasterizeOverlapTests omits it
                            // from the denominator).
                            let detectSignpostID = detectionRasterizeSignposter
                                .makeSignpostID()
                            let detectSignpostState =
                                detectionRasterizeSignposter.beginInterval(
                                    "detectPage", id: detectSignpostID,
                                    "page=\(i) trailing=true"
                                )
                            let detectStart = Date()
                            // Same previous-page
                            // doctype window as the lookahead branch above.
                            let prevPrimary: DoctypeClass? =
                                i > 0 ? accumulatedDiagnostics[i - 1]?.primary : nil
                            let doctypeCtx = prevPrimary.map { prev in
                                DoctypeWindow(primary: prev, secondary: nil)
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
                                DetectionRasterizeProbe.shared?.record(
                                    .init(pageIndex: i,
                                          phase: .rasterizePreflight,
                                          kind: .detect,
                                          start: detectStart, end: Date())
                                )
                                throw error
                            }
                            detectionRasterizeSignposter.endInterval(
                                "detectPage", detectSignpostState
                            )
                            DetectionRasterizeProbe.shared?.record(
                                .init(pageIndex: i,
                                      phase: .rasterizePreflight,
                                      kind: .detect,
                                      start: detectStart, end: Date())
                            )
                            accumulatedResults[i] = pageResult.detections
                            if let diag = pageResult.classificationDiagnostic {
                                accumulatedDiagnostics[i] = diag
                            }
                            // ST-83 — record the page-level OCR pixel-cap
                            // skip so the triage banner can surface it.
                            if pageResult.ocrProvenance.ocrSkipReason == .pixelCapExceeded {
                                accumulatedOCRCapSkips.insert(i)
                            }
                        }
                    }
                }

                // CANCEL-007: cooperative check between detect
                // loop completion and Jaro-Winkler / cross-page clustering.
                // Both clusterers are synchronous O(n²) in the worst case;
                // a cancel arriving here without this check would otherwise
                // wait for the entire clustering pass to complete.
                try Task.checkCancellation()

                // Document-level Stage 5: entity clustering on name detections.
                // Bare-surname clusters ≥15 get flagged for inline ambiguity hints.
                let clusterer = EntityClusterer()
                var clusterInputs: [EntityClusterer.ClusterInput] = []
                for (_, results) in accumulatedResults {
                    for result in results {
                        guard case .pii(let kind) = result.kind, kind == .name else { continue }
                        guard let text = result.matchedText,
                              let input = EntityClusterer.clusterInput(
                                for: result.id, rawName: text
                              ) else { continue }
                        clusterInputs.append(input)
                    }
                }
                let clusterReport = clusterer.cluster(names: clusterInputs)

                // CANCEL-007: second cooperative check between the
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

                // Write to state only after all pages succeed
                coordinator.redactionState.detectionResults = accumulatedResults
                coordinator.redactionState.pageDiagnostics = accumulatedDiagnostics
                coordinator.redactionState.ocrPixelCapSkippedPages = accumulatedOCRCapSkips
                coordinator.redactionState.ambiguousSurnameDetectionIDs = clusterReport.bareSurnameFlags
                coordinator.redactionState.crossPageEntityGroups = crossPageGroups
                let allResults = accumulatedResults

                if allResults.values.allSatisfy({ $0.isEmpty }) {
                    // No detections — transition to editing. The run record
                    // drives the persistent summary banner (UXF-06): the
                    // prior info toast was the only trace and expired in
                    // seconds, leaving no way to tell "ran and found
                    // nothing" from "never ran".
                    coordinator.documentState.transition(to: .editing)
                    coordinator.redactionState.recordDetectionRun(
                        .nothingFound(pageCount: coordinator.documentState.pageCount))
                    return
                }

                // Stage for triage review — every detection run is
                // reviewed; the auto-apply branch retired with its
                // Settings toggle (no region is created without an
                // explicit user selection).
                coordinator.redactionState.pendingTriage = allResults

                // Review-first arrival: detections arrive with NOTHING
                // selected — the machine proposes, only the user
                // selects. An empty map is the whole contract now: the
                // one apply path reads an absent id as not accepted, so
                // staging just clears any stale entries.
                coordinator.redactionState.triageSelections = [:]

                coordinator.documentState.transition(to: .editing)
                coordinator.redactionState.recordDetectionRun(.staged)
                // Triage sheet appears automatically via .sheet binding on pendingTriage

            } catch is CancellationError { // LegalPhrases:safe (Swift keyword)
                // Only mutate cancellation state if this
                // Task still owns the active run. Prevents a superseded
                // detection Task from clobbering a newer run's phase.
                //
                // MainActor hop mirroring the general-error
                // handler sibling below (which carries the real-doc crash backtrace for
                // the same off-main-resume mechanism). The run-ownership guard
                // moves inside the hop. `MainActor.assertIsolated()` is the
                // canary. Transition table unchanged (threading context only).
                await MainActor.run {
                    MainActor.assertIsolated()
                    guard coordinator.documentState.activeRunId == runId else { return }
                    if coordinator.documentState.phaseKind != .editing {
                        coordinator.documentState.transition(to: .editing)
                    }
                }
            } catch { // LegalPhrases:safe (Swift keyword)
                // Graceful degradation: a detection/render error (notably the
                // page-0 rasterize failing on a platform that can't service
                // Vision/Core Graphics, e.g. the Simulator) returns to a safe
                // `.editing` state with a mechanism-description toast. Detection
                // is an optional enhancement and the source document is intact,
                // so we degrade rather than perform the illegal `editing →
                // failed` transition that crashed here when the throw occurred
                // during the page-0 bootstrap (before the per-page loop entered
                // `.detecting`). CLAUDE.md hard-stop: transition table unchanged.
                //
                // MainActor.run: a thrown error can resume this handler OFF the
                // MainActor — the real-doc crash backtrace shows it on
                // com.apple.root.user-initiated-qos.cooperative — so hop back
                // before touching MainActor-isolated state or the toast queue
                // (whose MainActor.assumeIsolated would otherwise trap). The
                // The run-ownership guard moves inside the hop so it, too,
                // reads MainActor state on the MainActor.
                await MainActor.run {
                    guard coordinator.documentState.activeRunId == runId else { return }
                    coordinator.degradeDetectionToEditing()
                }
            }
        }
    }

    /// Graceful degradation for the detection pipeline. Returns to a safe
    /// `.editing` state and surfaces a mechanism-description toast. Detection
    /// is an optional enhancement: on a render/detection error — notably the
    /// page-0 rasterize failing on a platform that cannot service Vision/Core
    /// Graphics (e.g. the Simulator) — the source document is intact, so we
    /// degrade (the user can retry or draw redactions manually) rather than
    /// perform an illegal `editing → failed` transition. The transition table
    /// has no `editing → failed` pair and CLAUDE.md's hard-stop
    /// forbids adding one. The `!= .editing` guard keeps the transition legal
    /// when the failure happened mid-detection (`.detecting → .editing`) and is
    /// a no-op when the page-0 bootstrap failed before the per-page loop
    /// entered `.detecting` (phase still `.editing`). Mirrors the
    /// CancellationError handler's recovery guard and the "No items detected"
    /// success path — both end in `.editing`.
    func degradeDetectionToEditing() {
        if documentState.phaseKind != .editing {
            documentState.transition(to: .editing)
        }
        // UXF-06 — the failed outcome also lands in the run record so the
        // summary banner keeps a dismissable trace after this toast expires.
        redactionState.recordDetectionRun(.failed)
        enqueueToast(
            "Couldn't scan this document. Manual redaction tools remain available.",
            severity: .warning)
    }

    /// Phase label for the page render in the detection pipeline.
    /// Used by `renderPageForDetection` to stamp `os_signpost` intervals so
    /// the depth-2 lookahead overlap is observable in Instruments and from
    /// tests via the in-process collector below.
    ///
    /// - `.rasterizePreflight`: the bootstrap render at iteration entry
    ///   (page 0). Runs alone — there is no concurrent detect to overlap
    ///   with — so this interval is intentionally NOT counted toward the
    ///   overlap-rate metric in the acceptance test.
    /// - `.rasterizeLookahead`: a depth-2 lookahead render dispatched
    ///   concurrently with `orchestrator.detectPage` for the previous
    ///   iteration's page. These intervals form the numerator of the
    ///   overlap-rate metric.
    enum DetectionRasterizePhase: String, Sendable {
        case rasterizePreflight
        case rasterizeLookahead
    }

    /// Render a PDF page to CGImage at 150 DPI for detection.
    /// 150 DPI is sufficient for OCR and saves memory vs. the 300 DPI export
    /// resolution.
    ///
    /// Emits an `os_signpost` interval around the synchronous
    /// rasterize work and (if a test-bound `DetectionRasterizeProbe.shared`
    /// collector is active) appends a `(pageIndex, phase, start, end)`
    /// tuple to it. The interval lets `DetectionRasterizeOverlapTests`
    /// assert that the lookahead render for page N+1 overlaps the detect
    /// for page N (the depth-2 contract). Probe access is on MainActor —
    /// emits happen post-hop after the @concurrent engine call returns,
    /// so collector mutation is serialized through MainActor isolation.
    /// nonisolated(unsafe): PDFPage is not Sendable but is accessed
    /// single-threaded *per call* — the depth-2 lookahead dispatches
    /// `renderPageForDetection` on at most 2 *different* pages in flight,
    /// never the same page twice (same safety model as processDocument).
    nonisolated func renderPageForDetection(
        _ page: PDFPage, pageIndex: Int,
        phase: DetectionRasterizePhase = .rasterizePreflight,
        doctype: DoctypeClass? = nil
    ) async throws -> CGImage {
        // Memory budget check mirrors the main pipeline's selectDPI()
        // memory check; detection was missing this guard.
        let rawBounds = page.bounds(for: .cropBox)
        let effectiveSize = effectiveBounds(rawBounds, rotation: page.rotation).size

        // DPI selection + the
        // 4096-px photo-PDF cap live in the engine's DetectionRenderPolicy
        // (financial → 200 DPI, everything else 150; one source of truth
        // shared with the measurement harness). `doctype` is the window
        // seed available at render time — the previous page's recorded
        // classification, nil for bootstrap/unseeded pages.
        let detectionDPI = DetectionRenderPolicy.cappedDetectionDPI(
            for: doctype, effectiveSize: effectiveSize
        )

        let scale = detectionDPI / 72.0
        let bytesNeeded = Int(ceil(effectiveSize.width * scale))
                        * Int(ceil(effectiveSize.height * scale)) * 4
        let available = os_proc_available_memory()
        // Memory pre-flight is summed across the lookahead (up
        // to 2 in-flight pages) by passing a 3× factor: current page's
        // detect-resident CGImage + concurrent lookahead's render +
        // selectDPI's 2× allocator headroom for the render context.
        // Conservative — pages are usually identically sized so the
        // budget rarely shrinks against a single-page estimate.
        guard bytesNeeded * 3 < Int(available) - 150_000_000 else {
            throw PipelineError.detectionError(.visionError(pageIndex: pageIndex))
        }

        // nonisolated(unsafe): rebind `page` for the engine call below.
        // Single-threaded per call — the depth-2 lookahead has at most two
        // DIFFERENT pages in flight, never the same page twice (see this
        // method's doc comment).
        nonisolated(unsafe) let unsafePage = page

        // Signpost + (optional) probe-stamp interval around the
        // synchronous rasterize call. `OSSignposter` emits to the
        // configured subsystem when Instruments is attached; the in-process
        // probe collector is nil outside tests. Both are cheap when idle.
        let signpostID = detectionRasterizeSignposter.makeSignpostID()
        let signpostState = detectionRasterizeSignposter.beginInterval(
            "renderPageForDetection", id: signpostID,
            "page=\(pageIndex) phase=\(phase.rawValue) dpi=\(Int(detectionDPI))"
        )
        let stampStart = Date()
        defer {
            detectionRasterizeSignposter.endInterval(
                "renderPageForDetection", signpostState
            )
            DetectionRasterizeProbe.shared?.record(
                .init(pageIndex: pageIndex, phase: phase,
                      kind: .rasterize, start: stampStart, end: Date())
            )
        }

        return try await PageRasterizer().renderPage(
            unsafePage, pageIndex: pageIndex, dpi: detectionDPI)
    }

    // MARK: - Degraded-mode surface

    /// Inspect a `GazetteerLoadDiagnostics` produced by
    /// `PIIDetector.loadWithDiagnostics(...)`. On the first qualifying
    /// failure of the session, post a warning toast (mechanism-description
    /// copy) and flip `RedactionState.autoDetectionDegraded = true`.
    /// Subsequent runs that re-discover the same failure are silent — the
    /// persistent banner on the search sheet's Scan interface already
    /// communicates the state.
    func surfaceGazetteerLoadDiagnostics(_ diagnostics: GazetteerLoadDiagnostics) {
        guard diagnostics.didDegrade else { return }
        // Only toast once per session — `autoDetectionDegraded` doubles as
        // the "first-failure already announced" gate.
        guard !redactionState.autoDetectionDegraded else { return }
        redactionState.autoDetectionDegraded = true
        enqueueToast(
            "Detection degraded \u{2014} detection corpus failed to load. Manual redaction tools remain available.",
            severity: .warning
        )
    }

    /// Enqueue a toast notification. Bridges from @Observable's nonisolated context
    /// to ToastQueueManager's @MainActor isolation. Called from nonisolated(unsafe)
    /// coordinator reference inside Task — the Task runs on MainActor but the
    /// compiler can't verify that through the unsafe capture.
    func enqueueToast(_ message: String, severity: ToastSeverity) {
        guard let manager = toastManager else { return }
        // ToastQueueManager is @MainActor (Sendable); enqueue() drives
        // `withAnimation` + a UIKit feedback generator + a UIAccessibility post —
        // all of which require the main thread. Callers on the detection pipeline
        // Task may not be on the MainActor: the Task continuation
        // can resume on a cooperative background thread, so the sibling toast
        // paths ("No items detected", auto-apply success) can reach here off-main.
        // Off-main, `assumeIsolated` traps and
        // `enqueue()`'s `withAnimation` deadlocks the SwiftUI transaction lock.
        // Take the synchronous `assumeIsolated` fast-path only when already on the
        // main thread; otherwise hop onto the MainActor so no caller can hang the UI.
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                manager.enqueue(message, severity: severity)
            }
        } else {
            Task { @MainActor in
                manager.enqueue(message, severity: severity)
            }
        }
    }

    // MARK: - Session-close protection downgrade

    /// Hook invoked when the user closes the active document (the Done
    /// close path in `DocumentEditorView.performDoneCloseSession()`, and
    /// `FailedStateView`'s Start Over path). Recursively
    /// downgrades every regular file in the current session's temp subtree
    /// (`tempExportDirectory.url`, the `redacted_session_<UUID>/` directory)
    /// to `.completeUntilFirstUserAuthentication` via
    /// `TempFileHardening.downgradeTree(at:to:)`.
    ///
    /// The previous implementation called
    /// `TempFileHardening.applyProtection` on the matching *directory*
    /// entries in `FileManager.default.temporaryDirectory`. On iOS,
    /// `setAttributes([.protectionKey:], ofItemAtPath:)` against a directory
    /// rewrites only that directory inode — the files nested inside
    /// `redacted_session_<UUID>/` kept `.complete`, defeating the
    /// rationale below. `downgradeTree` is the existing engine helper that
    /// enumerates regular files and downgrades each. The walk is also
    /// narrower: it touches only this session's subtree. Crash-orphaned
    /// subtrees from prior sessions are reaped by `cleanOrphanedTempFiles()`
    /// at next launch (it matches the `redacted_`/`recon_`/`resecta_`
    /// prefixes).
    ///
    /// Rationale: while a session is live we keep `.complete` so a locked
    /// device cannot read intermediate output. Once the document closes,
    /// background cleanup (e.g., `cleanOrphanedTempFiles`) needs to be able
    /// to remove stale files even when the device is locked after first
    /// unlock — `.completeUntilFirstUserAuthentication` is the level that
    /// supports this.
    func downgradeTempProtectionOnSessionClose() {
        // Recurse into the session subtree via the engine helper —
        // best-effort, per-file errors are swallowed inside downgradeTree.
        TempFileHardening.downgradeTree(
            at: tempExportDirectory.url,
            to: .completeUntilFirstUserAuthentication
        )
    }

    // MARK: - Sensitive Term Collection

    /// Collect unique matched PII text from the APPLIED redactions for Layer 3
    /// binary string search verification. Terms below 3 characters
    /// are included here; the Aho-Corasick layer applies its own minimum filter.
    ///
    /// Scoped to the regions actually applied. The
    /// prior pass also harvested `redactionState.detectionResults.values` (EVERY
    /// detection, including triage-deselected / auxiliary ones —
    /// the staged-review apply filters `regions` by selection at
    /// `RedactionState.swift:775` but never prunes `detectionResults`), so terms
    /// for un-redacted detections were hunted across body text and surfaced as
    /// false "Sensitive text within a redacted region" Layer-2 reports.
    func collectSensitiveTerms() -> [SensitiveTerm] {
        Self.sensitiveTerms(
            fromAppliedRegions: redactionState.regions,
            metadata: redactionState.regionMetadata
        )
    }

    /// Pure core of `collectSensitiveTerms`: given the applied regions
    /// and their metadata, return the verifier's sensitive-term set. Split out as
    /// a `nonisolated static` seam so it is unit-testable without a live
    /// coordinator.
    ///
    /// Two contributions per region (PD-3):
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
        return requiresBoundaryByText.map {
            SensitiveTerm(text: $0.key, requiresTokenBoundary: $0.value)
        }
    }

    /// True when `text` is a single whitespace-delimited token.
    nonisolated static func isSingleToken(_ text: String) -> Bool {
        text.split(whereSeparator: { $0.isWhitespace }).count <= 1
    }

    // MARK: - Build PDFPageData

    /// Bridge user state into engine-ready PDFPageData array.
    ///
    /// `runSettings` is the run-entry snapshot used by the
    /// pipeline; when nil (test callers, ad-hoc preview paths) the
    /// method snapshots `settingsState` itself so production behavior
    /// is unchanged outside an active run.
    func buildPDFPageData(
        effectiveMode: PipelineMode,
        runSettings: RunSettings? = nil
    ) -> [PDFPageData] {
        guard let doc = documentState.sourceDocument else { return [] }
        let snapshot = runSettings ?? RunSettings.snapshot(from: settingsState)
        return (0..<doc.pageCount).compactMap { i -> PDFPageData? in
            guard let page = doc.page(at: i) else { return nil }
            // Pre-extract page geometry and the CGPDFPage SERIALLY here
            // so the concurrent rasterize path is CG-only — it never reads
            // `page.bounds(for:)` / `page.pageRef` off the shared source document.
            let cropBoxBounds = page.bounds(for: .cropBox)
            let cgPage = page.pageRef
            let pageRegions = redactionState.regions[i]?.compactMap { region -> RedactionRegion? in
                // Minimum dimension threshold.
                guard region.normalizedRect.width > 0.001,
                      region.normalizedRect.height > 0.001 else { return nil }
                var clamped = region
                clamped.normalizedRect = region.normalizedRect.clampedToNormalized()
                return clamped
            } ?? []

            let pageMode: PipelineMode
            // PD-5: the pre-flight reason is recorded (not just nil-checked)
            // and threaded through the run so the verification report can say
            // why a page rasterized. Reasons exist only for Searchable-mode
            // runs — a secure-raster-mode run rasterizes every page by
            // choice, so its pages carry nil.
            var fallbackReason: TextLayerDetector.FallbackReason?
            // Rotated pages now take
            // searchable mode. The canonical coordinate contract is complete —
            // `extractCharacters` applies T_rot so `CharacterInfo.bounds` are
            // zero-origin, rotation-applied (displayed) coordinates, matching the
            // rasterizer's `effectiveSize` region basis; the filter and the
            // verifier compare in one frame. Proven end-to-end by the
            // `RotatedPageCoordinateTests` matrix (4 rotations × {zero,offset}
            // CropBox origin, Layers 6–10 + tamper). The former `page.rotation == 0`
            // stopgap is removed.
            if effectiveMode == .searchableRedaction,
               documentState.textLayerStatus[i] == .rich {
                // Check per-page triggers BEFORE committing to
                // searchable mode (RTL/vertical/encoding-broken pages have
                // unreliable PDFKit bounds; fall back per-page). Rotated pages
                // now reach this gate for the first time — a real RTL/vertical
                // misclassification surfaces here as a per-page SR fallback (the
                // checkFallbackTriggers heuristics are geometry-agnostic).
                if let trigger = TextLayerDetector.checkFallbackTriggers(page) {
                    pageMode = .secureRasterization
                    fallbackReason = trigger
                } else {
                    pageMode = .searchableRedaction
                }
            } else {
                pageMode = .secureRasterization
                // A sparse/no-text page in a Searchable-mode run is also a
                // per-page fallback the report should explain; the trigger
                // check never ran, but the reason is the same fact the
                // sparse/none classification records (PD-5).
                if effectiveMode == .searchableRedaction {
                    fallbackReason = .noExtractableText
                }
            }

            // Compute hasText serially, searchable pages only. Secure-
            // rasterization pages short-circuit the searchable-mode assert's left
            // disjunct, so `false` is correct for them — and this avoids a
            // Release-only `page.string` scan that would otherwise feed only a
            // Debug-build assert. Searchable pages already paid for text scans
            // via textLayerStatus / checkFallbackTriggers above.
            let hasText = pageMode == .searchableRedaction
                ? (page.string?.isEmpty == false) : false

            return PDFPageData(
                page: page, pageIndex: i, regions: pageRegions,
                fillColor: snapshot.fillColor,
                targetDPI: snapshot.exportDPI,
                pipelineMode: pageMode,
                rotation: page.rotation,
                hasHiddenOCG: documentState.sourceHasHiddenOCG,
                cropBoxBounds: cropBoxBounds,
                cgPage: cgPage,
                hasText: hasText,
                fallbackReason: fallbackReason
            )
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
    /// pipeline, so OCR runs unconditionally — this is a hard stop.
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
