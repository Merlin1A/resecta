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

    /// Closing the paused notice clears the pause pair, so the banner's
    /// guard (`wasPausedByBackground && phaseKind == .editing`) reads false
    /// and the detection banner stands alone at the anchor. Restart no
    /// longer clears the pair itself: the run's start does, after its
    /// refusal check (`testFullRunStartClearsThePause`).
    @Test("Closing the paused notice clears the pause flag and its phase")
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
    /// notice's close, a full run's start, and the document's close or
    /// replacement clear.
    @Test("The paused notice keeps the top slot however long the app was away, until the pause is cleared")
    func testPausedNoticePersistsUntilCleared() {
        let documentState = DocumentState()
        documentState.phase = .editing
        documentState.wasPausedByBackground = true
        documentState.pausedFromPhase = .redacting
        #expect(TopBannerSlot.winner(documentState: documentState) == .paused)
        DocumentEditorView.clearBackgroundPause(documentState)
        #expect(TopBannerSlot.winner(documentState: documentState) == nil)
    }

    /// Leaving the app during Verify returns to the editor with the paused
    /// banner, as a cut Scan or Redact does, instead of landing on the
    /// results as skipped. The pause pair is read only in the editor, so it
    /// never shows over the results (`BackgroundVerifyResumeTests`).
    @Test("A background during Verify returns to the editor with the paused banner")
    func testBackgroundDuringVerifyRaisesThePause() {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.sourceDocument = makeTestPDFDocument()
        redaction.outputURL = URL(fileURLWithPath: "/tmp/verify-background.pdf")
        doc.phase = .verifying(progress:
            .init(currentLayer: 1, totalLayers: 5, layerName: "Layer 1",
                  completedLayers: []))

        ContentView.cancelForBackground(documentState: doc, redactionState: redaction)

        if case .verified = doc.phase {
            Issue.record("A background during Verify landed on the results as skipped")
        }
        #expect(doc.phaseKind == .editing)
        #expect(doc.wasPausedByBackground == true)
        #expect(doc.pausedFromPhase == .verifying)
        #expect(doc.wasPausedByBackground && doc.phaseKind == .editing,
                "the banner's mount predicate reads true")
    }

    // MARK: - The pause outlives the notice leaving the screen

    /// The notice is drawn inside the editor's editing branch, which leaves
    /// the screen under the screen-capture cover and during an import. Its
    /// view holds no hook that ends the pause when it leaves; the pause pair
    /// is ended in state only (the close, a full run's start, the document's
    /// close or replacement).
    @Test("The paused notice changes nothing when it leaves the screen")
    func testPausedNoticeHasNoLeavingHook() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ResectaApp/Views/DocumentEditorView+ResumeBanner.swift"),
            encoding: .utf8)
        #expect(source.contains("var resumeBannerOverlay"), "the notice's view is in this file")
        #expect(!source.contains("onDisappear"))
    }

    /// The two ways an import over the open document goes back to it: it
    /// fails (the failed screen's Return to Editor), or it is cancelled.
    enum ImportReturnRoute: CaseIterable {
        case failed
        case cancelled
    }

    @Test("A pause survives an import that fails")
    func testPauseSurvivesAnImportThatDoesNotOpen() {
        #expect(ImportReturnRoute.allCases.count == 2)
        for route in ImportReturnRoute.allCases {
            let doc = DocumentState()
            let redaction = RedactionState()
            doc.sourceDocument = makeTestPDFDocument()
            doc.phase = .editing
            doc.wasPausedByBackground = true
            doc.pausedFromPhase = .redacting

            switch route {
            case .failed:
                ImportService.refuse(.tooLarge(bytesRead: 60 * 1024 * 1024), documentState: doc)
                #expect(doc.phaseKind == .failed, "\(route)")
                guard case .failed(let error, let returnPhase) = doc.phase else { continue }
                #expect(FailedStateView.primaryAction(error: error, returnPhase: returnPhase) == .returnToEditor,
                        "\(route)")
                doc.transition(to: .editing)
            case .cancelled:
                doc.transition(to: .importing)
                #expect(doc.phaseKind == .importing, "\(route)")
                doc.cancelActivePipeline(redactionState: redaction)
            }

            #expect(doc.wasPausedByBackground && doc.phaseKind == .editing, "\(route)")
            #expect(doc.pausedFromPhase == .redacting, "\(route)")
        }
    }

    @Test("A full run's start clears the pause")
    func testFullRunStartClearsThePause() {
        let coord = makeLoadedCoordinator()
        coord.redactionState.addRegion(
            RedactionRegion(id: UUID(), normalizedRect: .init(x: 0.10, y: 0.10, width: 0.05, height: 0.02),
                            source: .manual),
            page: 0, undoManager: nil)
        coord.documentState.wasPausedByBackground = true
        coord.documentState.pausedFromPhase = .redacting

        coord.runFullPipeline(documentOverride: nil)
        defer { coord.documentState.cancelActivePipeline(redactionState: coord.redactionState) }

        #expect(coord.documentState.activePipelineTask != nil, "the run started")
        #expect(coord.documentState.wasPausedByBackground == false)
        #expect(coord.documentState.pausedFromPhase == nil)
    }

    /// Each refusal the run's check returns, set up in state while editing.
    enum RefusedRunRow: CaseIterable {
        case selectedMatches
        case noRegions
        case busy
    }

    @Test("A refused run leaves the pause as it was")
    func testRefusedRunLeavesThePause() {
        #expect(RefusedRunRow.allCases.count == 3)
        for row in RefusedRunRow.allCases {
            let coord = makeLoadedCoordinator()
            let doc = coord.documentState
            let redaction = coord.redactionState
            let expected: DocumentState.RedactRefusal
            switch row {
            case .selectedMatches:
                let search = SearchState(defaults: makeScratchDefaults().0)
                search.results = [SearchResult(
                    pageIndex: 0, normalizedRect: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.03),
                    matchedText: "alpha", contextSnippet: "…alpha…", source: .textLayer, term: "alpha",
                    isSelected: true)]
                redaction.activeSearch = search
                expected = .selectedMatches
            case .noRegions:
                expected = .noRegions
            case .busy:
                redaction.addRegion(
                    RedactionRegion(id: UUID(), normalizedRect: .init(x: 0.10, y: 0.10, width: 0.05, height: 0.02),
                                    source: .manual),
                    page: 0, undoManager: nil)
                doc.activePipelineTask = Task {}
                expected = .busy
            }
            doc.wasPausedByBackground = true
            doc.pausedFromPhase = .redacting
            #expect(doc.phaseKind == .editing, "\(row)")
            #expect(doc.redactRefusal(with: redaction) == expected, "\(row)")
            let heldTask = doc.activePipelineTask

            coord.runFullPipeline(documentOverride: nil)

            #expect(doc.activePipelineTask == heldTask, "\(row): no run started")
            #expect(doc.wasPausedByBackground == true, "\(row)")
            #expect(doc.pausedFromPhase == .redacting, "\(row)")
            doc.activePipelineTask = nil
        }
    }
}
