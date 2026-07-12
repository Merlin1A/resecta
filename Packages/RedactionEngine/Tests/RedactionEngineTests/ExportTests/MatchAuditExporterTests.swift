import Testing
import Foundation
@testable import RedactionEngine

// W5 — CSV + JSON serialization, RFC 4180 quoting, sensitive-content
// redaction, and rationale-summary formatting.

@Suite("MatchAuditExporter (W5)")
struct MatchAuditExporterTests {

    // MARK: - Helpers

    private func makeRecord(
        id: UUID = UUID(),
        pageIndex: Int = 0,
        matchedText: String = "Jane Doe",
        source: String = "textLayer",
        piiCategory: String? = "Name",
        piiConfidence: Double? = 0.92,
        term: String = "PII Scan",
        ruleID: String? = "name.nltagger",
        finalScore: Double? = 0.91,
        appliedThreshold: Double? = 0.70,
        rationaleSummary: String = "bloom.surname; thresholdPass(raw=0.91,cutoff=0.70)",
        isSelected: Bool = true,
        wasApplied: Bool = true
    ) -> MatchAuditRecord {
        MatchAuditRecord(
            id: id, pageIndex: pageIndex, matchedText: matchedText,
            source: source, piiCategory: piiCategory, piiConfidence: piiConfidence,
            term: term, ruleID: ruleID, finalScore: finalScore,
            appliedThreshold: appliedThreshold, rationaleSummary: rationaleSummary,
            isSelected: isSelected, wasApplied: wasApplied
        )
    }

    private func makeMetadata(total: Int = 1, applied: Int = 1) -> ExportMetadata {
        ExportMetadata(
            schemaVersion: 4,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "1.0.0 (42)",
            presetName: "Standard",
            perCategoryOverrides: [:],
            documentName: "sample.pdf",
            totalMatches: total,
            appliedMatches: applied
        )
    }

    // MARK: - Redaction

    @Test("redactedMatchedText collapses short strings to ellipsis")
    func shortStringRedacted() {
        #expect(MatchAuditExporter.redactedMatchedText("") == "…")
        #expect(MatchAuditExporter.redactedMatchedText("a") == "…")
        #expect(MatchAuditExporter.redactedMatchedText("abcd") == "…")
    }

    @Test("redactedMatchedText keeps first 2 + last 2 grapheme clusters")
    func standardRedaction() {
        #expect(MatchAuditExporter.redactedMatchedText("Acme Corp") == "Ac…rp")
        #expect(MatchAuditExporter.redactedMatchedText("Jane Doe") == "Ja…oe")
        #expect(MatchAuditExporter.redactedMatchedText("123-45-6789") == "12…89")
    }

    @Test("redactedMatchedText is grapheme-safe for emoji clusters")
    func emojiSafeRedaction() {
        // Family emoji is a single grapheme cluster composed of multiple
        // scalars. Redaction must operate on Character count, not UTF-16.
        let input = "👨‍👩‍👧🎉 hello"
        let redacted = MatchAuditExporter.redactedMatchedText(input)
        // 7 graphemes → keeps first 2 + "…" + last 2
        #expect(redacted.count == 5)
        #expect(redacted.first == "👨‍👩‍👧")
    }

    // MARK: - CSV

    @Test("CSV includes fixed header row after metadata comments")
    func csvHeaderRow() {
        let data = MatchAuditExporter.csv(
            [makeRecord()],
            metadata: makeMetadata(),
            includeSensitive: false
        )
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
        // Header is the first non-comment line. W-I2 schema v4 inserts
        // ruleVersion + gazetteerManifestVersion between ruleID and
        // finalScore (19 columns total).
        let header = lines.first { !$0.hasPrefix("#") }
        #expect(header == "id,pageIndex,matchedText,source,piiCategory,piiConfidence,term,ruleID,ruleVersion,gazetteerManifestVersion,finalScore,appliedThreshold,rationaleSummary,isSelected,wasApplied,suppressedByOverlap,foiaExemption,foiaCitation,foiaNote")
    }

    @Test("csvColumns has 19 fields after W-I2 schema v4 bump")
    func csvColumnCountIsNineteen() {
        #expect(MatchAuditExporter.csvColumns.count == 19)
    }

    @Test("CSV quotes fields containing commas, quotes, or newlines")
    func csvRFC4180Quoting() {
        let tricky = makeRecord(
            matchedText: "He said, \"hi\"\nand left",
            rationaleSummary: "validator(comma,split); ctx+(0.42)"
        )
        let data = MatchAuditExporter.csv(
            [tricky], metadata: makeMetadata(), includeSensitive: true
        )
        let text = String(data: data, encoding: .utf8) ?? ""
        // matchedText field is quoted and internal quotes doubled.
        #expect(text.contains("\"He said, \"\"hi\"\"\nand left\""))
        // rationaleSummary with comma is also quoted.
        #expect(text.contains("\"validator(comma,split); ctx+(0.42)\""))
    }

    @Test("CSV redacts matchedText by default")
    func csvRedactsByDefault() {
        let data = MatchAuditExporter.csv(
            [makeRecord(matchedText: "Acme Corp")],
            metadata: makeMetadata(),
            includeSensitive: false
        )
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text.contains("Ac…rp"))
        #expect(!text.contains("Acme Corp"))
    }

    @Test("CSV passes raw text through when includeSensitive is true")
    func csvRawWhenOptedIn() {
        let data = MatchAuditExporter.csv(
            [makeRecord(matchedText: "Acme Corp")],
            metadata: makeMetadata(),
            includeSensitive: true
        )
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text.contains("Acme Corp"))
        #expect(!text.contains("Ac…rp"))
    }

    @Test("CSV preserves input order")
    func csvOrderingStable() {
        let recs = (0..<5).map { makeRecord(pageIndex: $0, matchedText: "row\($0)") }
        let data = MatchAuditExporter.csv(
            recs, metadata: makeMetadata(total: 5, applied: 5), includeSensitive: true
        )
        let text = String(data: data, encoding: .utf8) ?? ""
        let bodyLines = text
            .split(separator: "\r\n", omittingEmptySubsequences: true)
            .drop(while: { $0.hasPrefix("#") || $0.hasPrefix("id,") })
        let indices = bodyLines.map { line -> Int in
            let fields = line.split(separator: ",", maxSplits: 2)
            return Int(fields[1]) ?? -1
        }
        #expect(Array(indices) == [0, 1, 2, 3, 4])
    }

    // MARK: - JSON

    @Test("JSON round-trips through decoder")
    func jsonRoundTrip() throws {
        let recs = [
            makeRecord(matchedText: "Acme Corp"),
            makeRecord(matchedText: "Jane Doe", piiCategory: "Name"),
        ]
        let metadata = makeMetadata(total: 2, applied: 2)
        let data = try MatchAuditExporter.json(
            recs, metadata: metadata, includeSensitive: true
        )
        struct Envelope: Decodable {
            let metadata: ExportMetadata
            let records: [MatchAuditRecord]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Envelope.self, from: data)
        #expect(decoded.metadata.schemaVersion == 4)
        #expect(decoded.records.count == 2)
        #expect(decoded.records[0].matchedText == "Acme Corp")
    }

    @Test("JSON round-trip preserves W-I2 ruleVersion + gazetteerManifestVersion")
    func jsonRoundTripV4Fields() throws {
        let rec = MatchAuditRecord(
            id: UUID(), pageIndex: 0, matchedText: "Acme",
            source: "textLayer", piiCategory: "Name", piiConfidence: 0.91,
            term: "PII Scan", ruleID: "name.nltagger",
            finalScore: 0.91, appliedThreshold: 0.70,
            rationaleSummary: "regex(name.nltagger)",
            isSelected: true, wasApplied: true,
            ruleVersion: "1.0",
            gazetteerManifestVersion: "1"
        )
        let data = try MatchAuditExporter.json(
            [rec], metadata: makeMetadata(), includeSensitive: true
        )
        struct Envelope: Decodable {
            let metadata: ExportMetadata
            let records: [MatchAuditRecord]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Envelope.self, from: data)
        #expect(decoded.metadata.schemaVersion == 4)
        #expect(decoded.records[0].ruleVersion == "1.0")
        #expect(decoded.records[0].gazetteerManifestVersion == "1")
    }

    @Test("CSV row places ruleVersion + gazetteerManifestVersion between ruleID and finalScore")
    func csvRowV4FieldOrdering() {
        let rec = MatchAuditRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            pageIndex: 0, matchedText: "Acme",
            source: "textLayer", piiCategory: "Name", piiConfidence: 0.91,
            term: "PII Scan", ruleID: "name.nltagger",
            finalScore: 0.91, appliedThreshold: 0.70,
            rationaleSummary: "regex(name.nltagger)",
            isSelected: true, wasApplied: true,
            ruleVersion: "1.0", gazetteerManifestVersion: "1"
        )
        let data = MatchAuditExporter.csv(
            [rec], metadata: makeMetadata(), includeSensitive: true
        )
        let text = String(data: data, encoding: .utf8) ?? ""
        // The two new columns sit immediately after ruleID and before
        // finalScore. Look for the ordered subsequence on the data row.
        #expect(text.contains(",name.nltagger,1.0,1,0.91,0.70,"))
    }

    @Test("JSON default redaction covers matchedText, term, and userFlag rationale (CAT-112)")
    func jsonDefaultRedactionCoversAllUserContentFields() throws {
        // Post-S6 (CAT-112): includeSensitive=false redacts EVERY
        // user-content field, not matchedText alone. Text-mode row, so
        // `term` is the user's own query (piiCategory nil) and the
        // rationale carries a user always-flag pattern. "Jane Doe" is a
        // synthetic stand-in for user PII; assertions compare against the
        // hard-coded fixture, never an interpolated runtime value (§10).
        let data = try MatchAuditExporter.json(
            [makeRecord(
                matchedText: "Jane Doe",
                piiCategory: nil,
                term: "Jane Doe",
                rationaleSummary: "userAlwaysFlag(Jane Doe); thresholdPass(raw=0.91,cutoff=0.70)"
            )],
            metadata: makeMetadata(),
            includeSensitive: false
        )
        let text = String(data: data, encoding: .utf8) ?? ""
        // The raw value must not survive in ANY field.
        #expect(!text.contains("Jane Doe"))
        // Redacted forms are present; non-flag metadata survives.
        #expect(text.contains("Ja…oe"))
        #expect(text.contains("userFlag([redacted])"))
        #expect(text.contains("thresholdPass(raw=0.91,cutoff=0.70)"))
    }

    @Test("JSON record object carries no keys outside the audit schema (no transient-field leak)")
    func jsonRecordHasNoUnexpectedKeys() throws {
        // S6 redacts in place rather than threading a transient raw-rationale
        // field through the record (the dossier's contingency architecture).
        // This pins that invariant generically: no out-of-schema key — a
        // future raw-rationale, debug, or un-CodingKey'd field — can reach
        // the on-disk JSON and re-open the leak.
        let allowedKeys: Set<String> = [
            "id", "pageIndex", "matchedText", "source", "piiCategory",
            "piiConfidence", "term", "ruleID", "finalScore", "appliedThreshold",
            "rationaleSummary", "isSelected", "wasApplied", "suppressedByOverlap",
            "foiaExemption", "foiaCitation", "foiaNote", "ruleVersion",
            "gazetteerManifestVersion",
        ]
        // Populate every field so the encoder omits none of the optionals.
        let rec = MatchAuditRecord(
            id: UUID(), pageIndex: 0, matchedText: "Acme Corp",
            source: "textLayer", piiCategory: "Name", piiConfidence: 0.9,
            term: "PII Scan", ruleID: "name.nltagger",
            finalScore: 0.9, appliedThreshold: 0.7,
            rationaleSummary: "regex(name.nltagger)",
            isSelected: true, wasApplied: true,
            suppressedByOverlap: false,
            foiaExemption: "(b)(6)", foiaCitation: "5 U.S.C. 552",
            foiaNote: "note", ruleVersion: "1.0", gazetteerManifestVersion: "1"
        )
        let data = try MatchAuditExporter.json(
            [rec], metadata: makeMetadata(), includeSensitive: false
        )
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let records = obj?["records"] as? [[String: Any]]
        let firstRecord = records?.first ?? [:]
        let keys = Set(firstRecord.keys)
        #expect(!keys.isEmpty)                 // sanity: the record decoded
        #expect(keys.isSubset(of: allowedKeys))
    }

    @Test("JSON envelope top-level keys sort deterministically")
    func jsonSortedKeys() throws {
        let data = try MatchAuditExporter.json(
            [], metadata: makeMetadata(total: 0, applied: 0), includeSensitive: true
        )
        let text = String(data: data, encoding: .utf8) ?? ""
        // sortedKeys guarantees metadata < records alphabetically.
        let metaIdx = text.range(of: "\"metadata\"")?.lowerBound
        let recsIdx = text.range(of: "\"records\"")?.lowerBound
        #expect(metaIdx != nil && recsIdx != nil && metaIdx! < recsIdx!)
    }

    // MARK: - rationaleSummary

    @Test("rationaleSummary flattens signals with separators")
    func rationaleSummaryFormat() {
        let rationale = MatchRationale(
            ruleID: "ssn.state-machine",
            signals: [
                .regexPattern(name: "ssn.sep"),
                .structuralValidator(name: "ssn.area"),
                .presetThresholdPass(raw: 0.91, cutoff: 0.70),
            ],
            preThresholdScore: 0.91,
            finalScore: 0.91,
            appliedThreshold: 0.70
        )
        let summary = MatchAuditExporter.rationaleSummary(rationale)
        #expect(summary == "regex(ssn.sep); validator(ssn.area); thresholdPass(raw=0.91,cutoff=0.70)")
    }

    @Test("rationaleSummary is empty when rationale is nil")
    func rationaleSummaryNil() {
        #expect(MatchAuditExporter.rationaleSummary(nil) == "")
    }

    @Test("rationaleSummary renders suppressedByOverlap with winner category")
    func rationaleSummarySuppressedByOverlap() {
        let rationale = MatchRationale(
            ruleID: "licensePlate.labeled",
            signals: [
                .regexPattern(name: "licensePlate.labeled"),
                .suppressedByOverlap(winnerCategory: .dea, loserCategory: .licensePlate),
            ],
            preThresholdScore: 0.30,
            finalScore: 0.80
        )
        let summary = MatchAuditExporter.rationaleSummary(rationale)
        #expect(summary == "regex(licensePlate.labeled); suppressedByOverlap(License Plate via DEA)")
    }

    @Test("CSV row serializes suppressedByOverlap=true literally")
    func csvSuppressedByOverlapTrue() {
        let rec = MatchAuditRecord(
            id: UUID(), pageIndex: 0, matchedText: "AB1234567",
            source: "textLayer", piiCategory: "License Plate", piiConfidence: 0.80,
            term: "PII Scan", ruleID: "licensePlate.labeled",
            finalScore: 0.80, appliedThreshold: 0.70,
            rationaleSummary: "regex(licensePlate.labeled); suppressedByOverlap(DEA)",
            isSelected: false, wasApplied: false,
            suppressedByOverlap: true
        )
        let data = MatchAuditExporter.csv(
            [rec], metadata: makeMetadata(), includeSensitive: true
        )
        let text = String(data: data, encoding: .utf8) ?? ""
        // 14th column (1-based). Row contents: ...,false,false,true,,,
        #expect(text.contains(",false,false,true,"))
    }

    @Test("JSON round-trip preserves suppressedByOverlap=true")
    func jsonSuppressedByOverlapRoundTrip() throws {
        let rec = MatchAuditRecord(
            id: UUID(), pageIndex: 1, matchedText: "QD793210",
            source: "textLayer", piiCategory: "Account", piiConfidence: 0.75,
            term: "PII Scan", ruleID: "account.regex",
            finalScore: 0.75, appliedThreshold: 0.70,
            rationaleSummary: "regex(account.regex); suppressedByOverlap(Medical Record)",
            isSelected: false, wasApplied: false,
            suppressedByOverlap: true
        )
        let data = try MatchAuditExporter.json(
            [rec], metadata: makeMetadata(), includeSensitive: true
        )
        struct Envelope: Decodable {
            let metadata: ExportMetadata
            let records: [MatchAuditRecord]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Envelope.self, from: data)
        #expect(decoded.records.first?.suppressedByOverlap == true)
    }

    @Test("sourceDescription stringifies textLayer and ocr variants")
    func sourceDescriptionShape() {
        #expect(MatchAuditExporter.sourceDescription(.textLayer) == "textLayer")
        #expect(MatchAuditExporter.sourceDescription(.ocr(confidence: 0.87)) == "ocr(confidence=0.87)")
    }

    // MARK: - S6 audit-leak fix (design 04 §audit)

    @Test("term column is redacted for non-piiScan rows when includeSensitive=false")
    func termRedactedWhenIncludeSensitiveFalse() throws {
        // Text-mode row: piiCategory is nil, the term is the user's query.
        let rec = makeRecord(
            matchedText: "Jane Doe",
            piiCategory: nil,
            term: "Jane Doe",
            rationaleSummary: ""
        )
        let csv = String(
            data: MatchAuditExporter.csv([rec], metadata: makeMetadata(), includeSensitive: false),
            encoding: .utf8
        ) ?? ""
        #expect(!csv.contains("Jane Doe"))
        #expect(csv.contains("Ja…oe"))

        let json = String(
            data: try MatchAuditExporter.json([rec], metadata: makeMetadata(), includeSensitive: false),
            encoding: .utf8
        ) ?? ""
        #expect(!json.contains("Jane Doe"))
    }

    @Test("term column keeps the category label for piiScan rows (piiCategory non-nil)")
    func termKeptForPIIScanRows() throws {
        // piiScan rows are identified by a non-nil piiCategory — the
        // category label is metadata, not PII.
        let rec = makeRecord(
            matchedText: "123-45-6789",
            piiCategory: "ssn",
            term: "PII Scan",
            rationaleSummary: "validator(ssn.area)"
        )
        let csv = String(
            data: MatchAuditExporter.csv([rec], metadata: makeMetadata(), includeSensitive: false),
            encoding: .utf8
        ) ?? ""
        // Pin the column sequence matchedText,source,piiCategory,
        // piiConfidence,term so the "ssn" hit is provably the TERM column,
        // not the adjacent piiCategory column.
        #expect(csv.contains("12…89,textLayer,ssn,0.92,ssn,"))
        #expect(!csv.contains("123-45-6789"))

        struct Envelope: Decodable { let records: [MatchAuditRecord] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            Envelope.self,
            from: try MatchAuditExporter.json([rec], metadata: makeMetadata(), includeSensitive: false)
        )
        #expect(decoded.records.first?.term == "ssn")
    }

    @Test("rationaleSummary strips the userAlwaysFlag pattern when includeSensitive=false")
    func rationaleSummaryStripsUserAlwaysFlag() {
        // Route through the live flattening so the test pins the actual
        // signalDescription format, then sanitize.
        let rationale = MatchRationale(
            ruleID: "user.alwaysFlag",
            signals: [
                .userAlwaysFlag(pattern: "123-45-6789"),
                .structuralValidator(name: "ssn.area"),
            ],
            preThresholdScore: 1.0,
            finalScore: 1.0
        )
        let summary = MatchAuditExporter.rationaleSummary(rationale)
        let sanitized = MatchAuditExporter.sanitizedRationaleSummary(summary)
        #expect(!sanitized.contains("123-45-6789"))
        #expect(sanitized.contains("userFlag([redacted])"))
        // Other signals are metadata and survive sanitization.
        #expect(sanitized.contains("validator(ssn.area)"))
    }

    @Test("rationaleSummary strips userNeverFlag and keeps non-flag signals")
    func rationaleSummaryStripsUserNeverFlag() {
        let sanitized = MatchAuditExporter.sanitizedRationaleSummary(
            "userNeverFlag(555-12-0000); thresholdPass(raw=0.91,cutoff=0.70)"
        )
        #expect(!sanitized.contains("555-12-0000"))
        #expect(sanitized.contains("thresholdPass(raw=0.91,cutoff=0.70)"))
    }

    @Test("Adversarial: a flag pattern containing a closing paren is stripped in full")
    func rationaleSummaryStripsParenBearingPattern() {
        // The closing-paren match anchors to a signal boundary (`)` then
        // `;` or end), so a pattern like `abc)def` cannot leak its tail.
        let sanitized = MatchAuditExporter.sanitizedRationaleSummary(
            "userAlwaysFlag(abc)def); validator(ssn.area)"
        )
        #expect(!sanitized.contains("abc"))
        #expect(!sanitized.contains("def"))
        #expect(sanitized.contains("validator(ssn.area)"))
    }

    @Test("Adversarial: term IS the user's SSN and only the redacted form ships")
    func termIsSSNAndIsRedactedInOutput() throws {
        // The user searched their own SSN in text mode — the term is the
        // PII. Both serializers must ship only first2+…+last2.
        let rec = makeRecord(
            matchedText: "123-45-6789",
            piiCategory: nil,
            term: "123-45-6789",
            rationaleSummary: "userAlwaysFlag(123-45-6789)"
        )
        let csvData = MatchAuditExporter.csv([rec], metadata: makeMetadata(), includeSensitive: false)
        let jsonData = try MatchAuditExporter.json([rec], metadata: makeMetadata(), includeSensitive: false)
        for output in [csvData, jsonData] {
            let text = String(data: output, encoding: .utf8) ?? ""
            #expect(!text.contains("123-45-6789"))
            #expect(text.contains("12…89"))
        }
    }

    @Test("includeSensitive=true keeps the raw term and rationale (no over-redaction)")
    func includeSensitiveTrueKeepsRawTermAndRationale() {
        let rec = makeRecord(
            matchedText: "Jane Doe",
            piiCategory: nil,
            term: "Jane Doe",
            rationaleSummary: "userAlwaysFlag(Jane Doe)"
        )
        let csv = String(
            data: MatchAuditExporter.csv([rec], metadata: makeMetadata(), includeSensitive: true),
            encoding: .utf8
        ) ?? ""
        #expect(csv.contains("Jane Doe"))
        #expect(csv.contains("userAlwaysFlag(Jane Doe)"))
    }

    // MARK: - Pkg C / ERR-02 — JSON encode failure propagates

    /// Pkg C / ERR-02: `MatchAuditExporter.json` is `throws` so encoder
    /// failures propagate to the caller (`MatchExportService.share`) where
    /// they wire into a Tier 1 `.error` toast. Inject an unencodable
    /// `Double.nan` into `ExportMetadata.perCategoryOverrides` — the
    /// default `JSONEncoder.NonConformingFloatEncodingStrategy.throw`
    /// rejects non-finite floats with `EncodingError.invalidValue`.
    @Test("JSON encode failure propagates as a throw (Pkg C / ERR-02)")
    func jsonEncodeFailurePropagates() {
        let unencodableMetadata = ExportMetadata(
            schemaVersion: 4,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "1.0.0 (42)",
            presetName: "Standard",
            perCategoryOverrides: ["Name": .nan],
            documentName: "sample.pdf",
            totalMatches: 1,
            appliedMatches: 1
        )
        #expect(throws: (any Error).self) {
            _ = try MatchAuditExporter.json(
                [makeRecord()],
                metadata: unencodableMetadata,
                includeSensitive: false
            )
        }
    }

    /// Round-trip on the happy path still works after the throwing
    /// signature change — guards against accidentally regressing the
    /// success path while wiring the propagation.
    @Test("JSON throws-signature does not regress the happy path (Pkg C)")
    func jsonHappyPathStillReturnsData() throws {
        let data = try MatchAuditExporter.json(
            [makeRecord()],
            metadata: makeMetadata(),
            includeSensitive: false
        )
        #expect(!data.isEmpty)
    }

    // MARK: - D07-F1 — CSV / formula-injection neutralizer (CWE-1236)

    /// The CWE-1236 lead characters the neutralizer defuses. Kept in the test
    /// independently of the production set so a silent drop from the source
    /// set surfaces here.
    private static let triggerLeads: [Character] = ["=", "+", "-", "@", "\u{0009}", "\u{000D}"]

    // Column indices into csvColumns (stable schema v4).
    private let matchedTextColumn = 2
    private let termColumn = 6
    private let rationaleSummaryColumn = 12

    /// Parse the first data row of a serialized CSV into its field VALUES,
    /// honoring RFC-4180 quoting (a quoted field is unwrapped and its doubled
    /// quotes collapsed). Skips the `#` metadata comments and the `id,` header.
    /// `"\r\n"` is a single grapheme cluster, so a lone `\r` inside a quoted
    /// field never splits a row.
    private func dataRowFields(_ data: Data) -> [String] {
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: true)
        guard let row = lines.first(where: { !$0.hasPrefix("#") && !$0.hasPrefix("id,") }) else {
            return []
        }
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(row)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        current.append("\"")
                        i += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    current.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        fields.append(current)
        return fields
    }

    @Test("Each formula-injection lead character is defused with a force-text apostrophe")
    func eachTriggerLeadIsDefused() {
        for trigger in Self.triggerLeads {
            let rec = makeRecord(matchedText: "\(trigger)HYPERLINK(\"x\")")
            let data = MatchAuditExporter.csv([rec], metadata: makeMetadata(), includeSensitive: true)
            let fields = dataRowFields(data)
            #expect(fields.count == 19,
                    "row should parse into all 19 columns for trigger \(trigger.debugDescription)")
            // The matchedText cell value leads with the force-text apostrophe.
            #expect(fields[matchedTextColumn].first == "'",
                    "matchedText cell must lead with ' for trigger \(trigger.debugDescription)")
            // No cell leads with a raw trigger character.
            for field in fields {
                if let first = field.first {
                    #expect(!Self.triggerLeads.contains(first),
                            "no cell may lead with a raw trigger; \(trigger.debugDescription) leaked as \(field.debugDescription)")
                }
            }
        }
    }

    @Test("A DDE command payload is defused and round-trips after stripping one apostrophe")
    func ddePayloadDefusedAndReversible() {
        let payload = "=cmd|'/c calc'!A1"
        let rec = makeRecord(matchedText: payload)
        let data = MatchAuditExporter.csv([rec], metadata: makeMetadata(), includeSensitive: true)
        let cell = dataRowFields(data)[matchedTextColumn]
        #expect(cell.first != "=")
        #expect(cell.first == "'")
        // Reversible: a consumer strips one leading apostrophe to recover the original.
        #expect(String(cell.dropFirst()) == payload)
    }

    @Test("Non-trigger content is byte-identical to the pre-fix output (no-op off the trigger path)")
    func nonTriggerContentUnchanged() {
        // Plain value: the neutralizer is a no-op and no quoting is needed.
        let plain = MatchAuditExporter.csv(
            [makeRecord(matchedText: "John Smith")],
            metadata: makeMetadata(), includeSensitive: true
        )
        #expect(dataRowFields(plain)[matchedTextColumn] == "John Smith")
        let plainText = String(data: plain, encoding: .utf8) ?? ""
        #expect(plainText.contains(",John Smith,"))   // emitted bare: no apostrophe, no quotes

        // RFC-4180 comma case: still wrapped in quotes, still no apostrophe.
        let comma = MatchAuditExporter.csv(
            [makeRecord(matchedText: "Smith, John")],
            metadata: makeMetadata(), includeSensitive: true
        )
        #expect(dataRowFields(comma)[matchedTextColumn] == "Smith, John")
        let commaText = String(data: comma, encoding: .utf8) ?? ""
        #expect(commaText.contains("\"Smith, John\""))   // RFC-4180 quoting preserved
    }

    @Test("The neutralizer covers every column, not just matchedText")
    func neutralizerCoversAllColumns() {
        // includeSensitive: true so term and rationaleSummary pass through raw,
        // each carrying its own trigger lead. Pins the fix at the csvEscape
        // choke point rather than a per-column patch.
        let rec = makeRecord(matchedText: "=A", term: "+B", rationaleSummary: "@C")
        let fields = dataRowFields(
            MatchAuditExporter.csv([rec], metadata: makeMetadata(), includeSensitive: true)
        )
        #expect(fields[matchedTextColumn] == "'=A")
        #expect(fields[termColumn] == "'+B")
        #expect(fields[rationaleSummaryColumn] == "'@C")
    }

    @Test("includeSensitive=false: a redacted value that leads with a trigger is also defused")
    func redactedValueWithTriggerLeadIsDefused() {
        // "=invalid=" redacts to first2+…+last2 = "=i…d=", which itself leads
        // with '=' — the neutralizer runs after redaction and defuses that too,
        // without re-exposing the raw value.
        let rec = makeRecord(matchedText: "=invalid=")
        let data = MatchAuditExporter.csv([rec], metadata: makeMetadata(), includeSensitive: false)
        let cell = dataRowFields(data)[matchedTextColumn]
        #expect(cell.first == "'")
        #expect(cell.contains("…"))            // the redacted form shipped, not the raw value
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(!text.contains("=invalid="))   // raw value never reaches the cell
    }
}
