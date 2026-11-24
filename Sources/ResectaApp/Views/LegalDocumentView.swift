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
// published at resecta.app. What Boxes Can Show is the one page that is not a
// legal document: in-app words bundled from Resources/, opened from Settings
// and from the results screen's boxes line.

/// The bundled pages shown read-only: the legal documents the first-launch
/// gate can present, and What Boxes Can Show.
enum LegalDocument: String, Identifiable, CaseIterable {
    case eula = "EULA"
    case privacyPolicy = "PRIVACY"
    /// The repo-root NOTICE: the third-party data and typeface attributions
    /// the product ships (Apache License 2.0, section 4(d)).
    case acknowledgements = "NOTICE"
    /// What a box can still show, what Cover Other Words does, what stays in
    /// the document, what Checks Passed means, AI tools, and what Search does
    /// not look for. Opened from Settings and from the results screen.
    case whatBoxesCanShow = "WhatBoxesCanShow"

    var id: String { rawValue }

    /// Bundle resource name (repo-root files, routed through project.yml
    /// `sources:` with an explicit resources buildPhase).
    var resourceName: String { rawValue }

    /// The repo-root file's extension: Markdown for the two legal texts,
    /// none for NOTICE.
    var fileExtension: String? {
        self == .acknowledgements ? nil : "md"
    }

    /// The file name (`EULA.md`, `PRIVACY.md`, `NOTICE`,
    /// `WhatBoxesCanShow.md`).
    var fileName: String {
        fileExtension.map { "\(resourceName).\($0)" } ?? resourceName
    }

    /// Where the file sits in the repository: the root for the three legal
    /// files, the app's Resources folder for What Boxes Can Show.
    var sourcePath: String {
        self == .whatBoxesCanShow ? "Resources/\(fileName)" : fileName
    }

    /// Navigation title — shares the gate link-label string so the sheet the
    /// user lands in is named exactly what they tapped.
    var titleKey: String.LocalizationValue {
        switch self {
        case .eula: "eula_view_eula"
        case .privacyPolicy: "eula_view_privacy"
        case .acknowledgements: "eula_view_acknowledgements"
        case .whatBoxesCanShow: "boxes_page_title"
        }
    }

    /// The page's name: its navigation title, and the label of every row
    /// that opens it.
    var title: String { String(localized: titleKey, table: "Legal") }
}

/// Minimal read-only Markdown presenter for the bundled legal documents.
///
/// Deliberately NOT a general document viewer: it renders the known,
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
            .navigationTitle(document.title)
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
    nonisolated enum Block: Equatable {
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
                forResource: document.resourceName, withExtension: document.fileExtension),
            let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            return [.paragraph(String(
                localized: "legal_doc_unavailable", table: "Legal"))]
        }
        return Self.blocks(in: contents)
    }

    /// The text split into blank-line-separated blocks, `#`-prefixed blocks
    /// read as headings.
    nonisolated static func blocks(in contents: String) -> [Block] {
        contents
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
            // The acknowledgements file is plain text with hard line breaks
            // and lined section breaks: a monospaced footnote keeps its
            // layout readable.
            Text(Self.inlineMarkdown(text))
                .font(document == .acknowledgements ? .system(.footnote, design: .monospaced) : .body)
        }
    }

    /// Inline-only Markdown pass: emphasis renders, line structure is kept
    /// verbatim, and block syntax is never reinterpreted — the legal text
    /// stays the legal text.
    ///
    /// HTML comments are stripped before parsing. The repo-root sources carry
    /// same-line `<!-- LegalPhrases:safe -->` audit-lint markers, and
    /// `.inlineOnlyPreservingWhitespace` passes inline HTML through as
    /// literal text (verified on-sim) — the markers must stay in the
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
