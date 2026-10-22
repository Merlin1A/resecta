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
            == "Choose how redacted output is produced. Secure Rasterization produces image-only output with all text removed; Searchable Redaction preserves non-redacted text, except on pages whose text shows no ink."
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

    @Test("Toast has no line cap at the accessibility sizes, for every severity",
          arguments: [
            ToastSeverity.info,
            .success,
            .warning,
            .error,
          ])
    func testToastAtAccessibilitySizesHasNoCap(severity: ToastSeverity) {
        for size in [DynamicTypeSize.accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5] {
            #expect(ToastView.toastLineLimit(severity: severity, dynamicTypeSize: size) == nil, "\(size)")
        }
        #expect(ToastView.toastLineLimit(severity: severity, dynamicTypeSize: .xxxLarge) == 2,
                "the largest standard size keeps the two-line cap")
    }

    @Test("Toast has no cap at AX5 for every severity",
          arguments: [
            ToastSeverity.info,
            .success,
            .warning,
            .error,
          ])
    func testToastAtAX5HasNoCap(severity: ToastSeverity) {
        #expect(
            ToastView.toastLineLimit(
                severity: severity,
                dynamicTypeSize: .accessibility5
            ) == nil
        )
    }

    @Test("The toast's icon stacks above the text at the accessibility sizes, beside it at the standard sizes")
    func testToastIconStacksAtAccessibilitySizes() {
        for size in [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5] {
            #expect(ToastView.stacksIconAboveText(size), "\(size)")
        }
        for size in [DynamicTypeSize.large, .xxxLarge] {
            #expect(!ToastView.stacksIconAboveText(size), "\(size)")
        }
    }

    @Test("Toast has no cap at AX4 (the second sentence shows whole)")
    func testToastAtAX4HasNoCap() {
        #expect(
            ToastView.toastLineLimit(
                severity: .info,
                dynamicTypeSize: .accessibility4
            ) == nil
        )
        #expect(
            ToastView.toastLineLimit(
                severity: .warning,
                dynamicTypeSize: .accessibility4
            ) == nil
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

    /// The row's spoken label over its display model.
    private static func rowLabel(_ layer: LayerResult) -> String {
        LayerResultRow.accessibilityLabel(model: .init(layer: layer, perPageModes: []), layer: layer)
    }

    @Test("Layer-scoped phrases never reuse the overall-run phrasing",
          arguments: [
            (VerificationStatus.pass, "Passed."),
            (VerificationStatus.warn("w"), "Warning."),
            (VerificationStatus.info("i"), "Note."),
            (VerificationStatus.attention("a"), "Needs review."),
            (VerificationStatus.fail("f"), "Failed."),
            (VerificationStatus.skipped, "Could not verify."),
          ])
    func testLayerAccessibilityPhrase(status: VerificationStatus, expected: String) {
        // Per-layer surfaces must not speak "All checks completed without
        // issues." after each of up to 10 layers mid-run — that is the
        // spoken twin of the premature-confidence anchoring that
        // intermediateColor prevents visually.
        #expect(status.layerAccessibilityPhrase == expected)
        #expect(status.layerAccessibilityPhrase != status.accessibilityLabel)
    }

    // The duration is not spoken: it is not
    // in the collapsed row any more (the expanded row's "Took … s" line is
    // its own reachable element), so the label ends at the page count.
    @Test("Row label speaks the reported diagnostic and page count, never the duration")
    func testRowLabelWarnWithPagesAndDuration() {
        let label = Self.rowLabel(Self.layer(
            status: .warn("w"),
            shortDescription: "OCR could not be run on 1 page.",
            pageReferences: [3, 7],
            durationSeconds: 1.34
        ))
        #expect(label == "OCR Check, Warning. OCR could not be run on 1 page., 2 affected pages")
    }

    // The expanded row's last line: "Took under 0.1 s" for every duration
    // below a tenth of a second (six of ten layers finish there — "0.0s"
    // read as "did not run"), else one decimal with a space before the unit.
    @Test("The expanded timing line prints the under-0.1 s floor and one decimal above it",
          arguments: [
            (0.04, "Took under 0.1 s"),
            (0.1, "Took 0.1 s"),
            (1.34, "Took 1.3 s"),
            (0.0, "Took under 0.1 s"),
          ])
    func expandedTimingTextPinsTheUnderOneTenthFloor(seconds: Double, expected: String) {
        #expect(LayerResultRow.expandedTimingText(durationSeconds: seconds) == expected)
    }

    @Test("Row label singular page suffix")
    func testRowLabelSingularPage() {
        let label = Self.rowLabel(Self.layer(
            status: .fail("f"),
            shortDescription: "Text remains on 1 page.",
            pageReferences: [0]
        ))
        #expect(label.contains("1 affected page,") == false)
        #expect(label.hasSuffix("Text remains on 1 page., 1 affected page"))
    }

    @Test("Row label pass: no page suffix, no duration tail at zero")
    func testRowLabelPassNoSuffixes() {
        let label = Self.rowLabel(Self.layer(status: .pass))
        // No identity: the title is the engine name, the caption its line.
        #expect(label == "OCR Check, Passed. No issues found.")
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
            == "Layer 2, OCR Check, Warning. OCR could not be run on 1 page."
        )

        let fail = Self.layer(
            status: .fail("f"),
            shortDescription: "Text remains on 1 page."
        )
        #expect(
            fail.completionAnnouncement(layerNumber: 6)
            == "Layer 6, OCR Check, Failed. Text remains on 1 page."
        )

        // pass/skipped stay a plain phrase — no filler sentence per layer.
        #expect(
            Self.layer(status: .pass).completionAnnouncement(layerNumber: 1)
            == "Layer 1, OCR Check, Passed."
        )
        #expect(
            Self.layer(status: .skipped).completionAnnouncement(layerNumber: 9)
            == "Layer 9, OCR Check, Could not verify."
        )
    }

    // MARK: - The accessibility rows (the P3 review's ten)

    @Test("Search sheet header stacks Dismiss, the title and Apply from the first accessibility size",
          arguments: [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5])
    func testHeaderStacksAtAccessibilitySizes(size: DynamicTypeSize) {
        #expect(SearchSheetHeaderSection.stacksAtAccessibilitySizes(size))
    }

    @Test("Search sheet header keeps its single row below the accessibility sizes",
          arguments: [DynamicTypeSize.xSmall, .large, .xxxLarge])
    func testHeaderRowBelowAccessibilitySizes(size: DynamicTypeSize) {
        #expect(!SearchSheetHeaderSection.stacksAtAccessibilitySizes(size))
    }

    @Test("Toast icon scales with the message and keeps a 20-pt floor, never a fixed box")
    func testToastIconScalesWithItsText() {
        #expect(ToastView.toastIconFont == .callout.weight(.medium))
        #expect(ToastView.toastIconMinimumSide == 20)
    }

    @Test("Search result row speaks the category, the page, the tier and 'applied' — the shape 'Address, page 1, medium confidence, applied'")
    func testSearchRowLabelShape() {
        let address = SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03),
            matchedText: "12 Elm Street",
            contextSnippet: "lives at 12 Elm Street since",
            source: .textLayer,
            term: "Address",
            piiCategory: .address,
            piiConfidence: 0.6
        )
        #expect(SearchResultRow.spokenCategory(for: address) == "Address")
        let spoken = SearchResultRow.accessibilityLabel(
            for: address, tier: .medium, showsTier: true, isApplied: true
        )
        #expect(spoken == "Address, page 1, medium confidence, applied")
        #expect(!spoken.contains("Elm"))

        let literal = SearchResult(
            pageIndex: 4,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03),
            matchedText: "Amount",
            contextSnippet: "the Amount due",
            source: .textLayer,
            term: "Amount"
        )
        #expect(SearchResultRow.spokenCategory(for: literal) == nil)
        #expect(SearchResultRow.accessibilityLabel(for: literal, tier: .high, showsTier: false)
                == "Search match, page 5")
    }

    @Test("Search result rows carry a per-row identifier keyed by the result's id")
    func testSearchRowIdentifier() {
        let result = SearchResult(
            pageIndex: 0,
            normalizedRect: .zero,
            matchedText: "a",
            contextSnippet: "a",
            source: .textLayer,
            term: "a"
        )
        #expect(SearchResultRow.accessibilityIdentifier(for: result)
                == "searchResultRow-\(result.id.uuidString)")
    }

    @Test("A staged term's remove control is named 'Remove ⟨term⟩'")
    func testRemoveTermLabel() {
        #expect(SearchToolbarSection.removeTermAccessibilityLabel("Amount") == "Remove Amount")
    }

    @Test("The Custom Terms add row's controls sit on the 46-pt effective floor")
    func testAddRowControlFloor() {
        #expect(CustomTermsView.addRowControlMinimumSide == 46)
        #expect(CustomTermsView.addRowControlMinimumSide == ResectaTokens.TouchTarget.minimum)
    }

    @Test("The parked strip's Apply capsule is named 'Applied' once the match is marked")
    func testApplyCapsuleLabelFollowsItsState() {
        #expect(SearchAndRedactSheet.applyAccessibilityLabel(applied: false) == "Apply")
        #expect(SearchAndRedactSheet.applyAccessibilityLabel(applied: true) == "Applied")
        #expect(SearchAndRedactSheet.applyAccessibilityLabel(applied: true) == AppliedFilter.applied.rawValue)
    }

    @Test("The page bar's counter is one spoken element: 'Page k of N, n regions'")
    func testPageBarCounterLabel() {
        #expect(PageNavigationBar.pageAccessibilityLabel(page: 1, pageCount: 23, regionCount: 28)
                == "Page 1 of 23, 28 regions")
        #expect(PageNavigationBar.pageAccessibilityLabel(page: 3, pageCount: 5, regionCount: 1)
                == "Page 3 of 5, 1 region")
        #expect(PageNavigationBar.pageAccessibilityLabel(page: 2, pageCount: 5, regionCount: 0)
                == "Page 2 of 5")
    }

    @Test("The parked strip offers the 'Show full sheet' action")
    func testShowFullSheetActionName() {
        #expect(SearchAndRedactSheet.showFullSheetActionName == "Show full sheet")
    }
}
