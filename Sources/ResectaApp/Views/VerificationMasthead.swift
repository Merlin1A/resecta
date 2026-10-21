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
            case 1:  return "Read the note in Verification Details before you share the PDF."
            default: return "Read the notes in Verification Details before you share the PDF."
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
