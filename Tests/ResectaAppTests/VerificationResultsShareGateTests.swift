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

    @Test("UXC-14: ATTENTION confirm's at-risk item list quotes the layer's shortDescription")
    func attentionAtRiskItemQuotesDiagnostic() {
        let attentionReport = VerificationReport(
            layers: [
                LayerResult(
                    name: "OCR Check", symbolName: "doc.text.magnifyingglass",
                    status: .attention("Text matching your redactions is still readable on page 2 (1 instance)"),
                    shortDescription: "Text matching your redactions is still readable on page 2.",
                    detailDescription: "", pageReferences: [1], durationSeconds: 0,
                    reviewTermTexts: ["redacted-term"]
                )
            ],
            overallStatus: .attention("Text matching your redactions is still readable on page 2 (1 instance)"),
            durationSeconds: 0
        )
        let lines = DocumentEditorView.atRiskItemLines(report: attentionReport)
        #expect(lines == ["Text matching your redactions is still readable on page 2."])
        // Content-free (ARCH §12.2): the item list never surfaces
        // reviewTermTexts (the matched term text), only shortDescription.
        #expect(!lines.joined().contains("redacted-term"))
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

    // UXC-14: the confirm sheet's at-risk item list is derived from EVERY
    // FAIL/ATTENTION layer's shortDescription (`atRiskItemLines`), not a
    // single quoted-and-fallback sentence — the retired
    // `shareAnywayConfirmMessage` / `shareAnywayConfirmFallbackMessage`
    // pinned that older single-message shape. `atRiskItemLines` distinguishes
    // FAIL classes the same way: each layer's own shortDescription, verbatim.
    @Test("At-risk item list quotes the L2 in-region diagnostic")
    func atRiskItemsQuoteInRegionDiagnostic() {
        let inRegionFail = VerificationReport(
            layers: [
                LayerResult(
                    name: "OCR Check", symbolName: "doc.text.magnifyingglass",
                    status: .fail("Readable text detected within a redacted region on 1 page(s): 1"),
                    shortDescription: "Readable text detected within a redacted region on 1 page(s): 1",
                    detailDescription: "", pageReferences: [1], durationSeconds: 0
                )
            ],
            overallStatus: .fail("Readable text detected within a redacted region on 1 page(s): 1"),
            durationSeconds: 0
        )
        #expect(DocumentEditorView.atRiskItemLines(report: inRegionFail)
            == ["Readable text detected within a redacted region on 1 page(s): 1"])
    }

    @Test("At-risk item list quotes a page-count diagnostic, not the in-region sentence")
    func atRiskItemsQuotePageCountDiagnostic() {
        let pageCountFail = VerificationReport(
            layers: [
                LayerResult(
                    name: "Page Count Check", symbolName: "exclamationmark.triangle",
                    status: .fail("Output page count does not match the source document"),
                    shortDescription: "Output page count does not match the source document.",
                    detailDescription: "", pageReferences: nil, durationSeconds: 0
                )
            ],
            overallStatus: .fail("Output page count does not match the source document"),
            durationSeconds: 0
        )
        let lines = DocumentEditorView.atRiskItemLines(report: pageCountFail)
        #expect(lines == ["Output page count does not match the source document."])
        #expect(!lines.joined().contains("readable text within a redacted region"))
    }

    @Test("At-risk item list quotes a metadata (Layer 5) diagnostic, not the in-region sentence")
    func atRiskItemsQuoteMetadataDiagnostic() {
        let metadataFail = VerificationReport(
            layers: [
                LayerResult(
                    name: "Metadata Check", symbolName: "doc.badge.gearshape",
                    status: .fail("Document metadata contains key: Author"),
                    shortDescription: "Document metadata contains key: Author",
                    detailDescription: "", pageReferences: nil, durationSeconds: 0
                )
            ],
            overallStatus: .fail("Document metadata contains key: Author"),
            durationSeconds: 0
        )
        let lines = DocumentEditorView.atRiskItemLines(report: metadataFail)
        #expect(lines == ["Document metadata contains key: Author"])
        #expect(!lines.joined().contains("readable text within a redacted region"))
    }

    @Test("A FAIL report with no layers (fixture-only shape) yields an empty at-risk item list, not a crash")
    func emptyLayersYieldsEmptyList() {
        // aggregateStatus can never actually produce .fail with empty
        // layers in production (overallStatus is derived FROM a failing
        // layer) — this fixture-only shape existed to exercise the former
        // `shareAnywayConfirmFallbackMessage`. `atRiskItemLines` has no
        // fallback concept: it degrades to an empty list, and the sheet
        // renders the header with no bullets under it.
        #expect(DocumentEditorView.atRiskItemLines(report: report(.fail(""))).isEmpty)
    }

    @Test("Non-FAIL/ATTENTION report yields an empty at-risk item list (the sheet is unreachable there anyway)")
    func nonFailAttentionYieldsEmptyList() {
        #expect(DocumentEditorView.atRiskItemLines(report: report(.pass)).isEmpty)
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

    /// The narrow incomplete-WARN shape (UXC-14 / GAP-14): overallStatus
    /// `.warn` with zero real WARN layers and ≥1 skipped layer. Needs actual
    /// layers, unlike this suite's zero-layer `report(_:)` fixture helper.
    private func incompleteWarnReport() -> VerificationReport {
        VerificationReport(
            layers: [
                LayerResult(name: "Character Count Cross-Check", symbolName: "number",
                           status: .skipped, shortDescription: "", detailDescription: "",
                           pageReferences: nil, durationSeconds: 0)
            ],
            overallStatus: .warn("Verification produced warnings"),
            durationSeconds: 0
        )
    }

    @Test("FAIL/ATTENTION, SKIPPED, and incomplete-WARN confirms never fire together, across every status shape")
    func threeWayMutualExclusion() {
        let statuses: [VerificationStatus] =
            [.pass, .info("i"), .warn("w"), .fail("x"), .attention("a"), .skipped]
        var fixtures: [VerificationReport] = statuses.map { report($0) }
        fixtures.append(incompleteWarnReport())
        for r in fixtures {
            let failFires = DocumentEditorView.shareNeedsFailConfirm(report: r)
            let skippedFires = DocumentEditorView.shareNeedsSkippedConfirm(report: r)
            let incompleteFires = DocumentEditorView.shareNeedsIncompleteWarnConfirm(
                report: r, acknowledged: false)
            let fireCount = [failFires, skippedFires, incompleteFires].filter { $0 }.count
            #expect(fireCount <= 1,
                    "more than one confirm family fired for \(r.overallStatus)")
        }
    }

    // Friction ladder (predicate-level): FAIL > SKIPPED == incomplete-WARN >
    // WARN == PASS (RB-34 D8). Score = confirms required + red Share tint.
    // FAIL scores 2 (confirm + red tint), SKIPPED and incomplete-WARN each
    // score 1 (confirm, default tint), routine WARN and PASS score 0. Pins
    // the deliberate shape: turning verification off, or sharing a run whose
    // digest-dependent layers were skipped, are never the least-friction
    // path to sharing.
    @Test("Friction ladder: FAIL > SKIPPED == incomplete-WARN > WARN == PASS")
    func frictionLadderHolds() {
        func friction(_ r: VerificationReport) -> Int {
            (DocumentEditorView.shareNeedsFailConfirm(report: r) ? 1 : 0)
                + (DocumentEditorView.shareNeedsSkippedConfirm(report: r) ? 1 : 0)
                + (DocumentEditorView.shareNeedsIncompleteWarnConfirm(
                    report: r, acknowledged: false) ? 1 : 0)
                + (VerificationResultsView.shouldTintShareRed(report: r) ? 1 : 0)
        }
        let fail = friction(report(.fail("x")))
        let skipped = friction(report(.skipped))
        let incompleteWarn = friction(incompleteWarnReport())
        let warn = friction(report(.warn("w")))
        let pass = friction(report(.pass))
        #expect(fail > skipped)
        #expect(skipped == incompleteWarn)
        #expect(incompleteWarn > warn)
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

    @Test("Skip-fact line names the state (mechanism description) — new UXC-14 sheet copy")
    func skipFactLineNamesState() {
        #expect(DocumentEditorView.shareRiskConfirmSkipFactLine
            == "Verification did not run on this output.")
    }
}

// UXC-14 — the bespoke share-risk confirm sheet's copy builders and haptic
// seam, replacing the two retired `.alert`s. Predicate-level suites above
// (FailExportGateTests, SkippedShareGateTests) cover the gate; this suite
// covers the sheet's own content derivation.
@Suite("Share-risk confirm sheet (UXC-14)")
@MainActor
struct ShareRiskConfirmSheetTests {

    // MARK: - Title / header / skip line — exact copy pins

    @Test("Title is exact and shared across all three confirm families")
    func titleExact() {
        #expect(DocumentEditorView.shareRiskConfirmTitle == "Share with reported issues?")
    }

    @Test("List header exact")
    func headerExact() {
        #expect(DocumentEditorView.shareRiskConfirmListHeader
            == "The verification check reported:")
    }

    @Test("Slide-control label exact")
    func slideLabelExact() {
        #expect(DocumentEditorView.shareRiskConfirmSlideLabel == "Slide to share anyway")
    }

    // MARK: - At-risk item list — content-free derivation from a fixture

    private func layer(
        _ status: VerificationStatus, shortDescription: String,
        reviewTermTexts: [String]? = nil
    ) -> LayerResult {
        LayerResult(
            name: "Layer", symbolName: "checkmark", status: status,
            shortDescription: shortDescription, detailDescription: "detail — never surfaced",
            pageReferences: nil, durationSeconds: 0, reviewTermTexts: reviewTermTexts
        )
    }

    @Test("Item list includes only FAIL/ATTENTION layers, in layer order, shortDescription only")
    func itemListDerivation() {
        let mixedReport = VerificationReport(
            layers: [
                layer(.pass, shortDescription: "passed — must not appear"),
                layer(.fail("x"), shortDescription: "Output has 2 pages; source has 3."),
                layer(.info("i"), shortDescription: "note — must not appear"),
                layer(.attention("a"), shortDescription: "Unredacted text remains on page 2.",
                      reviewTermTexts: ["a-matched-secret"]),
                layer(.warn("w"), shortDescription: "warned — must not appear"),
                layer(.skipped, shortDescription: "skipped — must not appear"),
            ],
            overallStatus: .fail("x"), durationSeconds: 0
        )
        let lines = DocumentEditorView.atRiskItemLines(report: mixedReport)
        #expect(lines == [
            "Output has 2 pages; source has 3.",
            "Unredacted text remains on page 2.",
        ])
        // Content-free (ARCH §12.2): never the matched text
        // (reviewTermTexts) or the detailDescription — shortDescription only.
        let joined = lines.joined()
        #expect(!joined.contains("a-matched-secret"))
        #expect(!joined.contains("never surfaced"))
    }

    // MARK: - Deselected-items line — singular/plural

    @Test("Singular")
    func deselectedLineSingular() {
        #expect(DocumentEditorView.deselectedItemsConfirmLine(count: 1)
            == "1 flagged item was deselected before redaction.")
    }

    @Test("Plural")
    func deselectedLinePlural() {
        #expect(DocumentEditorView.deselectedItemsConfirmLine(count: 3)
            == "3 flagged items were deselected before redaction.")
    }

    // MARK: - Accessibility identifiers per confirm family

    @Test("Each confirm family keeps a stable accessibility identifier for its completion element")
    func accessibilityIdentifiersPerFamily() {
        let empty = VerificationReport(layers: [], overallStatus: .fail("x"), durationSeconds: 0)
        #expect(ShareRiskConfirmKind.failOrAttention(empty).accessibilityIdentifier
            == "shareAnywayConfirm")
        #expect(ShareRiskConfirmKind.skipped(.skipped).accessibilityIdentifier
            == "shareSkippedConfirm")
        #expect(ShareRiskConfirmKind.incompleteWarn(empty).accessibilityIdentifier
            == "shareIncompleteWarnConfirm")
    }

    // MARK: - Completion function (haptic seam + acknowledgement + export)

    @Test("completeShareRiskConfirm(.failOrAttention): overrides the failure, fires the haptic once, exports the live report")
    func completeFailOrAttention() {
        var hapticFireCount = 0
        let savedHaptic = DocumentEditorView.shareRiskConfirmHaptic
        DocumentEditorView.shareRiskConfirmHaptic = { hapticFireCount += 1 }
        defer { DocumentEditorView.shareRiskConfirmHaptic = savedHaptic }

        let doc = DocumentState()
        let original = VerificationReport(layers: [], overallStatus: .fail("x"), durationSeconds: 0)
        doc.phase = .verified(report: original)

        var exported: VerificationReport?
        DocumentEditorView.completeShareRiskConfirm(
            kind: .failOrAttention(original),
            documentState: doc,
            beginExport: { exported = $0 }
        )

        #expect(hapticFireCount == 1)
        #expect(exported?.userOverrodeFailure == true)
        if case .verified(let updated) = doc.phase {
            #expect(updated.userOverrodeFailure == true)
        } else {
            Issue.record("expected .verified phase to persist through completion")
        }
    }

    @Test("completeShareRiskConfirm(.skipped): acknowledges the skip, fires the haptic once")
    func completeSkipped() {
        var hapticFireCount = 0
        let savedHaptic = DocumentEditorView.shareRiskConfirmHaptic
        DocumentEditorView.shareRiskConfirmHaptic = { hapticFireCount += 1 }
        defer { DocumentEditorView.shareRiskConfirmHaptic = savedHaptic }

        let doc = DocumentState()
        doc.phase = .verified(report: .skipped(reason: .cancelled))

        var exported: VerificationReport?
        DocumentEditorView.completeShareRiskConfirm(
            kind: .skipped(.skipped(reason: .cancelled)),
            documentState: doc,
            beginExport: { exported = $0 }
        )

        #expect(hapticFireCount == 1)
        #expect(exported?.userAcknowledgedSkippedShare == true)
    }

    @Test("completeShareRiskConfirm(.incompleteWarn): acknowledges on DocumentState, fires the haptic once")
    func completeIncompleteWarn() {
        var hapticFireCount = 0
        let savedHaptic = DocumentEditorView.shareRiskConfirmHaptic
        DocumentEditorView.shareRiskConfirmHaptic = { hapticFireCount += 1 }
        defer { DocumentEditorView.shareRiskConfirmHaptic = savedHaptic }

        let doc = DocumentState()
        let report = VerificationReport(
            layers: [LayerResult(name: "L", symbolName: "s", status: .skipped,
                                 shortDescription: "", detailDescription: "",
                                 pageReferences: nil, durationSeconds: 0)],
            overallStatus: .warn("w"), durationSeconds: 0
        )
        doc.phase = .verified(report: report)
        #expect(doc.incompleteWarnShareAcknowledged == false)

        var exportFired = false
        DocumentEditorView.completeShareRiskConfirm(
            kind: .incompleteWarn(report),
            documentState: doc,
            beginExport: { _ in exportFired = true }
        )

        #expect(hapticFireCount == 1)
        #expect(doc.incompleteWarnShareAcknowledged == true)
        #expect(exportFired == true)
        // The flag does NOT live on the report — the exported report's own
        // `userOverrodeFailure` / `userAcknowledgedSkippedShare` are
        // untouched by this path.
    }

    @Test("completeShareRiskConfirm re-reads the live phase rather than trusting the captured report")
    func completeReReadsLivePhase() {
        DocumentEditorView.shareRiskConfirmHaptic = { }
        let doc = DocumentState()
        let staleCaptured = VerificationReport(layers: [], overallStatus: .fail("stale"), durationSeconds: 0)
        // The live phase holds a DIFFERENT report value than the one
        // captured in `kind` at presentation time.
        let live = VerificationReport(layers: [], overallStatus: .fail("live"), durationSeconds: 0)
        doc.phase = .verified(report: live)

        var exported: VerificationReport?
        DocumentEditorView.completeShareRiskConfirm(
            kind: .failOrAttention(staleCaptured),
            documentState: doc,
            beginExport: { exported = $0 }
        )

        if case .fail(let msg) = exported?.overallStatus {
            #expect(msg == "live")
        } else {
            Issue.record("expected the re-read live report to export, not the captured one")
        }
    }
}

// Incomplete-WARN share confirm gate (UXC-14 / GAP-14). Tests target the
// pure static predicate shareNeedsIncompleteWarnConfirm(report:acknowledged:):
// a WARN report whose aggregate carries zero real WARN layers but ≥1 skipped
// layer — the exact condition VerificationResultsView.mastheadSubtitle's
// skip-induced-WARN branch renders on — routes the Share tap through the
// same confirm sheet as FAIL/ATTENTION/SKIPPED. Unlike its two siblings the
// acknowledgement flag is NOT on VerificationReport (Packages/RedactionEngine
// is C-5-fenced) — it lives on DocumentState instead
// (`incompleteWarnShareAcknowledged` / `acknowledgeIncompleteWarnShare()`),
// so the predicate takes `acknowledged` as an explicit parameter.
@Suite("Incomplete-WARN share confirm gate (UXC-14 / GAP-14)")
@MainActor
struct IncompleteWarnShareGateTests {

    private func layer(_ status: VerificationStatus) -> LayerResult {
        LayerResult(name: "Layer", symbolName: "checkmark", status: status,
                   shortDescription: "", detailDescription: "",
                   pageReferences: nil, durationSeconds: 0)
    }

    private func incompleteWarnReport() -> VerificationReport {
        VerificationReport(
            layers: [layer(.skipped), layer(.skipped)],
            overallStatus: .warn("Verification produced warnings"),
            durationSeconds: 0
        )
    }

    @Test("WARN with zero real WARN layers and ≥1 skipped layer needs the confirm")
    func narrowConditionNeedsConfirm() {
        #expect(DocumentEditorView.shareNeedsIncompleteWarnConfirm(
            report: incompleteWarnReport(), acknowledged: false) == true)
    }

    @Test("Acknowledged incomplete-WARN shares without re-confirm (confirm once)")
    func acknowledgedSharesFreely() {
        #expect(DocumentEditorView.shareNeedsIncompleteWarnConfirm(
            report: incompleteWarnReport(), acknowledged: true) == false)
    }

    @Test("A WARN mixing a real WARN layer with a skipped layer does NOT need this confirm")
    func mixedWarnAndSkipDoesNotConfirm() {
        // No approved copy exists for this mixed shape (the masthead's own
        // skip-sentence branch requires warnCount == 0); it stays
        // confirm-free like any other routine WARN.
        let mixed = VerificationReport(
            layers: [layer(.warn("w")), layer(.skipped)],
            overallStatus: .warn("w"), durationSeconds: 0
        )
        #expect(DocumentEditorView.shareNeedsIncompleteWarnConfirm(
            report: mixed, acknowledged: false) == false)
    }

    @Test("A WARN with no skipped layers does not need this confirm")
    func plainWarnDoesNotConfirm() {
        let plain = VerificationReport(
            layers: [layer(.warn("w"))], overallStatus: .warn("w"), durationSeconds: 0)
        #expect(DocumentEditorView.shareNeedsIncompleteWarnConfirm(
            report: plain, acknowledged: false) == false)
    }

    @Test("Non-WARN verdicts never need this confirm (PASS / INFO / ATTENTION / FAIL / SKIPPED)")
    func nonWarnVerdictsDoNotConfirm() {
        let statuses: [VerificationStatus] =
            [.pass, .info("i"), .attention("a"), .fail("x"), .skipped]
        for status in statuses {
            let r = VerificationReport(layers: [], overallStatus: status, durationSeconds: 0)
            #expect(DocumentEditorView.shareNeedsIncompleteWarnConfirm(
                report: r, acknowledged: false) == false)
        }
    }

    @Test("acknowledgeIncompleteWarnShare sets the DocumentState flag")
    func acknowledgeSetsFlag() {
        let doc = DocumentState()
        #expect(doc.incompleteWarnShareAcknowledged == false)
        doc.acknowledgeIncompleteWarnShare()
        #expect(doc.incompleteWarnShareAcknowledged == true)
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
