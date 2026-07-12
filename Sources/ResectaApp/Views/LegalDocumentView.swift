import SwiftUI

// Read-only in-app viewer for the bundled legal
// documents, presented from the first-launch gate so the EULA and Privacy
// Policy are readable BEFORE agreeing. View-only by design: no
// acceptance state is read or written here, and dismissing returns to the
// still-blocking gate. The documents render from the app bundle (no egress —
// the Settings-side resecta.app links stay the out-of-process Safari route
// for post-acceptance browsing; this surface must work offline at first
// launch). Bundled copies are byte-pinned to the repo-root EULA.md /
// PRIVACY.md by LegalDocumentBundleTests, so the text shown here is the text
// published at resecta.app.

/// The two bundled legal documents the first-launch gate can present.
enum LegalDocument: String, Identifiable {
    case eula = "EULA"
    case privacyPolicy = "PRIVACY"

    var id: String { rawValue }

    /// Bundle resource name (repo-root Markdown, routed through project.yml
    /// `sources:` with an explicit resources buildPhase).
    var resourceName: String { rawValue }

    /// Navigation title — shares the gate link-label string so the sheet the
    /// user lands in is named exactly what they tapped.
    var titleKey: String.LocalizationValue {
        switch self {
        case .eula: "eula_view_eula"
        case .privacyPolicy: "eula_view_privacy"
        }
    }
}

/// Minimal read-only Markdown presenter for the bundled legal documents.
///
/// Deliberately NOT a general document viewer: it renders the two known,
/// guard-pinned files verbatim — headings and paragraphs — with no links, no
/// selection actions, and no state side effects. Inline emphasis goes through
/// `AttributedString(markdown:)` with `.inlineOnlyPreservingWhitespace`, which
/// renders `**bold**` / `*italic*` while keeping the document's own line
/// structure and never synthesizing tappable URLs.
struct LegalDocumentView: View {
    let document: LegalDocument

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ResectaTokens.Spacing.md) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ResectaTokens.Spacing.md)
            }
            .navigationTitle(String(localized: document.titleKey, table: "Legal"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "legal_doc_done", table: "Legal")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("legalDocumentDone")
                }
            }
        }
        .accessibilityIdentifier("legalDocumentView")
    }

    // MARK: - Content

    /// One paragraph-level unit of the document.
    private enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
    }

    /// The document split into blank-line-separated blocks, with `#`-prefixed
    /// blocks classified as headings. Anything unreadable (missing resource —
    /// which LegalDocumentBundleTests fails the build over) degrades to a
    /// visible fallback line rather than an empty sheet.
    private var blocks: [Block] {
        guard
            let url = Bundle.main.url(
                forResource: document.resourceName, withExtension: "md"),
            let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            return [.paragraph(String(
                localized: "legal_doc_unavailable", table: "Legal"))]
        }
        return contents
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { block -> Block in
                if block.hasPrefix("## ") {
                    return .heading(level: 2, text: String(block.dropFirst(3)))
                }
                if block.hasPrefix("# ") {
                    return .heading(level: 1, text: String(block.dropFirst(2)))
                }
                return .paragraph(block)
            }
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(level == 1 ? .title2.weight(.semibold) : .headline)
                .padding(.top, level == 1 ? 0 : ResectaTokens.Spacing.sm)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(Self.inlineMarkdown(text))
                .font(.body)
        }
    }

    /// Inline-only Markdown pass: emphasis renders, line structure is kept
    /// verbatim, and block syntax is never reinterpreted — the legal text
    /// stays the legal text.
    ///
    /// HTML comments are stripped before parsing. The repo-root sources carry
    /// same-line `<!-- LegalPhrases:safe -->` audit-lint markers, and
    /// `.inlineOnlyPreservingWhitespace` passes inline HTML through as
    /// literal text (verified on-sim, LR-6) — the markers must stay in the
    /// .md files for the lint but never reach the sheet. Comments in the two
    /// known documents are always single-line.
    nonisolated static func inlineMarkdown(_ text: String) -> AttributedString {
        let stripped = text.replacingOccurrences(
            of: " ?<!--.*?-->", with: "", options: .regularExpression)
        return (try? AttributedString(
            markdown: stripped,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(stripped)
    }
}
