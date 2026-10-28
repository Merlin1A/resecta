import SwiftUI
import RedactionEngine

// Display properties for verification status.
// App target only — engine package has zero UI dependencies.

extension VerificationStatus {

    // MARK: - SF Symbols

    var symbolName: String {
        switch self {
        case .pass:      "checkmark.shield.fill"
        case .warn:      "exclamationmark.shield.fill"
        case .info:      "info.circle.fill"
        case .attention: "shield.lefthalf.filled"
        case .fail:      "xmark.shield.fill"
        case .skipped:   "shield.slash"
        case .notApplicable: "minus.circle"
        }
    }

    // MARK: - Colors

    var color: Color {
        switch self {
        case .pass:      .green
        case .warn:      .orange   // Changed from .yellow — contrast improvement
        case .info:      ResectaTokens.SemanticColor.searchableMode
        case .attention: .pink     // urgent family, distinct from warn orange / fail red
        case .fail:      .red
        case .skipped, .notApplicable: .secondary
        }
    }

    /// Neutral gray for PASS during .verifying phase to prevent
    /// premature confidence anchoring. FAIL/WARN shown immediately.
    var intermediateColor: Color {
        switch self {
        case .pass:      .secondary
        case .warn:      .orange   // Changed from .yellow
        case .info:      ResectaTokens.SemanticColor.searchableMode
        case .attention: .pink
        case .fail:      .red
        case .skipped, .notApplicable: .secondary
        }
    }

    /// WCAG-AA text tier for SMALL STATUS TEXT. `color`
    /// / `intermediateColor` above stay the GLYPH tier (system hues,
    /// which measure too low a contrast for small text in some
    /// combinations); this routes through the measured
    /// `ResectaTokens.SemanticColor.*Text` shades instead. `.skipped`
    /// has no dedicated text-tier shade — `.secondary` already clears
    /// AA for small text at every size.
    var textColor: Color {
        switch self {
        case .pass:      ResectaTokens.SemanticColor.passText
        case .warn:      ResectaTokens.SemanticColor.warnText
        case .info:      ResectaTokens.SemanticColor.infoText
        case .attention: ResectaTokens.SemanticColor.attentionText
        case .fail:      ResectaTokens.SemanticColor.failText
        case .skipped:   .secondary
        case .notApplicable: ResectaTokens.SemanticColor.supportText
        }
    }

    // MARK: - Titles

    /// The status-level title — the entry flash's, and the masthead's on
    /// every verdict but a WARN with a check that could not verify, which
    /// the results view titles `Some Checks Incomplete` from its rows. An
    /// INFO never aggregates; it reads as a pass. The no-break space keeps
    /// "with Warnings" together.
    var title: String {
        switch self {
        case .pass, .info: "Checks Passed"
        case .warn:        "Completed with\u{00A0}Warnings"
        case .attention:   "Needs Review"
        case .fail:        "Checks Failed"
        case .skipped:     "Verification Skipped"
        case .notApplicable: "Nothing to Check"
        }
    }

    // MARK: - Accessibility

    /// Layer-scoped VoiceOver phrase for a single check, in the Verification
    /// Details words (a skipped check could not verify). Never a phrase about
    /// the OVERALL run: spoken per-layer mid-run, that would be the same
    /// premature-confidence anchoring problem intermediateColor exists to
    /// prevent. The run's end is spoken by
    /// `VerificationResultsView.completionAnnouncement(report:)`, in the
    /// masthead's words; the finished rows speak their outcome's word.
    var layerAccessibilityPhrase: String {
        switch self {
        case .pass:      "Passed."
        case .warn:      "Warning."
        case .info:      "Note."
        case .attention: "Needs review."
        case .fail:      "Failed."
        case .skipped:   "Could not verify."
        case .notApplicable: "Nothing to check."
        }
    }
}

extension LayerResult {
    /// Spoken announcement when this layer completes mid-run
    /// (PipelineCoordinator's `UIAccessibility.post(.announcement, …)`
    /// sites). warn/fail/info append `shortDescription` — for those rows it
    /// IS the payload ("OCR could not be run on 1 page."); pass/skipped stay
    /// a plain phrase so an eleven-layer run isn't eleven sentences of filler.
    func completionAnnouncement(layerNumber: Int) -> String {
        switch status {
        case .warn, .fail, .info, .attention, .notApplicable:
            "Layer \(layerNumber), \(name), \(status.layerAccessibilityPhrase) \(shortDescription)"
        case .pass, .skipped:
            "Layer \(layerNumber), \(name), \(status.layerAccessibilityPhrase)"
        }
    }
}
