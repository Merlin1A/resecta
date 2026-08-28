import Testing
import SwiftUI
@testable import ResectaApp
@testable import RedactionEngine

// Pins the VoiceOver labels, hints, and values added by the
// Wave 1 accessibility sweep.
// The strings are exposed as `static` constants on each view so they can
// be unit-tested without rendering, mirroring the contract for
// `InlineWarningBanner.lineLimit(for:)`.

@Suite("Accessibility labels and hints")
struct AccessibilityLabelTests {

    // The triage batch-actions menu label and the triage
    // min-confidence slider label + spoken value retired with their
    // controls: the batch menu's job moved to the footer Select All +
    // Select-Where predicates, and the review-side confidence slider
    // followed the per-run Confidence slider out (predicates are the
    // confidence tools). The unified review surface's spoken contracts
    // are pinned by `FindingRowFamilyTests`.

    // MARK: - Settings picker hints

    @Test("Default Mode picker hint describes both pipeline modes")
    func testSettingsDefaultModeHint() {
        // The descriptive mode rows below the picker are
        // invisible to VoiceOver, so the hint carries the trade-off.
        // Mechanism-description language — no outcome
        // promise.
        #expect(
            SettingsView.defaultModeAccessibilityHint
            == "Choose how redacted output is produced. Secure Rasterization produces image-only output with all text removed; Searchable Redaction preserves non-redacted text, including text that is not visible on the page."
        )
    }

    @Test("Fill Color picker hint describes what the color controls")
    func testSettingsFillColorHint() {
        // The leading color swatch is .accessibilityHidden,
        // so without a hint VoiceOver announces "Fill Color, Black,
        // popup button" with no context on what gets filled.
        #expect(
            SettingsView.fillColorAccessibilityHint
            == "Color used to fill redacted regions in the output."
        )
    }

    @Test("Settings picker hints — both Default Mode and Fill Color pinned")
    func testSettingsPickerHints() {
        // Group test that re-asserts both picker hints in one place so
        // a future regression in either picker hint surfaces here even
        // if the individual tests are skipped.
        #expect(!SettingsView.defaultModeAccessibilityHint.isEmpty)
        #expect(!SettingsView.fillColorAccessibilityHint.isEmpty)
        #expect(SettingsView.defaultModeAccessibilityHint.contains("Secure Rasterization"))
        #expect(SettingsView.defaultModeAccessibilityHint.contains("Searchable Redaction"))
        #expect(SettingsView.fillColorAccessibilityHint.contains("redacted regions"))
    }

    // MARK: - Verify-Before-Export conditional hint

    @Test("Verify toggle default hint mentions verification before export")
    func testVerifyToggleDefaultHint() {
        // The default branch — when paranoid mode is off, the
        // hint describes the toggle's behavior using mechanism-description
        // copy.
        let hint = SettingsView.verifyToggleHint(paranoidMode: false)
        #expect(hint == SettingsView.verifyToggleDefaultHint)
        #expect(hint == "When enabled, the app runs verification checks before you can export")
    }

    @Test("Verify toggle paranoid hint explains the lock reason")
    func testParanoidLockedHint() {
        // The paranoid branch — when paranoid mode forces the
        // toggle on, swap the hint copy so VoiceOver explains *why* the
        // control reads as disabled. Paranoid-mode override #2 — paranoid mode
        // forces verification on; see SettingsView.workflowSection.
        let hint = SettingsView.verifyToggleHint(paranoidMode: true)
        #expect(hint == SettingsView.verifyToggleParanoidLockedHint)
        #expect(hint == "Locked on because Paranoid Mode is enabled.")
    }

    @Test("Verify toggle hint flips on paranoid mode change")
    func testVerifyToggleHintFlipsOnParanoidChange() {
        // The hint must differ between paranoid on/off so VoiceOver users
        // hear the lock reason when the toggle is forced on.
        #expect(
            SettingsView.verifyToggleHint(paranoidMode: true)
            != SettingsView.verifyToggleHint(paranoidMode: false)
        )
    }

    // MARK: - ToastView line-limit at AX5

    @Test("Toast caps at 2 lines for info severity below AX5")
    func testToastInfoBelowAX5CapsAtTwoLines() {
        // The compact-capsule contract, amended: the original 1-line
        // info cap truncated shipped messages mid-sentence at standard
        // text sizes (text-layer notice, dismissal-cleared counts), so
        // info matches the warning/error 2-line cap.
        #expect(
            ToastView.toastLineLimit(
                severity: .info,
                dynamicTypeSize: .large
            ) == 2
        )
    }

    @Test("Toast caps at 2 lines for success severity below AX5")
    func testToastSuccessBelowAX5CapsAtTwoLines() {
        #expect(
            ToastView.toastLineLimit(
                severity: .success,
                dynamicTypeSize: .large
            ) == 2
        )
    }

    @Test("Toast caps at 2 lines for warning severity below AX5")
    func testToastWarningBelowAX5CapsAtTwoLines() {
        // Attention-demanding severities get a second line so the
        // warning text isn't truncated mid-clause at standard sizes.
        #expect(
            ToastView.toastLineLimit(
                severity: .warning,
                dynamicTypeSize: .large
            ) == 2
        )
    }

    @Test("Toast caps at 2 lines for error severity below AX5")
    func testToastErrorBelowAX5CapsAtTwoLines() {
        #expect(
            ToastView.toastLineLimit(
                severity: .error,
                dynamicTypeSize: .large
            ) == 2
        )
    }

    @Test("Toast lifts to 3 lines at AX5 for every severity",
          arguments: [
            ToastSeverity.info,
            .success,
            .warning,
            .error,
          ])
    func testToastAtAX5LiftsToThreeLines(severity: ToastSeverity) {
        // At .accessibility5 the cap lifts to 3
        // lines for all severities, mirroring the InlineWarningBanner
        // pattern. Same lift applies regardless
        // of the per-severity baseline so long messages remain readable
        // when the text size is at its accessibility maximum.
        #expect(
            ToastView.toastLineLimit(
                severity: severity,
                dynamicTypeSize: .accessibility5
            ) == 3
        )
    }

    @Test("Toast stays at the severity baseline at AX4")
    func testToastAtAX4HoldsBaseline() {
        // .accessibility4 is the boundary below the AX5 lift — the
        // 2-line baseline still applies; the 3-line lift hasn't kicked in.
        #expect(
            ToastView.toastLineLimit(
                severity: .info,
                dynamicTypeSize: .accessibility4
            ) == 2
        )
        #expect(
            ToastView.toastLineLimit(
                severity: .warning,
                dynamicTypeSize: .accessibility4
            ) == 2
        )
    }

    // MARK: - Verification results action cards (nested-control fix)

    @Test("Share card VoiceOver label is pinned")
    func testShareCardAccessibilityLabel() {
        // The Share card was rebuilt as a single Button hosting
        // `HomeChoiceCardContent`; its spoken label is set explicitly via
        // this constant so the rebuild can't silently drop or alter the
        // VoiceOver string. (Combined content + explicit .accessibilityLabel
        // → one button element reading this label.)
        #expect(
            VerificationResultsView.shareCardAccessibilityLabel
            == "Share Document. Save the redacted PDF or share it from this device."
        )
    }

    @Test("Preview card VoiceOver label is pinned")
    func testPreviewCardAccessibilityLabel() {
        // The Preview card was rebuilt as a single NavigationLink hosting
        // `HomeChoiceCardContent`; same explicit-label contract as Share.
        #expect(
            VerificationResultsView.previewCardAccessibilityLabel
            == "Preview Redacted Document. Open the redacted output in a read-only viewer."
        )
    }

    // MARK: - Layer-scoped verification phrases + row labels

    private static func layer(
        status: VerificationStatus,
        shortDescription: String = "No issues found.",
        pageReferences: [Int]? = nil,
        durationSeconds: Double = 0
    ) -> LayerResult {
        LayerResult(
            name: "OCR Check",
            symbolName: "text.viewfinder",
            status: status,
            shortDescription: shortDescription,
            detailDescription: "Detail.",
            pageReferences: pageReferences,
            durationSeconds: durationSeconds
        )
    }

    @Test("Layer-scoped phrases never reuse the overall-run phrasing",
          arguments: [
            (VerificationStatus.pass, "Check passed."),
            (VerificationStatus.warn("w"), "Check found a note."),
            (VerificationStatus.info("i"), "Informational note."),
            (VerificationStatus.attention("a"), "Check needs review."),
            (VerificationStatus.fail("f"), "Check found an issue."),
            (VerificationStatus.skipped, "Check was skipped."),
          ])
    func testLayerAccessibilityPhrase(status: VerificationStatus, expected: String) {
        // Per-layer surfaces must not speak "All checks completed without
        // issues." after each of up to 10 layers mid-run — that is the
        // spoken twin of the premature-confidence anchoring that
        // intermediateColor prevents visually.
        #expect(status.layerAccessibilityPhrase == expected)
        #expect(status.layerAccessibilityPhrase != status.accessibilityLabel)
    }

    @Test("Row label speaks the reported diagnostic, page count, and duration")
    func testRowLabelWarnWithPagesAndDuration() {
        let label = LayerResultRow.accessibilityLabel(
            layerIndex: 2,
            layer: Self.layer(
                status: .warn("w"),
                shortDescription: "OCR could not be run on 1 page.",
                pageReferences: [3, 7],
                durationSeconds: 1.34
            )
        )
        #expect(label == "Layer 2, OCR Check, Check found a note. OCR could not be run on 1 page., 2 affected pages, 1.3 seconds")
    }

    @Test("Row label singular page suffix")
    func testRowLabelSingularPage() {
        let label = LayerResultRow.accessibilityLabel(
            layerIndex: 4,
            layer: Self.layer(
                status: .fail("f"),
                shortDescription: "Text remains on 1 page.",
                pageReferences: [0]
            )
        )
        #expect(label.contains("1 affected page,") == false)
        #expect(label.hasSuffix("Text remains on 1 page., 1 affected page"))
    }

    @Test("Row label pass: no page suffix, no duration tail at zero")
    func testRowLabelPassNoSuffixes() {
        let label = LayerResultRow.accessibilityLabel(
            layerIndex: 1,
            layer: Self.layer(status: .pass)
        )
        #expect(label == "Layer 1, OCR Check, Check passed. No issues found.")
    }

    @Test("Expand hint only on expandable rows",
          arguments: [
            (true, false, "Tap to expand details"),
            (true, true, "Tap to collapse details"),
            (false, false, ""),
            (false, true, ""),
          ])
    func testRowHintConditional(isExpandable: Bool, isExpanded: Bool, expected: String) {
        // VerificationProgressView rows are display-only (`onTap: {}`);
        // advertising a tap there promises a no-op.
        #expect(
            LayerResultRow.accessibilityHint(
                isExpandable: isExpandable, isExpanded: isExpanded
            ) == expected
        )
    }

    @Test("Layer completion announcement appends the diagnostic for warn/fail/info only")
    func testLayerCompletionAnnouncement() {
        let warn = Self.layer(
            status: .warn("w"),
            shortDescription: "OCR could not be run on 1 page."
        )
        #expect(
            warn.completionAnnouncement(layerNumber: 2)
            == "Layer 2, OCR Check, Check found a note. OCR could not be run on 1 page."
        )

        let fail = Self.layer(
            status: .fail("f"),
            shortDescription: "Text remains on 1 page."
        )
        #expect(
            fail.completionAnnouncement(layerNumber: 6)
            == "Layer 6, OCR Check, Check found an issue. Text remains on 1 page."
        )

        // pass/skipped stay a plain phrase — no filler sentence per layer.
        #expect(
            Self.layer(status: .pass).completionAnnouncement(layerNumber: 1)
            == "Layer 1, OCR Check, Check passed."
        )
        #expect(
            Self.layer(status: .skipped).completionAnnouncement(layerNumber: 9)
            == "Layer 9, OCR Check, Check was skipped."
        )
    }
}
