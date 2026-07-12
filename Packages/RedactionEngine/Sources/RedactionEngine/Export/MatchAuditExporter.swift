import Foundation

// W5 — turn `[SearchResult]` joined with apply state into CSV / JSON
// audit artifacts. Engine-owned so both serializers share the exact same
// column set and rationale-summary format. All redaction happens here
// (never in the caller). Under `includeSensitive=false` every
// user-content field is reduced to a redacted form before it reaches the
// on-disk artifact (no schema bump — this comment is the redacted-field
// manifest):
//   • matchedText           → first2+…+last2 via `redactedMatchedText`
//   • term                  → the piiCategory label for piiScan rows,
//                             else first2+…+last2 via `redactedTerm`
//   • userAlwaysFlag /      → the user's pattern arg is stripped to
//     userNeverFlag args       `userFlag([redacted])` via
//                             `sanitizedRationaleSummary`
// All other columns are structural metadata (rule names, scores,
// closed-vocabulary gazetteer keywords) and pass through unchanged.

public enum MatchAuditExporter {

    /// Fixed column order, stable across schema version 1. Renames bump
    /// `ExportMetadata.schemaVersion`.
    public static let csvColumns: [String] = [
        "id",
        "pageIndex",
        "matchedText",
        "source",
        "piiCategory",
        "piiConfidence",
        "term",
        "ruleID",
        "ruleVersion",                // W-I2 schema v4
        "gazetteerManifestVersion",   // W-I2 schema v4
        "finalScore",
        "appliedThreshold",
        "rationaleSummary",
        "isSelected",
        "wasApplied",
        "suppressedByOverlap",
        "foiaExemption",
        "foiaCitation",
        "foiaNote",
    ]

    // MARK: - CSV

    /// RFC 4180-compliant CSV. Leading `#` comment lines carry the
    /// envelope metadata; parsers can either skip them or treat them
    /// as informational. The data header row follows.
    public static func csv(
        _ records: [MatchAuditRecord],
        metadata: ExportMetadata,
        includeSensitive: Bool
    ) -> Data {
        var out = ""
        for line in metadataCommentLines(metadata) {
            out += "# " + line + "\r\n"
        }
        out += csvColumns.joined(separator: ",") + "\r\n"
        for record in records {
            out += csvRow(record, includeSensitive: includeSensitive) + "\r\n"
        }
        return Data(out.utf8)
    }

    private static func csvRow(
        _ record: MatchAuditRecord,
        includeSensitive: Bool
    ) -> String {
        let text = includeSensitive
            ? record.matchedText
            : redactedMatchedText(record.matchedText)
        // Audit-leak guard: with includeSensitive=false
        // the `term` column and the user-flag rationale signals carry the
        // user's own query/pattern — which IS the PII when the user searched
        // their SSN. Redact both through the same policy the JSON path uses.
        let term = includeSensitive
            ? record.term
            : redactedTerm(record.term, piiCategory: record.piiCategory)
        let rationale = includeSensitive
            ? record.rationaleSummary
            : sanitizedRationaleSummary(record.rationaleSummary)
        let fields: [String] = [
            record.id.uuidString,
            String(record.pageIndex),
            text,
            record.source,
            record.piiCategory ?? "",
            record.piiConfidence.map(formatDouble) ?? "",
            term,
            record.ruleID ?? "",
            record.ruleVersion ?? "",
            record.gazetteerManifestVersion ?? "",
            record.finalScore.map(formatDouble) ?? "",
            record.appliedThreshold.map(formatDouble) ?? "",
            rationale,
            record.isSelected ? "true" : "false",
            record.wasApplied ? "true" : "false",
            record.suppressedByOverlap ? "true" : "false",
            record.foiaExemption ?? "",
            record.foiaCitation ?? "",
            record.foiaNote ?? "",
        ]
        return fields.map(csvEscape).joined(separator: ",")
    }

    /// CWE-1236 (OWASP "CSV / formula injection") lead characters. A cell
    /// that begins with any of these is reinterpreted as a formula / DDE
    /// payload by Excel / Numbers / LibreOffice / Sheets on open. `\t`
    /// (0x09) and `\r` (0x0D) are included because leading whitespace can
    /// shift a later `=` into the lead position after some apps' trim pass.
    private static let formulaLeadCharacters: Set<Character> =
        ["=", "+", "-", "@", "\u{0009}", "\u{000D}"]

    /// Defuse a leading formula / DDE trigger by forcing the cell to text
    /// with a leading apostrophe (the "force text" prefix honored by Excel /
    /// LibreOffice / Sheets; rendered literally by Numbers). Applied to EVERY
    /// column at the serialization choke point, so every current and future
    /// column is routed through the same defusing. Reversible: a consumer
    /// strips one leading `'`. D07-F1.
    private static func neutralizeFormulaLead(_ field: String) -> String {
        guard let first = field.first,
              formulaLeadCharacters.contains(first) else {
            return field
        }
        return "'" + field
    }

    /// Wrap in double quotes when the field contains any of
    /// `,`, `"`, `\r`, `\n`; double internal quotes per RFC 4180.
    private static func csvEscape(_ field: String) -> String {
        // D07-F1: neutralize formula / DDE leads FIRST so a defused field is
        // then RFC-4180-quoted normally. Order matters — quoting alone does
        // not stop formula evaluation; the leading-apostrophe transform does.
        let safe = neutralizeFormulaLead(field)
        let needsQuoting = safe.contains(",")
            || safe.contains("\"")
            || safe.contains("\r")
            || safe.contains("\n")
        if !needsQuoting { return safe }
        let escaped = safe.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func metadataCommentLines(_ m: ExportMetadata) -> [String] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = [
            "schemaVersion=\(m.schemaVersion)",
            "exportedAt=\(iso.string(from: m.exportedAt))",
            "appVersion=\(m.appVersion)",
            "presetName=\(m.presetName)",
            "documentName=\(m.documentName)",
            "totalMatches=\(m.totalMatches)",
            "appliedMatches=\(m.appliedMatches)",
        ]
        if !m.perCategoryOverrides.isEmpty {
            let overrides = m.perCategoryOverrides.keys.sorted().map {
                "\($0):\(formatDouble(m.perCategoryOverrides[$0] ?? 0))"
            }.joined(separator: ",")
            lines.append("perCategoryOverrides=\(overrides)")
        }
        return lines
    }

    // MARK: - JSON

    /// Top-level envelope: `{ "metadata": ExportMetadata, "records": [...] }`.
    /// Pretty-printed + sorted keys for diff-friendly output.
    ///
    /// Pkg C / ERR-02: `throws` so encoder errors propagate to the caller
    /// (`MatchExportService.share`) where they wire into a Tier 1 `.error`
    /// toast. The prior `(try? …) ?? Data()` shape silently produced an
    /// empty `Data` on failure, leaving the share-sheet path
    /// indistinguishable from a UI bug. Signature change only — the
    /// PipelineError hierarchy is untouched.
    public static func json(
        _ records: [MatchAuditRecord],
        metadata: ExportMetadata,
        includeSensitive: Bool
    ) throws -> Data {
        let prepared: [MatchAuditRecord] = includeSensitive
            ? records
            : records.map { record in
                MatchAuditRecord(
                    id: record.id,
                    pageIndex: record.pageIndex,
                    matchedText: redactedMatchedText(record.matchedText),
                    source: record.source,
                    piiCategory: record.piiCategory,
                    piiConfidence: record.piiConfidence,
                    // S6 audit-leak fix: same term/rationale policy as csvRow.
                    term: redactedTerm(record.term, piiCategory: record.piiCategory),
                    ruleID: record.ruleID,
                    finalScore: record.finalScore,
                    appliedThreshold: record.appliedThreshold,
                    rationaleSummary: sanitizedRationaleSummary(record.rationaleSummary),
                    isSelected: record.isSelected,
                    wasApplied: record.wasApplied,
                    suppressedByOverlap: record.suppressedByOverlap,
                    foiaExemption: record.foiaExemption,
                    foiaCitation: record.foiaCitation,
                    foiaNote: record.foiaNote,
                    ruleVersion: record.ruleVersion,
                    gazetteerManifestVersion: record.gazetteerManifestVersion
                )
            }
        let envelope = Envelope(metadata: metadata, records: prepared)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    private struct Envelope: Codable {
        let metadata: ExportMetadata
        let records: [MatchAuditRecord]
    }

    // MARK: - Redaction + rationale summary

    /// Redact to `first(2) + "…" + last(2)` on Character (grapheme) units
    /// so emoji / composed sequences don't split. Strings of 4 characters
    /// or fewer collapse to `"…"` — too short to redact meaningfully.
    public static func redactedMatchedText(_ text: String) -> String {
        let count = text.count
        if count <= 4 { return "…" }
        let prefix = String(text.prefix(2))
        let suffix = String(text.suffix(2))
        return prefix + "…" + suffix
    }

    /// Audit-leak guard, field-by-field policy:
    /// the `term` column policy under `includeSensitive=false`.
    /// piiScan rows are identified by a non-nil `piiCategory` (the live
    /// `sourceDescription` never emits a "pii:" prefix — the category field
    /// is the signal). For those rows the category label ("ssn") is
    /// metadata, not PII, and the term column carries it. For
    /// text/regex/multiTerm rows the term is the user's own query — the
    /// term IS the PII when the user searched their SSN — so it gets the
    /// same first2+…+last2 treatment as matchedText.
    static func redactedTerm(_ term: String, piiCategory: String?) -> String {
        if let category = piiCategory {
            return category
        }
        return redactedMatchedText(term)
    }

    /// S6 audit-leak fix: strip the raw pattern out of
    /// `userAlwaysFlag(<pattern>)` / `userNeverFlag(<pattern>)` signal
    /// descriptions while keeping the signal's presence visible as
    /// `userFlag([redacted])`. All other signals (validator, threshold,
    /// bloom, context) are metadata and pass through unchanged.
    ///
    /// The closing-paren match is anchored to a signal boundary
    /// (`\)` followed by `";"` or end-of-string) rather than the design
    /// draft's `[^)]*\)` so a user pattern that itself contains `)` is
    /// still stripped in full instead of leaking its tail. Flagged for
    /// the batched security review alongside the policy table.
    static func sanitizedRationaleSummary(_ summary: String) -> String {
        let range = NSRange(summary.startIndex..., in: summary)
        var result = userFlagSignalRegex.stringByReplacingMatches(
            in: summary,
            range: range,
            withTemplate: "userFlag([redacted])"
        )
        result = result.replacingOccurrences(of: "; ;", with: ";")
            .trimmingCharacters(in: .init(charactersIn: "; "))
        return result
    }

    /// Compile-time-constant pattern; `try!` cannot trip at runtime.
    /// `.*?\)(?=;|$)` consumes through the LAST `)` before a signal
    /// separator, covering patterns that contain unbalanced parens.
    private static let userFlagSignalRegex = try! NSRegularExpression(
        pattern: "userAlways[Ff]lag\\(.*?\\)(?=;|$)|userNever[Ff]lag\\(.*?\\)(?=;|$)"
    )

    /// Build the `rationaleSummary` column by flattening `rationale.signals`
    /// into a short `"name(args)"` list joined with `"; "`. Public so the
    /// app layer can produce records from live `SearchResult` values.
    public static func rationaleSummary(_ rationale: MatchRationale?) -> String {
        guard let rationale else { return "" }
        let parts = rationale.signals.map(signalDescription)
        return parts.joined(separator: "; ")
    }

    private static func signalDescription(_ signal: MatchRationale.Signal) -> String {
        switch signal {
        case .regexPattern(let name):
            return "regex(\(name))"
        case .structuralValidator(let name):
            return "validator(\(name))"
        case .contextPositive(let score):
            return "ctx+(\(formatDouble(score)))"
        case .contextNegative(let multiplier):
            return "ctx-(\(formatDouble(multiplier)))"
        case .bloomSurnameHit:
            return "bloom.surname"
        case .bloomGivenHit:
            return "bloom.given"
        case .bloomFuzzySurnameHit(let score):
            return "bloom.fuzzy(\(formatDouble(score)))"
        case .doctypeGate(let doctype):
            return "doctype(\(doctype))"
        case .presetThresholdPass(let raw, let cutoff):
            return "thresholdPass(raw=\(formatDouble(raw)),cutoff=\(formatDouble(cutoff)))"
        case .ocrConfidence(let value):
            return "ocr(\(formatDouble(value)))"
        case .userAlwaysFlag(let pattern):
            return "userAlwaysFlag(\(pattern))"
        case .userNeverFlag(let pattern):
            return "userNeverFlag(\(pattern))"
        case .suppressedByOverlap(let winner, let loser):
            // QW-5 — name the loser as itself so the summary can't read as
            // if the suppressed row belonged to the winner's category.
            // Pre-QW-5 signals (no loserCategory) keep the legacy format.
            if let loser {
                return "suppressedByOverlap(\(loser.rawValue) via \(winner.rawValue))"
            }
            return "suppressedByOverlap(\(winner.rawValue))"
        case .contextPositiveDetail(let keywords):
            // WU-76 / [P4] — flatten the per-keyword breakdown into a
            // compact summary string. Format: `ctx+detail(k1=0.05;k2=0.05)`.
            // Uses a for-loop rather than .map { ... formatDouble ... } —
            // the closure form has surfaced a simulator-test crash; loop
            // form is the workaround.
            var parts: [String] = []
            for entry in keywords {
                parts.append("\(entry.keywordKey)=\(formatDouble(entry.contribution))")
            }
            return "ctx+detail(\(parts.joined(separator: ";")))"
        case .contextNegativeDetail(let keywords):
            var parts: [String] = []
            for entry in keywords {
                parts.append("\(entry.keywordKey)=\(formatDouble(entry.contribution))")
            }
            return "ctx-detail(\(parts.joined(separator: ";")))"
        case .negativeContextSuppressed(let keyword, let weight):
            // keyword is gazetteer data (closed vocabulary) — not document content.
            return "negCtxSuppressed(kw=\(keyword),w=\(formatDouble(weight)))"
        }
    }

    /// Stable `SearchSource` stringifier used by both the audit record and
    /// by the service layer when building records from snapshots.
    public static func sourceDescription(_ source: SearchSource) -> String {
        switch source {
        case .textLayer: return "textLayer"
        case .ocr(let confidence):
            return "ocr(confidence=\(formatDouble(Double(confidence))))"
        }
    }

    private static func formatDouble(_ value: Double) -> String {
        // Two decimals is enough precision for thresholds / confidences
        // and keeps CSV rows compact. No scientific notation.
        String(format: "%.2f", value)
    }
}
