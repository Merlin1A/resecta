import Testing
import SwiftUI
import UIKit
@testable import ResectaApp
@testable import RedactionEngine

// UI_UX §4.1–§4.3a: Verification status display property tests.

@Suite("VerificationStatus Display Properties", .tags(.display))
@MainActor
struct VerificationDisplayTests {

    // MARK: - SF Symbols (ENGINE §6.8)

    @Test("symbolName maps to correct SF Symbol",
          arguments: [
            (VerificationStatus.pass, "checkmark.shield.fill"),
            (VerificationStatus.warn("w"), "exclamationmark.shield.fill"),
            (VerificationStatus.info("i"), "info.circle.fill"),
            (VerificationStatus.attention("a"), "shield.lefthalf.filled"),
            (VerificationStatus.fail("f"), "xmark.shield.fill"),
            (VerificationStatus.skipped, "shield.slash"),
          ])
    func symbolNameForAllCases(status: VerificationStatus, expected: String) {
        #expect(status.symbolName == expected)
    }

    // MARK: - Colors (UI_UX §4.1)

    @Test("color maps to correct SwiftUI color",
          arguments: [
            (VerificationStatus.pass, Color.green),
            (VerificationStatus.warn("w"), Color.orange),
            (VerificationStatus.info("i"), ResectaTokens.SemanticColor.searchableMode),
            (VerificationStatus.attention("a"), Color.pink),
            (VerificationStatus.fail("f"), Color.red),
            (VerificationStatus.skipped, Color.secondary),
          ])
    func colorForAllCases(status: VerificationStatus, expected: Color) {
        #expect(status.color == expected)
    }

    // MARK: - Intermediate Colors (UI_UX §4.3a)

    @Test("intermediateColor for pass is secondary (prevents premature confidence anchoring)")
    func intermediateColorPassIsSecondary() {
        #expect(VerificationStatus.pass.intermediateColor == .secondary)
    }

    @Test("intermediateColor for non-pass matches standard color",
          arguments: [
            (VerificationStatus.warn("w"), Color.orange),
            (VerificationStatus.info("i"), ResectaTokens.SemanticColor.searchableMode),
            (VerificationStatus.attention("a"), Color.pink),
            (VerificationStatus.fail("f"), Color.red),
            (VerificationStatus.skipped, Color.secondary),
          ])
    func intermediateColorNonPassMatchesColor(status: VerificationStatus, expected: Color) {
        #expect(status.intermediateColor == expected)
    }

    // MARK: - Titles (mechanism-description language, ARCH §1.3)

    @Test("title is non-empty for all cases",
          arguments: [
            VerificationStatus.pass,
            VerificationStatus.warn("w"),
            VerificationStatus.info("i"),
            VerificationStatus.attention("a"),
            VerificationStatus.fail("f"),
            VerificationStatus.skipped,
          ])
    func titleNonEmpty(status: VerificationStatus) {
        #expect(!status.title.isEmpty)
    }

    @Test("subtitle is non-empty for all cases",
          arguments: [
            VerificationStatus.pass,
            VerificationStatus.warn("w"),
            VerificationStatus.info("i"),
            VerificationStatus.attention("a"),
            VerificationStatus.fail("f"),
            VerificationStatus.skipped,
          ])
    func subtitleNonEmpty(status: VerificationStatus) {
        #expect(!status.subtitle.isEmpty)
    }

    // VF-12: "Passed" is reserved for .pass — a WARN masthead that says
    // "Passed" frames reduced assurance as a pass (the trust strip on the
    // same screen already refuses the completeness claim on WARN).
    @Test("WARN title says completed, never passed")
    func warnTitleAvoidsPassClaim() {
        let status = VerificationStatus.warn("w")
        #expect(status.title == "Completed with Notes")
        let claimsPass = status.title.lowercased().contains("pass")
        #expect(claimsPass == false,
                "\"Passed\" is reserved for the .pass verdict")
    }

    // VF-12: the FAIL subtitle names the remediation path, not just the
    // review instruction — and the masthead's own .fail arm speaks the
    // same sentence, so the two surfaces cannot drift apart.
    @Test("FAIL subtitle names the remediation path on both surfaces")
    func failSubtitleNamesRemediation() {
        let subtitle = VerificationStatus.fail("f").subtitle
        #expect(subtitle
                == "Review the findings below. You can adjust regions and run redaction again, or share after reviewing.")
        let report = VerificationReport(
            layers: [], overallStatus: .fail("f"), durationSeconds: 0)
        #expect(VerificationResultsView.mastheadSubtitle(report: report) == subtitle)
        #expect(VerificationStatus.fail("f").title == "Issues Found",
                "The FAIL title is pinned — the preview verdict capsule quotes it")
    }

    // MARK: - Accessibility (UI_UX §4.1)

    @Test("accessibilityLabel is non-empty for all cases",
          arguments: [
            VerificationStatus.pass,
            VerificationStatus.warn("w"),
            VerificationStatus.info("i"),
            VerificationStatus.attention("a"),
            VerificationStatus.fail("f"),
            VerificationStatus.skipped,
          ])
    func accessibilityLabelNonEmpty(status: VerificationStatus) {
        #expect(!status.accessibilityLabel.isEmpty)
    }

    // VF-12: the spoken WARN label follows the retitled masthead.
    @Test("WARN accessibilityLabel matches the completed-with-notes framing")
    func warnAccessibilityLabelCompletedFraming() {
        #expect(VerificationStatus.warn("w").accessibilityLabel
                == "Verification completed with notes. Review the notes before sharing.")
    }

    // MARK: - Status text tier (q41 / CD-15, 07-PALETTE §1)

    // Pins the five AA-validated text-tier tokens to their spec hexes in
    // BOTH trait collections. These values were contrast-gated (≥4.5:1 on
    // their rendering surfaces) — a drift here silently loses AA.
    @Test("Status text-tier tokens resolve to spec hexes in light and dark",
          arguments: [
            ("passText", ResectaTokens.SemanticColor.passText, 0x1B7A33, 0x30D158),
            ("warnText", ResectaTokens.SemanticColor.warnText, 0x9A5B00, 0xFF9F0A),
            ("confidenceMediumText", ResectaTokens.SemanticColor.confidenceMediumText,
             0x7A6100, 0xFFD60A),
            ("failText", ResectaTokens.SemanticColor.failText, 0xC2262E, 0xFF7A72),
            ("infoText", ResectaTokens.SemanticColor.infoText, 0x1D5EBF, 0x6CB4EE),
          ])
    func textTierTokenMatchesSpecHex(name: String, token: Color, lightHex: Int, darkHex: Int) {
        for (style, hex) in [(UIUserInterfaceStyle.light, lightHex),
                             (UIUserInterfaceStyle.dark, darkHex)] {
            let trait = UITraitCollection(userInterfaceStyle: style)
            let resolved = UIColor(token).resolvedColor(with: trait)

            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            #expect(resolved.getRed(&r, green: &g, blue: &b, alpha: &a))

            // Same 1/255 tolerance rationale as AccentColorLockstepTests —
            // absorbs float rounding only, not a different color.
            let tolerance: CGFloat = 1.0 / 255.0
            let styleName = style == .dark ? "dark" : "light"
            #expect(abs(r - CGFloat((hex >> 16) & 0xFF) / 255) <= tolerance,
                    "\(name) red drifted (\(styleName))")
            #expect(abs(g - CGFloat((hex >> 8) & 0xFF) / 255) <= tolerance,
                    "\(name) green drifted (\(styleName))")
            #expect(abs(b - CGFloat(hex & 0xFF) / 255) <= tolerance,
                    "\(name) blue drifted (\(styleName))")
            #expect(a == 1, "\(name) alpha must be opaque (\(styleName))")
        }
    }

    // MARK: - Language Compliance (ARCH §1.3)

    @Test("No outcome-promise language in display strings",
          arguments: [
            VerificationStatus.pass,
            VerificationStatus.warn("w"),
            VerificationStatus.info("i"),
            VerificationStatus.attention("a"),
            VerificationStatus.fail("f"),
            VerificationStatus.skipped,
          ])
    func noOutcomePromiseLanguage(status: VerificationStatus) {
        let bannedWords = ["guaranteed", "ensures", "impossible", "guarantee", "ensure"]
        let allText = [status.title, status.subtitle, status.accessibilityLabel]
            .joined(separator: " ").lowercased()

        for word in bannedWords {
            #expect(!allText.contains(word),
                    "Display text for \(status) contains banned word '\(word)' (ARCH §1.3)")
        }
    }

    // MARK: - Attention masthead (PD-17/PD-18 — residual tier)

    @Test("ATTENTION title and subtitle are pinned")
    func attentionTitleSubtitlePinned() {
        #expect(VerificationStatus.attention("a").title == "Attention Needed")
        #expect(VerificationStatus.attention("a").subtitle
                == "Unredacted text remains — review the items below.")
    }

    @Test("ATTENTION masthead subtitle names the report's review terms")
    func attentionMastheadNamesTerms() {
        let residual = LayerResult(
            name: "Binary String Search", symbolName: "shield",
            status: .attention("Text matching your redactions is still readable on 2 pages: 2, 3 (2 instances)"),
            shortDescription: "", detailDescription: "",
            pageReferences: [1, 2], durationSeconds: 0,
            reviewTermTexts: ["DELIA"])
        let echo = LayerResult(
            name: "Operator Re-Extraction", symbolName: "shield",
            status: .attention("Text matching your redactions is readable in page 2 content (1 instance)"),
            shortDescription: "", detailDescription: "",
            pageReferences: [1], durationSeconds: 0,
            reviewTermTexts: ["DELIA"])
        let report = VerificationReport(
            layers: [residual, echo],
            overallStatus: .attention("x"), durationSeconds: 0)
        #expect(VerificationResultsView.mastheadSubtitle(report: report)
                == "Unredacted text remains: 'DELIA'")
        #expect(VerificationResultsView.reviewTermTexts(report: report) == ["DELIA"])
    }

    @Test("ATTENTION masthead subtitle stays generic without term texts")
    func attentionMastheadGenericFallback() {
        let report = VerificationReport(
            layers: [], overallStatus: .attention("x"), durationSeconds: 0)
        #expect(VerificationResultsView.mastheadSubtitle(report: report)
                == "Unredacted text remains — review the items below.")
    }

    @Test("Share tile tint: FAIL red, ATTENTION pink, WARN none")
    func shareTintPerVerdict() {
        func report(_ status: VerificationStatus) -> VerificationReport {
            VerificationReport(layers: [], overallStatus: status, durationSeconds: 0)
        }
        #expect(VerificationResultsView.shareTintColor(report: report(.fail("f"))) == .red)
        #expect(VerificationResultsView.shareTintColor(report: report(.attention("a"))) == .pink)
        #expect(VerificationResultsView.shareTintColor(report: report(.warn("w"))) == nil)
        #expect(VerificationResultsView.shareTintColor(report: report(.pass)) == nil)
    }

    // MARK: - Details summary line (stock copy; exact-string pins)

    private func layer(_ status: VerificationStatus) -> LayerResult {
        LayerResult(name: "L", symbolName: "shield", status: status,
                    shortDescription: "", detailDescription: "",
                    pageReferences: nil, durationSeconds: 0)
    }

    @Test("detailsSummaryText: a pass run with INFO layers reads passed + informational-notes suffix")
    func detailsSummaryPassWithInfoNotes() {
        // INFO layers count as passed (no actionable issue) and ride the
        // informational-notes suffix; an info-only run aggregates .pass, so
        // this is the stock line for e.g. a run whose only non-pass layer is
        // the demoted fill-artifact note.
        let report = VerificationReport(
            layers: [layer(.pass), layer(.pass), layer(.info("note"))],
            overallStatus: .pass, durationSeconds: 0)
        #expect(VerificationResultsView.detailsSummaryText(for: report)
                == "3 of 3 checks passed · 1 informational note")

        let two = VerificationReport(
            layers: [layer(.pass), layer(.info("a")), layer(.info("b"))],
            overallStatus: .pass, durationSeconds: 0)
        #expect(VerificationResultsView.detailsSummaryText(for: two)
                == "3 of 3 checks passed · 2 informational notes")
    }

    @Test("detailsSummaryText: an all-pass run carries no suffix")
    func detailsSummaryAllPassNoSuffix() {
        let report = VerificationReport(
            layers: [layer(.pass), layer(.pass)],
            overallStatus: .pass, durationSeconds: 0)
        #expect(VerificationResultsView.detailsSummaryText(for: report)
                == "2 of 2 checks passed")
    }

    @Test("detailsSummaryText: an ATTENTION run reads passed + need-review segments")
    func detailsSummaryAttentionShape() {
        // The PD-15 sample shape under PD-17: 2 residual layers, 1 warn,
        // 3 info, 4 pass → passed counts pass+info.
        let report = VerificationReport(
            layers: [layer(.pass), layer(.pass), layer(.pass), layer(.pass),
                     layer(.info("a")), layer(.info("b")), layer(.info("c")),
                     layer(.attention("r1")), layer(.attention("r2")),
                     layer(.warn("n"))],
            overallStatus: .attention("r1"), durationSeconds: 0)
        #expect(VerificationResultsView.detailsSummaryText(for: report)
                == "7 of 10 checks passed · 2 need review · 1 note · 3 informational notes")

        let single = VerificationReport(
            layers: [layer(.pass), layer(.attention("r"))],
            overallStatus: .attention("r"), durationSeconds: 0)
        #expect(VerificationResultsView.detailsSummaryText(for: single)
                == "1 of 2 checks passed · 1 needs review")
    }

    @Test("detailsSummaryText: a WARN run keeps the completed + notes shape")
    func detailsSummaryWarnShape() {
        let report = VerificationReport(
            layers: [layer(.pass), layer(.warn("w")), layer(.info("i"))],
            overallStatus: .warn("w"), durationSeconds: 0)
        #expect(VerificationResultsView.detailsSummaryText(for: report)
                == "3 of 3 checks completed · 1 note · 1 informational note")
    }
}

// PD-18: attention rows name the exact remaining text + the remedy.
@Suite("Attention row composition", .tags(.display))
@MainActor
struct AttentionRowCompositionTests {

    private func attentionLayer(
        terms: [String]?, pages: [Int]?
    ) -> LayerResult {
        LayerResult(
            name: "Binary String Search", symbolName: "shield",
            status: .attention("Text matching your redactions is still readable on 2 pages: 2, 3 (2 instances)"),
            shortDescription: "engine short line", detailDescription: "",
            pageReferences: pages, durationSeconds: 0,
            reviewTermTexts: terms)
    }

    @Test("Single term, two pages — the PD-15 sample shape")
    func singleTermTwoPages() {
        let text = LayerResultRow.reviewRowText(termTexts: ["DELIA"], pages: [1, 2])
        #expect(text == "'DELIA' is still readable on pages 2 and 3. "
                + "It matches text you redacted elsewhere. "
                + "Use text search to redact remaining instances.")
    }

    @Test("Single term, one page")
    func singleTermOnePage() {
        let text = LayerResultRow.reviewRowText(termTexts: ["DELIA"], pages: [1])
        #expect(text == "'DELIA' is still readable on page 2. "
                + "It matches text you redacted elsewhere. "
                + "Use text search to redact remaining instances.")
    }

    @Test("Multiple terms, three pages")
    func multiTermThreePages() {
        let text = LayerResultRow.reviewRowText(
            termTexts: ["DELIA", "Hartwell"], pages: [0, 1, 4])
        #expect(text == "'DELIA', 'Hartwell' are still readable on pages 1, 2, and 5. "
                + "They match text you redacted elsewhere. "
                + "Use text search to redact remaining instances.")
    }

    @Test("No page references falls back to a document-wide phrase")
    func noPages() {
        let text = LayerResultRow.reviewRowText(termTexts: ["acme"], pages: nil)
        #expect(text == "'acme' is still readable in the document. "
                + "It matches text you redacted elsewhere. "
                + "Use text search to redact remaining instances.")
    }

    @Test("rowSubtitleText composes for attention rows with terms")
    func subtitleComposesForAttention() {
        let layer = attentionLayer(terms: ["DELIA"], pages: [1, 2])
        #expect(LayerResultRow.rowSubtitleText(layer: layer)
                == LayerResultRow.reviewRowText(termTexts: ["DELIA"], pages: [1, 2]))
    }

    @Test("rowSubtitleText falls back to shortDescription without terms")
    func subtitleFallsBackWithoutTerms() {
        let noTerms = attentionLayer(terms: nil, pages: [1])
        #expect(LayerResultRow.rowSubtitleText(layer: noTerms) == "engine short line")
        let emptyTerms = attentionLayer(terms: [], pages: [1])
        #expect(LayerResultRow.rowSubtitleText(layer: emptyTerms) == "engine short line")
    }

    @Test("Non-attention rows keep their shortDescription")
    func nonAttentionUnchanged() {
        let warn = LayerResult(
            name: "OCR Check", symbolName: "shield", status: .warn("w"),
            shortDescription: "warn line", detailDescription: "",
            pageReferences: nil, durationSeconds: 0,
            reviewTermTexts: ["should be ignored"])
        #expect(LayerResultRow.rowSubtitleText(layer: warn) == "warn line")
    }

    @Test("Spoken row label speaks the composed attention sentence")
    func spokenLabelUsesComposedText() {
        let layer = attentionLayer(terms: ["DELIA"], pages: [1, 2])
        let label = LayerResultRow.accessibilityLabel(layerIndex: 3, layer: layer)
        #expect(label.contains("Check needs review."))
        #expect(label.contains("'DELIA' is still readable on pages 2 and 3."))
    }
}
