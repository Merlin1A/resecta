import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// Reworked for the results-screen Run Verification card.
//
// The mid-verify background-resume banner this suite used to cover was
// structurally unreachable: it gated on `.verified(report: .skipped)`, a phase
// whose router branch renders `VerificationResultsView` instead of the banner's
// host overlay chain. The recovery affordance is now a card on the results
// screen. SwiftUI mounts are not directly observable in unit tests; we cover
// the predicates that gate the card (`shouldShowRunVerificationCard`) and its
// pipeline routing (`runVerificationRoute`), mirroring the prior suite's
// approach. Manual hands-on verification of the rendered card is captured in
// the PR description.
@Suite("DocumentEditorView — run-verification card predicates")
@MainActor
struct DocumentEditorViewBackgroundBannerTests {

    // MARK: - Card visibility (mount regression)

    @Test("Run Verification card shows for a .verified(report: .skipped) phase")
    func testCardShowsForSkippedPhase() {
        // Predicate-level mount assertion: extract the report the router
        // hands to VerificationResultsView and apply the card's gate.
        guard case .verified(let report) = DocumentState.Phase.verified(report: .skipped) else {
            Issue.record("Phase construction failed")
            return
        }
        #expect(
            VerificationResultsView.shouldShowRunVerificationCard(report: report) == true,
            "Card must mount for the skipped sentinel report"
        )
    }

    @Test("Run Verification card shows for every skip reason",
          arguments: [
            VerificationReport.SkipReason.autoVerifyOff,
            .cancelled,
            .error,
          ])
    func testCardShowsForEverySkipReason(reason: VerificationReport.SkipReason) {
        #expect(
            VerificationResultsView.shouldShowRunVerificationCard(
                report: .skipped(reason: reason)
            ) == true
        )
    }

    @Test("Run Verification card hidden for completed reports")
    func testCardHiddenForCompletedReports() {
        let passReport = VerificationReport(
            layers: [], overallStatus: .pass, durationSeconds: 0.4
        )
        #expect(
            VerificationResultsView.shouldShowRunVerificationCard(report: passReport) == false,
            "A completed verify has nothing to recover from"
        )
        let warnReport = VerificationReport(
            layers: [], overallStatus: .warn("noise"), durationSeconds: 0.5
        )
        #expect(
            VerificationResultsView.shouldShowRunVerificationCard(report: warnReport) == false
        )
        let failReport = VerificationReport(
            layers: [], overallStatus: .fail("leak"), durationSeconds: 0.6
        )
        #expect(
            VerificationResultsView.shouldShowRunVerificationCard(report: failReport) == false
        )
    }

    // MARK: - Card routing

    @Test("Verify-only route when outputURL present and not stale")
    func testVerifyOnlyRouteWhenOutputCurrent() {
        // Mirrors the state read in `handleRunVerificationTap`.
        let redaction = RedactionState()
        redaction.outputURL = URL(fileURLWithPath: "/tmp/redacted.pdf")
        // Fresh RedactionState — stale flag starts false.
        #expect(
            DocumentEditorView.runVerificationRoute(
                hasOutput: redaction.outputURL != nil,
                isVerificationStale: redaction.isVerificationStale
            ) == .verifyOnly,
            "Current output must route to verify-only"
        )
    }

    @Test("The full-pipeline leg holds the Redact gate: unapplied selections block it, the verify-only leg is untouched")
    func testFullPipelineLegHoldsTheRedactGate() {
        #expect(DocumentEditorView.runVerificationRoute(
            hasOutput: false, isVerificationStale: true, hasUnappliedSelections: true) == .blockedBySelections)
        #expect(DocumentEditorView.runVerificationRoute(
            hasOutput: true, isVerificationStale: true, hasUnappliedSelections: true) == .blockedBySelections)
        #expect(DocumentEditorView.runVerificationRoute(
            hasOutput: true, isVerificationStale: false, hasUnappliedSelections: true) == .verifyOnly,
            "verify-only keeps the session; nothing to hold")
        #expect(DocumentEditorView.runVerificationRoute(
            hasOutput: false, isVerificationStale: true, hasUnappliedSelections: false) == .fullPipeline)
    }

    @Test("Full-pipeline route when regions modified after redact")
    func testFullPipelineRouteWhenRegionsModified() {
        let redaction = RedactionState()
        // Region edit flips the stale flag. Simulate the post-redact state
        // by adding the region first, then restoring outputURL — the
        // production cancel-from-verifying path preserves outputURL while
        // leaving regionsModifiedSinceVerification at whatever it was.
        redaction.addRegion(
            RedactionRegion(
                id: UUID(),
                normalizedRect: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                source: .manual
            ),
            page: 0,
            undoManager: nil
        )
        redaction.outputURL = URL(fileURLWithPath: "/tmp/redacted.pdf")
        #expect(redaction.isVerificationStale == true,
                "Precondition — region edit set the stale flag")
        #expect(
            DocumentEditorView.runVerificationRoute(
                hasOutput: redaction.outputURL != nil,
                isVerificationStale: redaction.isVerificationStale
            ) == .fullPipeline,
            "Stale regions must route to the full pipeline"
        )
    }

    @Test("Full-pipeline route when outputURL absent")
    func testFullPipelineRouteWhenOutputMissing() {
        let redaction = RedactionState()
        // outputURL nil (e.g., a purge or a cleared output).
        #expect(
            DocumentEditorView.runVerificationRoute(
                hasOutput: redaction.outputURL != nil,
                isVerificationStale: redaction.isVerificationStale
            ) == .fullPipeline,
            "A missing output must route to the full pipeline"
        )
    }

    // MARK: - KI-4 purge re-run round-trips verified -> editing

    /// The purge re-run toast fires only from `.verified`, but
    /// `runFullPipeline` guards `canStartPipeline` which requires
    /// `.editing`. The action's preamble must round-trip the phase so the guard
    /// passes — otherwise the "Re-run" button silently no-ops and strands the
    /// user (gone output, disabled Share). The Run Verification card's
    /// full-pipeline leg reuses the same preamble.
    @Test("KI-4 re-run preamble round-trips verified -> editing so the pipeline guard passes")
    func testKI4ActionTransitionsThenRuns() {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.phase = .verified(report: .skipped)
        // Bug repro: the pipeline guard rejects from .verified.
        #expect(doc.canStartPipeline == false)

        DocumentEditorView.prepareForPurgeRerun(
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .editing)                       // legal round-trip
        #expect(doc.canStartPipeline == true)   // guard now passes
    }

    /// The primary action clears the pause state before it launches the
    /// run it offers, so when the resumed detection returns to `.editing`
    /// the banner's guard (`wasPausedByBackground && phaseKind == .editing`)
    /// reads false and the detection banner stands alone at the anchor.
    @Test("Resume banner's primary action clears the pause flag and its phase")
    func testPrimaryActionClearsPauseState() {
        let documentState = DocumentState()
        documentState.phase = .editing
        documentState.wasPausedByBackground = true
        documentState.pausedFromPhase = .detecting

        DocumentEditorView.clearBackgroundPause(documentState)

        #expect(documentState.wasPausedByBackground == false)
        #expect(documentState.pausedFromPhase == nil)
        #expect(documentState.phaseKind == .editing, "the phase is the run's to move, not the banner's")
    }

    /// The paused notice records a run that did not finish, so time away
    /// does not end it: the slot reads only the pause pair, which the
    /// banner's own dismiss and Restart (and its leaving the screen with
    /// the editing phase) clear.
    @Test("The paused notice keeps the top slot however long the app was away, until the pause is cleared")
    func testPausedNoticePersistsUntilCleared() {
        let documentState = DocumentState()
        documentState.phase = .editing
        documentState.wasPausedByBackground = true
        documentState.pausedFromPhase = .redacting
        #expect(TopBannerSlot.winner(documentState: documentState, detectionBannerPresent: true) == .paused)
        DocumentEditorView.clearBackgroundPause(documentState)
        #expect(TopBannerSlot.winner(documentState: documentState, detectionBannerPresent: true) == .detection)
    }

    /// Leaving the app during Verify lands on the results screen, where
    /// nothing reads the pause pair. Left set, Keep Editing (a bare
    /// transition to `.editing`) mounted the paused banner over a finished
    /// redaction. A background during Verify raises no pause.
    @Test("Keep Editing after a background during Verify shows no paused banner")
    func testBackgroundDuringVerifyRaisesNoPause() {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.sourceDocument = makeTestPDFDocument()
        redaction.outputURL = URL(fileURLWithPath: "/tmp/verify-background.pdf")
        doc.phase = .verifying(progress:
            .init(currentLayer: 1, totalLayers: 5, layerName: "Layer 1",
                  completedLayers: []))

        ContentView.cancelForBackground(documentState: doc, redactionState: redaction)

        guard case .verified(let report) = doc.phase else {
            Issue.record("Expected .verified after a background during Verify, got \(doc.phaseKind)")
            return
        }
        #expect(report.overallStatus == .skipped)
        #expect(doc.wasPausedByBackground == false)
        #expect(doc.pausedFromPhase == nil)

        doc.transition(to: .editing)
        #expect(!(doc.wasPausedByBackground && doc.phaseKind == .editing),
                "the banner's mount predicate reads false after Keep Editing")
    }
}
