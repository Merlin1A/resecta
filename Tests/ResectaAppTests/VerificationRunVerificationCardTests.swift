import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// CANCEL-009 results-screen recovery — copy, retention, and re-verify honesty.
//
// Covers the Run Verification card's reason-specific copy, the skip-induced
// WARN masthead arm, the skipped-checks footnote gate, and the verify-only
// input retention: a re-verify must check the terms the artifact was built
// with and report the original run's per-page modes, not re-synthesized
// stand-ins. Card mount/routing predicates live in
// DocumentEditorViewBackgroundBannerTests.
@Suite("Verification Run-Verification card & re-verify input retention")
@MainActor
struct VerificationRunVerificationCardTests {

    // MARK: - Card copy

    @Test("Card body copy is neutral for autoVerifyOff")
    func cardBodyAutoVerifyOff() {
        #expect(VerificationResultsView.runVerificationCardBodyText(reason: .autoVerifyOff)
                == "Runs the post-redaction checks on this output.")
    }

    @Test("Card body copy carries urgency for cancelled and error",
          arguments: [VerificationReport.SkipReason.cancelled, .error])
    func cardBodyInterrupted(reason: VerificationReport.SkipReason) {
        #expect(VerificationResultsView.runVerificationCardBodyText(reason: reason)
                == "Verification did not finish — run the checks on this output before sharing.")
    }

    @Test("No outcome-promise language in the card and footnote strings")
    func noOutcomePromiseLanguage() {
        let bannedWords = ["guaranteed", "ensures", "impossible", "guarantee", "ensure"] // LegalPhrases:safe (test data — the ban list itself)
        let allText = [
            VerificationResultsView.runVerificationCardBodyText(reason: .autoVerifyOff),
            VerificationResultsView.runVerificationCardBodyText(reason: .cancelled),
            VerificationResultsView.skippedChecksFootnoteText,
        ].joined(separator: " ").lowercased()
        for word in bannedWords {
            #expect(!allText.contains(word),
                    "Display text contains banned word '\(word)' (ARCH §1.3)")
        }
    }

    // MARK: - Masthead skip-induced WARN arm

    @Test("Skip-induced WARN masthead names the skips, not zero notes")
    func mastheadSkipInducedWarn() {
        let report = VerificationReport(
            layers: [
                makeLayer(name: "Check A", status: .pass),
                makeLayer(name: "Check B", status: .skipped),
                makeLayer(name: "Check C", status: .skipped),
            ],
            overallStatus: .warn("Some verification checks were skipped — results may be incomplete"),
            durationSeconds: 0.5
        )
        #expect(VerificationResultsView.mastheadSubtitle(report: report)
                == "Completed with 2 of 3 checks skipped — results may be incomplete.")
    }

    @Test("Warn-layer WARN masthead is unchanged")
    func mastheadWarnLayerWarn() {
        let report = VerificationReport(
            layers: [
                makeLayer(name: "Check A", status: .pass),
                makeLayer(name: "Check B", status: .warn("noise")),
            ],
            overallStatus: .warn("noise"),
            durationSeconds: 0.5
        )
        #expect(VerificationResultsView.mastheadSubtitle(report: report)
                == "Verification completed with 1 note. Review below before sharing.")
    }

    @Test("WARN with both warn and skipped layers keeps the note-count copy")
    func mastheadWarnWithSkips() {
        // A real WARN layer takes precedence — the skip arm applies only
        // when NO row backs up a note count.
        let report = VerificationReport(
            layers: [
                makeLayer(name: "Check A", status: .warn("noise")),
                makeLayer(name: "Check B", status: .skipped),
            ],
            overallStatus: .warn("noise"),
            durationSeconds: 0.5
        )
        #expect(VerificationResultsView.mastheadSubtitle(report: report)
                == "Verification completed with 1 note. Review below before sharing.")
    }

    // MARK: - Skipped-checks footnote gate

    @Test("Footnote shows for a WARN report with a skipped layer")
    func footnoteShowsForSkipInducedWarn() {
        let report = VerificationReport(
            layers: [makeLayer(name: "Check B", status: .skipped)],
            overallStatus: .warn("skips"),
            durationSeconds: 0.1
        )
        #expect(VerificationResultsView.shouldShowSkippedChecksFootnote(report: report) == true)
    }

    @Test("Footnote hidden when no layer is skipped")
    func footnoteHiddenWithoutSkips() {
        let report = VerificationReport(
            layers: [makeLayer(name: "Check A", status: .warn("noise"))],
            overallStatus: .warn("noise"),
            durationSeconds: 0.1
        )
        #expect(VerificationResultsView.shouldShowSkippedChecksFootnote(report: report) == false)
    }

    @Test("Footnote hidden on a PASS report even with a skipped layer")
    func footnoteHiddenOnPass() {
        // Defensive: the aggregate never passes with skips (CAT-373), but
        // the gate must not rely on that invariant alone.
        let report = VerificationReport(
            layers: [makeLayer(name: "Check B", status: .skipped)],
            overallStatus: .pass,
            durationSeconds: 0.1
        )
        #expect(VerificationResultsView.shouldShowSkippedChecksFootnote(report: report) == false)
    }

    @Test("Footnote hidden on the empty skipped sentinel")
    func footnoteHiddenOnSentinel() {
        // The sentinel has no layers — nothing ran, so there is no
        // skipped-row copy to correct; the masthead subtitle carries the
        // reason instead.
        #expect(VerificationResultsView.shouldShowSkippedChecksFootnote(report: .skipped) == false)
    }

    // MARK: - RedactionState retention lifecycle

    @Test("recordLastRunInputs retains; clearOutput clears")
    func retentionClearedWithOutput() {
        let redaction = RedactionState()
        #expect(redaction.lastRunPerPageModes == nil)
        #expect(redaction.lastRunPerPageFallbackReasons == nil)
        #expect(redaction.lastRunSensitiveTerms == nil)

        redaction.recordLastRunInputs(
            perPageModes: [.searchableRedaction, .secureRasterization],
            perPageFallbackReasons: [nil, .rtlText],
            sensitiveTerms: [SensitiveTerm(text: "Delia Hartwell")])
        #expect(redaction.lastRunPerPageModes == [.searchableRedaction, .secureRasterization])
        #expect(redaction.lastRunPerPageFallbackReasons == [nil, .rtlText])
        #expect(redaction.lastRunSensitiveTerms == [SensitiveTerm(text: "Delia Hartwell")])

        redaction.clearOutput()
        #expect(redaction.lastRunPerPageModes == nil,
                "Discarding the output must drop the run inputs that describe it")
        #expect(redaction.lastRunPerPageFallbackReasons == nil)
        #expect(redaction.lastRunSensitiveTerms == nil)
    }

    @Test("clearForNewDocument clears the retained run inputs")
    func retentionClearedOnNewDocument() {
        let redaction = RedactionState()
        redaction.recordLastRunInputs(
            perPageModes: [.secureRasterization],
            perPageFallbackReasons: [nil],
            sensitiveTerms: [SensitiveTerm(text: "Delia Hartwell")])
        redaction.clearForNewDocument()
        #expect(redaction.lastRunPerPageModes == nil)
        #expect(redaction.lastRunPerPageFallbackReasons == nil)
        #expect(redaction.lastRunSensitiveTerms == nil)
    }

    // MARK: - Verify-only input retention (end to end)

    @Test("Re-verify reports the ORIGINAL run's per-page modes, not a uniform synthesis")
    func reVerifyKeepsMixedModeRecord() async throws {
        let coordinator = makeCoordinator()
        let documentState = coordinator.documentState
        let redactionState = coordinator.redactionState

        documentState.sourceDocument = makeMultiPagePDFDocument(pages: 2)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vf07_modes_\(UUID().uuidString).pdf")
        try makeMultiPagePDFData(pages: 2).write(to: outputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        redactionState.outputURL = outputURL

        // The original (mixed) run: page 0 kept searchable mode, page 1
        // fell back to rasterization. A uniform re-synthesis would erase
        // the fallback record from the results Page-Modes chips.
        let originalModes: [PipelineMode] = [.searchableRedaction, .secureRasterization]
        // PD-5: the reason record rides beside the mode record — page 1
        // fell back with a recorded trigger.
        let originalReasons: [TextLayerDetector.FallbackReason?] =
            [nil, .unresolvedEncoding]
        redactionState.recordLastRunInputs(
            perPageModes: originalModes,
            perPageFallbackReasons: originalReasons,
            sensitiveTerms: [])
        documentState.lastUsedPipelineMode = .secureRasterization
        documentState.phase = .verified(report: .skipped)

        coordinator.runVerifyOnly()
        await documentState.activePipelineTask?.value

        guard case .verified(let report) = documentState.phase else {
            Issue.record("Expected .verified after verify-only, got \(documentState.phaseKind)")
            return
        }
        #expect(report.perPageModes == originalModes,
                "Re-verify must carry the original run's per-page mode record")
        #expect(report.perPageFallbackReasons == originalReasons,
                "Re-verify must carry the original run's fallback-reason record (PD-5)")
    }

    @Test("Re-verify checks the ORIGINAL run's term snapshot, not re-collected terms")
    func reVerifyUsesTermSnapshot() async throws {
        // Output PDF whose decoded page text contains the snapshot term.
        // The current session has NO applied regions, so a re-collection
        // would yield an empty term set and Layer 3 would report INFO
        // ("no terms provided"). Only the retained snapshot makes Layer 3
        // search — and flag — the term the artifact was built with.
        let coordinator = makeCoordinator()
        let documentState = coordinator.documentState
        let redactionState = coordinator.redactionState

        documentState.sourceDocument = makeTextPDFDocument(
            text: "Statement for Delia Hartwell")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vf07_terms_\(UUID().uuidString).pdf")
        try makeTextPDFData(text: "Statement for Delia Hartwell").write(to: outputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        redactionState.outputURL = outputURL

        redactionState.recordLastRunInputs(
            perPageModes: [.secureRasterization],
            perPageFallbackReasons: [nil],
            sensitiveTerms: [SensitiveTerm(text: "Delia Hartwell")])
        documentState.lastUsedPipelineMode = .secureRasterization
        documentState.phase = .verified(report: .skipped)

        coordinator.runVerifyOnly()
        await documentState.activePipelineTask?.value

        guard case .verified(let report) = documentState.phase else {
            Issue.record("Expected .verified after verify-only, got \(documentState.phaseKind)")
            return
        }
        let sensitiveHit = report.layers.contains {
            if case .attention(let message) = $0.status {
                return message.contains("still readable")
            }
            return false
        }
        #expect(sensitiveHit,
                "The string-search layer must flag the snapshot term left in the output")
    }

    @Test("Without retained inputs the re-verify falls back to re-collection")
    func reVerifyFallsBackWithoutRetention() async throws {
        // Same fixture as above but nothing retained (resumed old session):
        // no applied regions → empty collected terms → no sensitive-string
        // FAIL. Pins the fallback leg so retention stays an enhancement,
        // not a requirement.
        let coordinator = makeCoordinator()
        let documentState = coordinator.documentState
        let redactionState = coordinator.redactionState

        documentState.sourceDocument = makeTextPDFDocument(
            text: "Statement for Delia Hartwell")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vf07_fallback_\(UUID().uuidString).pdf")
        try makeTextPDFData(text: "Statement for Delia Hartwell").write(to: outputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        redactionState.outputURL = outputURL

        documentState.lastUsedPipelineMode = .secureRasterization
        documentState.phase = .verified(report: .skipped)

        coordinator.runVerifyOnly()
        await documentState.activePipelineTask?.value

        guard case .verified(let report) = documentState.phase else {
            Issue.record("Expected .verified after verify-only, got \(documentState.phaseKind)")
            return
        }
        let sensitiveHit = report.layers.contains {
            if case .fail(let message) = $0.status {
                return message.contains("Sensitive")
            }
            return false
        }
        #expect(!sensitiveHit,
                "With no snapshot and no regions there is no term set to flag")
        // The fallback also synthesizes a uniform mode array sized to the
        // document.
        #expect(report.perPageModes == [.secureRasterization])
    }

    // MARK: - Helpers

    private func makeLayer(name: String, status: VerificationStatus) -> LayerResult {
        LayerResult(
            name: name,
            symbolName: "checkmark.shield",
            status: status,
            shortDescription: "test layer",
            detailDescription: "test layer detail",
            pageReferences: nil,
            durationSeconds: 0
        )
    }
}
