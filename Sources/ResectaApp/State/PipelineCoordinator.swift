import Foundation
import PDFKit
import UIKit
import Vision
import os
import RedactionEngine

/// Signpost emission for the detection-pipeline depth-2
/// lookahead. The rasterize-for-detection and detect-page intervals are
/// emitted to this category so they can be sampled in Instruments
/// without re-instrumenting every release. Cheap when idle.
// nonisolated: file-level OSSignposter (Sendable, immutable) read from both the
// MainActor detection-pipeline closures and the `nonisolated renderPageForDetection`
// rasterize path. Under the SE-0466 MainActor-default flip an unannotated global
// `let` becomes MainActor-isolated, which the nonisolated callers cannot touch; pin
// it nonisolated to restore the pre-flip cross-isolation access (signposting is
// thread-safe).
nonisolated let detectionRasterizeSignposter = OSSignposter(
    subsystem: "com.resecta.app", category: "DetectionRasterize"
)

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
    /// Once raised to `1` we do NOT gradually re-raise: the
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
    struct PipelineRunContext: Sendable {
        let outputURL: URL
        let filterDigests: [PageFilterDigest?]
        let perPageModes: [PipelineMode]
        /// Sibling of `perPageModes` — the effective per-page fallback
        /// reason from each RasterizeResult (nil = kept searchable mode or
        /// secure-raster-mode run).
        let perPageFallbackReasons: [TextLayerDetector.FallbackReason?]
        let sensitiveTerms: [SensitiveTerm]
        /// The applied searches the Search Re-check re-runs on the output
        /// (one request per distinct applied query), beside `sensitiveTerms`.
        /// Empty ⇒ the re-check reports INFO. Derived at run entry by
        /// `collectAppliedSearches()` (present regions joined to the match
        /// audit); the verify-only path re-feeds the retained
        /// `lastRunAppliedSearches` or re-derives the same way.
        let appliedSearches: [SearchRecheckRequest]
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
        // Once collapsed to 1 we do not re-raise: dpiCap +
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

        // At the Apply seam, the Search &
        // Redact sheet mutates `redactionState.regions` and is incompatible
        // with the `.redacting` / `.verifying` phases this run enters, and
        // the editor's ONE `.sheet(item:)` slot sits above its phase
        // switch — a live session rode the compact float over the progress
        // card, the results screen and its Preview / Details pushes, and
        // Keep Editing came back with Scan / Search still disabled. Tear it
        // down here, the single funnel for Redact, ⇧⌘R, the resume banner's
        // Restart and the purge re-run — exactly what `prepareForPurgeRerun`
        // already did for its path. A staged review cannot be pending here
        // (`canStartPipeline(with:)`), so nothing needs parking.
        redactionState.dismissActiveSearch()

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
        launch(.full(effectiveMode: effectiveMode, runSettings: runSettings))
    }

    // MARK: - Verify-Only Re-Run

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
                layerName: verifier.layerName(at: 0, mode: effectiveMode),
                completedLayers: []
            )
        ))

        launch(.verifyOnly(outputURL: outputURL, effectiveMode: effectiveMode))
    }

    // MARK: - Launch

    /// How a run ended early: the two error-handler shapes of the scaffolds.
    enum PipelineRunEnd {
        case cancelled
        case failed(any Error, stage: PipelineFailureStage)
    }

    /// The state change a run's early end drives — the transitions the
    /// three scaffolds' recovery handlers made, one case per shape.
    enum PipelineRunRecovery {
        /// Nothing to drive (a superseded run, or a phase already settled
        /// by `cancelActivePipeline()`).
        case none
        /// `.editing`, optionally discarding the registered output first.
        case returnToEditing(clearOutput: Bool)
        /// `.verified(report: .skipped(reason: .cancelled))`.
        case verifiedSkippedCancelled
        /// `.failed(error:returnPhase:)`, optionally discarding the
        /// registered output first.
        case failed(PipelineError, returnPhase: DocumentState.ReturnPhase, clearOutput: Bool)
        /// `degradeDetectionToEditing()`.
        case degradeDetection
    }

    /// The recovery table: today's transitions per kind and end, exactly.
    /// Pure so the table is unit-testable without a live run; `phaseKind`
    /// is the phase read INSIDE the MainActor hop after the run-ownership
    /// guard (the cancel shapes only transition from a still-running
    /// phase — `cancelActivePipeline()` already handled cleanup and the
    /// transition when the user pressed Stop).
    static func recovery(
        for kind: PipelineRunKind, after end: PipelineRunEnd,
        phaseKind: DocumentState.PhaseKind
    ) -> PipelineRunRecovery {
        switch (kind, end) {
        case (.full, .cancelled):
            return phaseKind != .editing && phaseKind != .verified
                ? .returnToEditing(clearOutput: true) : .none
        case (.verifyOnly, .cancelled):
            return phaseKind != .editing && phaseKind != .verified
                ? .verifiedSkippedCancelled : .none
        case (.detection, .cancelled):
            return phaseKind != .editing ? .returnToEditing(clearOutput: false) : .none
        case (.full, .failed(let error, let stage)):
            // Classify by the FAILING STAGE, not by outputURL presence.
            // A redaction/import-stage error means the output was never
            // promoted (`replaceItemAt` never ran); discard the dangling
            // registration and return to the editor. A verification-stage
            // error leaves a valid promoted output; keep it and return to
            // the skipped-report screen.
            if stage == .verification {
                return .failed(
                    error as? PipelineError
                        ?? .verificationError(.engineCrash(layerIndex: 0)),
                    returnPhase: .verified(report: .skipped(reason: .error)),
                    clearOutput: false)
            }
            return .failed(
                error as? PipelineError ?? .redactionError(.reconstructionFailed),
                returnPhase: .editing,
                clearOutput: true)
        case (.verifyOnly, .failed(let error, _)):
            // Re-verify crashed, but the redacted output remains valid.
            // Surface as a failure that returns the user to the skipped
            // state (matching the full run).
            return .failed(
                error as? PipelineError
                    ?? .verificationError(.engineCrash(layerIndex: 0)),
                returnPhase: .verified(report: .skipped(reason: .error)),
                clearOutput: false)
        case (.detection, .failed):
            // Graceful degradation: a detection/render error (notably the
            // page-0 rasterize failing on a platform that can't service
            // Vision/Core Graphics, e.g. the Simulator) returns to a safe
            // `.editing` state with a mechanism-description toast.
            return .degradeDetection
        }
    }

    /// The one launch path behind the three entry points: mint the run
    /// token, create the run `Task` from the MainActor, hand the run to
    /// `PipelineRunner` with this coordinator as its event sink, and drive
    /// the recovery table when the run ends early.
    private func launch(_ kind: PipelineRunKind) {
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
            do {
                let runner = PipelineRunner(
                    coordinator: coordinator, sink: { coordinator.apply($0) })
                _ = try await runner.run(kind: kind)
            } catch is CancellationError { // LegalPhrases:safe (Swift keyword)
                // Hop to the MainActor before touching @Observable state. A
                // thrown CancellationError can resume this handler OFF the
                // MainActor (a Task.detached intermediate breaks the
                // actor-inheritance chain — see the general handler's
                // real-doc crash backtrace). The run-ownership guard moves
                // inside the hop so it, too, reads MainActor state on the
                // MainActor. `MainActor.assertIsolated()` is the canary — a
                // CI trap if the hop is ever removed. Transition table
                // unchanged (threading context only).
                await MainActor.run {
                    MainActor.assertIsolated()
                    // Only mutate cancellation state if this Task still owns
                    // the active run. After Stop → restart, the older Task's
                    // CancellationError must NOT clear the newer run's
                    // outputURL or override its phase transition.
                    guard coordinator.documentState.activeRunId == runId else { return }
                    coordinator.apply(recovery: Self.recovery(
                        for: kind, after: .cancelled,
                        phaseKind: coordinator.documentState.phaseKind))
                }
            } catch { // LegalPhrases:safe (Swift keyword)
                let failure = error as? PipelineRunFailure
                let underlying = failure?.underlying ?? error
                let stage = Self.classifyPipelineFailure(
                    underlying, redactionSucceeded: failure?.redactionSucceeded ?? false)
                // MainActor.run: a thrown error can resume this handler OFF the
                // MainActor — the real-doc crash backtrace shows it on
                // com.apple.root.user-initiated-qos.cooperative — so hop back
                // before touching MainActor-isolated state or the toast queue.
                // The run-ownership guard moves inside the hop so it, too,
                // reads MainActor state on the MainActor.
                await MainActor.run {
                    // Same UUID guard as the cancellation path — a late
                    // recovery from a superseded run must not stomp the
                    // newer run's state.
                    guard coordinator.documentState.activeRunId == runId else { return }
                    coordinator.apply(recovery: Self.recovery(
                        for: kind, after: .failed(underlying, stage: stage),
                        phaseKind: coordinator.documentState.phaseKind))
                }
            }
        }
    }

    /// Drive one recovery from the table.
    func apply(recovery: PipelineRunRecovery) {
        switch recovery {
        case .none:
            break
        case .returnToEditing(let clearOutput):
            if clearOutput { redactionState.clearOutput() }
            documentState.transition(to: .editing)
        case .verifiedSkippedCancelled:
            documentState.transition(
                to: .verified(report: .skipped(reason: .cancelled)))
        case .failed(let error, let returnPhase, let clearOutput):
            if clearOutput { redactionState.clearOutput() }
            documentState.transition(to: .failed(error: error, returnPhase: returnPhase))
        case .degradeDetection:
            degradeDetectionToEditing()
        }
    }

    // MARK: - Run events (the MainActor adapter)

    /// Apply one `PipelineRunEvent`: the state writes, transitions, toasts
    /// and announcements a run causes, in the order the runner reports
    /// them. Synchronous and MainActor-isolated, so the runner's next
    /// statement observes the write.
    func apply(_ event: PipelineRunEvent) {
        switch event {
        case .phase(let phase):
            documentState.transition(to: phase)
        case .announce(let announcement):
            UIAccessibility.post(notification: .announcement, argument: announcement)
        case .runStarted(let effectiveMode):
            documentState.lastUsedPipelineMode = effectiveMode
        case .outputRegistered(let outputURL):
            // Orphan hygiene: if a previous run's output is still
            // registered, clear it (which also removes its file from
            // disk) before registering this run's URL — a bare
            // re-assignment would overwrite the published URL and orphan
            // the prior file until the next-launch sweep.
            if redactionState.outputURL != nil {
                redactionState.clearOutput()
            }
            redactionState.outputURL = outputURL
        case .redactionFinished(let outputURL, let runContext, let deselection):
            // `outputURL` was already registered. The explicit
            // re-assignment here is intentional: if a redactionState
            // mutation occurred between the eager register and
            // `processDocument` returning, we restore the canonical
            // published value. Idempotent.
            redactionState.outputURL = outputURL
            redactionState.clearTextExtractionBuffer()
            // Retain the run's verification inputs beside the output so
            // a verify-only re-run checks the terms the artifact was built
            // with and reports the true per-page modes, instead of
            // re-synthesizing both (see RedactionState.lastRunPerPageModes).
            redactionState.recordLastRunInputs(
                perPageModes: runContext.perPageModes,
                perPageFallbackReasons: runContext.perPageFallbackReasons,
                sensitiveTerms: runContext.sensitiveTerms,
                appliedSearches: runContext.appliedSearches)
            // Record the run-entry deselection snapshot beside the run
            // inputs (nil clears a previous run's record). Cleared with
            // the output in `clearOutput()`.
            redactionState.recordLastRunDeselection(deselection)
        case .verificationSkipped:
            documentState.transition(to: .verified(report: .skipped))
            redactionState.markVerificationCurrent()
        case .verified(let report):
            documentState.transition(to: .verified(report: report))
            redactionState.markVerificationCurrent()
        case .gazetteerDiagnostics(let diagnostics):
            surfaceGazetteerLoadDiagnostics(diagnostics)
        case .detectionBootstrapFailed:
            degradeDetectionToEditing()
        case .detectionFinished(let detection):
            // Write to state only after all pages succeed
            redactionState.detectionResults = detection.results
            redactionState.pageDiagnostics = detection.diagnostics
            redactionState.ocrPixelCapSkippedPages = detection.ocrPixelCapSkippedPages
            redactionState.ambiguousSurnameDetectionIDs = detection.ambiguousSurnameDetectionIDs
            redactionState.crossPageEntityGroups = detection.crossPageEntityGroups
            let allResults = detection.results

            if allResults.values.allSatisfy({ $0.isEmpty }) {
                // No detections — transition to editing. The run record
                // drives the persistent summary banner: the
                // prior info toast was the only trace and expired in
                // seconds, leaving no way to tell "ran and found
                // nothing" from "never ran".
                documentState.transition(to: .editing)
                redactionState.recordDetectionRun(
                    .nothingFound(pageCount: documentState.pageCount),
                    ocrSkippedPages: redactionState.ocrPixelCapSkippedPages)
                return
            }

            // Stage for triage review — every detection run is
            // reviewed; the auto-apply branch retired with its
            // Settings toggle (no region is created without an
            // explicit user selection).
            redactionState.pendingTriage = allResults

            // Review-first arrival: detections arrive with NOTHING
            // selected — the machine proposes, only the user
            // selects. An empty map is the whole contract now: the
            // one apply path reads an absent id as not accepted, so
            // staging just clears any stale entries.
            redactionState.triageSelections = [:]

            documentState.transition(to: .editing)
            redactionState.recordDetectionRun(
                .staged,
                ocrSkippedPages: redactionState.ocrPixelCapSkippedPages)
            // Triage sheet appears automatically via .sheet binding on pendingTriage
        }
    }

    // MARK: - Rasterization + Reconstruction

    /// Process all pages: rasterize → fill → reconstruct PDF.
    /// Returns a PipelineRunContext with per-page digests and modes for verification.
    /// Reports progress through `onProgress` (the runner turns each tick
    /// into a `.redacting` self-transition).
    func processDocument(
        _ pages: [PDFPageData],
        outputURL: URL,
        sensitiveTerms: [SensitiveTerm],
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

        // Atomic rename: same APFS volume (both in temporaryDirectory)
        _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tempURL)

        return PipelineRunContext(
            outputURL: outputURL,
            filterDigests: filterDigests,
            perPageModes: perPageModes,
            perPageFallbackReasons: perPageFallbackReasons,
            sensitiveTerms: sensitiveTerms,
            appliedSearches: appliedSearches
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

    /// Rasterize `pages` page-parallel with STREAMING ordered append: the
    /// schedule — the bounded submission, the index-tagged in-order drain,
    /// the residency gate — is `PageRasterizationScheduler`'s; this method
    /// binds it to the coordinator's live `dpiCap` / `parallelismOverride`
    /// reads, its `rasterizeWithRetry`, the `.redacting` progress transition
    /// and the DEBUG residency telemetry. Each parallel task wraps the
    /// rasterize call in `rasterizeWithRetry`, so the per-page half-DPI retry
    /// on `fillVerificationFailed` happens inside the task — preserving the
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

    // MARK: - Verification

    /// Seam: run the parallel base-layer batch and return the
    /// `(layerIndex, LayerResult)` pairs in completion order. Index adapter
    /// over the identity form below (indices in `pipelineMode`'s
    /// `layers(for:)` order) — kept for the guard test that drives the seam
    /// by index.
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
        let ordered = verifier.layers(for: pipelineMode)
        let identities = layers.map { ordered[$0] }
        let results = try await collectParallelBaseLayerResults(
            layers: identities,
            outputURL: outputURL,
            shared: shared,
            verifier: verifier,
            sourcePageCount: sourcePageCount,
            regions: regions,
            sensitiveTerms: sensitiveTerms,
            pipelineMode: pipelineMode,
            filterDigests: filterDigests,
            perPageModes: perPageModes
        )
        return results.map { (ordered.firstIndex(of: $0.0) ?? 0, $0.1) }
    }

    /// Seam: run the parallel base-layer batch and return the
    /// `(layer, LayerResult)` pairs in completion order. The batch itself is
    /// `VerificationOrchestrator.collectParallelBaseLayerResults`; this
    /// method binds it to the app's off-main per-layer document
    /// provisioning so a guard test can drive the fan-out directly and
    /// assert each parallel layer receives its own `PDFDocument` instance
    /// (mirrors the deliberate `internal` precedent of `rasterizePagesInParallel`).
    ///
    /// `nonisolated`: the per-layer document provisioning is CPU-bound on
    /// large outputs and runs off MainActor; the layer fan-out is
    /// `@concurrent`. All parameters are `Sendable` value types.
    nonisolated func collectParallelBaseLayerResults(
        layers: [VerificationLayer],
        outputURL: URL,
        shared: SendablePDFDocument,
        verifier: VerificationEngine,
        sourcePageCount: Int,
        regions: [Int: [RedactionRegion]],
        sensitiveTerms: [SensitiveTerm],
        pipelineMode: PipelineMode,
        filterDigests: [PageFilterDigest?],
        perPageModes: [PipelineMode]
    ) async throws -> [(VerificationLayer, LayerResult)] {
        // Provision one PDFDocument instance per parallel layer off
        // MainActor. nil ⇒ at least one re-open failed.
        let perLayerDocs = await Self.provisionLayerDocumentsOffMainActor(
            outputURL, layers: layers)
        return try await VerificationOrchestrator(verifier: verifier)
            .collectParallelBaseLayerResults(
                layers: layers,
                shared: shared,
                perLayerDocuments: perLayerDocs,
                sourcePageCount: sourcePageCount,
                regions: regions,
                sensitiveTerms: sensitiveTerms,
                pipelineMode: pipelineMode,
                filterDigests: filterDigests,
                perPageModes: perPageModes
            )
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

        launch(.detection(recognitionLevel: recognitionLevel, runSettings: runSettings))
    }

    /// Graceful degradation for the detection pipeline. Returns to a safe
    /// `.editing` state and surfaces a mechanism-description toast. Detection
    /// is an optional enhancement: on a render/detection error — notably the
    /// page-0 rasterize failing on a platform that cannot service Vision/Core
    /// Graphics (e.g. the Simulator) — the source document is intact, so we
    /// degrade (the user can retry or draw redactions manually) rather than
    /// perform an illegal `editing → failed` transition. The transition table
    /// has no `editing → failed` pair, and none is added.
    /// The `!= .editing` guard keeps the transition legal
    /// when the failure happened mid-detection (`.detecting → .editing`) and is
    /// a no-op when the page-0 bootstrap failed before the per-page loop
    /// entered `.detecting` (phase still `.editing`). Mirrors the
    /// CancellationError handler's recovery guard and the "No items detected"
    /// success path — both end in `.editing`.
    func degradeDetectionToEditing() {
        if documentState.phaseKind != .editing {
            documentState.transition(to: .editing)
        }
        // The failed outcome also lands in the run record so the
        // summary banner keeps a dismissable trace after this toast expires.
        // ocrSkippedPages stays at its default empty set here: a
        // run that did not complete never reached the write at line 1842,
        // so `ocrPixelCapSkippedPages` on state may still hold a prior
        // run's pages, and this outcome must not carry that value forward.
        redactionState.recordDetectionRun(.failed)
        enqueueToast(
            "Couldn't scan this document. Manual redaction tools remain available.",
            severity: .warning)
    }

    /// Phase label for the page render in the detection pipeline.
    /// Used by `renderPageForDetection` to stamp `os_signpost` intervals so
    /// the depth-2 lookahead overlap is observable in Instruments.
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
    /// rasterize work so the depth-2 lookahead overlap is observable
    /// in Instruments.
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

        // Signpost interval around the synchronous rasterize call.
        // `OSSignposter` emits to the configured subsystem when Instruments
        // is attached; cheap when idle.
        let signpostID = detectionRasterizeSignposter.makeSignpostID()
        let signpostState = detectionRasterizeSignposter.beginInterval(
            "renderPageForDetection", id: signpostID,
            "page=\(pageIndex) phase=\(phase.rawValue) dpi=\(Int(detectionDPI))"
        )
        defer {
            detectionRasterizeSignposter.endInterval(
                "renderPageForDetection", signpostState
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
        redactionState.autoDetectionDegradeFailures = diagnostics.failedGazetteers
        enqueueToast(
            DetectionDegradeCopy.toast(
                failedGazetteers: diagnostics.failedGazetteers),
            severity: .warning
        )
    }

    /// Enqueue a toast notification. Statically MainActor-isolated: the
    /// coordinator is MainActor by the SE-0466 default, so every caller
    /// already runs on the MainActor — the detection pipeline's degrade and
    /// diagnostics paths hop through `MainActor.run` before they call in.
    /// `ToastQueueManager.enqueue` drives `withAnimation`, a UIKit feedback
    /// generator and a UIAccessibility post, all of which need the main
    /// thread; the isolation proves that at compile time, where a runtime
    /// thread check could only trap or hop. Synchronous, so a caller's
    /// next statement observes the enqueued toast.
    @MainActor
    func enqueueToast(_ message: String, severity: ToastSeverity) {
        toastManager?.enqueue(message, severity: severity)
    }

    // MARK: - Session-close protection downgrade

    /// Hook invoked when the user closes the active document (the Done
    /// close path in `DocumentEditorView.performDoneCloseSession()`, and
    /// `FailedStateView`'s Start Over path). Removes any `recon_*`
    /// intermediate left in the session directory, then recursively
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
        // An intermediate still in the session directory at close was
        // abandoned by its run (every exit path of `processDocument`
        // removes its own `recon_*`): unlink it now rather than leave it
        // for the launch sweep's 1-hour TTL. The session's output stays —
        // it is the registered `outputURL` until `clearAll()` runs.
        Self.removeAbandonedIntermediates(in: tempExportDirectory.url)
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

    // MARK: - Applied-Search Collection

    /// Collect the Search Re-check requests for this run — one per
    /// distinct query the user applied from the Search interface whose
    /// regions are still present. Read at run entry beside
    /// `collectSensitiveTerms()`; the verify-only path re-feeds the
    /// retained copy or calls this again.
    func collectAppliedSearches() -> [SearchRecheckRequest] {
        Self.appliedSearches(
            fromRegions: redactionState.regions,
            audit: redactionState.appliedMatchAudit
        )
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
            // The pre-flight reason is recorded (not just nil-checked)
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
                // sparse/none classification records.
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
}
