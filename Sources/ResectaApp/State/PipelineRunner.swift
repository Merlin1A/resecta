import Foundation
import PDFKit
import UIKit
import Vision
import RedactionEngine

// MARK: - Kinds, events, outcomes

/// What `PipelineRunner.run(kind:)` performs — one case per product entry
/// point, carrying the values the entry point snapshots at launch.
enum PipelineRunKind: Sendable {
    /// Redact → Verify → Results (`runFullPipeline`).
    case full(effectiveMode: PipelineMode, runSettings: PipelineCoordinator.RunSettings)
    /// Verify the existing output again without re-rasterizing (`runVerifyOnly`).
    case verifyOnly(outputURL: URL, effectiveMode: PipelineMode)
    /// PII and face detection across all pages (`runDetectionPipeline`).
    case detection(recognitionLevel: VNRequestTextRecognitionLevel,
                   runSettings: PipelineCoordinator.RunSettings)
}

/// What the runner reports to its sink. The runner performs no
/// `DocumentState` / `RedactionState` write, toast or accessibility post
/// itself: every state change a run causes is one of these, handed to the
/// coordinator (the MainActor adapter, `PipelineCoordinator.apply(_:)`) at
/// the point the run reaches it, in the order the run scaffolds fired them.
enum PipelineRunEvent {
    /// Drive a `DocumentState` phase transition (the progress ticks and
    /// the `.failed` landings a run publishes itself).
    case phase(DocumentState.Phase)
    /// Post a VoiceOver announcement.
    case announce(String)
    /// `runFullPipeline` entry: the run's effective mode is recorded.
    case runStarted(effectiveMode: PipelineMode)
    /// The output URL is registered BEFORE rasterization (a stale
    /// registration is cleared first — see `PipelineCoordinator.apply`).
    case outputRegistered(URL)
    /// `processDocument` returned: the URL is re-published, the extraction
    /// buffer cleared and the run's verification inputs retained beside
    /// the output with the run-entry deselection snapshot.
    case redactionFinished(
        outputURL: URL,
        runContext: PipelineCoordinator.PipelineRunContext,
        deselection: RedactionState.DeselectionSnapshot?)
    /// Auto-verify is off for this run: the skipped report is published.
    case verificationSkipped
    /// A verification report to publish.
    case verified(VerificationReport)
    /// Detection: the gazetteer-load diagnostics to surface.
    case gazetteerDiagnostics(GazetteerLoadDiagnostics)
    /// Detection: the page-0 bootstrap could not start — degrade to editing.
    case detectionBootstrapFailed
    /// Detection: every page detected — the accumulators to write and stage.
    case detectionFinished(PipelineRunner.DetectionResults)
}

/// How a run ended when it did not throw. Informational: the launcher's
/// bookkeeping is the same for every case (the scaffolds' early `return`s).
enum PipelineRunOutcome: Sendable {
    case completed
    /// Sub-threshold guard — no page carried an effective redaction.
    case noEffectiveRegions
    /// The redacted output could not be opened for verification.
    case verificationLoadFailed
    /// Detection could not render page 0.
    case detectionBootstrapFailed
    /// Detection could not read the next page for the lookahead render.
    case detectionLookaheadPageMissing(pageIndex: Int)
}

/// A non-cancellation error thrown out of a run, with the stage marker
/// the full run's generic recovery needs: `redactionSucceeded` is false
/// until `processDocument` returns, so a non-`PipelineError` throw can be
/// attributed to the redaction stage vs. the verification stage. The
/// published `outputURL` cannot serve as that discriminator — it is
/// registered eagerly, BEFORE `processDocument` runs.
struct PipelineRunFailure: Error {
    let underlying: any Error
    let redactionSucceeded: Bool
}

// MARK: - The runner

/// The one run path behind the coordinator's three entry points. UI-free:
/// it reads the document, redaction and settings state through the
/// coordinator, performs the pipeline work, and reports every state change
/// as a `PipelineRunEvent` to `sink` — it writes no `DocumentState` /
/// `RedactionState` itself, posts no toast and no accessibility
/// announcement. MainActor-isolated by the app target's default (the sink
/// is called synchronously between suspension points); the layers,
/// rasterization and the detached loads run where they ran before.
struct PipelineRunner {
    let coordinator: PipelineCoordinator
    let sink: @MainActor (PipelineRunEvent) -> Void

    /// Perform `kind`. Throws `CancellationError` on cancellation and
    /// `PipelineRunFailure` on any other error.
    func run(kind: PipelineRunKind) async throws -> PipelineRunOutcome {
        do {
            switch kind {
            case .full(let effectiveMode, let runSettings):
                return try await runFull(effectiveMode: effectiveMode, runSettings: runSettings)
            case .verifyOnly(let outputURL, let effectiveMode):
                return try await runVerifyOnly(outputURL: outputURL, effectiveMode: effectiveMode)
            case .detection(let recognitionLevel, let runSettings):
                return try await runDetection(
                    recognitionLevel: recognitionLevel, runSettings: runSettings)
            }
        } catch let cancellation as CancellationError { // LegalPhrases:safe (Swift keyword)
            throw cancellation
        } catch let failure as PipelineRunFailure { // LegalPhrases:safe (Swift keyword)
            throw failure
        } catch { // LegalPhrases:safe (Swift keyword)
            throw PipelineRunFailure(underlying: error, redactionSucceeded: false)
        }
    }

    // MARK: - Full run

    /// Redact → Verify → Results.
    private func runFull(
        effectiveMode: PipelineMode, runSettings: PipelineCoordinator.RunSettings
    ) async throws -> PipelineRunOutcome {
        // Stage marker for the generic error handler: false until
        // `processDocument` returns (see `PipelineRunFailure`).
        var redactionSucceeded = false
        do {
            sink(.runStarted(effectiveMode: effectiveMode))
            let pages = coordinator.buildPDFPageData(
                effectiveMode: effectiveMode, runSettings: runSettings)
            let sensitiveTerms = coordinator.collectSensitiveTerms()
            // The applied searches, read at the same point and from the
            // same present-region set: the Search Re-check re-runs
            // exactly the queries whose regions this run redacts.
            let appliedSearches = coordinator.collectAppliedSearches()

            // Capture the run's deselection facts at run entry,
            // before any pipeline work. The value is recorded onto
            // RedactionState only after `processDocument` returns
            // (beside `recordLastRunInputs`), but reading it HERE pins
            // the counts the user saw when they pressed Redact — a
            // programmatic or user re-selection during `.redacting` /
            // `.verifying` cannot drift what the results screen reports.
            // `runEntryDeselectionSnapshot()` prefers the
            // apply-commit snapshot (set at the moment the user last
            // applied selected search results, even if the sheet has
            // since dismissed and nil'd `activeSearch`) and falls back
            // to the live search session's snapshot — nil only when
            // neither source has one (no apply this document session
            // and no live PII-scan session at run entry).
            let deselectionSnapshot =
                coordinator.redactionState.runEntryDeselectionSnapshot()

            // Sub-threshold guard — no pages with effective redactions
            guard !pages.allSatisfy({ $0.regions.isEmpty }) else {
                return .noEffectiveRegions
            }

            // Route all session temp writes through the
            // backup-excluded per-session subdirectory. childURL throws
            // on directory-creation failure (e.g., disk full); the
            // outer error path wraps unknown throws as .redactionError.
            let outputURL = try coordinator.tempExportDirectory.childURL(
                named: "redacted_\(UUID().uuidString).pdf")

            // Register `outputURL` BEFORE the `processDocument` →
            // `replaceItemAt` race window. If the pipeline throws
            // (cancellation, reconstruction failure) after `replaceItemAt`
            // has already promoted the file but before this run completes,
            // the recovery calls `clearOutput()`, which reads the published
            // `outputURL` and removes the file from disk. Registering the
            // URL eagerly closes the leak where a post-rename failure would
            // otherwise orphan the file in the per-session temp
            // subdirectory until tear-down.
            sink(.outputRegistered(outputURL))

            // --- Rasterization + Reconstruction ---
            sink(.phase(.redacting(
                progress: .init(currentPage: 0, totalPages: pages.count,
                                currentStep: "Starting\u{2026}")
            )))

            let runContext = try await coordinator.processDocument(
                pages, outputURL: outputURL,
                sensitiveTerms: sensitiveTerms,
                appliedSearches: appliedSearches
            ) { progress in
                sink(.phase(.redacting(progress: progress)))
            }
            redactionSucceeded = true

            // Re-apply `.complete` to the promoted output URL.
            // `replaceItemAt` rewrites the protection class of the
            // destination, so the engine-side `.complete` on the temp
            // file does not survive the rename. Best-effort: errors are
            // non-fatal — a failure here leaves the file at the
            // filesystem default, which is no worse than the prior
            // contract.
            try? TempFileHardening.applyProtection(outputURL, level: .complete)

            sink(.redactionFinished(
                outputURL: outputURL, runContext: runContext,
                deselection: deselectionSnapshot))

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
                return try await verify(runContext: runContext, effectiveMode: effectiveMode)
            } else {
                sink(.verificationSkipped)
                return .completed
            }
        } catch let cancellation as CancellationError { // LegalPhrases:safe (Swift keyword)
            throw cancellation
        } catch { // LegalPhrases:safe (Swift keyword)
            throw PipelineRunFailure(underlying: error, redactionSucceeded: redactionSucceeded)
        }
    }

    // MARK: - Verify-only re-run

    /// Re-run verification against the existing `outputURL` without
    /// re-rasterizing. Per-page rasterize artifacts (`filterDigests`)
    /// cannot be reconstructed from the output PDF alone, so the layers
    /// that consume them (Layers 7 and 9 — the character-count and
    /// character-lineage cross-checks; Layer 8 is font verification and
    /// needs no digest) report `.skipped` rather than a silent `.pass`,
    /// and the overall verdict degrades to WARN rather than re-running the
    /// rasterize pipeline.
    private func runVerifyOnly(
        outputURL: URL, effectiveMode: PipelineMode
    ) async throws -> PipelineRunOutcome {
        let redactionState = coordinator.redactionState
        // Prefer the retained inputs of the run that produced the
        // output (recorded beside `outputURL` when `processDocument`
        // returned): the terms snapshot keeps the re-verify checking
        // what the artifact was built with even if regions changed
        // since, and the retained mode array preserves a mixed run's
        // per-page fallback record in the report. Fall back to
        // re-synthesis when absent (resumed old session).
        let sensitiveTerms = redactionState.lastRunSensitiveTerms
            ?? coordinator.collectSensitiveTerms()
        // Same retention contract for the Search Re-check requests:
        // the retained set when the run recorded one, else the same
        // derivation from the live audit (nothing is persisted; no
        // relaunch-restore path exists to consume a serialized copy).
        let appliedSearches = redactionState.lastRunAppliedSearches
            ?? coordinator.collectAppliedSearches()
        let pageCount = coordinator.documentState.pageCount
        // Per-page rasterize artifacts are not available on this
        // path; sandwich layers detect missing entries and skip.
        // Digests stay all-nil even with retained inputs — they
        // cannot be rebuilt from the output PDF, by design.
        let filterDigests: [PageFilterDigest?] = Array(
            repeating: nil, count: pageCount)
        let perPageModes: [PipelineMode] = redactionState
            .lastRunPerPageModes
            ?? Array(repeating: effectiveMode, count: pageCount)
        // Same retention contract as the mode array — the
        // retained reasons preserve a mixed run's fallback record on
        // re-verify; the all-nil synthesis matches the digest
        // fallback (per-page rasterize artifacts are unavailable).
        let perPageFallbackReasons: [TextLayerDetector.FallbackReason?] =
            redactionState.lastRunPerPageFallbackReasons
            ?? Array(repeating: nil, count: pageCount)

        let runContext = PipelineCoordinator.PipelineRunContext(
            outputURL: outputURL,
            filterDigests: filterDigests,
            perPageModes: perPageModes,
            perPageFallbackReasons: perPageFallbackReasons,
            sensitiveTerms: sensitiveTerms,
            appliedSearches: appliedSearches
        )
        return try await verify(runContext: runContext, effectiveMode: effectiveMode)
    }

    // MARK: - Verification

    /// Run every verification layer and publish the report. The schedule —
    /// the page-count gate, the phase partition, the parallel base batch,
    /// the sequential phases, the canonical assembly and the aggregate
    /// verdict — is the engine's `VerificationOrchestrator.run`; this
    /// method loads the output, snapshots the MainActor-isolated inputs,
    /// adapts the orchestrator's events to the `.verifying` transitions and
    /// the VoiceOver announcements, and publishes the report.
    private func verify(
        runContext: PipelineCoordinator.PipelineRunContext, effectiveMode: PipelineMode
    ) async throws -> PipelineRunOutcome {
        // `PDFDocument(url:)` is CPU-bound on large outputs; routing
        // through `Task.detached` keeps the MainActor-isolated run free
        // to drive the progress UI.
        let outputURL = runContext.outputURL
        let wrappedDoc: SendablePDFDocument
        do {
            wrappedDoc = try await Task.detached {
                try PipelineCoordinator.loadOutputDocumentOffMainActor(outputURL)
            }.value
        } catch { // LegalPhrases:safe (Swift keyword)
            sink(.phase(.failed(
                error: .verificationError(.engineCrash(layerIndex: 0)),
                returnPhase: .verified(report: .skipped(reason: .error))
            )))
            return .verificationLoadFailed
        }

        // Snapshot MainActor-isolated inputs once so the @concurrent
        // runLayer calls inside the batch do not re-cross the actor
        // boundary on every fan-out. Both source phases of the
        // `.verified` transition below, (.redacting,.verified) and
        // (.verifying,.verified), are legal transitions (no table change).
        let sourcePageCount = coordinator.documentState.pageCount
        let regionsSnapshot = coordinator.redactionState.regions

        let report = try await VerificationOrchestrator().run(
            outputDocument: wrappedDoc,
            sourcePageCount: sourcePageCount,
            regions: regionsSnapshot,
            sensitiveTerms: runContext.sensitiveTerms,
            pipelineMode: effectiveMode,
            filterDigests: runContext.filterDigests,
            perPageModes: runContext.perPageModes,
            perPageFallbackReasons: runContext.perPageFallbackReasons,
            appliedSearches: runContext.appliedSearches,
            provisionLayerDocuments: { layers in
                // Provision one PDFDocument instance per parallel layer off
                // MainActor. nil ⇒ at least one re-open failed.
                await PipelineCoordinator.provisionLayerDocumentsOffMainActor(
                    outputURL, layers: layers)
            },
            events: { event in
                switch event {
                case .layerStarted(let layer, let ordinal, let totalLayers, let completedLayers):
                    sink(.phase(.verifying(
                        progress: .init(
                            currentLayer: ordinal,
                            totalLayers: totalLayers,
                            layerName: layer.name,
                            completedLayers: completedLayers
                        )
                    )))
                case .layerFinished(_, let ordinal, let result):
                    sink(.announce(result.completionAnnouncement(layerNumber: ordinal)))
                }
            }
        )

        sink(.verified(report))
        // VoiceOver overall announcement
        sink(.announce("Verification complete. \(report.overallStatus.accessibilityLabel)"))
        return .completed
    }
}
