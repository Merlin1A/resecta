import SwiftUI
import RedactionEngine

// The results screen's findings that the checks of the redacted PDF cannot
// see: what each one is, its words and its pages. The checks read the
// output; these facts live in the original document or in the run's inputs,
// so no check row can carry them. This file is the one home each of them
// is added to: the value (`ResultsFinding`), its derivation from the
// real state (`ResultsFindings.derive`) and its rows (`ResultsFindingsSection`).

/// One fact about the run that no check of the redacted PDF can report.
enum ResultsFinding: Hashable {
    /// An annotation in the original sits over text no redaction box
    /// covers. The export is rebuilt from the page content, which carries
    /// no annotations, so that text is visible in it (`ConcealingAnnotations`).
    case coveredTextInOriginal(pages: [Int])

    static let coveredTextTitle = "Covered text in the original"

    var title: String {
        switch self {
        case .coveredTextInOriginal: Self.coveredTextTitle
        }
    }

    /// The sentence. The covered-text one is the share confirm's
    /// own line, so the results screen and the confirm say the same words.
    var sentence: String {
        switch self {
        case .coveredTextInOriginal(let pages): ConcealingAnnotations.confirmLine(pages: pages)
        }
    }

    /// 0-based pages it names; its page links open the Preview there.
    var pages: [Int] {
        switch self {
        case .coveredTextInOriginal(let pages): pages
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .coveredTextInOriginal: "resultsFinding_coveredText"
        }
    }

    /// VoiceOver reads the title, then the sentence (which names the pages).
    /// No document text.
    var spokenLabel: String { "\(title). \(sentence)" }
}

enum ResultsFindings {
    /// The findings for the open document, its boxes and its import facts,
    /// in screen order. `ConcealingAnnotations.pages` is synchronous PDFKit
    /// work, the same call the Share tap makes; the results view runs it
    /// when it appears and when the boxes change, never in `body`.
    static func derive(documentState: DocumentState, redactionState: RedactionState) -> [ResultsFinding] {
        let covered = ConcealingAnnotations.pages(
            in: documentState.sourceDocument, regions: redactionState.regions,
            textLayerStatus: documentState.textLayerStatus)
        return covered.isEmpty ? [] : [.coveredTextInOriginal(pages: covered)]
    }
}

/// The findings, one row each, in a headerless section under the actions.
/// A row reads like a needs-review row: the mark, the title, the sentence,
/// the page links. Nothing renders when the list is empty.
struct ResultsFindingsSection: View {
    let findings: [ResultsFinding]
    /// Page links show only while the redacted PDF exists.
    var pagesOnChips: Bool = false
    var onOpenPage: (Int) -> Void = { _ in }

    var body: some View {
        if !findings.isEmpty {
            GroupedSection {
                ForEach(Array(findings.enumerated()), id: \.element) { position, item in
                    if position > 0 { GroupedRowDivider() }
                    row(item)
                }
            }
            .padding(.top, ResectaTokens.Results.blockGap)
        }
    }

    private func row(_ item: ResultsFinding) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Image(systemName: VerificationOutcome.needsReview.markSymbolName)
                .font(.system(size: ResectaTokens.Results.leadMark))
                .foregroundStyle(LayerResultRow.groupedMarkColor(.needsReview))
                .frame(width: ResectaTokens.Results.leadColumn)
                .padding(.leading, ResectaTokens.Spacing.md)
                .padding(.trailing, ResectaTokens.Results.titleInset
                         - ResectaTokens.Spacing.md - ResectaTokens.Results.leadColumn)
            VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(item.sentence)
                    .font(.subheadline)
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    .fixedSize(horizontal: false, vertical: true)
                if pagesOnChips, !item.pages.isEmpty {
                    FlowLayout(spacing: ResectaTokens.Spacing.xs) {
                        ForEach(item.pages, id: \.self) { page in
                            PageChip(pageIndex: page) { onOpenPage(page) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, ResectaTokens.Spacing.md)
        }
        .padding(.vertical, ResectaTokens.Spacing.sm + ResectaTokens.Spacing.xs - 1)
        .frame(minHeight: ResectaTokens.Results.rowMinHeight)
        // One element per row; each page is a named action, as on a
        // collapsed check row.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.spokenLabel)
        .accessibilityActions {
            if pagesOnChips {
                ForEach(item.pages, id: \.self) { page in
                    Button("Go to page \(page + 1)") { onOpenPage(page) }
                }
            }
        }
        .accessibilityIdentifier(item.accessibilityIdentifier)
    }
}
