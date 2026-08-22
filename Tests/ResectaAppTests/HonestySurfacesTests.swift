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

    // UXC-15 (RB-43): placement-only re-weight — PASS mounts the honesty
    // disclaimer + non-visual limit line beneath the masthead instead of
    // at the bottom; every other verdict keeps the bottom mount.
    @Test("shouldMountLimitBlockBeneathMasthead: true for PASS, false for every other status")
    func mountLimitBlockBeneathMastheadTable() {
        #expect(VerificationResultsView.shouldMountLimitBlockBeneathMasthead(
            overallStatus: .pass) == true)
        let bottomMounted: [VerificationStatus] =
            [.warn("w"), .info("i"), .attention("a"), .fail("x"), .skipped]
        for status in bottomMounted {
            #expect(VerificationResultsView.shouldMountLimitBlockBeneathMasthead(
                overallStatus: status) == false,
                    "\(status) must keep the bottom mount, not the beneath-masthead one")
        }
    }

    @Test("Results view mounts the .redacted-profile disclaimer (source pin)")
    func resultsViewMountsRedactedProfile() throws {
        let source = try loadRepoFile(
            "Sources/ResectaApp/Views/VerificationResultsView.swift")
        // The mount must use the `.redacted` profile — `.unredacted`
        // carries the audit-dashboard wording, not the
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

// RB-28/29/30 — the run-facts strip (UXC-04/05/06) and the non-visual
// review-limitation line (UXC-16).
//
// UXC-04: OCR pixel-cap skip pages snapshotted onto
// `RedactionState.DetectionRunRecord`, rendered as a pinned singular/
// plural builder using `SearchResultsSection.formatPageList`.
// UXC-05: no detection ran this session, yet a region was applied for
// this output.
// UXC-06: the degrade-failure list snapshotted onto the record at
// record time, rendered by reusing `DetectionDegradeCopy.banner`
// verbatim.
// UXC-16: a pinned line above the honesty disclaimer, reused as the
// `RedactedPreviewView` verdict capsule's accessibility label.

@Suite("Run-facts strip (UXC-04/05/06) + non-visual limit line (UXC-16)")
@MainActor
struct RunFactsStripTests {

    // MARK: - F-04 (UXC-04)

    @Test("F-04 singular exact text — 0-indexed page 6 renders as Page 7")
    func ocrSkipLineSingular() {
        let line = VerificationResultsView.RunFactsStrip.ocrSkipLine(pages: [6])
        #expect(line == "Page 7 was too large to scan for text, so its image content was not examined by detection. Review that page manually before sharing.")
    }

    @Test("F-04 plural exact text — pages sorted regardless of Set iteration order")
    func ocrSkipLinePlural() {
        let unordered: Set<Int> = [6, 2, 4]
        let line = VerificationResultsView.RunFactsStrip.ocrSkipLine(pages: Array(unordered))
        #expect(line == "Pages 3, 5, and 7 were too large to scan for text, so image content there was not examined by detection. Review those pages manually before sharing.")
    }

    // MARK: - F-05 (UXC-05)

    @Test("F-05 exact text")
    func detectionNeverRanExactText() {
        #expect(VerificationResultsView.RunFactsStrip.detectionNeverRanLine
                == "Automated detection did not run on this document. Every region here came from Search or manual marking — review each page for anything those did not cover before sharing.")
    }

    // MARK: - F-16 (UXC-16)

    @Test("F-16 exact text")
    func voiceOverLimitExactText() {
        #expect(VerificationResultsView.voiceOverLimitText
                == "The preview is a visual check — VoiceOver cannot tell you whether a region fully covers what is beneath it. A non-visual review can go page by page in the editor, where each page announces its region count and each region's details name the kind of item it covers.")
    }

    // MARK: - F-06 (UXC-06) — verbatim reuse

    @Test("F-06 equals DetectionDegradeCopy.banner verbatim on both branches")
    func degradeLineMatchesBannerVerbatim() {
        let nerOnly = [GazetteerLoadDiagnostics.Gazetteer.nerNameModel.rawValue]
        let corpus = ["NameGazetteer"]
        #expect(VerificationResultsView.RunFactsStrip.degradeLine(failedGazetteers: nerOnly)
                == DetectionDegradeCopy.banner(failedGazetteers: nerOnly))
        #expect(VerificationResultsView.RunFactsStrip.degradeLine(failedGazetteers: corpus)
                == DetectionDegradeCopy.banner(failedGazetteers: corpus))
    }

    // MARK: - RunFactsStrip.lines(for:) gating + order

    @Test("Empty facts render no strip")
    func linesEmptyFacts() {
        #expect(VerificationResultsView.RunFactsStrip
            .lines(for: VerificationResultsView.RunFacts()).isEmpty)
    }

    @Test("Each single fact renders exactly one line")
    func linesSingleFact() {
        let ocrOnly = VerificationResultsView.RunFacts(ocrSkippedPages: [0])
        #expect(VerificationResultsView.RunFactsStrip.lines(for: ocrOnly).count == 1)

        let neverRanOnly = VerificationResultsView.RunFacts(detectionNeverRan: true)
        #expect(VerificationResultsView.RunFactsStrip.lines(for: neverRanOnly).count == 1)

        let degradeOnly = VerificationResultsView.RunFacts(degradeFailures: ["NameGazetteer"])
        #expect(VerificationResultsView.RunFactsStrip.lines(for: degradeOnly).count == 1)
    }

    @Test("F-04 + F-06 render in order [F-04, F-06]")
    func linesOCRAndDegrade() {
        let facts = VerificationResultsView.RunFacts(
            ocrSkippedPages: [0], degradeFailures: ["NameGazetteer"])
        let lines = VerificationResultsView.RunFactsStrip.lines(for: facts)
        #expect(lines.count == 2)
        #expect(lines[0] == VerificationResultsView.RunFactsStrip.ocrSkipLine(pages: [0]))
        #expect(lines[1] == VerificationResultsView.RunFactsStrip
            .degradeLine(failedGazetteers: ["NameGazetteer"]))
    }

    @Test("F-05 + F-06 render in order [F-05, F-06]")
    func linesNeverRanAndDegrade() {
        let facts = VerificationResultsView.RunFacts(
            detectionNeverRan: true, degradeFailures: ["NameGazetteer"])
        let lines = VerificationResultsView.RunFactsStrip.lines(for: facts)
        #expect(lines.count == 2)
        #expect(lines[0] == VerificationResultsView.RunFactsStrip.detectionNeverRanLine)
        #expect(lines[1] == VerificationResultsView.RunFactsStrip
            .degradeLine(failedGazetteers: ["NameGazetteer"]))
    }

    // MARK: - RunFacts.derive predicate table

    @Test("derive: nil record + no applied regions → nothing")
    func deriveNilRecordNoRegions() {
        let facts = VerificationResultsView.RunFacts.derive(
            lastDetectionRun: nil, hasAppliedRegions: false)
        #expect(facts == VerificationResultsView.RunFacts())
    }

    @Test("derive: nil record + applied regions → detectionNeverRan only")
    func deriveNilRecordWithRegions() {
        let facts = VerificationResultsView.RunFacts.derive(
            lastDetectionRun: nil, hasAppliedRegions: true)
        #expect(facts.detectionNeverRan)
        #expect(facts.ocrSkippedPages.isEmpty)
        #expect(facts.degradeFailures == nil)
    }

    @Test("derive: record with skips carries them; detectionNeverRan false")
    func deriveRecordWithSkips() {
        let record = RedactionState.DetectionRunRecord(
            run: 1, outcome: .staged, scanSummary: nil, ocrSkippedPages: [2, 4])
        let facts = VerificationResultsView.RunFacts.derive(
            lastDetectionRun: record, hasAppliedRegions: true)
        #expect(facts.ocrSkippedPages == [2, 4])
        #expect(!facts.detectionNeverRan)
    }

    @Test("derive: record with degradeFailures carries them; without, nil")
    func deriveRecordDegrade() {
        let degraded = RedactionState.DetectionRunRecord(
            run: 1, outcome: .staged, scanSummary: nil,
            degradeFailures: ["NameGazetteer"])
        let clean = RedactionState.DetectionRunRecord(
            run: 2, outcome: .staged, scanSummary: nil)
        #expect(VerificationResultsView.RunFacts.derive(
            lastDetectionRun: degraded, hasAppliedRegions: true
        ).degradeFailures == ["NameGazetteer"])
        #expect(VerificationResultsView.RunFacts.derive(
            lastDetectionRun: clean, hasAppliedRegions: true
        ).degradeFailures == nil)
    }

    // MARK: - DetectionRunRecord lifecycle

    @Test("recordDetectionRun stores the passed ocrSkippedPages")
    func recordDetectionRunStoresOCRSkips() {
        let state = RedactionState()
        state.recordDetectionRun(.staged, ocrSkippedPages: [2, 4, 6])
        #expect(state.lastDetectionRun?.ocrSkippedPages == [2, 4, 6])
    }

    @Test("recordDetectionRun snapshots degradeFailures from self — nil when not degraded, carried when degraded")
    func recordDetectionRunSnapshotsDegrade() {
        let state = RedactionState()
        state.recordDetectionRun(.staged)
        #expect(state.lastDetectionRun?.degradeFailures == nil)

        state.autoDetectionDegraded = true
        state.autoDetectionDegradeFailures = ["NameGazetteer"]
        state.recordDetectionRun(.staged)
        #expect(state.lastDetectionRun?.degradeFailures == ["NameGazetteer"])
    }

    @Test("clearForNewDocument nils the record — the new fields ride along with it")
    func clearForNewDocumentNilsRecord() {
        let state = RedactionState()
        state.autoDetectionDegraded = true
        state.autoDetectionDegradeFailures = ["NameGazetteer"]
        state.recordDetectionRun(.staged, ocrSkippedPages: [1])
        #expect(state.lastDetectionRun != nil)

        state.clearForNewDocument()
        #expect(state.lastDetectionRun == nil)
    }

    // MARK: - Mechanism-only vocabulary, no percent sign

    @Test("run-facts strip + limit-line copy stays mechanism-only, no percent sign")
    func runFactsCopyIsMechanismOnly() {
        let samples = [
            VerificationResultsView.RunFactsStrip.ocrSkipLine(pages: [6]),
            VerificationResultsView.RunFactsStrip.ocrSkipLine(pages: [2, 4, 6]),
            VerificationResultsView.RunFactsStrip.detectionNeverRanLine,
            VerificationResultsView.RunFactsStrip.degradeLine(
                failedGazetteers: ["NameGazetteer"]),
            VerificationResultsView.RunFactsStrip.degradeLine(
                failedGazetteers: [GazetteerLoadDiagnostics.Gazetteer.nerNameModel.rawValue]),
            VerificationResultsView.voiceOverLimitText,
        ]
        // Forbidden absolutes assembled from halves so this source does
        // not itself trip the M-1 sweep (mirrors Q11TruthLegibilityTests
        // .subtitleIsMechanism).
        let halves: [(String, String)] = [
            ("guaran", "tee"), ("ens", "ure"), ("imposs", "ible"),
            ("fin", "d"), ("cat", "ch"), ("perfect", "ly"),
            ("flaw", "lessly"), ("10", "0%"),
        ]
        for sample in samples {
            let lower = sample.lowercased()
            #expect(!lower.contains("%"), "percent sign in: \(sample)")
            for (a, b) in halves {
                let phrase = a + b
                #expect(!lower.contains(phrase), "forbidden phrase '\(phrase)' in: \(sample)")
            }
        }
    }

    // MARK: - Source pin (mirrors HonestyDisclaimerMountTests.resultsViewMountsRedactedProfile)

    @Test("VerificationResultsView mounts runFactsStrip + voiceOverLimitLine; RedactedPreviewView references voiceOverLimitText")
    func sourcePinsForNewMounts() throws {
        let viewSource = try loadRepoFile(
            "Sources/ResectaApp/Views/VerificationResultsView.swift")
        #expect(viewSource.contains("runFactsStrip"),
                "VerificationResultsView must mount the run-facts strip")
        #expect(viewSource.contains("voiceOverLimitLine"),
                "VerificationResultsView must mount the non-visual limit line")

        let previewSource = try loadRepoFile(
            "Sources/ResectaApp/Views/RedactedPreviewView.swift")
        #expect(previewSource.contains("voiceOverLimitText"),
                "RedactedPreviewView must reference the shared UXC-16 copy")
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
