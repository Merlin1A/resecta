import Foundation
import NaturalLanguage

/// Person names: the two NLTagger passes (mixed case; the ALL-CAPS shadow),
/// the legal-prefix pass and the label-anchor routes, resolved by range.
struct NameDetector: FamilyDetector {
    typealias PIIMatch = PIIDetector.PIIMatch
    let category: PIICategory = .name
    let telemetryLabel = "name"

    // Optional because NameGazetteer.init?() fails when bundled
    // resources are stripped (test-bundle-only builds). `runNLTagger` reads
    // this via `?.` so a nil gazetteer preserves the 0.70 baseline.
    let nameGazetteer: NameGazetteer?
    // Context-keywords loader: the label-anchor routes read the shipped
    // name positives in scope for the doctype from it. nil = the legal
    // prefixes alone label the routes (test-bundle-only builds).
    let contextLoader: ContextKeywordsLoader?

    init(nameGazetteer: NameGazetteer?, contextLoader: ContextKeywordsLoader?) {
        self.nameGazetteer = nameGazetteer
        self.contextLoader = contextLoader
    }

    func detect(in context: DetectionContext) -> [PIIMatch] {
        detect(in: context.text, doctype: context.doctype)
    }

    // MARK: - Name Detection via NLTagger

    /// Detect names using NLTagger with ALL-CAPS workaround.
    ///
    /// The mixed-case pass runs non-strict (miss is neutral — baseline
    /// 0.70 stays). The shadow pass (nerShadow: title-casing + separator
    /// segmentation) runs strict — a candidate absent from both the surname
    /// and given-name blooms is suppressed, which is how we keep ALL-CAPS
    /// recall without letting the looser tokenizer flood the triage list.
    func detect(in text: String, doctype: DoctypeClass? = nil) -> [PIIMatch] {
        var results: [PIIMatch] = []
        // Per-page cache of gazetteer verdicts keyed on lowercased candidate
        // text. Bounds the Levenshtein-1 enumeration cost across both passes.
        var verdictCache: [String: NameGazetteer.NameGazetteerVerdict] = [:]

        // Pass 1: Original text (the mixed-case names). Non-strict.
        results.append(contentsOf: runNLTagger(
            on: text, original: text, strict: false, cache: &verdictCache))

        // Pass 2: NER shadow (surfaces ALL-CAPS and label-glued names).
        // Strict. The shadow preserves
        // UTF-16 offsets position-for-position, so each tagger hit anchors
        // at its own occurrence in `text` (see runNLTagger).
        let shadow = Self.nerShadow(text)
        if shadow != text {
            results.append(contentsOf: runNLTagger(
                on: shadow, original: text, strict: true, cache: &verdictCache))
        }

        // Pass 3: Legal prefix heuristics
        results.append(contentsOf: scanLegalPrefixes(in: text))

        // Pass 4: Label anchors — the deterministic readings of the label
        // slots (a role or field label with its colon, the caption
        // connector). Same confidence as the prefix pass; a tagger row on
        // the same text wins the overlap below.
        results.append(contentsOf: scanLabelAnchors(in: text, doctype: doctype))

        // Deduplicate overlapping name matches across the passes.
        // When multiple passes detect the same text region, keep the match
        // with the higher confidence to avoid duplicate triage entries.
        return Self.deduplicateByRange(results)
    }

    /// Remove name detection results whose NSRanges overlap. When two matches
    /// overlap, the one with higher confidence is retained.
    private static func deduplicateByRange(_ matches: [PIIMatch]) -> [PIIMatch] {
        guard matches.count > 1 else { return matches }
        let sorted = matches.sorted { $0.confidence > $1.confidence }
        var kept: [PIIMatch] = []
        for candidate in sorted {
            let overlaps = kept.contains { existing in
                NSIntersectionRange(existing.range, candidate.range).length > 0
            }
            if !overlaps {
                kept.append(candidate)
            }
        }
        return kept
    }

    private func runNLTagger(
        on text: String,
        original: String,
        strict: Bool,
        cache: inout [String: NameGazetteer.NameGazetteerVerdict]
    ) -> [PIIMatch] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var results: [PIIMatch] = []

        let originalNS = original as NSString
        // Production invariant: Pass 1 passes
        // `original` itself and Pass 2 passes `nerShadow(original)`, which
        // substitutes and case-folds in place without inserting or removing
        // UTF-16 units — so a tagger range on `text` indexes `original`
        // directly. Only the DEBUG test seam can supply a cross-length pair.
        let offsetsAligned = (text as NSString).length == originalNS.length

        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word, scheme: .nameType) { tag, range in
            if tag == .personalName {
                let name = String(text[range])
                guard name.count >= 2 else { return true }
                // A whole-candidate stop token (`nameStopTokens`) is never a
                // name by itself, whatever the tagger says of it.
                guard !Self.nameStopTokens.contains(name) else { return true }
                // `range` indexes `text` (the `on:` string),
                // but the redaction box must index `original`. Anchor at THIS
                // tag's own offset: a from-zero `range(of:)` search resolves
                // every repeat of the same name to its first occurrence, so N
                // occurrences collapse to one box and repeats ship unredacted.
                let shadowRange = NSRange(range, in: text)
                let nsRange: NSRange
                if offsetsAligned, NSMaxRange(shadowRange) <= originalNS.length {
                    nsRange = shadowRange
                } else {
                    // Seam-only path (cross-length `on:`/`original:` pair):
                    // legacy first-occurrence search — imprecise for repeats
                    // but in-bounds and non-fatal.
                    let foundInOriginal = originalNS.range(
                        of: name,
                        options: [.caseInsensitive],
                        range: NSRange(location: 0, length: originalNS.length)
                    )
                    nsRange = foundInOriginal.location != NSNotFound
                        ? foundInOriginal
                        : shadowRange
                }
                // Surface the ORIGINAL casing in the match text — the range
                // points at "DELIA", the shadow's "Delia" is the tagger's view.
                let matchedText = NSMaxRange(nsRange) <= originalNS.length
                    ? originalNS.substring(with: nsRange)
                    : name

                // Consult gazetteer if available. Cache keyed on
                // lowercased name so both passes pay the Levenshtein-1
                // enumeration cost at most once per unique candidate.
                let verdict: NameGazetteer.NameGazetteerVerdict
                if let gazetteer = nameGazetteer {
                    let cacheKey = name.lowercased()
                    if let cached = cache[cacheKey] {
                        verdict = cached
                    } else {
                        verdict = gazetteer.queryBoosted(candidate: name, fuzzy: !strict)
                        cache[cacheKey] = verdict
                    }
                } else {
                    verdict = .none
                }

                // Inventory gate on BOTH tagger passes. The strict (ALL-CAPS
                // shadow) pass suppresses candidates the gazetteer didn't
                // recognize at all (`hadAnyHit`); the first pass suppresses
                // candidates the inventory does not SUPPORT (`hadSupport`:
                // an exact surname hit that is not a curated common word, or
                // a fuzzy hit) — the mirror of the strict gate, so a
                // Title-case pair the inventory has never seen no longer
                // surfaces at 0.70 on the tagger's word alone. The prefix
                // pass is untouched. nil-gazetteer → fall through so
                // stripped-bundle environments keep the same behavior.
                // `unit: .word` delivers one-word candidates
                // and `queryBoosted` treats a lone token as a surname query,
                // so a given-name word ("Delia") tagged on a transaction line
                // would be suppressed even once the tagger sees it. Accept a
                // single-token candidate present in the given-name bloom on
                // either pass; the boost table is unchanged (given-only
                // carries no boost).
                var givenNameOnlyHit = false
                if let gazetteer = nameGazetteer,
                   strict ? !verdict.hadAnyHit : !verdict.hadSupport {
                    givenNameOnlyHit = !name.contains(" ")
                        && gazetteer.contains(givenName: name)
                    if !givenNameOnlyHit {
                        return true
                    }
                }

                var signals: [MatchRationale.Signal] = [.regexPattern(name: "name.nltagger")]
                if verdict.surnameHit { signals.append(.bloomSurnameHit) }
                if verdict.givenHit || givenNameOnlyHit { signals.append(.bloomGivenHit) }
                if verdict.fuzzySurnameHit {
                    signals.append(.bloomFuzzySurnameHit(score: verdict.fuzzyScore ?? 0.6))
                }

                let confidence = 0.70 + verdict.boost
                let rationale = MatchRationale(
                    ruleID: "name.nltagger",
                    signals: signals,
                    preThresholdScore: 0.70,
                    finalScore: confidence
                )
                results.append(PIIMatch(text: matchedText, range: nsRange, kind: .name,
                                       confidence: confidence, rationale: rationale))
            }
            return true
        }
        return results
    }

    // MARK: - Name Stop Tokens

    /// Tokens the name path never surfaces as a name candidate on their own.
    /// Exact, case-sensitive, whole-candidate equality — nothing looser: a
    /// name that follows a role noun still surfaces (the prefix pass exists
    /// for that), the bare role noun never does. Two measured units: the five
    /// court and licence label tokens the tagger reads as given names when
    /// they open a sentence or a label ("Plaintiff is a corporation, Business
    /// Registration # …", "Reg # …", the "PP" / "Lic" / "DL" document labels),
    /// then the five furniture tokens — the honorific with and without its
    /// period, two role nouns and the legal opener — that the tagger and the
    /// prefix pass surface alone on furniture-dense pages ("Dr." before a
    /// line break, "Patient reports …", "Pursuant to …", "Counsel for …").
    /// Each unit was added together and measured together on the synthetic
    /// corpus and its furniture profiles, where it removes label and
    /// furniture false positives and changes no true positive. Any addition
    /// is its own measured change, never a quiet edit here. Checked before
    /// the gazetteer query on both tagger passes and on the prefix pass's
    /// assembled name.
    static let nameStopTokens: Set<String> = [
        "Plaintiff", "Reg", "PP", "Lic", "DL",
        "Dr.", "Dr", "Patient", "Pursuant", "Counsel",
    ]

    // MARK: - ALL-CAPS Title-Casing

    private static let acronymWhitelist: Set<String> = [
        "FBI", "CIA", "SSN", "EIN", "DOJ", "DOD", "IRS", "SEC", "FTC",
        "LLC", "INC", "LLP", "DBA", "AKA", "DOB", "SSA", "ICE", "DEA",
        "ATF", "TSA", "FAA", "EPA", "FDA", "OSHA", "HIPAA", "FOIA",
        "USA", "NYC", "PDF", "OCR", "PII"
    ]

    /// Separator characters that glue name tokens to transaction-line labels
    /// (`INDN:DELIA`, `PAYMENT TO DELIA HARTWELL,CHECKING`). Substituted with
    /// a space in the NER shadow so the tagger sees word boundaries. `.` is
    /// deliberately absent: abbreviations and decimal amounts rely on it, and
    /// the observed leak class is label-glued colons/commas, not periods.
    private static let nerShadowSeparators: Set<Character> = [":", ";", ",", "/"]

    /// Build the Pass-2 NER shadow.
    ///
    /// The legacy single-space-split title-casing this replaced title-cased
    /// a label-glued token (`INDN:DELIA`) to `Indn:delia`, so the embedded
    /// name never surfaced as a taggable word; its space-run collapse also
    /// drifted shadow offsets away from the original. This shadow instead:
    /// - substitutes separator punctuation (`nerShadowSeparators`) with a
    ///   space, so glued tokens segment into words the tagger can see;
    /// - treats all whitespace (including newlines and tabs) as word
    ///   boundaries, so line breaks do not glue words;
    /// - title-cases ALL-CAPS words per character, keeping the first letter
    ///   of every letter run uppercase (`O'BRIEN` → `O'Brien`, `MARY-JANE` →
    ///   `Mary-Jane`) and preserving whitelisted acronyms;
    /// - does not insert, remove, or reorder characters: a substitution that
    ///   would change a character's UTF-16 width is skipped, so
    ///   `shadow.utf16.count == text.utf16.count` holds by construction and a
    ///   tagger range on the shadow indexes the original string directly (the
    ///   per-occurrence anchoring invariant consumed by `runNLTagger`).
    static func nerShadow(_ text: String) -> String {
        var chars = Array(text)
        for i in chars.indices where Self.nerShadowSeparators.contains(chars[i]) {
            chars[i] = " "
        }
        var i = 0
        while i < chars.count {
            guard !chars[i].isWhitespace else {
                i += 1
                continue
            }
            var j = i
            while j < chars.count, !chars[j].isWhitespace { j += 1 }
            Self.titleCaseAllCapsWordInPlace(&chars, in: i..<j)
            i = j
        }
        return String(chars)
    }

    /// Title-case one shadow word in place. No-ops unless the word is
    /// ALL-CAPS (≥2 characters, contains a letter, equals its own
    /// uppercasing) and is not a whitelisted acronym. Width-changing case
    /// mappings are skipped to preserve the shadow's UTF-16 length invariant.
    private static func titleCaseAllCapsWordInPlace(
        _ chars: inout [Character], in word: Range<Int>
    ) {
        let s = String(chars[word])
        let stripped = s.trimmingCharacters(in: .punctuationCharacters)
        if acronymWhitelist.contains(stripped) { return }
        guard s.count >= 2, s == s.uppercased(),
              s.rangeOfCharacter(from: .letters) != nil else { return }
        var previousWasLetter = false
        for k in word {
            let c = chars[k]
            defer { previousWasLetter = c.isLetter }
            // The first letter of each letter run stays uppercase so
            // apostrophe/hyphen-joined name parts remain tagger-visible.
            guard c.isLetter, previousWasLetter else { continue }
            let lower = String(c).lowercased()
            if lower.count == 1, let lc = lower.first,
               String(c).utf16.count == lower.utf16.count {
                chars[k] = lc
            }
        }
    }
}
