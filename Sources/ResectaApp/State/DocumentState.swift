import Foundation
import PDFKit
import os
import RedactionEngine
import Vision  // VNRequestTextRecognitionLevel for lastUsedRecognitionLevel

// See ARCH §4.1 for canonical definition.
// See UI_UX §1.2 for transition table, §1.3 for transition engine.

// ARCH §12.2: Log only phase kind (enum case names) as .public.
// Never log document content, file paths, or redaction coordinates.
private let logger = Logger(subsystem: "com.resecta.app", category: "state")

/// Document lifecycle and source data. MainActor by SE-0466 default.
@Observable
class DocumentState {

    // MARK: - Phase and Progress Types

    enum Phase: Sendable {
        case empty
        case importing
        case editing
        case detecting(progress: DetectionProgress)
        case redacting(progress: RedactionProgress)
        case verifying(progress: VerificationProgress)
        case verified(report: VerificationReport)
        case exporting
        case failed(error: PipelineError, returnPhase: ReturnPhase)
    }

    struct DetectionProgress: Sendable {
        var currentPage: Int
        var totalPages: Int
        var currentStep: String
        var fraction: Double { Double(currentPage) / Double(max(totalPages, 1)) }
    }

    struct RedactionProgress: Sendable {
        var currentPage: Int
        var totalPages: Int
        var currentStep: String
        var fraction: Double { Double(currentPage) / Double(max(totalPages, 1)) }
    }

    struct VerificationProgress: Sendable {
        var currentLayer: Int       // 1-based layer index
        var totalLayers: Int        // Mode-dependent: 5 or 8 (NEVER hardcoded — R4)
        var layerName: String
        var completedLayers: [LayerResult]
        var subPhase: SubPhase = .verifying

        // The OCR post-processing path was scaffolded
        // but never wired to a production writer; `ocrReturnReport` +
        // `SubPhase.ocrProcessing` are removed. SubPhase now discriminates a
        // single verification sub-phase; the property is retained so existing
        // call sites and the progress fraction need no signature change.
        enum SubPhase: Sendable {
            case verifying
        }

        var fraction: Double {
            switch subPhase {
            case .verifying:
                return Double(currentLayer - 1) / Double(max(totalLayers, 1))
            }
        }
    }

    /// Where to return after a failure.
    enum ReturnPhase: Sendable {
        case empty
        case editing
        case verified(report: VerificationReport)
    }

    /// Discriminator enum — strips associated values for transition validation.
    enum PhaseKind: Hashable, CustomStringConvertible {
        case empty, importing, editing, detecting, redacting,
             verifying, verified, exporting, failed

        var description: String {
            switch self {
            case .empty: "empty"
            case .importing: "importing"
            case .editing: "editing"
            case .detecting: "detecting"
            case .redacting: "redacting"
            case .verifying: "verifying"
            case .verified: "verified"
            case .exporting: "exporting"
            case .failed: "failed"
            }
        }
    }

    // MARK: - Pipeline Progress (decoupled from phase for observation efficiency)

    /// Lightweight progress data updated on every pipeline tick. Views that display
    /// progress numbers observe this instead of `phase`, so self-transitions
    /// (progress ticks) only invalidate progress-displaying views, not the entire
    /// DocumentEditorView body which routes on `phase`.
    struct PipelineProgress: Sendable {
        var current: Int               // Page index (detecting/redacting) or layer index (verifying), 1-based
        var total: Int                 // Total pages or total layers
        var stepDescription: String    // "Processing page 3…" or layer name
        var completedLayers: [LayerResult] = []
        var verificationSubPhase: VerificationProgress.SubPhase = .verifying

        var fraction: Double {
            switch verificationSubPhase {
            case .verifying:
                return Double(current - 1) / Double(max(total, 1))
            }
        }

        /// Page-oriented fraction (detecting/redacting).
        var pageFraction: Double {
            Double(current) / Double(max(total, 1))
        }
    }

    var pipelineProgress: PipelineProgress?

    // MARK: - State

    var phase: Phase = .empty
    var sourceDocument: PDFDocument?
    var currentPageIndex: Int = 0
    var pageCount: Int { sourceDocument?.pageCount ?? 0 }

    // SEARCH D10-F1 — per-consumer PDFDocument copy. PDFDocument/PDFPage are
    // not thread-safe for concurrent read while the main-thread PDFView renders
    // the live instance, so the background search and the off-main live-preview
    // text-walk each read their OWN copy (per-consumer discipline, here
    // for the search path). Takes the `SendablePDFDocument` wrapper so the
    // caller can build the copy inside `Task.detached` off MainActor without a
    // non-Sendable capture (mirrors `firstPageText`). `nil` ⇒ the data
    // roundtrip failed; the caller surfaces a mechanism toast / clears the
    // preview and does NOT fall back to a shared-instance read.
    nonisolated static func makeSearchCopy(of source: SendablePDFDocument) -> SendablePDFDocument? {
        guard let data = source.document.dataRepresentation(),
              let copy = PDFDocument(data: data) else { return nil }
        return SendablePDFDocument(copy)
    }

    /// Active pipeline task — stored for cancellation support (UI_UX §1.4).
    var activePipelineTask: Task<Void, Never>?

    /// Active import task — stored for cancellation support. Parallels
    /// `activePipelineTask`. CANCEL-006: the import path has its own
    /// MainActor entry point in `ImportService` and runs CPU-bound
    /// per-page validation off MainActor via `Task.detached`; tracking
    /// the import task separately lets `cancelActivePipeline` reach the
    /// detached worker via the structured `Task.checkCancellation()`
    /// checks at the top of each per-page loop.
    var activeImportTask: Task<Void, Never>?

    /// STATE-2 (Pkg E): UUID stamp owned by the active pipeline Task.
    /// Set at Task dispatch in `runFullPipeline` / `runDetectionPipeline`,
    /// nilled in the Task's defer/error-recovery blocks only when it matches.
    /// This guards against the cancel-then-restart race where an older
    /// Task's error-recovery block would clear the NEW run's outputURL /
    /// activePipelineTask.
    var activeRunId: UUID?

    /// STATE-8 (Pkg N): cancellation-in-progress sentinel. Set true while
    /// `cancelActivePipeline` is unwinding the active pipeline / import
    /// Task; cleared once cancellation has propagated to the chosen exit
    /// phase. While true, `transition()` refuses to re-enter the active
    /// pipeline phases (`.detecting`, `.redacting`, `.verifying`); this
    /// suppresses the progress-card flicker that the cancelled Task's
    /// in-flight progress tick can otherwise produce between the user's
    /// Stop tap and the Task's `Task.checkCancellation()` surrender. The
    /// guard is in addition to the legal-transition table, not in place
    /// of it.
    var isCancelling: Bool = false

    /// Set when pipeline was paused by app backgrounding (ARCH §11).
    var wasPausedByBackground: Bool = false

    /// The phase the pipeline was cancelled from when
    /// backgrounded, captured before `cancelActivePipeline` transitions to
    /// `.editing`. Lets the editing-phase background-resume banner offer the
    /// matching pipeline (detect-only vs. full redact) instead of always
    /// re-running the full pipeline. A PROPERTY addition only — the Phase enum
    /// and transition table are untouched. Cleared at every
    /// `wasPausedByBackground` reset site.
    var pausedFromPhase: PhaseKind? = nil

    /// Per-page text layer detection results, populated during import.
    var textLayerStatus: [Int: TextLayerStatus] = [:]

    /// Doc-level OCG hidden-layer presence, precomputed at import time.
    /// M1: `PDFDocument(data:)` (every production import path) returns a
    /// document with `documentURL == nil`, so the engine could not reach
    /// the catalog at extraction time. The flag is computed from the raw
    /// bytes in `ImportService.validatePDFOffMainActor` and propagated into
    /// `PDFPageData` via `PipelineCoordinator.buildPDFPageData`.
    var sourceHasHiddenOCG: Bool = false

    /// Pipeline mode used for the most recent redaction run.
    var lastUsedPipelineMode: PipelineMode?

    /// Recognition level of the most recent Auto-Detect run,
    /// recorded by `runDetectionPipeline`. A detect-pause resume re-uses it so
    /// the re-run matches the level the user originally chose (fallback
    /// `.accurate` when nil). A PROPERTY addition only — mirrors
    /// `lastUsedPipelineMode`; the Phase enum and transition table are untouched.
    var lastUsedRecognitionLevel: VNRequestTextRecognitionLevel?

    /// True if at least one page has a rich text layer.
    var hasAnyTextLayer: Bool {
        textLayerStatus.values.contains(.rich)
    }

    var phaseKind: PhaseKind {
        kindOf(phase)
    }

    // MARK: - Phase Gating Predicates (Pkg D — STATE-1, STATE-3, STATE-7)

    /// True when a new document import (drop / file picker / photos) is a
    /// permitted transition from the current phase. False during phases
    /// that own in-flight mutation of `sourceDocument` or `redactionState`
    /// (`.importing`, `.detecting`, `.redacting`, `.verifying`). Predicate
    /// describes the transition-table contract — entry-point handlers
    /// consult this before staging an import so a mid-pipeline drop does
    /// not call `clearForNewDocument()` against an in-flight document.
    var canStartImport: Bool {
        switch phaseKind {
        case .empty, .editing, .verified, .failed:
            return true
        case .importing, .detecting, .redacting, .verifying, .exporting:
            return false
        }
    }

    /// Import gate combining the document-only `canStartImport`
    /// predicate with `RedactionState.pendingTriage`. Mirrors
    /// `canStartPipeline(with:)`: the triage-pending flag lives on
    /// `RedactionState`, so `canStartImport` stays ignorant of it and call
    /// sites that hold both states compose the full predicate here. A pending
    /// detection-review sheet belongs to the CURRENT document; admitting a
    /// replacement underneath it would let an Accept stamp the prior document's
    /// page-coordinate regions onto the new one (data integrity). The drag-drop
    /// path is the sole importer that bypasses the D12 import-while-editing
    /// confirmation, so it consults this composed gate directly.
    func canStartImport(with redactionState: RedactionState) -> Bool {
        canStartImport && redactionState.pendingTriage == nil
    }

    /// True when the full Redact-pipeline can be initiated. Requires
    /// `.editing` phase with no active pipeline task already running.
    /// The triage-sheet half of STATE-3 lives in `canStartPipeline(with:)`
    /// because the triage-pending flag lives on `RedactionState`; this
    /// computed property is the document-only half so call sites that
    /// already hold both states can compose the full predicate.
    var canStartPipeline: Bool {
        phaseKind == .editing && activePipelineTask == nil
    }

    /// Full Redact-pipeline gate combining the document-only predicate
    /// with the `RedactionState.pendingTriage` check. STATE-3 — Redact
    /// button is disabled while the triage sheet is up.
    func canStartPipeline(with redactionState: RedactionState) -> Bool {
        canStartPipeline && redactionState.pendingTriage == nil
    }

    /// True when caller mutations of `redactionState.regions` /
    /// `redactionState.regionMetadata` are a safe transition. False during
    /// phases that the pipeline owns (`.detecting`, `.redacting`,
    /// `.verifying`); the `applyFindings` write-back transaction
    /// must not interleave with those. STATE-7 — Apply during pipeline.
    var canMutateRegions: Bool {
        switch phaseKind {
        case .empty, .editing, .importing, .verified, .failed:
            return true
        case .detecting, .redacting, .verifying, .exporting:
            return false
        }
    }

    /// Toast copy for drop/file/photo rejection while the pipeline is
    /// active. Mechanism-description language (ARCH §1.3 / MASTER_LEGAL
    /// §19) — names what the app declined to do plus a recovery hint.
    static let importBlockedDuringPipelineMessage =
        "Cannot import while processing. Try again after the current step finishes."

    /// Toast copy for a drag-drop import declined because a detection
    /// review is open for the current document (the drop path bypasses the D12
    /// import-while-editing confirmation that the file/photo pickers stage).
    /// Mechanism-description language (ARCH §1.3 / MASTER_LEGAL §19) — names
    /// what the app declined to do plus a recovery hint.
    static let importBlockedDuringTriageMessage =
        "Cannot import while reviewing detections. Apply or dismiss them first."

    /// Mark the current verification report as user-overridden (§3.4 FAIL override).
    func overrideVerificationFailure() {
        guard case .verified(var report) = phase else { return }
        report.userOverrodeFailure = true
        phase = .verified(report: report)
    }

    /// Mark the current skipped-verification report as acknowledged for
    /// sharing (the one-time skipped-share confirm). Mirrors
    /// `overrideVerificationFailure()`: mutates the live `.verified` report,
    /// so the flag lives and dies with this report.
    func acknowledgeSkippedShare() {
        guard case .verified(var report) = phase else { return }
        report.userAcknowledgedSkippedShare = true
        phase = .verified(report: report)
    }

    // MARK: - Transition Engine (UI_UX §1.3)

    /// All legal transitions as (from-kind, to-kind) pairs.
    /// See UI_UX §1.2 for the full transition table.
    /// Internal (not private) for testability via @testable import.
    static let legalTransitions: Set<TransitionPair> = [
        .init(.empty, .importing),
        .init(.importing, .editing),
        .init(.importing, .failed),
        .init(.importing, .empty),          // CANCEL-006: user-initiated cancel
        .init(.editing, .detecting),
        .init(.editing, .redacting),
        .init(.editing, .importing),
        .init(.editing, .empty),
        .init(.detecting, .editing),
        .init(.detecting, .detecting),      // Self-transition: progress updates
        .init(.detecting, .failed),
        .init(.redacting, .verifying),
        .init(.redacting, .verified),       // autoVerify disabled path
        .init(.redacting, .redacting),      // Self-transition: progress updates
        .init(.redacting, .editing),
        .init(.redacting, .failed),
        .init(.verifying, .verified),
        .init(.verifying, .verifying),      // Self-transition: progress updates
        .init(.verifying, .editing),
        .init(.verifying, .failed),
        .init(.verified, .exporting),
        .init(.verified, .editing),
        .init(.verified, .empty),
        .init(.verified, .verifying),       // OCR post-processing re-verification (§5.7)
        .init(.exporting, .verified),
        .init(.exporting, .failed),
        .init(.failed, .editing),
        .init(.failed, .empty),
        .init(.failed, .verified),
    ]

    struct TransitionPair: Hashable {
        let from: PhaseKind
        let to: PhaseKind
        init(_ from: PhaseKind, _ to: PhaseKind) {
            self.from = from; self.to = to
        }
    }

    /// Attempt a phase transition. Returns false and logs if illegal.
    /// Self-transitions (same phaseKind) update only `pipelineProgress` to avoid
    /// invalidating views that observe `phase` for routing. Real transitions
    /// update both `phase` and `pipelineProgress`.
    @discardableResult
    func transition(to newPhase: Phase) -> Bool {
        let newKind = kindOf(newPhase)
        let pair = TransitionPair(phaseKind, newKind)

        // STATE-8 (Pkg N): drop progress-tick (self-transition) and re-entry
        // attempts into the active pipeline phases while a cancel is in
        // flight. The cancelled Task's `Task.checkCancellation()` surrender
        // can race the user's Stop tap; without this guard a final progress
        // tick from the dying Task flips the card back to `.redacting /
        // .detecting / .verifying` for one frame before the exit transition
        // lands. Legal-transition check still runs below for the unguarded
        // exit transitions (e.g., `.detecting → .editing`).
        if isCancelling {
            switch newKind {
            case .detecting, .redacting, .verifying:
                return false
            default:
                break
            }
        }

        guard Self.legalTransitions.contains(pair) else {
            logger.error(
                "Illegal phase transition: \(self.phaseKind, privacy: .public) → \(newKind, privacy: .public)"
            )
            assertionFailure("Illegal phase transition: \(phaseKind) → \(newKind)")
            return false
        }

        if phaseKind == newKind {
            // Self-transition: update progress only (avoids invalidating phase observers)
            syncProgress(from: newPhase)
        } else {
            logger.info("Phase: \(self.phaseKind, privacy: .public) → \(newKind, privacy: .public)")
            phase = newPhase
            syncProgress(from: newPhase)
        }
        return true
    }

    /// Sync pipelineProgress from a Phase value. Called on every transition.
    private func syncProgress(from newPhase: Phase) {
        switch newPhase {
        case .detecting(let p):
            pipelineProgress = PipelineProgress(
                current: p.currentPage, total: p.totalPages,
                stepDescription: p.currentStep)
        case .redacting(let p):
            pipelineProgress = PipelineProgress(
                current: p.currentPage, total: p.totalPages,
                stepDescription: p.currentStep)
        case .verifying(let p):
            pipelineProgress = PipelineProgress(
                current: p.currentLayer, total: p.totalLayers,
                stepDescription: p.layerName,
                completedLayers: p.completedLayers,
                verificationSubPhase: p.subPhase)
        default:
            pipelineProgress = nil
        }
    }

    private func kindOf(_ phase: Phase) -> PhaseKind {
        switch phase {
        case .empty: .empty
        case .importing: .importing
        case .editing: .editing
        case .detecting: .detecting
        case .redacting: .redacting
        case .verifying: .verifying
        case .verified: .verified
        case .exporting: .exporting
        case .failed: .failed
        }
    }

    // MARK: - Start Over Teardown

    /// STATE-6 (Pkg I): teardown for Start Over, extracted from
    /// `FailedStateView.performStartOver()` so the teardown postcondition is
    /// unit-testable. The previous inline body lived on a private
    /// SwiftUI View method that no test could call; its copy in
    /// `FailedStateViewStartOverTests` omitted the phase transition, so a
    /// regression dropping `transition(to: .empty)` stayed green.
    ///
    /// Mirrors `DocumentEditorView.performDoneCloseSession()` so the failed
    /// path doesn't leave PII (matchedText, regions, sourceDocument) in
    /// memory: session fields are reset before the phase transition.
    ///
    /// The SEC-1 session-close protection downgrade runs FIRST
    /// (matching `performDoneCloseSession()` order), recursing the session
    /// subtree via `TempFileHardening.downgradeTree`. The downgrade
    /// is carried into the extraction so the production teardown — including
    /// this step — is exercised by a unit test rather than an inline copy.
    ///
    /// This extraction is behavior-identical to the prior inline
    /// `performStartOver()` body. The Phase enum and `legalTransitions` table
    /// are byte-untouched; `transition(to: .empty)` is the same call, with the
    /// same argument, in the same position at the end of the sequence.
    func resetForStartOver(redactionState: RedactionState, coordinator: PipelineCoordinator) {
        coordinator.downgradeTempProtectionOnSessionClose()
        redactionState.clearAll()
        sourceDocument = nil
        textLayerStatus = [:]
        currentPageIndex = 0
        lastUsedPipelineMode = nil
        wasPausedByBackground = false
        pausedFromPhase = nil  // clear alongside wasPausedByBackground
        transition(to: .empty)
    }

    // MARK: - Cancellation (UI_UX §1.4)

    /// Cancel the active pipeline or import task and return to a safe phase.
    /// CANCEL-006 (Pkg B): `.importing` is now cancellable. The import
    /// task is tracked separately on `activeImportTask` because the
    /// import path runs its CPU-bound per-page validation on a detached
    /// `Task`, distinct from the structured pipeline `Task` that owns
    /// detect/redact/verify. The signal reaches the detached worker
    /// through the `Task.checkCancellation()` calls at the top of
    /// `ImportService.validatePDFOffMainActor`'s per-page loops.
    ///
    /// CANCEL-011 (Pkg N): `isCancelling = true` for the duration of the
    /// transition so the cancelled Task's racing progress-tick is dropped
    /// by `transition()`. A detached MainActor awaiter waits on each
    /// cancelled Task's `.value` so the Task's `defer` block — which
    /// nils `activePipelineTask` / `activeRunId` only when the run still
    /// matches — observably completes before the next pipeline kicks off
    /// from the same workspace. The sync signature is preserved; callers
    /// from button-tap and `RedactWorkspace.tearDown()` need no change.
    func cancelActivePipeline(redactionState: RedactionState) {
        // CANCEL-011: capture references before nilling so the awaiter
        // below can observe each cancelled Task's `defer` complete.
        let pipelineCaptured = activePipelineTask
        let importCaptured = activeImportTask

        activePipelineTask?.cancel()
        activePipelineTask = nil
        activeImportTask?.cancel()
        activeImportTask = nil

        // STATE-8: gate the cancelled Task's racing progress-tick out of
        // the active pipeline phases. Cleared at the end of this function
        // — once `transition()` has driven phase to the chosen safe state
        // the gate is no longer required.
        isCancelling = true
        defer { isCancelling = false }

        switch phaseKind {
        case .importing:
            // CANCEL-006: no `sourceDocument` mutation here — the import
            // path applies state only after validation succeeds (see
            // `ImportService.validateAndLoad`), so cancellation leaves
            // any prior document untouched. Returning to `.empty` matches
            // the documented user-facing contract for "Cancel Import."
            transition(to: .empty)
        case .detecting:
            transition(to: .editing)
        case .redacting:
            redactionState.clearOutput()
            transition(to: .editing)
        case .verifying:
            // Pkg L (CANCEL-009): preserve `outputURL` and the
            // `regionsModifiedSinceVerification` flag. The redacted output
            // is valid even if verification was interrupted (SER-6), so we
            // transition to `.verified(report: .skipped)` rather than
            // `.editing`. The DocumentEditorView background-resume banner
            // reads the flag to choose between Re-verify (when output is
            // still valid and no regions were modified) and Restart.
            // Note: clearVerification() is intentionally NOT called here —
            // doing so would reset `regionsModifiedSinceVerification`
            // to false and misrepresent staleness to the banner predicate.
            // The OCR-return-report contract was removed
            // (no production writer ever set `ocrReturnReport`), so cancel from
            // `.verifying` unconditionally lands on the skipped report,
            // carrying `.cancelled` so the results copy names the real cause
            // (covers both user Stop and backgrounding mid-verify — same path).
            transition(to: .verified(report: .skipped(reason: .cancelled)))
        default:
            break
        }

        // CANCEL-011: drain the cancelled Tasks in a detached MainActor
        // awaiter. The awaiter has no observable side-effect on the
        // current call (this function returns immediately), but its
        // existence makes the cleanup ordering test-pinnable: a unit
        // test can `await Task.yield()` until the cancelled Task's
        // `.value` resolves and assert that `activePipelineTask` /
        // `activeRunId` have settled. STATE-2's UUID guard inside each
        // Task's defer prevents stomping a newer run's state — the
        // awaiter does not interact with that guard, only observes it.
        if pipelineCaptured != nil || importCaptured != nil {
            Task { @MainActor in
                if let pipelineCaptured { await pipelineCaptured.value }
                if let importCaptured { await importCaptured.value }
            }
        }
    }
}

// MARK: - PhaseKind convenience (UI_UX §1.5)

extension DocumentState.PhaseKind {
    /// True when a pipeline is actively running.
    var isPipelineActive: Bool {
        switch self {
        case .detecting, .redacting, .verifying, .importing, .exporting: true
        default: false
        }
    }

    /// Phases that support user-initiated cancellation (UI_UX §1.2).
    /// CANCEL-006 (Pkg B): `.importing` joined the cancellable set so
    /// the scene-phase observer in `ContentView` and the in-card Cancel
    /// button in `DocumentEditorView` route through the same predicate.
    var isCancellable: Bool {
        switch self {
        case .detecting, .redacting, .verifying, .importing: true
        default: false
        }
    }
}

extension DocumentState.Phase {
    var isCancellable: Bool {
        switch self {
        case .detecting, .redacting, .verifying, .importing: true
        default: false
        }
    }
}
