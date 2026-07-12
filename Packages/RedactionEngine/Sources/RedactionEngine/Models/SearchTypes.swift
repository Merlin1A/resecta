import Foundation

// SEARCH-AND-REDACT §2.1: Engine-layer types for document search.
// All types are Sendable value types for safe cross-isolation transfer.

/// PII category for search-level filtering. Maps to RedactionRegion.PIIKind
/// but provides a stable, CaseIterable type for UI pickers and filter chips.
public enum PIICategory: String, CaseIterable, Sendable, Equatable, Hashable, Codable {
    case ssn = "SSN"
    case creditCard = "Credit Card"
    case email = "Email"
    case phone = "Phone"
    case address = "Address"
    case ein = "EIN"
    case itin = "ITIN"
    case driversLicense = "Driver's License"
    case name = "Name"
    case dateOfBirth = "Date of Birth"
    case passport = "Passport"
    case medicalRecord = "Medical Record"
    case npi = "NPI"
    case dea = "DEA"
    case account = "Account"
    // ABA routing number.
    case routingNumber = "Routing Number"
    case licensePlate = "License Plate"

    /// Convert to RedactionRegion.PIIKind for region creation.
    public var piiKind: RedactionRegion.PIIKind {
        switch self {
        case .ssn: .ssn
        case .creditCard: .creditCard
        case .email: .email
        case .phone: .phone
        case .address: .address
        case .ein: .ein
        case .itin: .itin
        case .driversLicense: .driversLicense
        case .name: .name
        case .dateOfBirth: .dateOfBirth
        case .passport: .passport
        case .medicalRecord: .medicalRecord
        case .npi: .npi
        case .dea: .dea
        case .account: .account
        case .routingNumber: .routingNumber
        case .licensePlate: .licensePlate
        }
    }

    /// Map from PIIKind to PIICategory.
    public init?(piiKind: RedactionRegion.PIIKind) {
        switch piiKind {
        case .ssn: self = .ssn
        case .creditCard: self = .creditCard
        case .email: self = .email
        case .phone: self = .phone
        case .address: self = .address
        case .ein: self = .ein
        case .itin: self = .itin
        case .driversLicense: self = .driversLicense
        case .name: self = .name
        case .dateOfBirth: self = .dateOfBirth
        case .passport: self = .passport
        case .medicalRecord: self = .medicalRecord
        case .npi: self = .npi
        case .dea: self = .dea
        case .account: self = .account
        case .routingNumber: self = .routingNumber
        case .licensePlate: self = .licensePlate
        case .barcode: return nil  // DRAW-2 — barcodes are detected via Vision, not text search.
        // DRAW-3 — `.signatureCandidate` is a heuristic visual suggestion, not
        // a text-search category, so it has no PIICategory. The triage sheet
        // still surfaces it; calibrated scoring / preset thresholds / search
        // are intentionally out of scope.
        case .signatureCandidate: return nil
        case .other: return nil
        }
    }

    /// SF Symbol name for category badge display.
    public var symbolName: String {
        switch self {
        case .ssn: "number.circle"
        case .creditCard: "creditcard"
        case .email: "envelope"
        case .phone: "phone"
        case .address: "house"
        case .ein: "building.2"
        case .itin: "person.text.rectangle"
        case .driversLicense: "car"
        case .name: "person"
        case .dateOfBirth: "calendar"
        case .passport: "airplane"
        case .medicalRecord: "cross.case"
        case .npi: "stethoscope"
        case .dea: "pills"
        case .account: "number.square"
        case .routingNumber: "arrow.triangle.branch"
        case .licensePlate: "car"
        }
    }
}

/// How to interpret the search query.
public enum SearchMode: Sendable {
    case text(String, options: SearchOptions)
    case regex(String, options: SearchOptions)
    case multiTerm([String], options: SearchOptions)
    /// Auto-detect PII patterns across the document.
    /// Only categories in the set are scanned; pass PIICategory.allCases for full scan.
    case piiScan(categories: Set<PIICategory>, options: SearchOptions)
}

// MARK: - W7 Live Preview / Scope-Aware Navigation

/// W7 — scope of a live-preview pass. Controls how many pages
/// `DocumentSearcher.previewMatches` walks while still scoping the
/// per-page highlight ranges to the visible page.
public enum SearchPreviewScope: Sendable, Equatable {
    case currentPage(pageIndex: Int)
    case wholeDocument
}

/// W7 — result of a live-preview pass. `currentPageMatches` is always
/// scoped to the visible page so the overlay can highlight without
/// rescanning, while `totalCount` reflects the requested scope.
public struct SearchPreviewResult: Sendable, Equatable {
    public let mode: SearchMode
    public let scope: SearchPreviewScope
    public let totalCount: Int
    public let saturated: Bool
    public let regexInvalid: Bool
    public let currentPageMatches: [NSRange]

    public init(
        mode: SearchMode,
        scope: SearchPreviewScope,
        totalCount: Int,
        saturated: Bool,
        regexInvalid: Bool,
        currentPageMatches: [NSRange]
    ) {
        self.mode = mode
        self.scope = scope
        self.totalCount = totalCount
        self.saturated = saturated
        self.regexInvalid = regexInvalid
        self.currentPageMatches = currentPageMatches
    }

    public static func == (lhs: SearchPreviewResult, rhs: SearchPreviewResult) -> Bool {
        lhs.scope == rhs.scope
            && lhs.totalCount == rhs.totalCount
            && lhs.saturated == rhs.saturated
            && lhs.regexInvalid == rhs.regexInvalid
            && lhs.currentPageMatches == rhs.currentPageMatches
    }
}

/// W7 — session-scoped scope for Cmd+G / J / K traversal.
public enum SearchNavigationScope: String, CaseIterable, Sendable, Equatable {
    case currentPage
    case wholeDocument
}

/// Configuration options for search behavior.
public struct SearchOptions: Sendable, Equatable {
    public var caseSensitive: Bool = false
    public var wholeWord: Bool = false
    public var includeOCR: Bool = true
    public var normalizeUnicode: Bool = true
    /// DRAW-5 — magic-wand select-by-similar-text. When `true`, the
    /// text-search runtime applies word-boundary semantics around every
    /// candidate match (alphanumeric / underscore on either side
    /// disqualifies it), so a query for "Doe" matches "Doe" but not
    /// "Doer" or "OldDoe". Default `false` so existing callers see no
    /// behavior change.
    ///
    /// Call-site contract: the search runtime treats the term as a
    /// literal substring (no regex), so the caller is responsible for
    /// escaping any regex metacharacters in the term before constructing
    /// the `.text(...)` mode. The `regex` mode path ignores this flag
    /// because callers there deliberately opt into pattern semantics
    /// and must handle word boundaries via `\b` themselves.
    ///
    /// Semantically equivalent to `wholeWord = true` on the text /
    /// multi-term / OCR paths; kept as a distinct flag so the magic-wand
    /// call site reads self-documentingly (plan §0.4 / §4 DRAW-5).
    public var exactMatch: Bool = false

    // Search-recall normalization extensions.
    // The two length-changing flags (separator strip, diacritic fold)
    // apply on the literal text/multi-term matcher and the OCR literal
    // path, where match ranges route through TextNormalizer's offset
    // map back to rect coordinates. They are intentionally NOT applied
    // on the regex paths: transforming a pattern corrupts its semantics
    // (e.g. an em-dash inside a character class), and transforming only
    // the page text without map-through would misplace rects.

    /// Digit-format-insensitive matching: "123456789" matches
    /// "123-45-6789" by stripping `-`, space, `.`, `/` from both sides
    /// before comparison. Off by default.
    public var stripDigitSeparators: Bool = false

    /// Smart-quote / em-dash folding ("—" matches "-"); 1:1 character
    /// substitution, length-preserving. On by default — universally
    /// helpful on typeset PDFs. On the regex paths only the page text
    /// is folded, never the pattern.
    public var normalizeSmartPunctuation: Bool = true

    /// Diacritic-insensitive matching ("Munoz" matches "Muñoz").
    /// Off by default: folding introduces false positives in non-Latin
    /// scripts and many name databases are accent-significant.
    public var foldDiacritics: Bool = false

    // Design 04 §4.5 — AND mode for multi-term search.
    // When true, `searchMultiTerm` retains only pages where EVERY term
    // has at least one result (page-level conjunction). When false (the
    // default), results from all terms are OR-joined — the historical
    // behavior for all existing callers.
    /// Page-level conjunction for multi-term search. `false` (default) = OR
    /// union (historical behavior); `true` = AND — only pages where every
    /// queried term has at least one result are included in the output.
    /// Has no effect on `.text`, `.regex`, or `.piiScan` modes.
    public var multiTermConjunction: Bool = false

    public init(
        caseSensitive: Bool = false,
        wholeWord: Bool = false,
        includeOCR: Bool = true,
        normalizeUnicode: Bool = true,
        exactMatch: Bool = false,
        stripDigitSeparators: Bool = false,
        normalizeSmartPunctuation: Bool = true,
        foldDiacritics: Bool = false,
        multiTermConjunction: Bool = false
    ) {
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.includeOCR = includeOCR
        self.normalizeUnicode = normalizeUnicode
        self.exactMatch = exactMatch
        self.stripDigitSeparators = stripDigitSeparators
        self.normalizeSmartPunctuation = normalizeSmartPunctuation
        self.foldDiacritics = foldDiacritics
        self.multiTermConjunction = multiTermConjunction
    }
}

/// Where the match was found.
public enum SearchSource: Sendable, Equatable {
    case textLayer
    case ocr(confidence: Float)
}

/// A single search hit — page, bounds, matched text, context.
public struct SearchResult: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let pageIndex: Int
    /// Bounding box in normalized coordinates (0–1, bottom-left origin),
    /// matching RedactionRegion.normalizedRect. See CANVAS_OVERLAY §S2.3.
    public let normalizedRect: CGRect
    public let matchedText: String
    /// ~40 characters of surrounding text for context display.
    public let contextSnippet: String
    public let source: SearchSource
    /// The search term that produced this match.
    public let term: String
    /// Whether this result is selected for redaction in the UI.
    public var isSelected: Bool = false
    /// PII category (nil for text/regex/multi-term results).
    public let piiCategory: PIICategory?
    /// PII detection confidence (nil for text/regex/multi-term results).
    public let piiConfidence: Double?
    /// W1 — why the detector emitted this hit. nil for text/regex/multi-term
    /// rows (no inferred rule to explain). Used by MatchRationaleSheet and
    /// by W5 audit export.
    public let rationale: MatchRationale?

    public init(
        id: UUID = UUID(),
        pageIndex: Int,
        normalizedRect: CGRect,
        matchedText: String,
        contextSnippet: String,
        source: SearchSource,
        term: String,
        isSelected: Bool = false,
        piiCategory: PIICategory? = nil,
        piiConfidence: Double? = nil,
        rationale: MatchRationale? = nil
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.normalizedRect = normalizedRect
        self.matchedText = matchedText
        self.contextSnippet = contextSnippet
        self.source = source
        self.term = term
        self.isSelected = isSelected
        self.piiCategory = piiCategory
        self.piiConfidence = piiConfidence
        self.rationale = rationale
    }
}

// MARK: - W1 MatchRationale
//
// Explainability record attached to PII detector hits. Drives the
// MatchRationaleSheet power-user disclosure and feeds W5's audit export.
// Designed to be cheap (value type, nil for non-PII rows) and stable enough
// that snapshot tests don't churn on every detector tweak.

/// Why a PII hit was emitted — the rule, the aggregated signals, and the
/// score journey from raw detector output to the final confidence that
/// was compared against the preset threshold.
public struct MatchRationale: Sendable, Equatable, Hashable, Codable {
    /// Stable identifier for the rule/pass that produced the hit
    /// (e.g. "ssn.state-machine", "name.nltagger", "mrn.regex.v1").
    public let ruleID: String
    /// The individual pieces of evidence that contributed to the score.
    /// Order is not significant. Empty is legal for a bare regex hit.
    public let signals: [Signal]
    /// Raw score from the detector before calibration or threshold comparison.
    public let preThresholdScore: Double
    /// Score used for the threshold decision. For detectors with no
    /// calibration step this equals `preThresholdScore`.
    public let finalScore: Double
    /// The cutoff this hit was compared against. nil when the scan did not
    /// apply a preset (e.g. back-compat callers, or a pass that skips the
    /// threshold gate).
    public let appliedThreshold: Double?

    public init(
        ruleID: String,
        signals: [Signal] = [],
        preThresholdScore: Double,
        finalScore: Double,
        appliedThreshold: Double? = nil
    ) {
        self.ruleID = ruleID
        self.signals = signals
        self.preThresholdScore = preThresholdScore
        self.finalScore = finalScore
        self.appliedThreshold = appliedThreshold
    }

    /// W4 — return a copy carrying the applied threshold and an extra
    /// signal (typically `.presetThresholdPass(raw:cutoff:)`). Keeps all
    /// existing fields `let` so W1 invariants are preserved.
    public func with(appliedThreshold: Double, addingSignal signal: Signal) -> MatchRationale {
        var appended = signals
        appended.append(signal)
        return MatchRationale(
            ruleID: ruleID,
            signals: appended,
            preThresholdScore: preThresholdScore,
            finalScore: finalScore,
            appliedThreshold: appliedThreshold
        )
    }

    /// Evidence types recorded during detection. Stable set — adding a case
    /// is additive (old rationale blobs decode fine) but renaming a case is
    /// a W5 audit-log break.
    public enum Signal: Sendable, Equatable, Hashable, Codable {
        /// A named regex pattern matched (e.g. "ssn.sep", "mrn.prefix").
        case regexPattern(name: String)
        /// A structural validator accepted the candidate (SSN area/group,
        /// Luhn, NPI 80840, DEA letter check, etc.).
        case structuralValidator(name: String)
        /// Positive context keywords raised the score.
        case contextPositive(score: Double)
        /// Negative context keywords multiplicatively suppressed the score.
        case contextNegative(multiplier: Double)
        /// Surname Bloom filter hit.
        case bloomSurnameHit
        /// Given-name Bloom filter hit.
        case bloomGivenHit
        /// Fuzzy (Levenshtein-1) surname hit, with the score multiplier
        /// `NameGazetteer.fuzzyContains` returned.
        case bloomFuzzySurnameHit(score: Double)
        /// The doctype gating rule that admitted this pass.
        case doctypeGate(doctype: DoctypeClass)
        /// Preset-threshold comparison recorded at decision time.
        case presetThresholdPass(raw: Double, cutoff: Double)
        /// OCR confidence folded in when the hit came from the OCR path.
        case ocrConfidence(value: Double)
        /// A user-defined always-flag term matched (W3).
        case userAlwaysFlag(pattern: String)
        /// A user-defined never-flag term matched (W3).
        case userNeverFlag(pattern: String)
        /// W10 — the overlap resolver picked a winner in this match's range;
        /// the associated `winnerCategory` is the surviving match's category.
        /// Mirrors `ConsiderationResult.overlapWinner` for the `MatchRationale`
        /// consumer.
        ///
        /// QW-5 (SRCH-ACCT-PHONE) — `loserCategory` is the suppressed
        /// match's OWN category, carried in the signal so audit/rationale
        /// surfaces can label the loser as itself ("Account, suppressed
        /// via Phone overlap") rather than showing only the winner's
        /// label. Optional: `.other` / non-text kinds have no
        /// `PIICategory`. Optional associated values decode as `nil` when
        /// absent, so pre-QW-5 rationale blobs still decode.
        case suppressedByOverlap(winnerCategory: PIICategory, loserCategory: PIICategory?)
        /// WU-76 / [P4] — per-keyword breakdown of the positive context
        /// contribution. Emitted alongside the existing scalar
        /// `.contextPositive(score:)` so consumers can render which
        /// specific gazetteer keywords drove the score. Each
        /// `KeywordContribution.keywordKey` is sourced from the
        /// gazetteer/profile — NEVER from page-extracted text. RR-31
        /// closed-vocabulary invariant; pinned by
        /// `KeywordContributionTests.keywordsClosedVocab`.
        case contextPositiveDetail(keywords: [KeywordContribution])
        /// WU-76 / [P4] — negative-context counterpart of
        /// `contextPositiveDetail`. Same closed-vocabulary invariant.
        case contextNegativeDetail(keywords: [KeywordContribution])
        /// S3 / WS2 §1.2 — the NegativeContextGazetteer fired and suppressed
        /// this hit. Carries the matched keyword (gazetteer data, closed
        /// vocabulary per RR-31 — not document content) and its
        /// `precedence_weight` (the per-MATCHED-keyword value from the S3
        /// semantics fix, not the bucket max). The `ContextWindowScorer`
        /// attaches this signal when `suppressionDetail` returns a non-nil
        /// keyword. Header-anchor path is deferred to S5.
        case negativeContextSuppressed(keyword: String, weight: Double)
    }
}

/// WU-76 / [P4] — a single keyword's contribution to a context-scoring pass.
/// `keywordKey` is sourced from the closed gazetteer/profile vocabulary
/// (RR-31); `contribution` is a scalar in [0, 1] representing this
/// keyword's share of the band-adjustment. Codable so the W5 audit
/// path can round-trip the new detail signals.
public struct KeywordContribution: Sendable, Equatable, Hashable, Codable {
    public let keywordKey: String
    public let contribution: Double

    public init(keywordKey: String, contribution: Double) {
        self.keywordKey = keywordKey
        self.contribution = contribution
    }
}

// MARK: - W9 Reverse Rationale / Coverage Report

/// W9 — evaluation summary for a single snippet across every detector
/// category. Produced by `PIIDetector.reverseRationale(for:fullContext:...)`
/// and shown in the "Why this match?" popover.
///
/// Scope contract: the snippet is scored against a bounded context buffer
/// (≤500 chars), so cross-page positive/negative context and N-gram
/// neighbors outside the window are absent. The popover footer surfaces
/// this contract so users don't conflate the result with full-document
/// scoring.
public struct ReverseRationale: Sendable, Equatable {
    public let snippet: String
    public let contextRange: NSRange
    public let considered: [ConsiderationResult]
    public let doctypeGatedOut: [PIICategory]

    public init(
        snippet: String,
        contextRange: NSRange,
        considered: [ConsiderationResult],
        doctypeGatedOut: [PIICategory]
    ) {
        self.snippet = snippet
        self.contextRange = contextRange
        self.considered = considered
        self.doctypeGatedOut = doctypeGatedOut
    }
}

/// W9 — per-category evaluation. Populated for every `PIICategory` even
/// when the detector does not run (doctypeGated / snippetNotInContext) so
/// the UI can render a stable row list.
public struct ConsiderationResult: Sendable, Equatable {
    public let category: PIICategory
    public let ruleID: String
    public let matched: Bool
    public let rawScore: Double?
    public let finalScore: Double?
    public let threshold: Double?
    public let reason: Reason
    /// Winner category when `reason == .suppressedByOverlap`. Always nil
    /// in W9 — W10's overlap resolver populates this field.
    public let overlapWinner: PIICategory?

    public init(
        category: PIICategory,
        ruleID: String,
        matched: Bool,
        rawScore: Double?,
        finalScore: Double?,
        threshold: Double?,
        reason: Reason,
        overlapWinner: PIICategory? = nil
    ) {
        self.category = category
        self.ruleID = ruleID
        self.matched = matched
        self.rawScore = rawScore
        self.finalScore = finalScore
        self.threshold = threshold
        self.reason = reason
        self.overlapWinner = overlapWinner
    }

    public enum Reason: String, Sendable, Equatable, Codable {
        case noMatch = "no-match"
        case belowThreshold = "below-threshold"
        case aboveThreshold = "above-threshold"
        case doctypeGated = "doctype-gated"
        case suppressedByUserTerm = "suppressed-by-user-term"
        case matchedAlwaysFlag = "matched-always-flag"
        case suppressedByOverlap = "suppressed-by-overlap"
        case snippetNotInContext = "snippet-not-in-context"
    }
}

/// W9 — per-scan coverage summary. Produced by `DetectionOrchestrator`
/// alongside the audit export and surfaced in the "Scan coverage" panel.
/// `deselectedCount` is the only field the UI layer fills in (from
/// `triageSelections`); the orchestrator leaves it at 0.
public struct CoverageReport: Sendable, Equatable {
    public let scannedPageCount: Int
    public let enabledCategories: Set<PIICategory>
    public let candidateCountByCategory: [PIICategory: Int]
    public let appliedCount: Int
    public let deselectedCount: Int
    public let belowThresholdSuppressedCount: Int
    public let overlapSuppressedCountByCategory: [PIICategory: Int]
    public let startedAt: Date
    public let completedAt: Date

    public init(
        scannedPageCount: Int,
        enabledCategories: Set<PIICategory>,
        candidateCountByCategory: [PIICategory: Int],
        appliedCount: Int,
        deselectedCount: Int,
        belowThresholdSuppressedCount: Int,
        overlapSuppressedCountByCategory: [PIICategory: Int],
        startedAt: Date,
        completedAt: Date
    ) {
        self.scannedPageCount = scannedPageCount
        self.enabledCategories = enabledCategories
        self.candidateCountByCategory = candidateCountByCategory
        self.appliedCount = appliedCount
        self.deselectedCount = deselectedCount
        self.belowThresholdSuppressedCount = belowThresholdSuppressedCount
        self.overlapSuppressedCountByCategory = overlapSuppressedCountByCategory
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    /// Return a copy with `deselectedCount` replaced. The UI layer uses
    /// this to fold in triage-sheet deselections after the scan completes.
    public func withDeselectedCount(_ count: Int) -> CoverageReport {
        CoverageReport(
            scannedPageCount: scannedPageCount,
            enabledCategories: enabledCategories,
            candidateCountByCategory: candidateCountByCategory,
            appliedCount: appliedCount,
            deselectedCount: count,
            belowThresholdSuppressedCount: belowThresholdSuppressedCount,
            overlapSuppressedCountByCategory: overlapSuppressedCountByCategory,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    /// D06-F2 Part 2 (Session 7 consumer) — return a copy with `appliedCount`
    /// replaced. Pure value-type copy-with sibling to `withDeselectedCount`; the
    /// UI layer will fold in the applied-result count from view state. Added now
    /// so Session 7's panel/export wiring has the API; no call site this session.
    public func withAppliedCount(_ count: Int) -> CoverageReport {
        CoverageReport(
            scannedPageCount: scannedPageCount,
            enabledCategories: enabledCategories,
            candidateCountByCategory: candidateCountByCategory,
            appliedCount: count,
            deselectedCount: deselectedCount,
            belowThresholdSuppressedCount: belowThresholdSuppressedCount,
            overlapSuppressedCountByCategory: overlapSuppressedCountByCategory,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }
}
