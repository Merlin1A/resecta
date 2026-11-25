import SwiftUI
import RedactionEngine

// The results masthead's words: the row-word title, the one sentence on
// every verdict, the spoken label with the counts, and the rules behind
// them (the run's mode, the review terms, the visible notes, the
// page-count gate). Static so every arm is unit-testable without a host.

extension VerificationResultsView {
    /// The control names never break across lines.
    private static let keepEditing = "Keep\u{00A0}Editing"
    private static let textSearch = "text\u{00A0}search"
    private static let runVerification = "Run\u{00A0}Verification"
    /// The Settings toggle's label (`SettingsView`).
    private static let verifyBeforeExport = "Verify Before Export"

    /// The longest masthead sentence; the term forms fall back past it.
    static let mastheadSentenceLimit = 70

    /// The masthead title: the status-level title, except a WARN that holds
    /// a check that could not verify (a skipped one included), which reads
    /// `Some Checks Incomplete`.
    static func mastheadTitle(report: VerificationReport) -> String {
        if report.overallStatus.isWarn, partition(report).count(.couldNotVerify) > 0 {
            return "Some Checks Incomplete"
        }
        return report.overallStatus.title
    }

    /// The masthead's spoken label: the title, the counts (line 2's dots
    /// spoken as commas) and the sentence; on SKIPPED, the title and the
    /// sentence.
    static func mastheadAccessibilityLabel(
        report: VerificationReport, outputExists: Bool = true, isStale: Bool = false,
        mode: RunMode = .searchableOrUnknown, findingCount: Int = 0
    ) -> String {
        let title = mastheadTitle(report: report)
        let sentence = mastheadSubtitle(
            report: report, outputExists: outputExists, isStale: isStale, mode: mode,
            findingCount: findingCount) ?? ""
        guard !report.overallStatus.isSkipped else { return "\(title). \(sentence)" }
        let partition = partition(report)
        var parts = ["\(title).", "\(partition.summaryLine1)."]
        if let line2 = partition.summaryLine2 {
            parts.append(line2.replacingOccurrences(of: " · ", with: ", ") + ".")
        }
        parts.append(sentence)
        return parts.joined(separator: " ")
    }

    /// The VoiceOver line at the end of a run: the masthead's title, as the
    /// screen shows it ("Some Checks Incomplete" included), and line 1's
    /// counts; a PASS with rows that did not pass (a check that had nothing
    /// to check, a note) adds line 2's counts. A skipped run has no counts.
    /// Never the masthead sentence: it can quote the review terms, and an
    /// announcement speaks document text aloud.
    static func completionAnnouncement(report: VerificationReport) -> String {
        let title = mastheadTitle(report: report)
        guard !report.overallStatus.isSkipped else { return "Verification complete. \(title)." }
        let partition = partition(report)
        var line = "Verification complete. \(title). \(partition.summaryLine1)."
        if case .pass = report.overallStatus, let line2 = partition.summaryLine2 {
            line += " \(line2.replacingOccurrences(of: " · ", with: ", "))."
        }
        return line
    }

    /// The run's mode as the SKIPPED sentences need it: a Secure run had
    /// every page rasterized by choice (no fallback reason); anything else,
    /// or no record of the run, reads as Searchable.
    enum RunMode: Equatable {
        case secure
        case searchableOrUnknown

        static func of(perPageModes: [PipelineMode],
                       fallbackReasons: [TextLayerDetector.FallbackReason?]) -> RunMode {
            guard !perPageModes.isEmpty,
                  perPageModes.allSatisfy({ $0 == .secureRasterization }),
                  !fallbackReasons.contains(where: { $0 != nil })
            else { return .searchableOrUnknown }
            return .secure
        }
    }

    /// The SKIPPED sentence: the reason, then the step — `Run Verification`,
    /// and on a Searchable (or unknown) run the full Redact that includes
    /// the checks a verify-only run cannot complete.
    static func skippedSubtitle(reason: VerificationReport.SkipReason, mode: RunMode = .searchableOrUnknown) -> String {
        let cause = switch reason {
        case .autoVerifyOff: "Off in Settings."
        case .cancelled:     "Stopped early."
        case .error:         "Could not finish."
        }
        // With the setting off, Redact skips the checks again: the full
        // run's step names the setting instead.
        let step = switch (mode, reason) {
        case (.secure, _): "\(runVerification) below before you share the PDF."
        case (_, .autoVerifyOff): "\(runVerification), or turn on \(verifyBeforeExport)."
        default: "\(runVerification), or run Redact for all checks."
        }
        return "\(cause) \(step)"
    }

    /// The sentence when the result no longer stands: every verdict's
    /// sentence gives way to it, since each would invite a share the Share
    /// button cannot make.
    static let outputMissingSentence = "\(keepEditing), then run Redact again to share the PDF."

    /// Whether the result stands: the redacted PDF exists and the boxes have
    /// not changed since it was made, exactly when Share is enabled
    /// (`canExport(report:)`, DocumentEditorView+Export.swift).
    static func resultStands(outputExists: Bool, isStale: Bool) -> Bool {
        outputExists && !isStale
    }

    /// Whether the masthead sentence names user text: true exactly when it
    /// quotes a review term. Static so the predicate is unit-testable
    /// without a SwiftUI host.
    static func mastheadSubtitleIsPrivacySensitive(
        report: VerificationReport, outputExists: Bool = true, isStale: Bool = false
    ) -> Bool {
        guard resultStands(outputExists: outputExists, isStale: isStale) else { return false }
        guard report.overallStatus.isAttention else { return false }
        return attentionSentence(report: report).quotesTerms
    }

    /// The masthead sentence, by verdict and the rows behind it. Never nil
    /// (the optional is the shipped call sites' shape). `findingCount` is
    /// the number of the results screen's findings the checks cannot see
    /// (`ResultsFindings`); a passing run counts them as notes. Static so
    /// every arm is unit-testable without a SwiftUI host.
    static func mastheadSubtitle(
        report: VerificationReport, outputExists: Bool = true, isStale: Bool = false,
        mode: RunMode = .searchableOrUnknown, findingCount: Int = 0
    ) -> String? {
        guard resultStands(outputExists: outputExists, isStale: isStale) else { return outputMissingSentence }
        let partition = partition(report)
        switch report.overallStatus {
        case .pass, .info, .notApplicable:
            let notes = visibleNoteCount(partition) + findingCount
            switch notes {
            case 0:  return "Look over the redacted PDF in Preview before you share it."
            case 1:  return "Read the note below before you share the PDF."
            default: return "Read the notes below before you share the PDF."
            }
        case .warn:
            let couldNotVerify = partition.couldNotVerify.map { report.layers[$0] }
            if !couldNotVerify.isEmpty, couldNotVerify.allSatisfy(\.status.isSkipped) {
                // True whether the setting is on or off: with it off, Redact
                // would skip the checks again.
                return couldNotVerify.count == 1
                    ? "To include the skipped check, run Redact again with verification on."
                    : "To include the skipped checks, run Redact again with verification on."
            }
            if !couldNotVerify.isEmpty {
                return couldNotVerify.count == 1
                    ? "1 check could not run in full; read it below before you share."
                    : "\(couldNotVerify.count) checks could not run in full; read them below before you share."
            }
            return partition.count(.warning) == 1
                ? "Read the warning below before you share the PDF."
                : "Read the warnings below before you share the PDF."
        case .attention:
            return attentionSentence(report: report).text
        case .fail:
            return isPageCountGateRun(report)
                ? "\(keepEditing) and run Redact again; the other checks did not run."
                : "\(keepEditing) to fix what failed, or share after review."
        case .skipped:
            return skippedSubtitle(reason: report.skipReason, mode: mode)
        }
    }

    /// The ATTENTION sentence. Term rows win over a Search Re-check row;
    /// the term forms are tried in order and the first that fits is taken
    /// — every term, then the first term and a count, then "the terms
    /// below" — so a term is never cut.
    static func attentionSentence(report: VerificationReport) -> (text: String, quotesTerms: Bool) {
        let termRows = report.layers.filter {
            $0.status.isAttention && VerificationRowModel.quotesReviewTerms($0.layer)
        }
        let lead = "\(keepEditing), then use \(textSearch) to redact"
        if !termRows.isEmpty {
            // A term whose remaining matches are all ones the user left
            // unapplied is not one to redact: it is named as left.
            let kept = VerificationRowModel.keptQueries(report: report)
            let allTerms = reviewTermTexts(report: report)
            let terms = allTerms.filter { kept[$0.lowercased()] == nil }
            if !allTerms.isEmpty, terms.isEmpty {
                return keptSentence(terms: allTerms, matches: allTerms.compactMap { kept[$0.lowercased()] }.reduce(0, +))
            }
            let quoted = terms.map { "\u{201C}\($0)\u{201D}" }
            var candidates: [String] = []
            if terms.count == 1 || terms.count == 2 {
                candidates.append("\(lead) \(VerificationRowModel.listPhrase(quoted)).")
            }
            if terms.count >= 2 {
                candidates.append("\(lead) \(quoted[0]) and \(terms.count - 1) more.")
            }
            if let fit = candidates.first(where: { $0.count <= mastheadSentenceLimit }) {
                return (fit, true)
            }
            return (terms.count > 1 ? "\(lead) the terms below." : "\(lead) the term below.", false)
        }
        let searches = report.layers
            .filter { $0.status.isAttention && $0.layer == .searchRecheck }
            .flatMap(VerificationRowModel.matchingQueryLines)
        if !searches.isEmpty {
            return (searches.count == 1
                ? "\(keepEditing) and run your search again with Include OCR Pages on."
                : "\(keepEditing) and run your searches again with Include OCR Pages on.", false)
        }
        // The Detection Sweep lists no terms, and what it reads may sit in
        // a page image text search does not reach: the sentence points to
        // Scan, as the sweep row's "Open Scan to review." does.
        if report.layers.contains(where: { $0.status.isAttention && $0.layer == .detectionSweep }) {
            return ("\(keepEditing), then open Scan to review the pages below.", false)
        }
        return ("\(lead) the terms below.", false)
    }

    /// The ATTENTION sentence when every review term's remaining matches
    /// are ones the user left unredacted: the count and the term, else the
    /// count alone, so a term is never cut.
    private static func keptSentence(terms: [String], matches: Int) -> (text: String, quotesTerms: Bool) {
        let count = matches == 1 ? "1 match" : "\(matches) matches"
        let tail = matches == 1 ? "unredacted; review it before you share." : "unredacted; review them before you share."
        if terms.count == 1 {
            let quoted = "You left \(count) of \u{201C}\(terms[0])\u{201D} \(tail)"
            if quoted.count <= mastheadSentenceLimit { return (quoted, true) }
        }
        return ("You left \(count) \(tail)", false)
    }

    /// The review terms the ATTENTION sentence may quote: the needs-review
    /// rows of the three term checks, in engine order, normalised as the
    /// user would type them and de-duplicated case-insensitively. Static so
    /// the masthead derivation is unit-testable without a SwiftUI host.
    static func reviewTermTexts(report: VerificationReport) -> [String] {
        VerificationRowModel.normalizedTerms(report.layers
            .filter { $0.status.isAttention && VerificationRowModel.quotesReviewTerms($0.layer) }
            .flatMap { $0.reviewTermTexts ?? [] })
    }

    /// The notes a PASS reader sees without opening anything: the Notes
    /// section's rows, plus the notes riding in the pass cluster when the
    /// cluster opens by default (nothing sits above it).
    static func visibleNoteCount(_ partition: VerificationLayerPartition) -> Int {
        partition.notes.count + (partition.isWhollyClean ? partition.clusterNoteCount : 0)
    }

    /// The page-count gate's report: its one row is the gate, so the other
    /// checks did not run.
    static func isPageCountGateRun(_ report: VerificationReport) -> Bool {
        report.layers.count == 1
            && report.layers[0].name == VerificationRowModel.pageCountGateName
            && report.layers[0].layer == nil
    }

    private static func partition(_ report: VerificationReport) -> VerificationLayerPartition {
        VerificationLayerPartition(layers: report.layers, perPageModes: report.perPageModes)
    }
}

// MARK: - The masthead

/// The results masthead, said once: the count ring, the row-word title and
/// one sentence naming the control to use. One VoiceOver header element
/// whose label also states the counts; the ring itself is hidden from
/// VoiceOver.
struct VerificationMasthead: View {
    let report: VerificationReport
    let outputExists: Bool
    /// The boxes changed since the redacted PDF was made.
    var isStale: Bool = false
    let mode: VerificationResultsView.RunMode
    /// The number of the results screen's findings (`ResultsFindings`).
    var findingCount: Int = 0

    var body: some View {
        let sentence = VerificationResultsView.mastheadSubtitle(
            report: report, outputExists: outputExists, isStale: isStale, mode: mode, findingCount: findingCount)
        let quotesTerms = VerificationResultsView.mastheadSubtitleIsPrivacySensitive(
            report: report, outputExists: outputExists, isStale: isStale)
        VStack(spacing: 0) {
            CountRing(content: VerificationMasthead.ringContent(
                report: report, outputExists: outputExists, isStale: isStale))
            BalancedText(string: VerificationResultsView.mastheadTitle(report: report), font: .title.bold())
                .foregroundStyle(.primary)
                .padding(.top, ResectaTokens.Results.ringToTitle)
            if let sentence {
                BalancedText(string: sentence, font: .subheadline)
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    .frame(maxWidth: ResectaTokens.Results.sentenceMaxWidth)
                    .padding(.top, ResectaTokens.Results.titleToSentence)
                    // The ATTENTION sentence can quote the review terms —
                    // text the checks found still readable in the output.
                    .privacySensitive(quotesTerms)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(VerificationResultsView.mastheadAccessibilityLabel(
            report: report, outputExists: outputExists, isStale: isStale, mode: mode, findingCount: findingCount))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("verificationMasthead")
        .privacySensitive(quotesTerms)
    }

    /// What the ring shows: SKIPPED's slot, or P of T with the verdict's
    /// tone. T counts the checks that had something to check; INFO reads
    /// as a pass. A result that no longer stands keeps its count in grey,
    /// without the verdict's tone; SKIPPED keeps its slot.
    static func ringContent(
        report: VerificationReport, outputExists: Bool = true, isStale: Bool = false
    ) -> CountRing.Content {
        let stands = VerificationResultsView.resultStands(outputExists: outputExists, isStale: isStale)
        let tone: CountRing.Tone
        switch report.overallStatus {
        case .skipped: return .skipped
        case _ where !stands: tone = .noLongerStands
        case .pass, .info, .notApplicable: tone = .pass
        case .warn: tone = .warn
        case .attention: tone = .attention
        case .fail: tone = .fail
        }
        let partition = VerificationLayerPartition(layers: report.layers, perPageModes: report.perPageModes)
        return .count(passed: partition.passedCount, total: partition.totalWithSomethingToCheck, tone: tone)
    }
}

/// The count ring: a tertiary track, a round-capped arc from twelve
/// o'clock for P of T in the verdict's text colour, the figure and the
/// word `passed` inside. P = 0 draws the whole track tinted, never a solid
/// ring; SKIPPED draws the track with `shield.slash`. While the checks run
/// it is grey: the arc for the results published so far over the checks
/// in the run, the figure, and the word `completed`; before the first
/// announcement, the track alone. The arc is drawn at its value, never
/// swept in. Fixed size at every Dynamic Type size; hidden from VoiceOver
/// (the block around it speaks the count).
struct CountRing: View {
    /// The verdict's tone; `noLongerStands` is a result whose PDF is gone
    /// or whose boxes changed since, drawn in the caption grey.
    enum Tone: Equatable { case pass, warn, attention, fail, noLongerStands }
    enum Content: Equatable {
        case count(passed: Int, total: Int, tone: Tone)
        case skipped
        case running(finished: Int, total: Int)
    }

    let content: Content

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var size: CGFloat { ResectaTokens.Results.ringSize }
    private var stroke: CGFloat { ResectaTokens.Results.ringStroke }

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: stroke)
            switch content {
            case .skipped:
                Image(systemName: "shield.slash")
                    .font(.system(size: ResectaTokens.Results.ringSkippedGlyph))
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
            case .count(let passed, let total, let tone):
                if passed > 0 {
                    Circle()
                        .trim(from: 0, to: Self.progress(passed: passed, total: total))
                        .stroke(Self.arcColor(tone), style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                figure(passed, of: total, word: "passed", wordSize: ResectaTokens.Results.ringWord,
                       grey: tone == .noLongerStands)
            case .running(let finished, let total):
                if total > 0 {
                    if finished > 0 {
                        runningArc(finished: finished, total: total)
                    }
                    figure(finished, of: total, word: "completed", wordSize: ResectaTokens.Results.ringRunningWord)
                }
            }
        }
        .padding(stroke / 2)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// The running arc grows with each result; under Reduce Motion it
    /// changes by a short cross-fade, never a sweep.
    @ViewBuilder
    private func runningArc(finished: Int, total: Int) -> some View {
        let arc = Circle()
            .trim(from: 0, to: Self.progress(passed: finished, total: total))
            .stroke(ResectaTokens.SemanticColor.supportText, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            .rotationEffect(.degrees(-90))
        if reduceMotion {
            arc.id(finished)
                .transition(.opacity)
                .animation(.easeInOut(duration: ResectaTokens.Results.runningArcFade), value: finished)
        } else {
            arc.animation(.easeOut(duration: ResectaTokens.Results.runningArcGrow), value: finished)
        }
    }

    private func figure(_ count: Int, of total: Int, word: String, wordSize: CGFloat, grey: Bool = false) -> some View {
        let size = Self.figureSize(total: total)
        return VStack(spacing: 1) {
            Text("\(count)\(Text("/").font(.system(size: size, weight: .light)).foregroundStyle(ResectaTokens.SemanticColor.supportText))\(total)")
                .font(.system(size: size, weight: .semibold).monospacedDigit())
                .foregroundStyle(grey ? AnyShapeStyle(ResectaTokens.SemanticColor.supportText) : AnyShapeStyle(HierarchicalShapeStyle.primary))
                .contentTransition(.numericText())
            Text(word)
                .font(.system(size: wordSize))
                .foregroundStyle(ResectaTokens.SemanticColor.supportText)
        }
        .lineLimit(1)
        .offset(y: -0.5)
    }

    private var trackColor: Color {
        if case .count(0, _, let tone) = content {
            return Self.arcColor(tone).opacity(colorScheme == .dark
                ? ResectaTokens.Results.zeroTrackOpacityDark : ResectaTokens.Results.zeroTrackOpacityLight)
        }
        return Color(red: 116 / 255, green: 116 / 255, blue: 128 / 255).opacity(colorScheme == .dark
            ? ResectaTokens.Results.trackOpacityDark : ResectaTokens.Results.trackOpacityLight)
    }

    /// The arc's share of the ring.
    static func progress(passed: Int, total: Int) -> CGFloat {
        total > 0 ? CGFloat(passed) / CGFloat(total) : 0
    }

    /// The figure's size: 22 pt below ten checks, 20 pt from ten.
    static func figureSize(total: Int) -> CGFloat {
        total < 10 ? ResectaTokens.Results.ringFigureSmallCount : ResectaTokens.Results.ringFigureLargeCount
    }

    /// The arc in the text tier; the light WARN arc is the ring-only orange;
    /// a result that no longer stands, the caption grey.
    static func arcColor(_ tone: Tone) -> Color {
        switch tone {
        case .noLongerStands: ResectaTokens.SemanticColor.supportText
        case .pass: ResectaTokens.SemanticColor.passText
        case .warn: ResectaTokens.Results.warnRing
        case .attention: ResectaTokens.SemanticColor.attentionText
        case .fail: ResectaTokens.SemanticColor.failText
        }
    }
}

/// The masthead's title or its sentence: the string in its font, centred,
/// laid out by `BalancedLines`. The one place a balanced text is built; the
/// callers give it their colour, padding and width limit from outside.
struct BalancedText: View {
    let string: String
    let font: Font

    var body: some View {
        BalancedLines {
            Text(string)
                .font(font)
                .multilineTextAlignment(.center)
            // Each run of the text in the same font, each as a text of its
            // own, one over another: the stack's width is the widest run,
            // which the layout never goes below. A run is measured alone
            // because one text holding every run, one per line, measures up
            // to two points narrower at large sizes. Never drawn, never
            // spoken.
            ZStack {
                ForEach(Array(Self.runs(of: string).enumerated()), id: \.offset) { run in
                    Text(run.element)
                        .font(font)
                        .fixedSize()
                }
            }
            .hidden()
            .accessibilityHidden(true)
        }
    }

    /// The text's unbreakable runs: split on ordinary spaces and line breaks
    /// only. A no-break space does not end a run; it keeps its words together.
    static func runs(of string: String) -> [Substring] {
        string.split(whereSeparator: { $0 == " " || $0 == "\n" })
    }
}

/// Lays one wrapping text out at the narrowest width that keeps its line
/// count, so a two-line title or sentence breaks into balanced lines
/// instead of a long line and a short one. A second subview, when there is
/// one, holds the text's unbreakable runs, each measured alone; the width
/// never goes below its width, so no word breaks to keep the line count.
struct BalancedLines: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let width = balancedWidth(subviews, proposal: proposal)
        return text.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let text = subviews.first else { return }
        let width = balancedWidth(subviews, proposal: ProposedViewSize(width: bounds.width, height: nil))
        let size = text.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let top = CGPoint(x: bounds.midX, y: bounds.minY)
        text.place(at: top, anchor: .top,
                   proposal: ProposedViewSize(width: size.width, height: size.height))
        // The measuring runs sit at the same point with no size; they add
        // nothing to the size the layout reports.
        for runs in subviews.dropFirst() {
            runs.place(at: top, anchor: .top, proposal: .zero)
        }
    }

    private func balancedWidth(_ subviews: Subviews, proposal: ProposedViewSize) -> CGFloat? {
        let text = subviews[0]
        let floor = subviews.count > 1 ? subviews[1].sizeThatFits(.unspecified).width : 0
        return Self.narrowestWidth(
            available: proposal.width, single: text.sizeThatFits(.unspecified).width, floor: floor
        ) { text.sizeThatFits(ProposedViewSize(width: $0, height: nil)).height }
    }

    /// The width the layout gives its text, in plain numbers: `available` is
    /// the proposed width, `single` the text's width on one line, `floor` its
    /// widest run's width, and `height(w)` its height at width `w`. The
    /// narrowest width, rounded up to a whole point, whose height is that at
    /// `available`; never below `floor` unless the run is wider than the line.
    static func narrowestWidth(available: CGFloat?, single: CGFloat, floor: CGFloat,
                               height: (CGFloat) -> CGFloat) -> CGFloat? {
        guard let available, available.isFinite else { return available }
        guard single > available else { return available }
        var low = min(available, max(available / 2, floor))
        // `low` is never above `available`; at it there is nothing narrower.
        if low == available { return available }
        let target = height(available)
        var high = available
        for _ in 0..<12 {
            let mid = (low + high) / 2
            if height(mid) > target + 0.5 {
                low = mid
            } else {
                high = mid
            }
        }
        return ceil(high)
    }
}
