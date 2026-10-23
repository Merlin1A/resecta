import Foundation
import PDFKit
import UIKit
import RedactionEngine

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
    /// The user's custom terms; read at run entry for the sweep request.
    let userTermsStore: UserTermsStore

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
    var lastReconstructorAppendOrder: [Int] = []

    #if DEBUG
    /// Test seam: runs on the run's task just before the reconstructed
    /// output is promoted to its URL (after `finalize()`); never read by
    /// production code. `StopDuringFinalizeTests` takes Stop from it.
    var beforeOutputPromotionSeam: (() -> Void)?
    #endif

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
    @ObservationIgnored var maxResidentResults: Int = 0
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
    weak var activeRasterizer: PageRasterizer?

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
        let sensitiveTerms: SensitiveTermSet
        /// The applied searches the Search Re-check re-runs on the output
        /// (one request per distinct applied query), beside `sensitiveTerms`.
        /// Empty ⇒ the re-check reports INFO. Derived at run entry by
        /// `collectAppliedSearches()` (present regions joined to the match
        /// audit); the verify-only path re-feeds the retained
        /// `lastRunInputs` or re-derives the same way.
        let appliedSearches: [SearchRecheckRequest]
    }

    /// Snapshot of pipeline-affecting settings, captured once
    /// at `runFullPipeline` entry. Subsequent
    /// mid-run reads route through the snapshot so a settings toggle
    /// during `.redacting / .verifying` cannot divert
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
        /// points (`runFullPipeline`, `buildPDFPageData`). No explicit
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
         settingsState: SettingsState, userTermsStore: UserTermsStore = UserTermsStore()) {
        self.documentState = documentState
        self.redactionState = redactionState
        self.settingsState = settingsState
        self.userTermsStore = userTermsStore

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

    // MARK: - Full Pipeline

    /// Run the complete Redact → Verify → Results pipeline.
    /// Stores the Task in documentState.activePipelineTask for cancellation.
    func runFullPipeline(documentOverride: PipelineMode?) {
        // The Redact button's rule, read before any side effect: every
        // route into a run (the paused banner's Restart, the purge Re-run,
        // Run Verification's full route) is refused where the button is
        // disabled, with the button's hint as a notice.
        if let refusal = documentState.redactRefusal(with: redactionState) {
            if !refusal.hint.isEmpty { enqueueToast(refusal.hint, severity: .warning) }
            return
        }

        // At the Apply seam, the Search & Redact sheet mutates
        // `redactionState.regions` and is incompatible with the phases this
        // run enters, and the editor's ONE `.sheet(item:)` slot sits above
        // its phase switch. Tear it down here, the single funnel for Redact,
        // ⇧⌘R, the resume banner's Restart and the purge re-run. Neither
        // unapplied selections nor a staged review can be pending here
        // (`redactRefusal(with:)`).
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
        let scheduledLayers = verifier.layers(for: effectiveMode)
        documentState.transition(to: .verifying(
            progress: .init(
                currentLayer: 1,
                totalLayers: scheduledLayers.count,
                layerName: scheduledLayers.first?.name ?? "",
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
    /// two scaffolds' recovery handlers made, one case per shape.
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
        case (.full, .cancelled):  // `.empty`: the session closed under a pending run
            return phaseKind != .editing && phaseKind != .verified && phaseKind != .empty
                ? .returnToEditing(clearOutput: true) : .none
        case (.verifyOnly, .cancelled):
            return phaseKind != .editing && phaseKind != .verified
                ? .verifiedSkippedCancelled : .none
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
        }
    }

    /// The one launch path behind the two entry points: mint the run
    /// token, create the run `Task` from the MainActor, hand the run to
    /// `PipelineRunner` with this coordinator as its event sink, and drive
    /// the recovery table when the run ends early.
    private func launch(_ kind: PipelineRunKind) {
        // nonisolated(unsafe): @Observable prevents Sendable; Task captures self
        // implicitly. Safe because all access is on MainActor (UndoManager pattern).
        nonisolated(unsafe) let coordinator = self
        // Stamp this run with a UUID owned by the Task: the sink, the defer
        // and the error-recovery guards below only act while the active run
        // still matches.
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
                    coordinator: coordinator, sink: { coordinator.apply($0, from: runId) })
                _ = try await runner.run(kind: kind)
            } catch is CancellationError { // LegalPhrases:safe (Swift keyword)
                // Hop to the MainActor before touching @Observable state: a
                // thrown CancellationError can resume this handler OFF the
                // MainActor (a Task.detached intermediate breaks the
                // actor-inheritance chain). The run-ownership guard reads
                // MainActor state inside the hop; `assertIsolated()` is the
                // canary if the hop is ever removed.
                await MainActor.run {
                    MainActor.assertIsolated()
                    // Only this Task's own run: after Stop → restart (or
                    // Stop alone) the run is no longer the active one.
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
                // MainActor (the real-doc crash backtrace showed it on the
                // cooperative pool), so hop back before touching
                // MainActor-isolated state or the toast queue.
                await MainActor.run {
                    // The same ownership guard as the cancellation path.
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
        }
    }

    // MARK: - Run events (the MainActor adapter)

    /// Apply one `PipelineRunEvent`: the state writes, transitions, toasts
    /// and announcements a run causes, in the order the runner reports
    /// them. Synchronous and MainActor-isolated, so the runner's next
    /// statement observes the write.
    /// The run's sink: an event lands only while `runId` is still the
    /// active run. Stop invalidates the run in its synchronous step and a
    /// restart mints a new id, so a cancelled or superseded Task's late
    /// events — its progress tick first of all — are dropped here.
    func apply(_ event: PipelineRunEvent, from runId: UUID) {
        guard documentState.activeRunId == runId else { return }
        apply(event)
    }

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
        case .redactionFinished(let outputURL, let inputs):
            // `outputURL` was already registered. The explicit
            // re-assignment here is intentional: if a redactionState
            // mutation occurred between the eager register and
            // `processDocument` returning, we restore the canonical
            // published value. Idempotent.
            redactionState.outputURL = outputURL
            redactionState.clearTextExtractionBuffer()
            // Retain the run's verification inputs beside the output as
            // one value, so a verify-only re-run checks what the artifact
            // was built with and the results screen describes this run
            // (see RedactionState.LastRunInputs).
            redactionState.recordLastRunInputs(inputs)
            // The results card says Redact cleared the undo history. It is
            // cleared when the redacted copy exists, so Stop, a background
            // pause or a failed run keep the history; an Undo after Keep
            // Editing still cannot unlink the built output.
            undoManager?.removeAllActions()
        case .verificationSkipped(let burnedRegionVersion):
            documentState.transition(to: .verified(report: .skipped))
            redactionState.markVerificationCurrent(burnedRegionVersion: burnedRegionVersion)
        case .verified(let report, let burnedRegionVersion):
            documentState.transition(to: .verified(report: report))
            redactionState.markVerificationCurrent(burnedRegionVersion: burnedRegionVersion)
        }
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

    /// Enqueue a toast notification. Statically MainActor-isolated: the
    /// coordinator is MainActor by the SE-0466 default, so every caller
    /// already runs on the MainActor.
    /// `ToastQueueManager.enqueue` drives `withAnimation`, a UIKit feedback
    /// generator and a UIAccessibility post, all of which need the main
    /// thread; the isolation proves that at compile time, where a runtime
    /// thread check could only trap or hop. Synchronous, so a caller's
    /// next statement observes the enqueued toast.
    @MainActor
    func enqueueToast(_ message: String, severity: ToastSeverity) {
        toastManager?.enqueue(message, severity: severity)
    }

    /// The one document boundary: a new document (a drop over an open one,
    /// the Home open, the password re-run) starts with an empty undo
    /// history and no notices from the previous document. The window's
    /// undo manager and toast queue outlive the document, and the editor
    /// stays mounted across a drop, so its close-time clear never runs.
    func documentDidChange() {
        undoManager?.removeAllActions()
        toastManager?.clearAll()
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
    func collectSensitiveTerms() -> [SensitiveTerm] {
        Self.sensitiveTerms(
            fromAppliedRegions: redactionState.regions,
            metadata: redactionState.regionMetadata,
            audit: redactionState.appliedMatchAudit
        )
    }

    // MARK: - Applied-Search Collection

    /// Collect the applied re-check requests for this run — one per
    /// distinct query (a typed search or a Scan) the user applied whose
    /// regions are still present; `deselected` rides the Scan requests.
    /// Read at run entry beside `collectSensitiveTerms()`; the verify-only
    /// path re-feeds the retained copy or calls this again.
    func collectAppliedSearches(deselected: [SearchResult] = []) -> [SearchRecheckRequest] {
        Self.appliedSearches(
            fromRegions: redactionState.regions,
            audit: redactionState.appliedMatchAudit,
            deselected: deselected
        )
    }

    // MARK: - Build PDFPageData

    /// Bridge user state into engine-ready PDFPageData array. The bridge
    /// itself is `RunInputs.pageData`, a pure function of values; this
    /// method snapshots the state objects and forwards.
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
        return RunInputs.pageData(
            document: doc,
            regions: redactionState.regions,
            textLayerStatus: documentState.textLayerStatus,
            sourceHasHiddenOCG: documentState.sourceHasHiddenOCG,
            settings: runSettings ?? RunSettings.snapshot(from: settingsState),
            effectiveMode: effectiveMode
        )
    }
}
