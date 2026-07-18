import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// VerificationReport.skipReason — producer → display mapping.
//
// A skipped report used to be a single sentinel, and the display copy
// asserted one cause ("verification is turned off") for every producer —
// including user cancellation and verification errors. The report now
// carries a SkipReason; these tests pin each producer's reason and the
// reason-specific masthead copy.
@Suite("VerificationReport.skipReason", .tags(.coordination))
@MainActor
struct VerificationSkipReasonTests {

    // MARK: - Model

    @Test("Static .skipped sentinel carries .autoVerifyOff")
    func sentinelCarriesAutoVerifyOff() {
        #expect(VerificationReport.skipped.skipReason == .autoVerifyOff)
        #expect(VerificationReport.skipped.overallStatus == .skipped)
    }

    @Test("skipped(reason:) factory carries the requested reason",
          arguments: [
            VerificationReport.SkipReason.autoVerifyOff,
            .cancelled,
            .error,
          ])
    func factoryCarriesReason(reason: VerificationReport.SkipReason) {
        let report = VerificationReport.skipped(reason: reason)
        #expect(report.skipReason == reason)
        #expect(report.overallStatus == .skipped)
        #expect(report.layers.isEmpty)
    }

    @Test("Memberwise init defaults skipReason to .autoVerifyOff")
    func memberwiseInitDefault() {
        let report = VerificationReport(
            layers: [], overallStatus: .pass, durationSeconds: 0)
        #expect(report.skipReason == .autoVerifyOff)
    }

    // MARK: - Producer mapping

    @Test("autoVerify-off full run lands on .skipped with .autoVerifyOff")
    func autoVerifyOffRunMapsToAutoVerifyOff() async throws {
        cleanSettingsDefaults()
        defer { cleanSettingsDefaults() }

        let coord = makeLoadedCoordinator()
        coord.settingsState.paranoidMode = false
        coord.settingsState.autoVerify = false
        addRegion(to: coord)

        coord.runFullPipeline(documentOverride: .secureRasterization)
        let task = coord.documentState.activePipelineTask
        _ = await task?.value

        // Poll briefly — the terminal transition lands on MainActor after
        // the Task body resolves.
        for _ in 0..<300 {
            if case .verified = coord.documentState.phase { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        guard case .verified(let report) = coord.documentState.phase else {
            Issue.record("Expected .verified after an autoVerify-off run, got \(coord.documentState.phaseKind)")
            return
        }
        #expect(report.overallStatus == .skipped)
        #expect(report.skipReason == .autoVerifyOff,
                "The verify-or-skip arm keeps the autoVerifyOff sentinel")
    }

    @Test("Verify-only run with an unloadable output lands on .skipped(.error)")
    func verifyErrorMapsToErrorReason() async throws {
        let coord = makeLoadedCoordinator()
        // A path with no file behind it: the off-main document load in
        // runVerification throws, driving the .failed transition whose
        // returnPhase is the skipped report under test.
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skipreason_missing_\(UUID().uuidString).pdf")
        coord.redactionState.outputURL = missingURL
        // Mirror the real verify-only entry posture (see
        // PipelineCoordinatorRestartRaceTests — editing → verifying is not
        // a legal transition).
        coord.documentState.phase = .verified(report: .skipped)

        coord.runVerifyOnly()
        let task = coord.documentState.activePipelineTask
        _ = await task?.value

        for _ in 0..<300 {
            if case .failed = coord.documentState.phase { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        guard case .failed(_, let returnPhase) = coord.documentState.phase,
              case .verified(let report) = returnPhase else {
            Issue.record("Expected .failed with a .verified returnPhase, got \(coord.documentState.phaseKind)")
            return
        }
        #expect(report.overallStatus == .skipped)
        #expect(report.skipReason == .error,
                "Verification failure paths must carry .error, not the autoVerifyOff default")
    }

    // The cancel-mid-verify producer (user Stop and backgrounding share the
    // `.verifying` arm of cancelActivePipeline) is pinned to `.cancelled`
    // in DocumentStateVerifyingCancelTests alongside the existing
    // phase-transition assertions.

    // MARK: - Display

    @Test("skippedSubtitle names the real cause per reason")
    func skippedSubtitleVariants() {
        #expect(VerificationResultsView.skippedSubtitle(reason: .autoVerifyOff)
                == "Verification is turned off in Settings. Run Redact again with verification on, or share unverified.")
        #expect(VerificationResultsView.skippedSubtitle(reason: .cancelled)
                == "Verification was stopped before it finished. Run it again before sharing.")
        #expect(VerificationResultsView.skippedSubtitle(reason: .error)
                == "Verification could not be completed. Run it again before sharing.")
    }

    @Test("Masthead a11y label is reason-specific for skipped reports",
          arguments: [
            VerificationReport.SkipReason.autoVerifyOff,
            .cancelled,
            .error,
          ])
    func mastheadAccessibilityLabelSkipped(reason: VerificationReport.SkipReason) {
        let label = VerificationResultsView.mastheadAccessibilityLabel(
            report: .skipped(reason: reason))
        #expect(label.contains(VerificationResultsView.skippedSubtitle(reason: reason)),
                "Skipped masthead a11y label must carry the same variant as the visible subtitle")
    }

    @Test("Masthead a11y label keeps the status-level label for non-skipped reports")
    func mastheadAccessibilityLabelNonSkipped() {
        let report = VerificationReport(
            layers: [], overallStatus: .pass, durationSeconds: 0)
        #expect(VerificationResultsView.mastheadAccessibilityLabel(report: report)
                == VerificationStatus.pass.accessibilityLabel)
    }

    @Test("No outcome-promise language in the reason-specific strings",
          arguments: [
            VerificationReport.SkipReason.autoVerifyOff,
            .cancelled,
            .error,
          ])
    func noOutcomePromiseLanguage(reason: VerificationReport.SkipReason) {
        let bannedWords = ["guaranteed", "ensures", "impossible", "guarantee", "ensure"] // LegalPhrases:safe (test data — the ban list itself)
        let allText = [
            VerificationResultsView.skippedSubtitle(reason: reason),
            VerificationResultsView.mastheadAccessibilityLabel(
                report: .skipped(reason: reason)),
        ].joined(separator: " ").lowercased()
        for word in bannedWords {
            #expect(!allText.contains(word),
                    "Skipped display text for \(reason) contains banned word '\(word)' (ARCH §1.3)")
        }
    }

    // VF-12: a skipped sentinel has no layer results — the details
    // disclosure ("0 of 0 checks passed", expanding to nothing) and the
    // timing footer ("0 checks") described a run that never happened.
    // One gate hides both mounts.
    @Test("Run breakdown is hidden on the skipped sentinel",
          arguments: [
            VerificationReport.SkipReason.autoVerifyOff,
            .cancelled,
            .error,
          ])
    func runBreakdownHiddenWhenNoLayersRan(reason: VerificationReport.SkipReason) {
        let shown = VerificationResultsView.shouldShowRunBreakdown(
            report: .skipped(reason: reason))
        #expect(shown == false,
                "No layers ran — there is no run breakdown to describe")
    }

    @Test("Run breakdown shows whenever layer results exist")
    func runBreakdownShownWithLayers() {
        let layer = LayerResult(
            name: "Test Layer",
            symbolName: "checkmark.shield",
            status: .pass,
            shortDescription: "test layer",
            detailDescription: "test layer detail",
            pageReferences: nil,
            durationSeconds: 0)
        let report = VerificationReport(
            layers: [layer], overallStatus: .pass, durationSeconds: 1)
        #expect(VerificationResultsView.shouldShowRunBreakdown(report: report))
    }

    // MARK: - Helpers

    private func cleanSettingsDefaults() {
        let keys = [
            "paranoidMode", "autoVerify", "pipelineMode.v2",
            "exportDPI", "fillColor",
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func makeLoadedCoordinator() -> PipelineCoordinator {
        let coord = PipelineCoordinator(
            documentState: DocumentState(),
            redactionState: RedactionState(),
            settingsState: SettingsState())
        coord.documentState.sourceDocument = makeTestPDFDocument()
        coord.documentState.phase = .editing
        return coord
    }

    private func addRegion(to coord: PipelineCoordinator) {
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.05),
            source: .manual)
        coord.redactionState.addRegion(region, page: 0, undoManager: nil)
    }
}
