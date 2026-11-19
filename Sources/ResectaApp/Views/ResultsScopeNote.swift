import SwiftUI
import RedactionEngine

// The small print under the results screen's buttons on a run titled
// Checks Passed: one paragraph made of the sentences it is given, joined by
// single spaces, in the style of the reason under Share. On any other title,
// or with no sentences, it draws nothing and takes no room.

struct ResultsScopeNote: View {
    let report: VerificationReport
    let sentences: [String]

    var body: some View {
        if let paragraph = Self.paragraph(report: report, sentences: sentences) {
            Text(paragraph)
                .font(.footnote)
                .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ResectaTokens.Spacing.md)
                .padding(.top, ResectaTokens.Results.reasonGap)
                .accessibilityIdentifier("checksPassedScope")
        }
    }

    /// The sentences joined by single spaces; nil when there are none.
    static func joined(_ sentences: [String]) -> String? {
        sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// Shown only on a run titled Checks Passed, and only with sentences.
    static func shows(report: VerificationReport, sentences: [String]) -> Bool {
        !sentences.isEmpty
            && VerificationResultsView.mastheadTitle(report: report) == VerificationStatus.pass.title
    }

    /// The paragraph drawn, or nil.
    static func paragraph(report: VerificationReport, sentences: [String]) -> String? {
        shows(report: report, sentences: sentences) ? joined(sentences) : nil
    }
}
