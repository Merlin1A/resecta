import SwiftUI
import RedactionEngine

// UI_UX §4.1–§4.3a: Display properties for verification status.
// App target only — engine package has zero UI dependencies.

extension VerificationStatus {

    // MARK: - SF Symbols (ENGINE §6.8)

    var symbolName: String {
        switch self {
        case .pass:      "checkmark.shield.fill"
        case .warn:      "exclamationmark.shield.fill"
        case .info:      "info.circle.fill"
        case .attention: "shield.lefthalf.filled"
        case .fail:      "xmark.shield.fill"
        case .skipped:   "shield.slash"
        }
    }

    // MARK: - Colors (UI_UX §4.1)

    var color: Color {
        switch self {
        case .pass:      .green
        case .warn:      .orange   // A5.1: Changed from .yellow — contrast improvement
        case .info:      ResectaTokens.SemanticColor.searchableMode
        case .attention: .pink     // urgent family, distinct from warn orange / fail red
        case .fail:      .red
        case .skipped:   .secondary
        }
    }

    /// §4.3a: Neutral gray for PASS during .verifying phase to prevent
    /// premature confidence anchoring. FAIL/WARN shown immediately.
    var intermediateColor: Color {
        switch self {
        case .pass:      .secondary
        case .warn:      .orange   // A5.1: Changed from .yellow
        case .info:      ResectaTokens.SemanticColor.searchableMode
        case .attention: .pink
        case .fail:      .red
        case .skipped:   .secondary
        }
    }

    // MARK: - Titles (UI_UX §4.1 — mechanism-description language, R1)

    var title: String {
        switch self {
        case .pass:      "Checks Passed"
        case .warn:      "Completed with Notes"
        case .info:      "Metadata Notes"
        case .attention: "Attention Needed"
        case .fail:      "Issues Found"
        case .skipped:   "Verification Skipped"
        }
    }

    var subtitle: String {
        switch self {
        case .pass:    "All verification layers completed without issues."
        case .warn:    "Verification completed. Review notes below before sharing."
        case .info:    "Document metadata found. No action required."
        // Report-aware sites (the results masthead) name the exact text via
        // the report's review terms; this status-level line stays generic.
        case .attention: "Unredacted text remains — review the items below."
        case .fail:    "Review the findings below. You can adjust regions and run redaction again, or share after reviewing."
        // Cause-neutral fallback — VerificationStatus cannot see the report's
        // skipReason. Report-aware sites (the results masthead) derive
        // reason-specific copy from the report instead.
        case .skipped: "Verification did not run for this output. Run it before sharing."
        }
    }

    // MARK: - Accessibility (UI_UX §4.1)

    var accessibilityLabel: String {
        switch self {
        case .pass:    "Verification passed. All checks completed without issues."
        case .warn:    "Verification completed with notes. Review the notes before sharing."
        case .info:    "Document metadata note. Informational only."
        case .attention: "Attention needed. Unredacted text remains — review before sharing."
        case .fail:    "Verification found issues. Review issues below before sharing."
        case .skipped: "Verification was skipped. Consider verifying before sharing."
        }
    }

    /// Layer-scoped VoiceOver phrase for a single check. `accessibilityLabel`
    /// above describes the OVERALL run ("All checks completed without
    /// issues.") — spoken per-row or per-layer mid-run, that phrasing is the
    /// same premature-confidence anchoring §4.3a's intermediateColor exists
    /// to prevent. Per-layer surfaces (LayerResultRow, the coordinator's
    /// layer-completion announcements) speak this instead.
    var layerAccessibilityPhrase: String {
        switch self {
        case .pass:      "Check passed."
        case .warn:      "Check found a note."
        case .info:      "Informational note."
        case .attention: "Check needs review."
        case .fail:      "Check found an issue."
        case .skipped:   "Check was skipped."
        }
    }
}

extension LayerResult {
    /// Spoken announcement when this layer completes mid-run
    /// (PipelineCoordinator's `UIAccessibility.post(.announcement, …)`
    /// sites). warn/fail/info append `shortDescription` — for those rows it
    /// IS the payload ("OCR could not be run on 1 page."); pass/skipped stay
    /// a plain phrase so a 10-layer run isn't ten sentences of filler.
    func completionAnnouncement(layerNumber: Int) -> String {
        switch status {
        case .warn, .fail, .info, .attention:
            "Layer \(layerNumber), \(name), \(status.layerAccessibilityPhrase) \(shortDescription)"
        case .pass, .skipped:
            "Layer \(layerNumber), \(name), \(status.layerAccessibilityPhrase)"
        }
    }
}
