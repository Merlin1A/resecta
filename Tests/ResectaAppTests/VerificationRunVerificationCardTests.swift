import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// Results-screen recovery — copy, retention, and re-verify honesty.
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

    @Test("One card body for every skip reason; the masthead carries the reason")
    func cardBody() {
        #expect(VerificationResultsView.runVerificationCardBodyText
                == "Run the checks on the redacted PDF before you share it.")
    }

    @Test("No outcome-promise language in the card strings and the skipped row's caption")
    func noOutcomePromiseLanguage() {
        let bannedWords = ["guaranteed", "ensures", "impossible", "guarantee", "ensure"] // LegalPhrases:safe (test data — the ban list itself)
        let allText = [
            VerificationResultsView.runVerificationCardBodyText,
            VerificationRowModel.skippedCaption,
            VerificationRowModel.skippedLead,
        ].joined(separator: " ").lowercased()
        for word in bannedWords {
            #expect(!allText.contains(word),
                    "Display text contains banned word '\(word)'")
        }
    }

    // MARK: - Masthead skip-induced WARN arm

    @Test("Skip-induced WARN masthead names the step that includes the skipped checks")
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
                == "Run Redact with Verify Before Export on to include the skipped checks.")
        #expect(VerificationResultsView.mastheadTitle(report: report) == "Some Checks Incomplete")
    }

    @Test("Warn-layer WARN masthead points at the warning")
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
                == "Read the warning below before you share the PDF.")
        #expect(VerificationResultsView.mastheadTitle(report: report) == "Completed with\u{00A0}Warnings")
    }

    @Test("WARN with both warn and skipped layers is decided by the could-not-verify rows")
    func mastheadWarnWithSkips() {
        // The could-not-verify rows decide, never the warnings: every one
        // of them is skipped, so the sentence names the step.
        let report = VerificationReport(
            layers: [
                makeLayer(name: "Check A", status: .warn("noise")),
                makeLayer(name: "Check B", status: .skipped),
            ],
            overallStatus: .warn("noise"),
            durationSeconds: 0.5
        )
        #expect(VerificationResultsView.mastheadSubtitle(report: report)
                == "Run Redact with Verify Before Export on to include the skipped check.")
    }

    // MARK: - RedactionState retention lifecycle

    @Test("recordLastRunInputs retains; clearOutput clears")
    func retentionClearedWithOutput() {
        let redaction = RedactionState()
        #expect(redaction.lastRunInputs == nil)

        redaction.recordLastRunInputs(.fixture(
            perPageModes: [.searchableRedaction, .secureRasterization],
            perPageFallbackReasons: [nil, .rtlText],
            sensitiveTerms: [SensitiveTerm(text: "Delia Hartwell")]))
        #expect(redaction.lastRunInputs?.perPageModes == [.searchableRedaction, .secureRasterization])
        #expect(redaction.lastRunInputs?.perPageFallbackReasons == [nil, .rtlText])
        #expect(redaction.lastRunInputs?.sensitiveTerms.terms == [SensitiveTerm(text: "Delia Hartwell")])

        redaction.clearOutput()
        #expect(redaction.lastRunInputs == nil,
                "Discarding the output must drop the run inputs that describe it")
    }

    @Test("clearForNewDocument clears the retained run inputs")
    func retentionClearedOnNewDocument() {
        let redaction = RedactionState()
        redaction.recordLastRunInputs(.fixture(
            perPageModes: [.secureRasterization],
            sensitiveTerms: [SensitiveTerm(text: "Delia Hartwell")]))
        redaction.clearForNewDocument()
        #expect(redaction.lastRunInputs == nil)
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
        // The reason record rides beside the mode record — page 1
        // fell back with a recorded trigger.
        let originalReasons: [TextLayerDetector.FallbackReason?] =
            [nil, .unresolvedEncoding]
        redactionState.recordLastRunInputs(.fixture(
            perPageModes: originalModes,
            perPageFallbackReasons: originalReasons))
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
                "Re-verify must carry the original run's fallback-reason record")
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

        redactionState.recordLastRunInputs(.fixture(
            perPageModes: [.secureRasterization],
            sensitiveTerms: [SensitiveTerm(text: "Delia Hartwell")]))
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
