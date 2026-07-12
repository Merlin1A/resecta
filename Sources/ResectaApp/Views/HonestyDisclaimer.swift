import SwiftUI
import RedactionEngine

// Honesty disclaimer for audit dashboard.
// Exact text legally reviewed — mechanism-description language ONLY.
// Profile A and Profile B have different wording. Do NOT rephrase.
// Always visible. Never removable. No dismiss button.

struct HonestyDisclaimer: View {
    var profile: DocumentProfile = .unredacted

    var body: some View {
        Text(disclaimerText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, ResectaTokens.Spacing.lg)
            .accessibilityLabel("Disclaimer: \(disclaimerText)")
    }

    /// Profile-specific disclaimer — exact strings, legally reviewed.
    private var disclaimerText: String {
        switch profile {
        case .unredacted:
            "This audit checks for known structural elements and metadata patterns. It is designed to assist with document review but may not detect all forms of embedded or hidden content."
        case .redacted:
            "This audit checks redaction marks for known failure patterns including text under overlays, recoverable document history, and metadata remnants. Verification is designed to help identify potential issues but cannot guarantee that all content has been successfully removed. Users are responsible for verifying that redaction output meets their specific requirements."
        }
    }
}
