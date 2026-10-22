import Testing
import Foundation
@testable import ResectaApp
import RedactionEngine

// Honesty surfaces at the share decision.
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
            [.pass, .warn("w"), .info("i"), .fail("x"), .attention("a"), .skipped]
        for status in statuses {
            let shown = VerificationResultsView.shouldShowHonestyDisclaimer(
                overallStatus: status)
            #expect(shown == true,
                    "disclaimer must mount for \(status) — always visible, never removable")
        }
    }

    // The disclaimer is the last section's footer: one gate-wrapped mount,
    // under the completion line, above the trust line that closes the page.
    @Test("Placement: one gate-wrapped mount, under the completion line, above the trust line")
    func disclaimerMountSitsAtThePageFoot() throws {
        let source = try loadRepoFile(
            "Sources/ResectaApp/Views/VerificationResultsView.swift")
        let gateCalls = source.components(
            separatedBy: "Self.shouldShowHonestyDisclaimer(").count - 1
        #expect(gateCalls == 1,
                "expected exactly ONE gated disclaimer mount in the body, found \(gateCalls)")
        // The page stack: the sections, then the footer block, then the trust line.
        guard let sections = source.range(of: "VerificationDetailsSection("),
              let footer = source.range(of: "\n                        footerBlock\n",
                                        range: sections.upperBound..<source.endIndex),
              let trust = source.range(of: "                        trustStrip\n",
                                       range: footer.upperBound..<source.endIndex)
        else {
            Issue.record("Could not locate the page stack's sections → footerBlock → trustStrip mounts")
            return
        }
        #expect(sections.upperBound <= footer.lowerBound && footer.upperBound <= trust.lowerBound)
        // Inside the footer block: the completion line, then the disclaimer.
        guard let block = source.range(of: "private var footerBlock: some View {"),
              let completion = source.range(of: "Self.completionLineText(report: report)",
                                            range: block.upperBound..<source.endIndex),
              let mount = source.range(of: "\n                honestyDisclaimer\n",
                                       range: completion.upperBound..<source.endIndex)
        else {
            Issue.record("Could not locate the footer block's completion line → honestyDisclaimer")
            return
        }
        #expect(completion.upperBound <= mount.lowerBound)
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
        // import class keeps it (deliberate current UX).
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

// The run-facts strip and the non-visual review-limitation line.
//
// OCR pixel-cap skip pages snapshotted onto
// `RedactionState.DetectionRunRecord`, rendered as a pinned singular/
// plural builder using `SearchResultsSection.formatPageList`.
// No detection ran this session, yet a region was applied for
// this output.
// The degrade-failure list snapshotted onto the record at
// record time, rendered by reusing `DetectionDegradeCopy.banner`
// verbatim.
// A pinned line above the honesty disclaimer, reused as the
// `RedactedPreviewView` verdict capsule's accessibility label.

@Suite("Run-facts strip + non-visual limit line")
@MainActor
struct RunFactsStripTests {

    // MARK: - OCR skip line

    @Test("Singular exact text — 0-indexed page 6 renders as Page 7")
    func ocrSkipLineSingular() {
        let line = VerificationResultsView.RunFactsStrip.ocrSkipLine(pages: [6])
        #expect(line == "Page 7 was too large to scan for text, so its image content was not examined by detection. Review that page manually before sharing.")
    }

    @Test("Plural exact text — pages sorted regardless of Set iteration order")
    func ocrSkipLinePlural() {
        let unordered: Set<Int> = [6, 2, 4]
        let line = VerificationResultsView.RunFactsStrip.ocrSkipLine(pages: Array(unordered))
        #expect(line == "Pages 3, 5, and 7 were too large to scan for text, so image content there was not examined by detection. Review those pages manually before sharing.")
    }

    // MARK: - Degrade line — verbatim reuse

    @Test("Degrade line equals DetectionDegradeCopy.banner verbatim on both branches")
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

        let degradeOnly = VerificationResultsView.RunFacts(degradeFailures: ["NameGazetteer"])
        #expect(VerificationResultsView.RunFactsStrip.lines(for: degradeOnly).count == 1)
    }

    @Test("OCR skip line + degrade line render in order")
    func linesOCRAndDegrade() {
        let facts = VerificationResultsView.RunFacts(
            ocrSkippedPages: [0], degradeFailures: ["NameGazetteer"])
        let lines = VerificationResultsView.RunFactsStrip.lines(for: facts)
        #expect(lines.count == 2)
        #expect(lines[0] == VerificationResultsView.RunFactsStrip.ocrSkipLine(pages: [0]))
        #expect(lines[1] == VerificationResultsView.RunFactsStrip
            .degradeLine(failedGazetteers: ["NameGazetteer"]))
    }

    @Test("The strip has no detection-disclosure line — the two remaining facts are the run's own")
    func stripCarriesOnlyRunFacts() {
        // Every line the strip can render comes from the two facts below;
        // a search-only or manual-only run with neither renders no strip.
        let every = VerificationResultsView.RunFacts(
            ocrSkippedPages: [0], degradeFailures: ["NameGazetteer"])
        let lines = VerificationResultsView.RunFactsStrip.lines(for: every)
        #expect(lines.count == 2)
        #expect(!lines.contains { $0.contains("Automated detection did not run") })
        #expect(!lines.contains { $0.contains("Search or manual marking") })
    }

    // MARK: - RunFacts.derive — reads the run's own inputs

    @Test("derive: no retained run → nothing")
    func deriveNoRun() {
        let facts = VerificationResultsView.RunFacts.derive(inputs: nil)
        #expect(facts == VerificationResultsView.RunFacts())
    }

    @Test("derive: the run's OCR-skip pages are carried")
    func deriveCarriesOCRSkips() {
        let facts = VerificationResultsView.RunFacts.derive(
            inputs: .fixture(ocrSkippedPages: [2, 4]))
        #expect(facts.ocrSkippedPages == [2, 4])
        #expect(facts.degradeFailures == nil)
    }

    @Test("derive: the run's degrade list is carried; nil when the run was not degraded")
    func deriveCarriesDegrade() {
        #expect(VerificationResultsView.RunFacts.derive(
            inputs: .fixture(degradeFailures: ["NameGazetteer"])
        ).degradeFailures == ["NameGazetteer"])
        #expect(VerificationResultsView.RunFacts.derive(
            inputs: .fixture()
        ).degradeFailures == nil)
    }

    @Test("derive: a later scan record does not move the strip — only the run's inputs do")
    func deriveIgnoresSessionScanRecord() {
        let state = RedactionState()
        state.recordLastRunInputs(.fixture(ocrSkippedPages: [1]))
        // A scan after the run (not followed by another Redact) records
        // different skips on the session; the on-screen report is still
        // the run's.
        state.recordDetectionRun(.staged, ocrSkippedPages: [5, 6])
        let facts = VerificationResultsView.RunFacts.derive(inputs: state.lastRunInputs)
        #expect(facts.ocrSkippedPages == [1])
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

    @Test("run-facts strip copy stays mechanism-only, no percent sign")
    func runFactsCopyIsMechanismOnly() {
        // The non-visual limit line was removed — its copy is out of
        // the sample set with it.
        let samples = [
            VerificationResultsView.RunFactsStrip.ocrSkipLine(pages: [6]),
            VerificationResultsView.RunFactsStrip.ocrSkipLine(pages: [2, 4, 6]),
            VerificationResultsView.RunFactsStrip.degradeLine(
                failedGazetteers: ["NameGazetteer"]),
            VerificationResultsView.RunFactsStrip.degradeLine(
                failedGazetteers: [GazetteerLoadDiagnostics.Gazetteer.nerNameModel.rawValue]),
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

    @Test("The run facts mount as the run section's first rows")
    func sourcePinsForNewMounts() throws {
        // The results view threads the lines in; the run section mounts
        // them, the first carrying the `runFactsStrip` identifier.
        let viewSource = try loadRepoFile(
            "Sources/ResectaApp/Views/VerificationResultsView.swift")
        #expect(viewSource.contains("runFactsLines: runFactsLines"),
                "VerificationResultsView must thread the run facts into the sections")
        let sectionSource = try loadRepoFile(
            "Sources/ResectaApp/Views/VerificationDetailsSection.swift")
        #expect(sectionSource.contains("\"runFactsStrip\""),
                "the run section must mount the run-facts rows")
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
