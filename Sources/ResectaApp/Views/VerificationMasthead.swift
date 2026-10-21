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
        report: VerificationReport, outputExists: Bool = true, mode: RunMode = .searchableOrUnknown
    ) -> String {
        let title = mastheadTitle(report: report)
        let sentence = mastheadSubtitle(report: report, outputExists: outputExists, mode: mode) ?? ""
        guard !report.overallStatus.isSkipped else { return "\(title). \(sentence)" }
        let partition = partition(report)
        var parts = ["\(title).", "\(partition.summaryLine1)."]
        if let line2 = partition.summaryLine2 {
            parts.append(line2.replacingOccurrences(of: " · ", with: ", ") + ".")
        }
        parts.append(sentence)
        return parts.joined(separator: " ")
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
        let step = mode == .secure
            ? "\(runVerification) below before you share the PDF."
            : "\(runVerification), or run Redact for all checks."
        return "\(cause) \(step)"
    }

    /// The sentence when the redacted PDF no longer exists: every arm that
    /// names Preview or Run Verification gives way to it.
    static let outputMissingSentence = "\(keepEditing), then run Redact again to share the PDF."

    /// Whether the masthead sentence names user text: true exactly when it
    /// quotes a review term. Static so the predicate is unit-testable
    /// without a SwiftUI host.
    static func mastheadSubtitleIsPrivacySensitive(report: VerificationReport) -> Bool {
        guard report.overallStatus.isAttention else { return false }
        return attentionSentence(report: report).quotesTerms
    }

    /// The masthead sentence, by verdict and the rows behind it. Never nil
    /// (the optional is the shipped call sites' shape). Static so every arm
    /// is unit-testable without a SwiftUI host.
    static func mastheadSubtitle(
        report: VerificationReport, outputExists: Bool = true, mode: RunMode = .searchableOrUnknown
    ) -> String? {
        let partition = partition(report)
        switch report.overallStatus {
        case .pass, .info:
            let notes = visibleNoteCount(partition)
            switch notes {
            case 0:
                return outputExists
                    ? "Look over the redacted PDF in Preview before you share it." : outputMissingSentence
            case 1:  return "Read the note below before you share the PDF."
            default: return "Read the notes below before you share the PDF."
            }
        case .warn:
            let couldNotVerify = partition.couldNotVerify.map { report.layers[$0] }
            if !couldNotVerify.isEmpty, couldNotVerify.allSatisfy(\.status.isSkipped) {
                return couldNotVerify.count == 1
                    ? "Run Redact again from \(keepEditing) to include the skipped check."
                    : "Run Redact again from \(keepEditing) to include the skipped checks."
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
            guard outputExists else { return outputMissingSentence }
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
            let terms = reviewTermTexts(report: report)
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
                ? "\(keepEditing) and run your search again with OCR on."
                : "\(keepEditing) and run your searches again with OCR on.", false)
        }
        return ("\(lead) the terms below.", false)
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
    let mode: VerificationResultsView.RunMode

    var body: some View {
        let sentence = VerificationResultsView.mastheadSubtitle(report: report, outputExists: outputExists, mode: mode)
        let quotesTerms = VerificationResultsView.mastheadSubtitleIsPrivacySensitive(report: report)
        VStack(spacing: 0) {
            CountRing(content: VerificationMasthead.ringContent(report: report),
                      drawKey: VerificationMasthead.drawKey(for: report))
            BalancedLines {
                Text(VerificationResultsView.mastheadTitle(report: report))
                    .font(.title.bold())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, ResectaTokens.Results.ringToTitle)
            if let sentence {
                BalancedLines {
                    Text(sentence)
                        .font(.subheadline)
                        .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                        .multilineTextAlignment(.center)
                }
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
            report: report, outputExists: outputExists, mode: mode))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("verificationMasthead")
        .privacySensitive(quotesTerms)
    }

    /// What the ring shows: SKIPPED's slot, or P of T with the verdict's
    /// tone. T counts every check; INFO reads as a pass.
    static func ringContent(report: VerificationReport) -> CountRing.Content {
        let tone: CountRing.Tone
        switch report.overallStatus {
        case .skipped: return .skipped
        case .pass, .info: tone = .pass
        case .warn: tone = .warn
        case .attention: tone = .attention
        case .fail: tone = .fail
        }
        let partition = VerificationLayerPartition(layers: report.layers, perPageModes: report.perPageModes)
        return .count(passed: partition.passedCount, total: partition.total, tone: tone)
    }

    /// The report the arc last drew in for: a remount (after Share, Cancel
    /// or the capture shield) shows the same report static.
    private static var lastDrawnKey: String?

    /// The report's identity for the draw-in.
    static func drawKey(for report: VerificationReport) -> String {
        "\(report.overallStatus)|\(report.layers.count)|\(report.durationSeconds)"
    }

    /// Whether the arc draws in, claimed once per report when the ring
    /// appears: a fresh report, never a seeded or UI-test launch, never a
    /// remount of the same report.
    static func claimsDrawIn(key: String) -> Bool {
        guard !CommandLine.arguments.contains("--uitesting") else { return false }
        defer { lastDrawnKey = key }
        return lastDrawnKey != key
    }
}

/// The count ring: a tertiary track, a round-capped arc from twelve
/// o'clock for P of T in the verdict's text colour, the figure and the
/// word `passed` inside. P = 0 draws the whole track tinted, never a solid
/// ring; SKIPPED draws the track with `shield.slash`. Fixed size at every
/// Dynamic Type size; hidden from VoiceOver (the masthead's label speaks
/// the count).
struct CountRing: View {
    enum Tone: Equatable { case pass, warn, attention, fail }
    enum Content: Equatable {
        case count(passed: Int, total: Int, tone: Tone)
        case skipped
    }

    let content: Content
    /// The report's draw-in key (`VerificationMasthead.drawKey(for:)`).
    let drawKey: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat?

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
                        .trim(from: 0, to: drawn ?? Self.progress(passed: passed, total: total))
                        .stroke(Self.arcColor(tone), style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                figure(passed: passed, total: total)
            }
        }
        .padding(stroke / 2)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear {
            guard case .count(let passed, let total, _) = content, passed > 0 else { return }
            let target = Self.progress(passed: passed, total: total)
            guard !reduceMotion, VerificationMasthead.claimsDrawIn(key: drawKey) else { drawn = target; return }
            drawn = 0
            withAnimation(ResectaTokens.Results.arcDrawIn.delay(ResectaTokens.Results.arcDrawInDelay)) {
                drawn = target
            }
        }
    }

    private func figure(passed: Int, total: Int) -> some View {
        let size = Self.figureSize(total: total)
        return VStack(spacing: 1) {
            Text("\(passed)\(Text("/").font(.system(size: size, weight: .light)).foregroundStyle(ResectaTokens.SemanticColor.supportText))\(total)")
                .font(.system(size: size, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
            Text("passed")
                .font(.system(size: ResectaTokens.Results.ringWord))
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

    /// The arc in the text tier; the light WARN arc is the ring-only orange.
    static func arcColor(_ tone: Tone) -> Color {
        switch tone {
        case .pass: ResectaTokens.SemanticColor.passText
        case .warn: ResectaTokens.Results.warnRing
        case .attention: ResectaTokens.SemanticColor.attentionText
        case .fail: ResectaTokens.SemanticColor.failText
        }
    }
}

/// Lays one wrapping text out at the narrowest width that keeps its line
/// count, so a two-line title or sentence breaks into balanced lines
/// instead of a long line and a short one.
struct BalancedLines: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let width = balancedWidth(text, proposal: proposal)
        return text.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let text = subviews.first else { return }
        let width = balancedWidth(text, proposal: ProposedViewSize(width: bounds.width, height: nil))
        let size = text.sizeThatFits(ProposedViewSize(width: width, height: nil))
        text.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
                   proposal: ProposedViewSize(width: size.width, height: size.height))
    }

    private func balancedWidth(_ text: LayoutSubview, proposal: ProposedViewSize) -> CGFloat? {
        guard let available = proposal.width, available.isFinite else { return proposal.width }
        let height = text.sizeThatFits(ProposedViewSize(width: available, height: nil)).height
        let single = text.sizeThatFits(ProposedViewSize(width: nil, height: nil))
        guard single.width > available else { return available }
        var low = available / 2, high = available
        for _ in 0..<12 {
            let mid = (low + high) / 2
            if text.sizeThatFits(ProposedViewSize(width: mid, height: nil)).height > height + 0.5 {
                low = mid
            } else {
                high = mid
            }
        }
        return ceil(high)
    }
}
