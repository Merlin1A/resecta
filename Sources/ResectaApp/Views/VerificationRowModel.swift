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
    /// "P of T checks passed" base: the screen's order, top to bottom.
    static let headerClauseOrder: [VerificationOutcome] = [
        .failed, .needsReview, .warning, .couldNotVerify, .note, .nothingToCheck,
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
    /// no identity, except the page-count gate (`Page Count`).
    let title: String
    /// One line on what the check reads; nil for a row with no identity.
    let explainer: String?
    /// What must be true for the check to pass, and what it does not see
    /// (the expanded block's second tier); nil for a row with no identity
    /// other than the page-count gate.
    let rule: String?
    let outcome: VerificationOutcome
    /// The line under the title; nil when the row has nothing to add.
    let caption: String?
    /// True when the caption quotes the user's redacted terms or searches
    /// (the needs review captions) — the row marks it `.privacySensitive()`.
    let captionIsPrivacySensitive: Bool
    /// The expanded block's first lines: what to do about this row (a
    /// skipped check, a search that still matches) and, on the content
    /// stream search, where its scan stopped.
    let lead: [String]
    /// Whether the expanded block shows the engine's detail sentence. False
    /// on a skipped check, whose engine detail names a reason that does not
    /// apply to the app's skipped rows (they lacked the redaction run's
    /// per-page data).
    let showsEngineDetail: Bool
    /// True for the one note that leaves something to act on: the
    /// Detection Sweep with remaining possible items.
    let hasItemsRemaining: Bool
    /// "{Title}, {Word}." then the caption, each part ending in a period —
    /// the row's spoken label before the row adds the sweep's gate and the
    /// pages.
    let spokenLabel: String

    /// `pagesOnChips`: the row's page links carry the pages, so an
    /// app-composed caption drops its page phrase (engine captions stay
    /// verbatim); false while the redacted PDF is missing.
    init(layer: LayerResult, perPageModes: [PipelineMode], pagesOnChips: Bool = false) {
        let outcome = Self.outcome(for: layer, perPageModes: perPageModes)
        let title = Self.title(for: layer)
        let caption = Self.caption(for: layer, outcome: outcome, perPageModes: perPageModes,
                                   pagesOnChips: pagesOnChips)
        self.title = title
        self.explainer = layer.layer.map { Self.explainer(for: $0, perPageModes: perPageModes) }
        self.rule = Self.rule(for: layer)
        self.outcome = outcome
        self.caption = caption
        self.captionIsPrivacySensitive = outcome == .needsReview
            && (Self.composesTermCaption(layer) || Self.composesRecheckCaption(layer))
        self.lead = Self.lead(for: layer, outcome: outcome, perPageModes: perPageModes)
        self.showsEngineDetail = !layer.status.isSkipped
        self.hasItemsRemaining = Self.hasItemsRemaining(layer)
        self.spokenLabel = Self.sentence("\(title), \(outcome.word)")
            + (caption.map { " " + Self.sentence($0) } ?? "")
    }

    // MARK: - The derivation

    /// The row's outcome. Keyed on status × identity × whether query lines
    /// are present × the run's page modes × the could-not-verify flag:
    ///
    /// - fail → Failed · attention → Needs review
    /// - warn → Could not verify when the engine flagged it, else Warning
    /// - skipped → Could not verify (a skipped check gates sharing)
    /// - notApplicable → Nothing to check (the engine says so: no search
    ///   or scan applied, no redacted term to search for, or no page kept
    ///   a text layer)
    /// - info → Note
    /// - pass → Passed
    ///
    /// The page modes no longer decide an outcome — the engine reports a
    /// check with nothing to check as NOT APPLICABLE itself. The parameter
    /// stays so every caller keeps one signature. The derivation table in
    /// `VerificationRowModelTests` pins every cell.
    static func outcome(for layer: LayerResult, perPageModes _: [PipelineMode]) -> VerificationOutcome {
        switch layer.status {
        case .fail:
            return .failed
        case .attention:
            return .needsReview
        case .warn:
            return layer.couldNotVerify ? .couldNotVerify : .warning
        case .skipped:
            return .couldNotVerify
        case .notApplicable:
            return .nothingToCheck
        case .info:
            return .note
        case .pass:
            return .passed
        }
    }

    static func hasItemsRemaining(_ layer: LayerResult) -> Bool {
        layer.layer == .detectionSweep && layer.status.isInfo && layer.queryLines != nil
    }

    /// Every page of a known run rasterized; an empty list is unknown.
    private static func hasNoSearchablePage(_ perPageModes: [PipelineMode]) -> Bool {
        !perPageModes.isEmpty && !perPageModes.contains(.searchableRedaction)
    }

    // MARK: - The copy

    /// The engine's name for the page-count gate, the one row with no
    /// identity on a real report. Keyed on the name, never on a missing
    /// identity: test reports build identity-less rows named for other
    /// checks.
    static let pageCountGateName = "Page Count Check"

    static func title(for layer: LayerResult) -> String {
        guard let identity = layer.layer else {
            return layer.name == pageCountGateName ? "Page Count" : layer.name
        }
        switch identity {
        case .textExtraction:       return "Text & Annotations in the Redacted PDF"
        case .ocrCheck:             return "OCR of Page Images"
        case .binaryStringSearch:   return "Terms in Text & Bytes"
        case .structureCheck:       return "Active Content & Structure"
        case .metadataCheck:        return "Document Metadata"
        case .spatialVerification:  return "Character Positions"
        case .characterCount:       return "Character Count"
        case .fontVerification:     return "Monospace Fonts"
        case .characterLineage:     return "Character Sequence"
        case .operatorReExtraction: return "Terms in Content Streams"
        case .searchRecheck:        return "Search Re-check"
        case .detectionSweep:       return "Detection Sweep"
        }
    }

    /// One line on what the check reads — a passing row's caption, and the
    /// first line of every other row's expanded block. Character Positions
    /// reads differently when no page of the run kept a text layer.
    static func explainer(for identity: VerificationLayer, perPageModes: [PipelineMode] = []) -> String {
        switch identity {
        case .textExtraction:       "Checks Rasterized-page text and markup."
        case .ocrCheck:             "Reads page images against redactions."
        case .binaryStringSearch:   "Searches text and bytes for your terms."
        case .structureCheck:       "Checks file structure for active content."
        case .metadataCheck:        "Checks metadata for leftover fields."
        case .spatialVerification:
            hasNoSearchablePage(perPageModes)
                ? "Checks Rasterized pages for a text layer."
                : "Measures characters against regions."
        case .characterCount:       "Compares character counts with the record."
        case .fontVerification:     "Checks fonts against Courier and Menlo."
        case .characterLineage:     "Compares kept characters with the record."
        case .operatorReExtraction: "Searches text commands for your terms."
        case .searchRecheck:        "Re-runs your searches on the redacted PDF."
        case .detectionSweep:       "Runs the detectors on the redacted PDF."
        }
    }

    /// What must be true for the check to pass, then what it does not see.
    /// The Detection Sweep's limit is said by its fixed collapsed line and
    /// its engine detail instead.
    static func rule(for identity: VerificationLayer) -> String {
        switch identity {
        case .textExtraction:
            "Rasterized pages must have no text layer. Any annotation, bookmark, or form field fails."
        case .ocrCheck:
            "OCR must read no text inside a region and none of your terms outside one. Misread text is not seen."
        case .binaryStringSearch:
            "No term may appear in page text, image EXIF, or the file's bytes. Bytes inside streams are not searched."
        case .structureCheck:
            "Scripts, actions, attachments, forms, media, encryption, or appended saves fail. Links are only a warning."
        case .metadataCheck:
            "Only producer, dates, and file ID may remain, each set by Resecta. Metadata in compressed data is not read."
        case .spatialVerification:
            "No character may sit inside a region, and spacing must be even. Touching an edge is only a warning."
        case .characterCount:
            "Each page's count must match the one recorded at redaction, or be at most 2 over. Spaces are not counted."
        case .fontVerification:
            "Fonts on Searchable pages must be Courier or Menlo, both fixed-width. Any other font fails."
        case .characterLineage:
            "Each page's kept characters must match the fingerprint recorded at redaction. Zero-width marks are not seen."
        case .operatorReExtraction:
            "No term may appear in the commands that draw text. Scanning stops at the first page with a match."
        case .searchRecheck:
            "Each text, regex, or multi-term search is re-run with OCR on and must match nothing. Misread text is not seen."
        case .detectionSweep:
            "The detectors must report nothing beyond the items you chose to leave."
        }
    }

    /// The page-count gate's rule.
    static let pageCountGateRule =
        "Compares the PDF's page count with the original's. The other checks run only when they match."

    static func rule(for layer: LayerResult) -> String? {
        if let identity = layer.layer { return rule(for: identity) }
        return layer.name == pageCountGateName ? pageCountGateRule : nil
    }

    /// Why a check had nothing to check, by identity; nil for the checks
    /// that never read as Nothing to check.
    static func nothingToCheckReason(for identity: VerificationLayer) -> String? {
        switch identity {
        case .searchRecheck:
            "No searches to re-run."
        case .detectionSweep:
            "No scan to re-run."
        case .binaryStringSearch, .operatorReExtraction:
            "No captured text to search for."
        case .characterCount, .fontVerification, .characterLineage:
            "No Searchable pages to check."
        case .textExtraction, .ocrCheck, .structureCheck, .metadataCheck, .spatialVerification:
            nil
        }
    }

    /// A skipped check's caption: the state and its cause.
    static let skippedCaption = "Skipped. No record to compare with."
    /// A skipped check's lead: what would have saved the record.
    static let skippedLead = "Only a full Redact run saves that record."

    /// The caption under the title, by outcome — never by text.
    static func caption(for layer: LayerResult, outcome: VerificationOutcome,
                        perPageModes: [PipelineMode] = [], pagesOnChips: Bool = false) -> String? {
        switch outcome {
        case .passed:
            // A Search Re-check that re-ran no typed search (a run that
            // applied a scan only) carries no query lines: its own line says
            // what the coverage check compared, and the re-run explainer
            // would not be true of it.
            if layer.layer == .searchRecheck, (layer.queryLines ?? []).isEmpty {
                return layer.shortDescription
            }
            return layer.layer.map { explainer(for: $0, perPageModes: perPageModes) } ?? layer.shortDescription
        case .nothingToCheck:
            return layer.layer.flatMap(nothingToCheckReason(for:)) ?? layer.shortDescription
        case .note:
            return hasItemsRemaining(layer) ? sweepRemainingCaption(layer, pagesOnChips: pagesOnChips) : layer.shortDescription
        case .couldNotVerify where layer.status.isSkipped:
            return skippedCaption
        case .warning, .couldNotVerify, .failed:
            return layer.shortDescription
        case .needsReview:
            if composesTermCaption(layer) {
                return layer.reviewIsFragment
                    ? fragmentSentence(termTexts: layer.reviewTermTexts ?? [], pages: layer.pageReferences,
                                       pagesOnChips: pagesOnChips)
                    : reviewSentence(termTexts: layer.reviewTermTexts ?? [], pages: layer.pageReferences,
                                     pagesOnChips: pagesOnChips)
            }
            if composesRecheckCaption(layer) {
                return recheckReviewCaption(layer, pagesOnChips: pagesOnChips)
            }
            return layer.shortDescription
        }
    }

    /// The expanded block's lead lines, by outcome.
    static func lead(for layer: LayerResult, outcome: VerificationOutcome,
                     perPageModes: [PipelineMode]) -> [String] {
        switch outcome {
        case .couldNotVerify where layer.status.isSkipped:
            return [skippedLead]
        case .needsReview:
            if composesRecheckCaption(layer) {
                return [matchingQueryLines(layer).count == 1
                    ? "Run it again with OCR on to redact the rest."
                    : "Run them again with OCR on to redact the rest."]
            }
            if composesTermCaption(layer) {
                let terms = normalizedTerms(layer.reviewTermTexts ?? [])
                var lines = [reviewLead(termCount: terms.count)]
                if layer.layer == .operatorReExtraction,
                   let stop = contentStreamStopLine(pages: layer.pageReferences, pageCount: perPageModes.count) {
                    lines.append(stop)
                }
                return lines
            }
            return []
        default:
            return []
        }
    }

    // MARK: - Needs review

    /// The three checks whose needs review texts are document terms (OCR of
    /// Page Images, Terms in Text & Bytes, Terms in Content Streams). The
    /// Search Re-check's are query labels — a regex would quote its pattern.
    static func quotesReviewTerms(_ identity: VerificationLayer?) -> Bool {
        switch identity {
        case .ocrCheck, .binaryStringSearch, .operatorReExtraction: true
        default: false
        }
    }

    /// A term row's caption is composed when the row carries its terms.
    static func composesTermCaption(_ layer: LayerResult) -> Bool {
        layer.status.isAttention && quotesReviewTerms(layer.layer)
            && !normalizedTerms(layer.reviewTermTexts ?? []).isEmpty
    }

    /// A Search Re-check row's caption is composed from its query lines when
    /// a search still matches.
    static func composesRecheckCaption(_ layer: LayerResult) -> Bool {
        layer.status.isAttention && layer.layer == .searchRecheck && !matchingQueryLines(layer).isEmpty
    }

    /// The searches that still match on the output.
    /// The searches whose remaining matches on the output are all ones the
    /// user left unapplied (`remainingCount ≤ foundCount − appliedCount`, the
    /// found count measured, not capped): the label without its curly
    /// quotes, lowercased and whitespace-normalised → the remaining count. A typed search records no deselection,
    /// so found − applied is the app's only measure of a kept occurrence.
    static func keptQueries(report: VerificationReport) -> [String: Int] {
        var kept: [String: Int] = [:]
        for line in report.layers.filter({ $0.layer == .searchRecheck }).flatMap({ $0.queryLines ?? [] })
        where !line.unchecked && !line.foundHitCap && line.remainingCount > 0
            && line.remainingCount <= line.foundCount - line.appliedCount {
            let unquoted = line.label.trimmingCharacters(in: CharacterSet(charactersIn: "\u{201C}\u{201D}"))
            guard let label = normalizedTerms([unquoted]).first?.lowercased() else { continue }
            kept[label, default: 0] += line.remainingCount
        }
        return kept
    }

    static func matchingQueryLines(_ layer: LayerResult) -> [SearchRecheckQueryLine] {
        (layer.queryLines ?? []).filter { !$0.unchecked && $0.remainingCount > 0 }
    }

    /// Review terms as the user would type them: whitespace runs (a
    /// two-line region's line break included) collapse to one space, and a
    /// term repeated in another case keeps its first form.
    static func normalizedTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in terms {
            let term = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            result.append(term)
        }
        return result
    }

    /// “a” · “a” and “b” · “a”, “b”, and “c” — curly quotes, the commas
    /// outside them.
    static func quotedList(_ terms: [String]) -> String {
        listPhrase(terms.map { "\u{201C}\($0)\u{201D}" })
    }

    /// The needs-review caption of a term row: names the term(s) and where
    /// they remain — the pages on the chips when they show, else "on page
    /// 2", else "in the PDF". Pages are 0-based storage, displayed 1-based.
    static func reviewSentence(termTexts: [String], pages: [Int]?, pagesOnChips: Bool = false) -> String {
        let terms = normalizedTerms(termTexts)
        let verb = terms.count == 1 ? "is" : "are"
        let hasPages = !(pages ?? []).isEmpty
        if pagesOnChips, hasPages { return "\(quotedList(terms)) \(verb) still readable." }
        let location = pageLocation(pages) ?? "in the PDF"
        return "\(quotedList(terms)) \(verb) still readable \(location)."
    }

    /// A term row's lead: what the text is and the remedy.
    static func reviewLead(termCount: Int) -> String {
        (termCount == 1 ? "It matches text you redacted." : "They match text you redacted.")
            + " Use text\u{00A0}search to redact the rest."
    }

    /// The needs-review caption of the OCR Check's edge-fragment arm
    /// (`LayerResult.reviewIsFragment`): part of the term is readable
    /// beside a redaction box — the box is short of its text, so the remedy
    /// is the box, not a search. Pages are 0-based storage, displayed 1-based.
    static func fragmentSentence(termTexts: [String], pages: [Int]?, pagesOnChips: Bool = false) -> String {
        let terms = normalizedTerms(termTexts)
        let one = terms.count == 1
        // One box per term: the count follows the terms, not the pages.
        let oneBox = terms.count == 1
        let boxes = oneBox ? "a redaction box" : "redaction boxes"
        let remedy = oneBox ? "Adjust the box and redact again." : "Adjust the boxes and redact again."
        let hasPages = !(pages ?? []).isEmpty
        let location = pagesOnChips && hasPages ? "" : " \(pageLocation(pages) ?? "in the PDF")"
        return "\(one ? "Part" : "Parts") of \(quotedList(terms)) \(one ? "is" : "are") readable beside \(boxes)\(location). \(remedy)"
    }

    /// The Search Re-check's needs-review caption: the searches that still
    /// match, how many matches remain and where.
    static func recheckReviewCaption(_ layer: LayerResult, pagesOnChips: Bool = false) -> String {
        let lines = matchingQueryLines(layer)
        let total = lines.reduce(0) { $0 + $1.remainingCount }
        let labels = listPhrase(lines.map(\.label))
        let matches = total == 1 ? "1 match" : "\(total) matches"
        let location = pagesOnChips ? "" : (pageLocation(layer.pageReferences).map { " \($0)" } ?? "")
        return lines.count == 1
            ? "Your search \(labels) still has \(matches)\(location)."
            : "Your searches \(labels) still have \(matches)\(location)."
    }

    /// The content stream search stops at the first page with a match; the
    /// line names it when later pages exist. Nil when the page count is
    /// unknown or the hit is on the last page.
    static func contentStreamStopLine(pages: [Int]?, pageCount: Int) -> String? {
        guard let first = pages?.min(), pageCount > first + 1 else { return nil }
        return "Scanning stopped at page \(first + 1). Later pages were not searched."
    }

    // MARK: - The sweep

    /// The Detection Sweep note's caption, composed from its structured
    /// fields (the engine's own line points at an action the results screen
    /// does not offer): "N possible items remain on pages 1 and 3." when
    /// every line is the run's own sweep, whose remaining counts add up;
    /// otherwise — an applied scan's line counts what the user left, which
    /// the report does not separate — "Further possible items remain on
    /// pages 1 and 3.".
    static func sweepRemainingCaption(_ layer: LayerResult, pagesOnChips: Bool = false) -> String {
        let lines = layer.queryLines ?? []
        let total = lines.reduce(0) { $0 + $1.remainingCount }
        let pages = layer.pageReferences ?? []
        let location = pageLocation(pages).map { " \($0)" } ?? ""
        if !lines.isEmpty, lines.allSatisfy(isUnappliedSweepLine), total > 0 {
            let items = total == 1 ? "1 possible item remains" : "\(total) possible items remain"
            return pagesOnChips ? "\(items)." : "\(items)\(location)."
        }
        if pagesOnChips, !pages.isEmpty {
            return "Further possible items remain on \(pages.count == 1 ? "1 page" : "\(pages.count) pages")."
        }
        return "Further possible items remain\(location)."
    }

    /// A sweep line that found and applied nothing — the run's own sweep,
    /// never an apply (an applied scan found at least what it applied).
    static func isUnappliedSweepLine(_ line: SearchRecheckQueryLine) -> Bool {
        line.foundCount == 0 && !line.foundHitCap && line.appliedCount == 0
    }

    // MARK: - Lists, pages and sentences

    /// "a" · "a and b" · "a, b, and c".
    static func listPhrase(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and \(items[items.count - 1])"
        }
    }

    /// "on page 2" · "on pages 1 and 3" · "on pages 1, 3, and 7", from
    /// 0-based storage, the last three words held together so a page
    /// number never wraps away from its noun; nil when no pages are named.
    static func pageLocation(_ pages: [Int]?) -> String? {
        guard let pages, !pages.isEmpty else { return nil }
        let shown = listPhrase(pages.map { String($0 + 1) })
        return glueLastThreeWords(pages.count == 1 ? "on page \(shown)" : "on pages \(shown)")
    }

    /// Joins the last three words with no-break spaces.
    static func glueLastThreeWords(_ text: String) -> String {
        var words = text.components(separatedBy: " ")
        guard words.count >= 3 else { return words.joined(separator: "\u{00A0}") }
        let tail = words.suffix(3).joined(separator: "\u{00A0}")
        words.removeLast(3)
        return (words + [tail]).joined(separator: " ")
    }

    /// The spoken page list: "Page 3." · "Pages 1 and 3." · "Pages 2, 3,
    /// and 4." — up to five pages; with more, four then the count: "Pages
    /// 2, 3, 4, 5, and 8 more.".
    static func spokenPages(_ pages: [Int]) -> String? {
        guard !pages.isEmpty else { return nil }
        let shown = pages.map { String($0 + 1) }
        if shown.count == 1 { return "Page \(shown[0])." }
        if shown.count <= 5 { return "Pages \(listPhrase(shown))." }
        return "Pages \(shown.prefix(4).joined(separator: ", ")), and \(shown.count - 4) more."
    }

    /// A spoken part ends in a period unless it already ends a sentence.
    static func sentence(_ part: String) -> String {
        guard let last = part.last else { return part }
        return ".?!…".contains(last) ? part : part + "."
    }
}
