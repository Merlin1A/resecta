import Testing
import Foundation
@testable import ResectaApp
import RedactionEngine

// VF-16 — honesty surfaces at the share decision.
//
// Three pinned contracts:
//
//   1. The legally reviewed HonestyDisclaimer (`.redacted` profile) mounts
//      on the verification results screen for EVERY verdict state — it
//      previously had zero production call sites, so no surface named the
//      checks' epistemic limits where the share decision is made.
//   2. The redacted-output preview carries an in-context verdict cue
//      (nav-bar capsule) exactly for FAIL and SKIPPED reports — preview
//      availability itself stays decoupled from the verdict (#217).
//   3. FailedStateView's primary action is keyed on
//      `PipelineError.isRecoverable` in addition to the return phase —
//      retry-style primaries appear only for recoverable error classes,
//      with the import-while-editing go-back carve-out.
//
// Predicate-level posture per repo convention: building a SwiftUI host is
// neither possible nor needed on this machine; the static helpers are the
// single source of truth. The mount itself is pinned by a source scan
// (LegalKeyExistenceTests / TransparencyClaimsTests #filePath loader posture).

@Suite("Honesty disclaimer mount gate")
@MainActor
struct HonestyDisclaimerMountTests {

    @Test("Disclaimer shows on PASS and FAIL fixtures")
    func showsOnPassAndFail() {
        let onPass = VerificationResultsView.shouldShowHonestyDisclaimer(
            overallStatus: .pass)
        let onFail = VerificationResultsView.shouldShowHonestyDisclaimer(
            overallStatus: .fail("x"))
        #expect(onPass == true)
        #expect(onFail == true)
    }

    @Test("Disclaimer shows on every verdict state — no dismissal, no gating")
    func showsOnEveryStatus() {
        let statuses: [VerificationStatus] =
            [.pass, .warn("w"), .info("i"), .fail("x"), .skipped]
        for status in statuses {
            let shown = VerificationResultsView.shouldShowHonestyDisclaimer(
                overallStatus: status)
            #expect(shown == true,
                    "disclaimer must mount for \(status) — always visible, never removable")
        }
    }

    @Test("Results view mounts the .redacted-profile disclaimer (source pin)")
    func resultsViewMountsRedactedProfile() throws {
        let source = try loadRepoFile(
            "Sources/ResectaApp/Views/VerificationResultsView.swift")
        // The mount must use the `.redacted` profile — the `.unredacted`
        // default carries the audit-dashboard wording, not the
        // post-redaction scope-limitation wording this surface needs.
        #expect(source.contains("HonestyDisclaimer(profile: .redacted"),
                "VerificationResultsView must mount HonestyDisclaimer with the .redacted profile")
        #expect(source.contains("shouldShowHonestyDisclaimer("),
                "the mount must route through the tested gate")
    }

    private func loadRepoFile(
        _ relativePath: String, from file: StaticString = #filePath
    ) throws -> String {
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }
}

@Suite("Preview verdict capsule")
@MainActor
struct PreviewVerdictCapsuleTests {

    @Test("FAIL verdict shows the review-before-sharing capsule")
    func failShowsCapsule() {
        let text = RedactedPreviewView.verdictCapsuleText(verdict: .fail("x"))
        #expect(text == "Issues Found — review before sharing")
    }

    @Test("SKIPPED verdict shows the not-verified capsule")
    func skippedShowsCapsule() {
        let text = RedactedPreviewView.verdictCapsuleText(verdict: .skipped)
        #expect(text == "Not verified")
    }

    @Test("ATTENTION verdict shows the review-before-sharing capsule")
    func attentionShowsCapsule() {
        let text = RedactedPreviewView.verdictCapsuleText(verdict: .attention("x"))
        #expect(text == "Attention needed — review before sharing")
    }

    @Test("PASS / WARN / INFO verdicts show no capsule")
    func passWarnInfoShowNothing() {
        let onPass = RedactedPreviewView.verdictCapsuleText(verdict: .pass)
        let onWarn = RedactedPreviewView.verdictCapsuleText(verdict: .warn("w"))
        let onInfo = RedactedPreviewView.verdictCapsuleText(verdict: .info("i"))
        #expect(onPass == nil)
        #expect(onWarn == nil)
        #expect(onInfo == nil)
    }

    @Test("No verdict threaded (default init) shows no capsule")
    func nilVerdictShowsNothing() {
        let text = RedactedPreviewView.verdictCapsuleText(verdict: nil)
        #expect(text == nil)
    }
}

@Suite("FailedStateView primary action vs isRecoverable")
@MainActor
struct FailedStatePrimaryActionTests {

    private typealias Action = FailedStateView.PrimaryAction

    // MARK: - .empty return phase

    @Test("filePurged + .empty → Re-open Document (KI-4, recoverable)")
    func filePurgedEmptyReopens() {
        let action = FailedStateView.primaryAction(
            error: .exportError(.filePurged), returnPhase: .empty)
        #expect(action == Action.reopenDocument)
    }

    @Test("Non-recoverable import failure + .empty → Choose Another File")
    func corruptImportEmptyChoosesAnother() {
        let action = FailedStateView.primaryAction(
            error: .importError(.corrupt), returnPhase: .empty)
        #expect(action == Action.chooseAnotherFile)
    }

    // MARK: - .editing return phase

    @Test("Import failure + .editing → Return to Editor (go-back carve-out, not a retry)")
    func importWhileEditingReturnsToEditor() {
        // Import-while-editing: the editor still holds the PREVIOUS,
        // valid document. Returning is a go-back, so the non-recoverable
        // import class keeps it (deliberate current UX, noted in VF-16).
        let action = FailedStateView.primaryAction(
            error: .importError(.corrupt), returnPhase: .editing)
        #expect(action == Action.returnToEditor)
    }

    @Test("Recoverable pipeline failure + .editing → Return to Editor")
    func recoverablePipelineFailureReturnsToEditor() {
        let action = FailedStateView.primaryAction(
            error: .redactionError(.reconstructionFailed), returnPhase: .editing)
        #expect(action == Action.returnToEditor)
    }

    @Test("Non-recoverable non-import failure + .editing → Choose Another File")
    func diskFullEditingChoosesAnother() {
        // diskFull needs storage freed outside the app — a "Return to
        // Editor" retry loop is dishonest. Defensive today (no production
        // site pairs diskFull with .editing) but the wiring holds.
        let action = FailedStateView.primaryAction(
            error: .exportError(.diskFull), returnPhase: .editing)
        #expect(action == Action.chooseAnotherFile)
    }

    // MARK: - .verified return phase

    @Test("Recoverable export failure + .verified → Return to Results")
    func writeFailedVerifiedReturnsToResults() {
        let action = FailedStateView.primaryAction(
            error: .exportError(.writeFailed),
            returnPhase: .verified(report: .skipped(reason: .error)))
        #expect(action == Action.returnToResults)
    }

    @Test("Non-recoverable failure + .verified → Choose Another File")
    func diskFullVerifiedChoosesAnother() {
        let action = FailedStateView.primaryAction(
            error: .exportError(.diskFull),
            returnPhase: .verified(report: .skipped(reason: .error)))
        #expect(action == Action.chooseAnotherFile)
    }

    // MARK: - Matrix invariant

    @Test("Retry-style primaries are offered only for recoverable errors (import carve-out aside)")
    func retryStyleImpliesRecoverable() {
        let errors: [PipelineError] = [
            .importError(.corrupt),
            .importError(.passwordProtected),
            .detectionError(.ocrUnavailable),
            .redactionError(.reconstructionFailed),
            .verificationError(.engineCrash(layerIndex: 0)),
            .exportError(.diskFull),
            .exportError(.writeFailed),
            .exportError(.filePurged),
        ]
        let phases: [DocumentState.ReturnPhase] = [
            .empty, .editing, .verified(report: .skipped(reason: .error)),
        ]
        for error in errors {
            // The carve-out class: import-while-editing is a go-back.
            if case .importError = error { continue }
            for phase in phases {
                let action = FailedStateView.primaryAction(
                    error: error, returnPhase: phase)
                let isRetryStyle = action == Action.reopenDocument
                    || action == Action.returnToEditor
                    || action == Action.returnToResults
                if isRetryStyle {
                    #expect(error.isRecoverable == true,
                            "\(error) offered a retry-style primary while non-recoverable")
                }
            }
        }
    }
}
