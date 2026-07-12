import Testing
@testable import ResectaApp
import RedactionEngine

// Pins the §3.4 Share gate on the verification-results Share card.
//
// Source-of-truth helpers:
//   • VerificationResultsView.shareDisabled(canExport:) — the card's
//     enabled/disabled mapping (Share enabled exactly when canExport is true).
//   • DocumentEditorView.shareNeedsFailConfirm(report:) — §3.4 FAIL override
//     "Option B": a standing FAIL verdict (not user-overridden) routes the
//     Share tap through a one-time "Share Anyway" confirm before export.
//     canExport(report:) no longer folds this in — a FAIL leaves the Share
//     card enabled (red-tinted) — and handleExportTap consults the predicate
//     to present the confirm before ever entering beginExport.
//   • DocumentEditorView.shareNeedsSkippedConfirm(report:) — the one-time
//     skipped-share confirm: a SKIPPED report (verification never ran) not
//     yet acknowledged routes the Share tap through its own confirm
//     (SkippedShareGateTests below).
//
// The userOverrodeFailure conjunct is what makes the confirm one-time: once
// overrideVerificationFailure() sets it, the predicate is false and the Share
// tap falls straight through to beginExport.

@Suite("Verification results Share gate (§4.4a)")
@MainActor
struct VerificationResultsShareGateTests {

    @Test("Exportable output → Share enabled")
    func exportableEnablesShare() {
        #expect(VerificationResultsView.shareDisabled(canExport: true) == false)
    }

    @Test("No exportable output → Share disabled (§4.4a gate holds)")
    func notExportableDisablesShare() {
        #expect(VerificationResultsView.shareDisabled(canExport: false) == true)
    }
}

// Disabled-Share explanation: shareDisabledReason(outputExists:isStale:) maps
// the two facts behind canExport to caption copy, nil exactly when Share is
// enabled (exists ∧ ¬stale). A missing output file wins over staleness.
@Suite("Share-disabled reason caption")
@MainActor
struct ShareDisabledReasonTests {

    @Test("Output exists, not stale → no caption (Share enabled)")
    func enabledHasNoReason() {
        #expect(VerificationResultsView.shareDisabledReason(
            outputExists: true, isStale: false) == nil)
    }

    @Test("Stale regions → stale copy naming Run Redact")
    func staleGivesStaleCopy() {
        let reason = VerificationResultsView.shareDisabledReason(
            outputExists: true, isStale: true)
        #expect(reason == "Regions changed since this output was made — run Redact again to share.")
    }

    @Test("Missing output file → missing-file copy naming Run Redact")
    func missingFileGivesMissingCopy() {
        let reason = VerificationResultsView.shareDisabledReason(
            outputExists: false, isStale: false)
        #expect(reason == "The output file is no longer available — run Redact again.")
    }

    @Test("Missing file AND stale → missing-file copy wins")
    func missingFileWinsOverStale() {
        let reason = VerificationResultsView.shareDisabledReason(
            outputExists: false, isStale: true)
        #expect(reason == "The output file is no longer available — run Redact again.")
    }

    @Test("Reason is nil exactly when the derived canExport would be true")
    func reasonAgreesWithGate() {
        for exists in [true, false] {
            for stale in [true, false] {
                let derivedCanExport = exists && !stale
                let reason = VerificationResultsView.shareDisabledReason(
                    outputExists: exists, isStale: stale)
                #expect((reason == nil) == derivedCanExport)
                #expect(VerificationResultsView.shareDisabled(canExport: derivedCanExport)
                    == (reason != nil))
            }
        }
    }
}

// §3.4 FAIL override / "Option B" — the Share gate after a FAIL. Tests target
// the pure static predicate shareNeedsFailConfirm(report:): canExport(report:)
// no longer hard-blocks on it, and handleExportTap consults it to decide whether
// to present the one-time "Share Anyway" confirm before beginExport. Building a
// SwiftUI host is neither possible nor needed on this machine; the predicate is
// the single source of truth.
@Suite("§3.4 Share-after-FAIL confirm gate (Option B)")
@MainActor
struct FailExportGateTests {

    private func report(_ status: VerificationStatus,
                        overridden: Bool = false) -> VerificationReport {
        VerificationReport(layers: [], overallStatus: status,
                           durationSeconds: 0, userOverrodeFailure: overridden)
    }

    @Test("FAIL (no override) needs the one-time confirm before sharing")
    func failVerificationNeedsConfirm() {
        // Post-Option-B: a standing FAIL no longer disables Share; the tap routes
        // through the "Share Anyway" confirm (handleExportTap presents it).
        #expect(DocumentEditorView.shareNeedsFailConfirm(report: report(.fail("x"))) == true)
    }

    @Test("FAIL with user override shares without re-confirm (passes under A and B)")
    func failWithOverrideEnablesShare() {
        // Once overrideVerificationFailure() has run, the predicate is false and
        // the Share tap falls straight through to beginExport — "confirm once".
        #expect(DocumentEditorView.shareNeedsFailConfirm(report: report(.fail("x"), overridden: true)) == false)
    }

    @Test("Non-FAIL verdicts never need the FAIL confirm (PASS / INFO / WARN / SKIPPED)")
    func nonFailVerdictsDoNotBlock() {
        #expect(DocumentEditorView.shareNeedsFailConfirm(report: report(.pass)) == false)
        #expect(DocumentEditorView.shareNeedsFailConfirm(report: report(.info("i"))) == false)
        // WARN shares freely — only an un-overridden FAIL routes through this confirm.
        #expect(DocumentEditorView.shareNeedsFailConfirm(report: report(.warn("w"))) == false)
        // SKIPPED never takes the FAIL confirm — it routes through its own
        // one-time skipped-share confirm (SkippedShareGateTests below). The
        // former "skipped shares freely" pin is deliberately flipped there.
        #expect(DocumentEditorView.shareNeedsFailConfirm(report: report(.skipped)) == false)
    }

    // PD-17 residual tier: ATTENTION keeps the one-time confirm — the tier
    // re-class changes presentation, not the share-time acknowledgment.
    @Test("ATTENTION (no override) needs the one-time confirm before sharing")
    func attentionNeedsConfirm() {
        #expect(DocumentEditorView.shareNeedsFailConfirm(report: report(.attention("a"))) == true)
    }

    @Test("ATTENTION with user override shares without re-confirm")
    func attentionOverrideSharesFreely() {
        #expect(DocumentEditorView.shareNeedsFailConfirm(report: report(.attention("a"), overridden: true)) == false)
    }

    @Test("ATTENTION confirm message quotes the residual diagnostic")
    func attentionConfirmMessageQuotesDiagnostic() {
        let msg = DocumentEditorView.shareAnywayConfirmMessage(
            report: report(.attention("Text matching your redactions is still readable on page 2 (1 instance)")))
        #expect(msg.contains("still readable on page 2"))
        #expect(msg.contains("share the redacted document as it is"))
    }

    // VE-8-1 (F07) emits a synthetic single-layer "Page Count Check" FAIL when
    // a truncated output is detected on the verify-only resume path. Under
    // Option B that FAIL report now NEEDS the one-time confirm (no hard block).
    @Test("Integration: truncated-output (VE-8-1) FAIL report → needs confirm")
    func truncatedOutputFailReportNeedsConfirm() {
        let pageCountFail = VerificationReport(
            layers: [
                LayerResult(
                    name: "Page Count Check",
                    symbolName: "exclamationmark.triangle",
                    status: .fail("Output page count does not match the source document"),
                    shortDescription: "",
                    detailDescription: "",
                    pageReferences: nil,
                    durationSeconds: 0
                )
            ],
            overallStatus: .fail("Output page count does not match the source document"),
            durationSeconds: 0
        )
        #expect(DocumentEditorView.shareNeedsFailConfirm(report: pageCountFail) == true)
    }

    // D08-F2 (search pre-launch S1): the Secure-Rasterization in-region
    // readable-text FAIL aggregates to overall .fail. Under Option B it routes
    // through the SAME one-time confirm as any other FAIL — no separate gate.
    @Test("Integration: D08-F2 secure-raster in-region FAIL report → needs confirm")
    func secureRasterInRegionFailReportNeedsConfirm() {
        let ocrFail = VerificationReport(
            layers: [
                LayerResult(
                    name: "OCR Check",
                    symbolName: "doc.text.magnifyingglass",
                    status: .fail("Readable text detected within a redacted region on 1 page(s): 1"),
                    shortDescription: "",
                    detailDescription: "",
                    pageReferences: nil,
                    durationSeconds: 0
                )
            ],
            overallStatus: .fail("Readable text detected within a redacted region on 1 page(s): 1"),
            durationSeconds: 0
        )
        // The card's enabled/disabled mapping is unchanged in isolation — Share is
        // disabled only when no fresh output exists (canExport false). A FAIL report
        // no longer forces that; it routes through the confirm instead.
        #expect(DocumentEditorView.shareNeedsFailConfirm(report: ocrFail) == true)
        #expect(VerificationResultsView.shareDisabled(canExport: false) == true)
    }

    // ERR-06 (dossier §4): a FAIL-without-override Share tap routes through the
    // one-time confirm BEFORE beginExport(). handleExportTap returns early on a
    // true predicate (presenting the confirm) and reaches its only beginExport()
    // call on the open paths (override / non-FAIL); the `.exporting` transition
    // lives only inside beginExport(), so for a FAIL it is reached exactly when
    // the user has confirmed (override set) or the verdict is not FAIL.
    @Test("ERR-06: FAIL-without-override routes through the confirm before beginExport")
    func err06FailWithoutOverrideRoutesThroughConfirm() {
        // handleExportTap presents the confirm (returns early) on this:
        #expect(DocumentEditorView.shareNeedsFailConfirm(report: report(.fail("x"))) == true)
        // beginExport() is reached only on the open paths (override / non-FAIL):
        #expect(DocumentEditorView.shareNeedsFailConfirm(report: report(.fail("x"), overridden: true)) == false)
        #expect(DocumentEditorView.shareNeedsFailConfirm(report: report(.pass)) == false)
    }

    // The confirm's message quotes the diagnostic the FAIL aggregate preserved
    // (the first failing layer's message) instead of asserting the Layer-2
    // in-region cause for every FAIL class. Empty-message FAILs fall back to
    // the former sentence.
    @Test("Confirm message quotes the L2 in-region diagnostic")
    func confirmMessageQuotesInRegionDiagnostic() {
        let message = DocumentEditorView.shareAnywayConfirmMessage(
            report: report(.fail("Readable text detected within a redacted region on 1 page(s): 1")))
        #expect(message.contains("Readable text detected within a redacted region on 1 page(s): 1"))
        #expect(message.contains("share the redacted document as it is"))
    }

    @Test("Confirm message quotes a page-count diagnostic, not the in-region sentence")
    func confirmMessageQuotesPageCountDiagnostic() {
        let message = DocumentEditorView.shareAnywayConfirmMessage(
            report: report(.fail("Output page count does not match the source document")))
        #expect(message.contains("Output page count does not match the source document"))
        #expect(!message.contains("readable text within a redacted region"))
    }

    @Test("Confirm message quotes a metadata (Layer 5) diagnostic, not the in-region sentence")
    func confirmMessageQuotesMetadataDiagnostic() {
        let message = DocumentEditorView.shareAnywayConfirmMessage(
            report: report(.fail("Document metadata contains key: Author")))
        #expect(message.contains("Document metadata contains key: Author"))
        #expect(!message.contains("readable text within a redacted region"))
    }

    @Test("Empty FAIL message falls back to the former sentence")
    func emptyFailMessageFallsBack() {
        let message = DocumentEditorView.shareAnywayConfirmMessage(report: report(.fail("")))
        #expect(message == DocumentEditorView.shareAnywayConfirmFallbackMessage)
    }

    @Test("Non-FAIL report falls back (alert is unreachable there, copy still defined)")
    func nonFailFallsBack() {
        let message = DocumentEditorView.shareAnywayConfirmMessage(report: report(.pass))
        #expect(message == DocumentEditorView.shareAnywayConfirmFallbackMessage)
    }

    // "Confirm once": after overrideVerificationFailure() flips userOverrodeFailure
    // on the live .verified phase, a second Share tap no longer needs the confirm.
    // Exercises the real DocumentState override path (DocumentState.swift:299–303).
    @Test("Override then share does not re-confirm (confirm once)")
    func overrideThenShareDoesNotReconfirm() {
        let doc = DocumentState()
        doc.phase = .verified(report: report(.fail("x")))
        doc.overrideVerificationFailure()
        guard case .verified(let overridden) = doc.phase else {
            Issue.record("phase should remain .verified after override")
            return
        }
        #expect(overridden.userOverrodeFailure == true)
        #expect(DocumentEditorView.shareNeedsFailConfirm(report: overridden) == false)
    }
}

// Skipped-share confirm — the one-time confirm for sharing a SKIPPED report
// (verification never ran). Deliberately FLIPS the former pin that .skipped
// shared with zero friction: a skipped output carries no verification result,
// so sharing it now asks once, naming the state. Mirrors the FAIL confirm's
// machinery: pure static predicate shareNeedsSkippedConfirm(report:), a
// report-scoped userAcknowledgedSkippedShare flag set by
// DocumentState.acknowledgeSkippedShare(), and handleExportTap routing (after
// the FAIL branch — mutually exclusive by overallStatus). WARN friction is
// deliberately NOT added.
@Suite("Skipped-share confirm gate")
@MainActor
struct SkippedShareGateTests {

    private func report(_ status: VerificationStatus,
                        overridden: Bool = false,
                        acknowledged: Bool = false) -> VerificationReport {
        VerificationReport(layers: [], overallStatus: status,
                           durationSeconds: 0, userOverrodeFailure: overridden,
                           userAcknowledgedSkippedShare: acknowledged)
    }

    @Test("SKIPPED (no acknowledgement) needs the one-time confirm, for every skip reason")
    func skippedNeedsConfirmForAllReasons() {
        let reasons: [VerificationReport.SkipReason] = [.autoVerifyOff, .cancelled, .error]
        for reason in reasons {
            let skipped = VerificationReport.skipped(reason: reason)
            #expect(DocumentEditorView.shareNeedsSkippedConfirm(report: skipped) == true)
        }
    }

    @Test("SKIPPED with acknowledgement shares without re-confirm (confirm once)")
    func acknowledgedSkippedSharesFreely() {
        #expect(DocumentEditorView.shareNeedsSkippedConfirm(
            report: report(.skipped, acknowledged: true)) == false)
    }

    @Test("A fresh skipped report re-arms the confirm")
    func freshReportRearmsConfirm() {
        // Report-scoped flag: every factory-made report starts
        // unacknowledged, so a new verification run (or a new skip) re-arms
        // the confirm even if the user acknowledged a previous report.
        let fresh = VerificationReport.skipped(reason: .autoVerifyOff)
        #expect(fresh.userAcknowledgedSkippedShare == false)
        #expect(DocumentEditorView.shareNeedsSkippedConfirm(report: fresh) == true)
    }

    @Test("Non-SKIPPED verdicts never need the skipped confirm (PASS / INFO / WARN / FAIL)")
    func nonSkippedVerdictsDoNotConfirm() {
        #expect(DocumentEditorView.shareNeedsSkippedConfirm(report: report(.pass)) == false)
        #expect(DocumentEditorView.shareNeedsSkippedConfirm(report: report(.info("i"))) == false)
        // WARN and PASS stay confirm-free — friction was added for SKIPPED only.
        #expect(DocumentEditorView.shareNeedsSkippedConfirm(report: report(.warn("w"))) == false)
        #expect(DocumentEditorView.shareNeedsSkippedConfirm(report: report(.fail("x"))) == false)
    }

    @Test("FAIL and skipped confirms never both fire, across every status")
    func confirmsAreMutuallyExclusive() {
        let statuses: [VerificationStatus] =
            [.pass, .info("i"), .warn("w"), .fail("x"), .skipped]
        for status in statuses {
            let r = report(status)
            let bothFire = DocumentEditorView.shareNeedsFailConfirm(report: r)
                && DocumentEditorView.shareNeedsSkippedConfirm(report: r)
            #expect(bothFire == false)
        }
    }

    // Friction ladder (predicate-level): FAIL > SKIPPED > WARN == PASS.
    // Score = confirms required + red Share tint. FAIL scores 2 (confirm +
    // red tint), SKIPPED scores 1 (confirm, default tint), WARN and PASS
    // score 0. Pins the deliberate shape: turning verification off is never
    // the least-friction path to sharing.
    @Test("Friction ladder: FAIL > SKIPPED > WARN == PASS")
    func frictionLadderHolds() {
        func friction(_ r: VerificationReport) -> Int {
            (DocumentEditorView.shareNeedsFailConfirm(report: r) ? 1 : 0)
                + (DocumentEditorView.shareNeedsSkippedConfirm(report: r) ? 1 : 0)
                + (VerificationResultsView.shouldTintShareRed(report: r) ? 1 : 0)
        }
        let fail = friction(report(.fail("x")))
        let skipped = friction(report(.skipped))
        let warn = friction(report(.warn("w")))
        let pass = friction(report(.pass))
        #expect(fail > skipped)
        #expect(skipped > warn)
        #expect(warn == pass)
    }

    // "Confirm once": after acknowledgeSkippedShare() flips
    // userAcknowledgedSkippedShare on the live .verified phase, a second
    // Share tap no longer needs the confirm. Exercises the real DocumentState
    // path (mirrors overrideThenShareDoesNotReconfirm above).
    @Test("Acknowledge then share does not re-confirm (confirm once)")
    func acknowledgeThenShareDoesNotReconfirm() {
        let doc = DocumentState()
        doc.phase = .verified(report: VerificationReport.skipped(reason: .cancelled))
        doc.acknowledgeSkippedShare()
        guard case .verified(let acknowledged) = doc.phase else {
            Issue.record("phase should remain .verified after acknowledgement")
            return
        }
        #expect(acknowledged.userAcknowledgedSkippedShare == true)
        #expect(DocumentEditorView.shareNeedsSkippedConfirm(report: acknowledged) == false)
    }

    @Test("Confirm copy names the state and both choices (mechanism description)")
    func confirmCopyNamesStateAndChoices() {
        let message = DocumentEditorView.shareSkippedConfirmMessage
        #expect(message.contains("Verification did not run"))
        #expect(message.contains("run it from this screen"))
        #expect(message.contains("share the document as it is"))
    }
}

// Pins the decoupling fix: Share red-tint keys on overallStatus.isFail ALONE
// (independent of userOverrodeFailure / share round-trip), and Preview
// visibility keys on output-existence alone (decoupled from FAIL/override).
@Suite("Share red-tint + Preview visibility decoupling")
@MainActor
struct ShareTintAndPreviewDecouplingTests {

    private func report(_ s: VerificationStatus, overridden: Bool = false) -> VerificationReport {
        VerificationReport(layers: [], overallStatus: s,
                           durationSeconds: 0, userOverrodeFailure: overridden)
    }

    @Test("FAIL (no override) tints Share red")
    func failPreOverrideTintsRed() {
        #expect(VerificationResultsView.shouldTintShareRed(report: report(.fail("x"))) == true)
    }

    @Test("FAIL stays red AFTER override (does not flip on share round-trip)")
    func failPostOverrideStaysRed() {
        // Regression lock: the old isFailPreOverride returned false once overridden.
        #expect(VerificationResultsView.shouldTintShareRed(report: report(.fail("x"), overridden: true)) == true)
    }

    @Test("Non-FAIL verdicts never tint Share red")
    func nonFailNeverRed() {
        #expect(VerificationResultsView.shouldTintShareRed(report: report(.pass)) == false)
        #expect(VerificationResultsView.shouldTintShareRed(report: report(.warn("w"))) == false)
        #expect(VerificationResultsView.shouldTintShareRed(report: report(.info("i"))) == false)
        #expect(VerificationResultsView.shouldTintShareRed(report: report(.skipped)) == false)
    }
}
