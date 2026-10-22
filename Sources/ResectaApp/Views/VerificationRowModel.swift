import SwiftUI
import RedactionEngine

// The Verification Details rows' display model: what each check's row says,
// derived from the engine's structured fields — status, identity, whether the
// layer carries query lines, the run's per-page modes and the could-not-verify
// flag — never from its text. The engine strings stay as the engine wrote
// them; the titles, the one-line descriptions and the status words are app
// copy keyed on the check's identity.

/// One row's outcome: the seven words the Verification Details list speaks.
/// The engine's six statuses fold into these by `VerificationRowModel
/// .outcome(for:perPageModes:)`.
// nonisolated: a pure value read by the rows on the MainActor and by the
// parameterized display tests (whose argument arrays are nonisolated).
nonisolated enum VerificationOutcome: Equatable, CaseIterable {
    case passed
    case nothingToCheck
    case note
    case warning
    case couldNotVerify
    case needsReview
    case failed

    /// The leading status mark, an outline circle per outcome. Hidden from
    /// VoiceOver — the row's label speaks the word.
    var markSymbolName: String {
        switch self {
        case .passed:         "checkmark.circle"
        case .nothingToCheck: "minus.circle"
        case .note:           "info.circle"
        case .warning:        "exclamationmark.circle"
        case .couldNotVerify: "questionmark.circle"
        case .needsReview:    "eye.circle"
        case .failed:         "xmark.circle"
        }
    }

    /// The trailing status word.
    var word: String {
        switch self {
        case .passed:         "Passed"
        case .nothingToCheck: "Nothing to check"
        case .note:           "Note"
        case .warning:        "Warning"
        case .couldNotVerify: "Could not verify"
        case .needsReview:    "Needs review"
        case .failed:         "Failed"
        }
    }

    /// The mark's and the word's colour: the measured small-text tier.
    /// Could not verify shares the warning hue (both are a WARN in the
    /// engine's aggregate); its mark, word and group set it apart.
    var textColor: Color {
        switch self {
        case .passed:         ResectaTokens.SemanticColor.passText
        case .nothingToCheck: ResectaTokens.SemanticColor.supportText
        case .note:           ResectaTokens.SemanticColor.infoText
        case .warning:        ResectaTokens.SemanticColor.warnText
        case .couldNotVerify: ResectaTokens.SemanticColor.warnText
        case .needsReview:    ResectaTokens.SemanticColor.attentionText
        case .failed:         ResectaTokens.SemanticColor.failText
        }
    }

    /// The order the summary line names the outcomes in after its
    /// "P of T checks passed" base: severity first, then coverage.
    static let headerClauseOrder: [VerificationOutcome] = [
        .failed, .needsReview, .couldNotVerify, .warning, .note, .nothingToCheck,
    ]

    /// The summary line's clause for `count` rows of this outcome — the
    /// numeral, a no-break space (the count never wraps away from its
    /// noun), the noun. Nil at zero, and for `.passed`, which the line's
    /// base counts.
    func headerClause(count: Int) -> String? {
        guard count > 0 else { return nil }
        let noun: String
        switch self {
        case .passed:         return nil
        case .nothingToCheck: noun = "had nothing to check"
        case .note:           noun = count == 1 ? "note" : "notes"
        case .warning:        noun = count == 1 ? "warning" : "warnings"
        case .couldNotVerify: noun = "could not verify"
        case .needsReview:    noun = count == 1 ? "needs review" : "need review"
        case .failed:         noun = "failed"
        }
        return "\(count)\u{00A0}\(noun)"
    }

    /// The row label's status phrase.
    var spokenPhrase: String { "\(word)." }

    /// Whether a row with this outcome makes Share ask for confirmation
    /// first: a check that could not verify part of the output or was
    /// skipped, a check that needs review, a failed check.
    var gatesSharing: Bool {
        switch self {
        case .couldNotVerify, .needsReview, .failed: true
        case .passed, .nothingToCheck, .note, .warning: false
        }
    }
}

/// What one Verification Details row shows: its title, the status it reads
/// as, the caption under the title and what the expanded block carries.
nonisolated struct VerificationRowModel: Equatable {
    /// The check's plain-language title; the engine `name` for a row with
    /// no identity (the page-count gate).
    let title: String
    /// One line on what the check reads; nil for a row with no identity.
    let explainer: String?
    let outcome: VerificationOutcome
    /// The line under the title; nil when the row has nothing to add.
    let caption: String?
    /// True when the caption quotes the user's redacted terms (the needs
    /// review sentence) — the row marks it `.privacySensitive()`.
    let captionIsPrivacySensitive: Bool
    /// Whether the expanded block shows the engine's detail sentence. False
    /// on a skipped check, whose engine detail names a reason that does not
    /// apply to the app's skipped rows (they lacked the redaction run's
    /// per-page data).
    let showsEngineDetail: Bool
    /// True for the one note that leaves something to act on: the
    /// Detection Sweep with remaining possible items.
    let hasItemsRemaining: Bool
    /// "{Title}, {Word}." then the caption — the row's spoken label before
    /// the row adds the sweep's gate and the affected-page count.
    let spokenLabel: String

    init(layer: LayerResult, perPageModes: [PipelineMode]) {
        let outcome = Self.outcome(for: layer, perPageModes: perPageModes)
        let title = Self.title(for: layer)
        let caption = Self.caption(for: layer, outcome: outcome)
        self.title = title
        self.explainer = layer.layer.map(Self.explainer(for:))
        self.outcome = outcome
        self.caption = caption
        self.captionIsPrivacySensitive = outcome == .needsReview
            && !(layer.reviewTermTexts ?? []).isEmpty
        self.showsEngineDetail = !layer.status.isSkipped
        self.hasItemsRemaining = Self.hasItemsRemaining(layer)
        self.spokenLabel = "\(title), \(outcome.spokenPhrase)" + (caption.map { " \($0)" } ?? "")
    }

    // MARK: - The derivation

    /// The row's outcome. Keyed on status × identity × whether query lines
    /// are present × the run's page modes × the could-not-verify flag:
    ///
    /// - fail → Failed · attention → Needs review
    /// - warn → Could not verify when the engine flagged it, else Warning
    /// - skipped → Could not verify (a skipped check gates sharing)
    /// - info → Nothing to check on the two term searches (their only info
    ///   arm is "no redacted terms") and on an idle Search Re-check or
    ///   Detection Sweep (the arms that carry no query lines); every other
    ///   info is a Note
    /// - pass → Nothing to check on Character Count, Monospace Fonts and
    ///   Character Sequence Hash when every page of the run rasterized
    ///   (those checks read only pages that kept a text layer); an empty
    ///   page-mode list is unknown coverage and stays Passed
    ///
    /// The inference is fragile in one direction: a future info arm on
    /// the two term searches, or a future info arm without query lines on
    /// the re-check or the sweep, would read as Nothing to check. The
    /// derivation table in `VerificationRowModelTests` pins every cell, so
    /// such a change fails a test first.
    static func outcome(for layer: LayerResult, perPageModes: [PipelineMode]) -> VerificationOutcome {
        switch layer.status {
        case .fail:
            return .failed
        case .attention:
            return .needsReview
        case .warn:
            return layer.couldNotVerify ? .couldNotVerify : .warning
        case .skipped:
            return .couldNotVerify
        case .info:
            switch layer.layer {
            case .binaryStringSearch, .operatorReExtraction:
                return .nothingToCheck
            case .searchRecheck, .detectionSweep:
                return layer.queryLines == nil ? .nothingToCheck : .note
            default:
                return .note
            }
        case .pass:
            switch layer.layer {
            case .characterCount, .fontVerification, .characterLineage:
                let noTextLayerPage = !perPageModes.isEmpty
                    && !perPageModes.contains(.searchableRedaction)
                return noTextLayerPage ? .nothingToCheck : .passed
            default:
                return .passed
            }
        }
    }

    static func hasItemsRemaining(_ layer: LayerResult) -> Bool {
        layer.layer == .detectionSweep && layer.status.isInfo && layer.queryLines != nil
    }

    // MARK: - The copy

    static func title(for layer: LayerResult) -> String {
        guard let identity = layer.layer else { return layer.name }
        switch identity {
        case .textExtraction:       return "Text Layer & Annotations"
        case .ocrCheck:             return "OCR of Page Images"
        case .binaryStringSearch:   return "Redacted Terms in File Bytes"
        case .structureCheck:       return "Active Content & Structure"
        case .metadataCheck:        return "Document Metadata"
        case .spatialVerification:  return "Character Positions"
        case .characterCount:       return "Character Count"
        case .fontVerification:     return "Monospace Fonts"
        case .characterLineage:     return "Character Sequence Hash"
        case .operatorReExtraction: return "Redacted Terms in Content Streams"
        case .searchRecheck:        return "Search Re-check"
        case .detectionSweep:       return "Detection Sweep"
        }
    }

    /// One line on what the check reads — a passing row's caption, and the
    /// first line of every other row's expanded block.
    static func explainer(for identity: VerificationLayer) -> String {
        switch identity {
        case .textExtraction:       "Reads page text, annotations and forms."
        case .ocrCheck:             "Reads page images by OCR against regions."
        case .binaryStringSearch:   "Searches raw bytes for the redacted terms."
        case .structureCheck:       "Reads the catalog for active content."
        case .metadataCheck:        "Reads /Info and XMP for leftover fields."
        case .spatialVerification:  "Measures character boxes against regions."
        case .characterCount:       "Compares character counts with the record."
        case .fontVerification:     "Checks each font is an accepted monospace."
        case .characterLineage:     "Recomputes each page's character hash."
        case .operatorReExtraction: "Decodes content streams; searches terms."
        case .searchRecheck:        "Re-runs each applied search on the output."
        case .detectionSweep:       "Runs the detectors on the output."
        }
    }

    /// Why a check had nothing to check, by identity; nil for the checks
    /// that never read as Nothing to check.
    static func nothingToCheckReason(for identity: VerificationLayer) -> String? {
        switch identity {
        case .searchRecheck:
            "No searches were applied."
        case .detectionSweep:
            "No scan was applied."
        case .binaryStringSearch, .operatorReExtraction:
            "No redacted terms to search for."
        case .characterCount, .fontVerification, .characterLineage:
            "No page kept a text layer."
        case .textExtraction, .ocrCheck, .structureCheck, .metadataCheck, .spatialVerification:
            nil
        }
    }

    /// A skipped check's caption: the remedy.
    static let skippedCaption = "Run Redact again to include this check."

    /// The caption under the title, by outcome — never by text.
    static func caption(for layer: LayerResult, outcome: VerificationOutcome) -> String? {
        switch outcome {
        case .passed:
            return layer.layer.map(explainer(for:)) ?? layer.shortDescription
        case .nothingToCheck:
            return layer.layer.flatMap(nothingToCheckReason(for:)) ?? layer.shortDescription
        case .note:
            return hasItemsRemaining(layer) ? sweepRemainingCaption(layer) : layer.shortDescription
        case .couldNotVerify where layer.status.isSkipped:
            return skippedCaption
        case .warning, .couldNotVerify, .failed:
            return layer.shortDescription
        case .needsReview:
            guard let terms = layer.reviewTermTexts, !terms.isEmpty else {
                return layer.shortDescription
            }
            return layer.reviewIsFragment
                ? fragmentSentence(termTexts: terms, pages: layer.pageReferences)
                : reviewSentence(termTexts: terms, pages: layer.pageReferences)
        }
    }

    /// The needs-review sentence for the OCR Check's edge-fragment arm
    /// (`LayerResult.reviewIsFragment`): part of the term is readable
    /// beside a redaction box — the box is short of its text, so the remedy
    /// is the box, not a search. Pages are 0-based storage, displayed
    /// 1-based.
    static func fragmentSentence(termTexts: [String], pages: [Int]?) -> String {
        let quoted = termTexts.map { "'\($0)'" }.joined(separator: ", ")
        let one = termTexts.count == 1
        let location = pageLocationPhrase(pages)
        let boxes = (pages?.count ?? 1) == 1 ? "a redaction box" : "redaction boxes"
        let remedy = (pages?.count ?? 1) == 1 ? "Adjust the box and redact again." : "Adjust the boxes and redact again."
        return "\(one ? "Part" : "Parts") of \(quoted) \(one ? "is" : "are") readable beside \(boxes) \(location). \(remedy)"
    }

    /// "on page 2" · "on pages 1 and 3" · "on pages 1, 2, and 4" · "in the
    /// document" when the layer names no pages. 0-based storage, 1-based
    /// display.
    private static func pageLocationPhrase(_ pages: [Int]?) -> String {
        guard let pages, !pages.isEmpty else { return "in the document" }
        let shown = pages.map { String($0 + 1) }
        switch shown.count {
        case 1:  return "on page \(shown[0])"
        case 2:  return "on pages \(shown[0]) and \(shown[1])"
        default: return "on pages \(shown.dropLast().joined(separator: ", ")), and \(shown[shown.count - 1])"
        }
    }

    /// The Detection Sweep note's caption, composed from its structured
    /// fields (the engine's own line points at an action the results screen
    /// does not offer): "N possible items remain on pages 1, 3." when every
    /// line is the run's own sweep, whose remaining counts add up; otherwise
    /// — an applied scan's line counts what the user left, which the report
    /// does not separate — "Items remain on pages 1, 3.".
    static func sweepRemainingCaption(_ layer: LayerResult) -> String {
        let lines = layer.queryLines ?? []
        let total = lines.reduce(0) { $0 + $1.remainingCount }
        let pagePhrase = pageListPhrase(layer.pageReferences)
        if !lines.isEmpty, lines.allSatisfy(isUnappliedSweepLine), total > 0 {
            let items = total == 1 ? "1 possible item remains" : "\(total) possible items remain"
            return "\(items)\(pagePhrase)."
        }
        return "Items remain\(pagePhrase)."
    }

    /// A sweep line that found and applied nothing — the run's own sweep,
    /// never an apply (an applied scan found at least what it applied).
    static func isUnappliedSweepLine(_ line: SearchRecheckQueryLine) -> Bool {
        line.foundCount == 0 && !line.foundHitCap && line.appliedCount == 0
    }

    /// " on page 2" · " on pages 1, 3" (0-based storage, 1-based display);
    /// empty when the layer names no pages.
    private static func pageListPhrase(_ pages: [Int]?) -> String {
        guard let pages, !pages.isEmpty else { return "" }
        let shown = pages.map { String($0 + 1) }.joined(separator: ", ")
        return pages.count == 1 ? " on page \(shown)" : " on pages \(shown)"
    }

    /// The needs-review sentence: names the term(s), where they remain, and
    /// the remedy. Pages are 0-based storage, displayed 1-based.
    static func reviewSentence(termTexts: [String], pages: [Int]?) -> String {
        let quoted = termTexts.map { "'\($0)'" }.joined(separator: ", ")
        let verb = termTexts.count == 1 ? "is" : "are"
        let location = pageLocationPhrase(pages)
        let matchClause = termTexts.count == 1
            ? "It matches text you redacted elsewhere."
            : "They match text you redacted elsewhere."
        return "\(quoted) \(verb) still readable \(location). \(matchClause) "
            + "Use text search to redact remaining instances."
    }
}
