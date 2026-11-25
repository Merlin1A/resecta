import SwiftUI
import UIKit
import RedactionEngine

// One row of the results screen's Findings group: one problem of the run
// (`VerificationProblemModel.derive`), said once, with its pages. Closed,
// the row says the problem; opened, the step to take, then one line per
// check behind it and, for the two kinds about boxed text, every word that
// check reported. What a row says is a pure function of the problem and the
// report here, so the tests read the words the row draws. No sentence is
// cut out of another: each is read from the function that owns it.

/// What a problem's row says, by kind.
enum FindingRowModel {

    /// What the opened row leads with.
    enum Step: Equatable {
        case sentence(String)
        /// The shipped Review in Scan button.
        case reviewInScan
    }

    /// One line per check behind a problem, in the report's order.
    struct CheckLine: Equatable {
        let layerIndex: Int
        /// The share confirm's line for the check, with its own pages.
        let line: String
        /// The engine's sentence, for a check that could not run in full or
        /// could not finish.
        let sentence: String?
        /// Every word the check reported, whole, for the kinds about boxed text.
        let words: [String]
        /// Where the check stopped, when it stopped before it had read everything.
        let stopLines: [String]
    }

    // MARK: - New sentences

    static let boxedTextReadable = "Text matching what you boxed is still readable."
    static let partOfBoxedText = "Part of boxed text is readable beside its box."
    static let secureAvoidsThis = "Exporting as Secure Rasterization avoids this."
    static let lookAtThatPage = "Look at that page in Preview before you share."
    static let lookAtThosePages = "Look at those pages in Preview before you share."

    static func searchesStillMatch(_ count: Int) -> String {
        count == 1 ? "1 search still has matches." : "\(count) searches still have matches."
    }

    /// "1 check could not run in full on page 3." · "2 checks could not run
    /// in full on pages 3 and 7.", every page listed.
    static func couldNotRunInFull(checks: Int, pages: [Int]) -> String {
        let subject = checks == 1 ? "1 check" : "\(checks) checks"
        let location = VerificationRowModel.pageLocation(pages).map { " \($0)" } ?? ""
        return "\(subject) could not run in full\(location)."
    }

    static func skippedChecks(_ count: Int) -> String {
        count == 1 ? "1 check was skipped." : "\(count) checks were skipped."
    }

    // MARK: - The closed row

    /// The mark's outcome: its symbol and colour are that outcome's shipped
    /// ones. The form-values row keeps the mark the shipped row draws for it.
    static func markOutcome(_ problem: VerificationProblem) -> VerificationOutcome {
        if problem.kind == .formValuesNotCarried { return .needsReview }
        switch problem.mark {
        case .failed: return .failed
        case .needsReview: return .needsReview
        case .possibleItems: return .note
        case .couldNotVerify: return .couldNotVerify
        }
    }

    /// Whether the row draws page chips: only while the redacted PDF exists
    /// and the problem names pages.
    static func showsChips(_ problem: VerificationProblem, previewAvailable: Bool) -> Bool {
        previewAvailable && !problem.pages.isEmpty
    }

    /// The row's main line. A line built from the share confirm's own line
    /// leaves its page phrase out while chips show.
    static func mainLine(_ problem: VerificationProblem, report: VerificationReport,
                         previewAvailable: Bool) -> String {
        let chips = showsChips(problem, previewAvailable: previewAvailable)
        let first = problem.checks.first.map { report.layers[$0.layerIndex] }
        switch problem.kind {
        case .failedCheck:
            return factLine(first, outcome: "failed", withoutPages: chips)
        case .boxedTextReadable:
            return boxedTextReadable
        case .coveredTextInOriginal:
            return ResultsFinding.coveredTextTitle
        case .partOfBoxedText:
            return partOfBoxedText
        case .searchesStillMatch:
            return searchesStillMatch(problem.count ?? problem.checks.count)
        case .otherNeedsReview:
            if let first, first.layer == .detectionSweep {
                return VerificationRowModel.sweepRemainingCaption(first, pagesOnChips: chips)
            }
            return factLine(first, outcome: "needs review", withoutPages: chips)
        case .possibleItems:
            return first.map { VerificationRowModel.sweepRemainingCaption($0, pagesOnChips: chips) } ?? ""
        case .formValuesNotCarried:
            return ResultsFinding.filledFormValuesNotCarried(count: problem.count ?? 0).sentence
        case .couldNotRunOnPages:
            return couldNotRunInFull(checks: problem.count ?? problem.checks.count, pages: problem.pages)
        case .couldNotFinish:
            if let part = unreadPartLine(problem.checks.first, report: report) { return part }
            return factLine(first, outcome: "could not verify", withoutPages: chips)
        case .skippedChecks:
            return skippedChecks(problem.count ?? problem.checks.count)
        }
    }

    /// The line under the main line; nil when the kind has none. For the two
    /// kinds about boxed text it is the words (`closedWords`), drawn private.
    static func subLine(_ problem: VerificationProblem, report: VerificationReport,
                        fits: (String) -> Bool = { _ in true }) -> String? {
        let first = problem.checks.first.map { report.layers[$0.layerIndex] }
        switch problem.kind {
        case .failedCheck:
            return first?.shortDescription
        case .couldNotFinish:
            // The check's own sentence, or the sentence of the part it could
            // not read.
            return problem.checks.first?.sentence
        case .otherNeedsReview:
            return first?.layer == .detectionSweep ? nil : first?.shortDescription
        case .coveredTextInOriginal:
            return ConcealingAnnotations.confirmLine(pages: problem.pages)
        case .boxedTextReadable, .partOfBoxedText:
            return problem.words.isEmpty ? nil : closedWords(problem.words, fits: fits)
        case .searchesStillMatch, .possibleItems, .formValuesNotCarried, .couldNotRunOnPages, .skippedChecks:
            return nil
        }
    }

    /// Whether the line under the main line quotes the person's words.
    static func subLineIsPrivate(_ problem: VerificationProblem) -> Bool {
        problem.kind == .boxedTextReadable || problem.kind == .partOfBoxedText
    }

    /// The closed row's words: every word in quotes, joined as the app joins
    /// them, when that fits two lines; else the first word and "and ‹n›
    /// more", the masthead's form.
    static func closedWords(_ words: [String], fits: (String) -> Bool) -> String {
        let quoted = words.map { "\u{201C}\($0)\u{201D}" }
        let full = VerificationRowModel.quotedList(words)
        guard words.count > 1, !fits(full) else { return full }
        return "\(quoted[0]) and \(words.count - 1) more"
    }

    /// The pages the closed row shows as chips (at most five, else four and
    /// "+n more"); the opened row shows every page.
    static func chipPages(_ problem: VerificationProblem, isOpen: Bool) -> [Int] {
        isOpen ? problem.pages : LayerResultRow.collapsedChipPages(problem.pages)
    }

    static func moreChipsText(_ problem: VerificationProblem, isOpen: Bool) -> String? {
        isOpen ? nil : LayerResultRow.moreChipsText(problem.pages)
    }

    /// The closed row's spoken label: its main line and its pages. No
    /// document text: the words are elements of their own.
    static func spokenLabel(_ problem: VerificationProblem, report: VerificationReport,
                            previewAvailable: Bool) -> String {
        let main = VerificationRowModel.sentence(mainLine(problem, report: report, previewAvailable: previewAvailable))
        return ([main] + [VerificationRowModel.spokenPages(problem.pages)].compactMap { $0 }).joined(separator: " ")
    }

    // MARK: - The opened row

    /// The step, by kind; nil where the kind has none.
    static func step(_ problem: VerificationProblem, report: VerificationReport,
                     previewAvailable: Bool) -> Step? {
        let first = problem.checks.first.map { report.layers[$0.layerIndex] }
        switch problem.kind {
        case .failedCheck:
            // The checks a Secure export does not run: what they fail on is
            // text on a Searchable page, which a Secure export does not hold.
            guard let identity = first?.layer, !identity.appliesTo(.secureRasterization) else { return nil }
            return .sentence(secureAvoidsThis)
        case .partOfBoxedText:
            return .sentence(problem.words.count == 1
                ? VerificationRowModel.adjustTheBoxRemedy : VerificationRowModel.adjustTheBoxesRemedy)
        case .searchesStillMatch:
            let lines = problem.checks.flatMap {
                VerificationRowModel.lead(for: report.layers[$0.layerIndex], outcome: $0.outcome,
                                          perPageModes: report.perPageModes)
            }
            return lines.first.map(Step.sentence)
        case .otherNeedsReview:
            return first?.layer == .detectionSweep ? .reviewInScan : nil
        case .possibleItems:
            return .reviewInScan
        case .couldNotRunOnPages:
            guard previewAvailable, !problem.pages.isEmpty else { return nil }
            return .sentence(problem.pages.count == 1 ? lookAtThatPage : lookAtThosePages)
        case .boxedTextReadable, .coveredTextInOriginal, .formValuesNotCarried, .couldNotFinish, .skippedChecks:
            return nil
        }
    }

    /// One line per check behind the problem, in the report's order. None
    /// for a failed check and for possible items left: the closed row is
    /// already that check's line.
    static func checkLines(_ problem: VerificationProblem, report: VerificationReport) -> [CheckLine] {
        guard problem.kind != .failedCheck, problem.kind != .possibleItems else { return [] }
        let wordKind = problem.kind == .boxedTextReadable || problem.kind == .partOfBoxedText
        let sentenceKind = problem.kind == .couldNotRunOnPages || problem.kind == .couldNotFinish
        return problem.checks.map { check in
            // The part a failed or needs-review check could not read: the
            // share sheet's line for that part, its sentence, nothing else.
            if let part = unreadPartLine(check, report: report) {
                return CheckLine(layerIndex: check.layerIndex, line: part, sentence: sentenceKind ? check.sentence : nil,
                                 words: [], stopLines: [])
            }
            let layer = report.layers[check.layerIndex]
            let line = layer.status.isSkipped
                ? "\(VerificationRowModel.title(for: layer)): skipped"
                : DocumentEditorView.confirmFactLine(layer: layer, outcome: check.outcome.word.lowercased())
            var stops: [String] = []
            if layer.layer == .operatorReExtraction, layer.status.isAttention,
               let stop = VerificationRowModel.contentStreamStopLine(pages: layer.pageReferences,
                                                                     pageCount: report.perPageModes.count) {
                stops.append(stop)
            }
            if let stop = VerificationRowModel.stopLine(layer.stopped, pageCount: report.perPageModes.count) {
                stops.append(stop)
            }
            return CheckLine(layerIndex: check.layerIndex, line: line,
                             sentence: sentenceKind ? check.sentence : nil,
                             words: wordKind ? check.words : [], stopLines: stops)
        }
    }

    // MARK: - Helpers

    /// The share sheet's line for the part a failed or needs-review check
    /// could not read, when `check` is that part's entry: its outcome could
    /// not verify while its check failed or needs review. Nil otherwise.
    static func unreadPartLine(_ check: VerificationProblem.Check?, report: VerificationReport) -> String? {
        guard let check, check.outcome == .couldNotVerify else { return nil }
        return DocumentEditorView.couldNotVerifyPartLine(layer: report.layers[check.layerIndex])
    }

    /// The share confirm's line for a check; while chips carry the pages, the
    /// same call on a copy of the result with no pages.
    private static func factLine(_ layer: LayerResult?, outcome: String, withoutPages: Bool) -> String {
        guard let layer else { return "" }
        return DocumentEditorView.confirmFactLine(layer: withoutPages ? pageless(layer) : layer, outcome: outcome)
    }

    /// The result with no page references, every other field as it was.
    static func pageless(_ layer: LayerResult) -> LayerResult {
        LayerResult(name: layer.name, symbolName: layer.symbolName, status: layer.status,
                    shortDescription: layer.shortDescription, detailDescription: layer.detailDescription,
                    pageReferences: nil, durationSeconds: layer.durationSeconds,
                    reviewTermTexts: layer.reviewTermTexts, layer: layer.layer, queryLines: layer.queryLines,
                    couldNotVerify: layer.couldNotVerify, reviewIsFragment: layer.reviewIsFragment,
                    couldNotVerifyPart: layer.couldNotVerifyPart,
                    couldNotVerifyPartPages: layer.couldNotVerifyPartPages, stopped: layer.stopped)
    }
}

/// The row: closed, the mark, the main line, the line under it and the page
/// chips; opened in place on the shipped wash, the step, the checks' lines
/// and their words, and every page's chip.
struct FindingRow: View {
    let problem: VerificationProblem
    let report: VerificationReport
    let isOpen: Bool
    var previewAvailable: Bool = false
    let onTap: () -> Void
    var onOpenPage: (Int) -> Void = { _ in }
    var onReviewInScan: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The text column's width, for the closed words' two-line form.
    @State private var textWidth: CGFloat = 0

    private var chips: Bool { FindingRowModel.showsChips(problem, previewAvailable: previewAvailable) }
    private var spokenLabel: String {
        FindingRowModel.spokenLabel(problem, report: report, previewAvailable: previewAvailable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
                // Closed: one element, the main line and the pages, each page
                // a named action. Open: its parts, the main line the button.
                .accessibilityElement(children: isOpen ? .contain : .ignore)
                .modifier(FindingRowButton(applies: !isOpen, label: spokenLabel, isOpen: isOpen, action: onTap,
                                           pages: chips ? problem.pages : [], onOpenPage: onOpenPage))
            if isOpen {
                openedBlock
            }
        }
        .background(isOpen ? LayerResultRow.rowWash(colorScheme) : .clear)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("finding_\(problem.id)")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 0) {
            let outcome = FindingRowModel.markOutcome(problem)
            Image(systemName: outcome.markSymbolName)
                .font(.system(size: ResectaTokens.Results.leadMark))
                .foregroundStyle(LayerResultRow.groupedMarkColor(outcome))
                .frame(width: ResectaTokens.Results.leadColumn)
                .padding(.leading, ResectaTokens.Spacing.md)
                .padding(.trailing, ResectaTokens.Results.titleInset
                         - ResectaTokens.Spacing.md - ResectaTokens.Results.leadColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                Text(FindingRowModel.mainLine(problem, report: report, previewAvailable: previewAvailable))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(FindingRowButton(applies: isOpen, label: spokenLabel, isOpen: isOpen, action: onTap,
                                               pages: [], onOpenPage: onOpenPage))
                if let sub = FindingRowModel.subLine(problem, report: report, fits: fitsTwoLines) {
                    Text(sub)
                        .font(.subheadline)
                        .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                        .lineLimit(FindingRowModel.subLineIsPrivate(problem) ? 2 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .privacySensitive(FindingRowModel.subLineIsPrivate(problem))
                }
                if chips {
                    chipLine
                        .padding(.top, ResectaTokens.Spacing.xs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            DisclosureChevron(isExpanded: isOpen, tint: Color(.secondaryLabel))
                .frame(width: ResectaTokens.Results.chevronColumn)
                .padding(.top, ResectaTokens.Spacing.xs)
                .padding(.leading, ResectaTokens.Spacing.sm)
                .padding(.trailing, ResectaTokens.Spacing.md)
                .accessibilityHidden(true)
        }
        .padding(.vertical, ResectaTokens.Spacing.sm + ResectaTokens.Spacing.xs - 1)
        .frame(minHeight: ResectaTokens.Results.rowMinHeight, alignment: .top)
    }

    private var chipLine: some View {
        FlowLayout(spacing: ResectaTokens.Spacing.sm) {
            ForEach(FindingRowModel.chipPages(problem, isOpen: isOpen), id: \.self) { page in
                PageChip(pageIndex: page) { onOpenPage(page) }
            }
            if let more = FindingRowModel.moreChipsText(problem, isOpen: isOpen) {
                Text(more)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    .frame(minHeight: ResectaTokens.Results.chipHeight)
            }
        }
    }

    private var openedBlock: some View {
        VStack(alignment: .leading, spacing: ResectaTokens.Results.leadToReference) {
            switch FindingRowModel.step(problem, report: report, previewAvailable: previewAvailable) {
            case .sentence(let line):
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            case .reviewInScan:
                Button(LayerResultRow.reviewInScanLabel, action: onReviewInScan)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ResectaTokens.BrandTeal.text)
                    .accessibilityIdentifier("reviewInScanButton")
            case nil:
                EmptyView()
            }
            let lines = FindingRowModel.checkLines(problem, report: report)
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: ResectaTokens.Spacing.sm) {
                    ForEach(lines, id: \.layerIndex) { line in
                        checkLine(line)
                    }
                }
            }
        }
        .padding(.leading, ResectaTokens.Results.titleInset)
        .padding(.trailing, ResectaTokens.Spacing.md)
        .padding(.bottom, ResectaTokens.Spacing.md - 2)
        .transition(ResectaTokens.Anim.resolvedTransition(standard: .opacity, reduceMotion: reduceMotion))
    }

    private func checkLine(_ line: FindingRowModel.CheckLine) -> some View {
        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
            Text(LayerResultRow.gluedPageTail(line.line))
                .font(.footnote)
                .foregroundStyle(ResectaTokens.SemanticColor.supportText)
            if let sentence = line.sentence {
                Text(sentence)
                    .font(.footnote)
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
            }
            ForEach(Array(line.words.enumerated()), id: \.offset) { _, word in
                Text("\u{201C}\(word)\u{201D}")
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .privacySensitive()
            }
            ForEach(line.stopLines, id: \.self) { stop in
                Text(stop)
                    .font(.footnote)
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Whether a line of words fits two lines of the subheadline at the text
    /// column's width; before the width is known, the whole line is drawn.
    private func fitsTwoLines(_ text: String) -> Bool {
        guard textWidth > 0 else { return true }
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let font = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        let height = (text as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil).height
        return height <= font.lineHeight * 2 + 0.5
    }
}

/// A Findings row's button element: its spoken label, the shipped hint, the
/// button trait, a default action and each page as a named action. On the
/// whole header while the row is closed; on its main line while it is open.
private struct FindingRowButton: ViewModifier {
    let applies: Bool
    let label: String
    let isOpen: Bool
    let action: () -> Void
    let pages: [Int]
    let onOpenPage: (Int) -> Void

    func body(content: Content) -> some View {
        if applies {
            content
                .accessibilityLabel(label)
                .accessibilityHint(LayerResultRow.accessibilityHint(isExpandable: true, isExpanded: isOpen))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { action() }
                .accessibilityActions {
                    ForEach(pages, id: \.self) { page in
                        Button("Go to page \(page + 1)") { onOpenPage(page) }
                    }
                }
        } else {
            content
        }
    }
}
