import Testing
import Foundation
@testable import RedactionEngine

// Detection-quality baseline — standing emitter (NOT a pass/fail gate).
//
// Pinned by the detection-baseline evaluation contract.
// Per that contract: "standing baseline emitter, not a gate" — this suite runs
// the live detector over the whole G8 corpus once and writes the raw join cells
// + every raw score. The Python scorer (the contract's other half) derives all
// P/R/F1/FPR + demographic / doctype slices from these two files.
//
// Why a NEW suite rather than editing the D1 gate's sweepG8Corpus:
// the D1 gate lumps ALL ground-truth spans (including expected_outcome==suppress)
// into one set and counts a covered suppress span as a true positive. For the
// baseline we MUST split ground truth by expected_outcome (redact/flag → recall
// denominator; suppress → adversarial decoy, where a fire is an FP). This suite
// also keys cells by (category, doctype, demographic_bucket) and scores all 12
// G8 categories including phone/email (the gate's category map drops those two).
//
// Every emitted record carries
// category + offset-derived counts + bucket + raw score only. No document text,
// no PII values, no coordinates. The harness never reads or emits span/match
// `text`; only NSRange locations are used, and only as overlap arithmetic.
//
// Balanced cutoffs are sourced from the SAME free helper the D1 gate uses
// (`balancedCutoff(for:)` in NegativeContextGateSupport.swift), which reads the
// shipped balanced preset-thresholds vector via
// PresetThresholdBundle.loadFromEngineBundle(). Reusing it keeps the baseline's
// surfacing decision identical to the gate's, by construction.

@Suite("G8 detection baseline (standing emitter)", .serialized)
struct G8BaselineHarnessTests {

    // MARK: - Self-contained wire format (only the fields the baseline needs)

    struct BaselineG8Corpus: Decodable, Sendable {
        let seed: Int
        let documents: [BaselineG8Document]
    }

    struct BaselineG8Document: Decodable, Sendable {
        let id: String
        let doctype: String
        let demographic_bucket: String
        let text: String
        let pii_spans: [BaselineG8Span]
    }

    struct BaselineG8Span: Decodable, Sendable {
        let category: String
        let start: Int
        let end: Int
        let expected_outcome: String?
        // 1.2 P1.10 (C12-25 clause 2): the packet-tier bridge the dp generator
        // writes (must / should / watch / must_not). Optional so a
        // pre-extension corpus still decodes; `bridgedTier` re-derives it.
        let tier: String?

        /// The span's packet tier: the generator's explicit `tier`, else the
        /// same bridge dp applies (redact -> must, flag -> watch,
        /// suppress -> must_not).
        var bridgedTier: String {
            if let tier { return tier }
            switch expected_outcome {
            case "suppress": return "must_not"
            case "flag":     return "watch"
            default:         return "must"
            }
        }
    }

    // MARK: - Output JSON shapes

    /// One (category, doctype, bucket) cell. Field names and semantics are
    /// fixed by the baseline's output schema.
    ///
    /// The eight `tier_*` counters are ADDITIVE. The six legacy counts keep
    /// their original semantics (positive = every non-suppress span); the
    /// tier counters split the same ground truth by the packet-tier bridge so
    /// the datapipeline's `eval-baseline` can score per tier (must / should /
    /// watch recall, must_not fire rate) beside the document harness rows.
    struct BaselineCell: Encodable, Sendable {
        var true_positives: Int = 0
        var false_negatives: Int = 0
        var false_positives: Int = 0
        var adversarial_suppress_total: Int = 0
        var adversarial_suppress_fired: Int = 0
        var suppressed_by_negative_context: Int = 0
        var tier_must_total: Int = 0
        var tier_must_covered: Int = 0
        var tier_should_total: Int = 0
        var tier_should_covered: Int = 0
        var tier_watch_total: Int = 0
        var tier_watch_covered: Int = 0
        var tier_must_not_total: Int = 0
        var tier_must_not_fired: Int = 0

        /// Fold one ground-truth span of `tier` into the tier counters;
        /// `hit` = at least one surfaced detection overlaps it.
        mutating func tally(tier: String, hit: Bool) {
            switch tier {
            case "must":
                tier_must_total += 1
                if hit { tier_must_covered += 1 }
            case "should":
                tier_should_total += 1
                if hit { tier_should_covered += 1 }
            case "watch":
                tier_watch_total += 1
                if hit { tier_watch_covered += 1 }
            case "must_not":
                tier_must_not_total += 1
                if hit { tier_must_not_fired += 1 }
            default:
                break
            }
        }
    }

    struct BaselineCellsReport: Encodable, Sendable {
        let schema_version: Int
        let generated_by: String
        let g8_corpus_seed: Int
        let cutoff_preset: String
        // 1.2 H1.1: which surfacing gate produced the cells — "detector"
        // (PIIDetector raw vs balanced cutoff, this suite) or "siteB" (the
        // composed Search-and-Redact gate, G8SearchParityHarnessTests).
        let site: String
        let doc_count: Int
        let cells: [String: BaselineCell]
    }

    struct RawScoreRow: Encodable, Sendable {
        let category: String
        let doctype: String
        let bucket: String
        let raw: Double
        let gt_class: String  // "positive" | "suppress" | "none"
    }

    struct RawScoresReport: Encodable, Sendable {
        let schema_version: Int
        let site: String
        let balanced_cutoffs: [String: Double]
        let absorbing_state_floor: Double
        let rows: [RawScoreRow]
    }

    // MARK: - File 5: per-fire feature dump
    //
    // Offset-only, emitted ONLY for the five scored families
    // (account, phone, mrn, ein, itin). The `features` array is produced by the
    // @testable-imported production builder `contextFeatures(...)`, so these are
    // LITERALLY the features the context-scoring seam will compute (no test re-implementation).
    // category / offset / bucket / aggregate / raw-score /
    // doctype only — never match or span TEXT.
    //
    // `family` is the scorer/trainer block key (= wireName(for:),
    // MRN → "mrn"); `cell_category_key` joins to baseline_cells.json
    // (= PIICategory.rawValue lowercased, MRN → "medicalrecord"). The two differ
    // for exactly one family — both are emitted (neither is hard-coded).

    struct FireFeatureRow: Encodable, Sendable {
        let family: String
        let cell_category_key: String
        let doctype: String
        let bucket: String
        let start: Int
        let end: Int
        let raw: Double
        let gt_class: String   // "positive" | "suppress" | "none"
        let surfaced: Bool
        let features: [Double] // arity 13, in feature_order order
    }

    struct FireFeaturesReport: Encodable, Sendable {
        let schema_version: Int
        let generated_by: String
        let site: String
        let feature_order: [String]
        let fires: [FireFeatureRow]
    }

    // MARK: - Category map (ALL 17 G8 categories, incl. phone/email)
    //
    // G8 corpus category strings (G8CorpusIngestionTests.allowedCategories):
    //   ssn, npi, dea, dob, address, account, mrn, name, phone, email,
    //   routingNumber, ein — and, since 1.2 T1.1 (C12-25): itin, creditCard,
    //   driversLicense, passport, licensePlate.
    // This is the baseline's OWN map (the gate's gateMapCategory drops
    // phone/email and the detector emits both with no doctype gate).

    static func baselineMapCategory(_ s: String) -> RedactionRegion.PIIKind? {
        switch s {
        case "ssn":            return .ssn
        case "npi":            return .npi
        case "dea":            return .dea
        case "dob":            return .dateOfBirth
        case "address":        return .address
        case "account":        return .account
        case "mrn":            return .medicalRecord
        case "name":           return .name
        case "phone":          return .phone
        case "email":          return .email
        case "routingNumber":  return .routingNumber
        case "ein":            return .ein
        case "itin":           return .itin
        case "creditCard":     return .creditCard
        case "driversLicense": return .driversLicense
        case "passport":       return .passport
        case "licensePlate":   return .licensePlate
        default:               return nil
        }
    }

    /// Every kind the corpus can carry, in the cutoff-map order the raw_scores
    /// header lists them (the 12 original kinds, then the five added ones).
    static let allCorpusKinds: [RedactionRegion.PIIKind] = [
        .ssn, .name, .address, .account, .ein, .npi, .dea,
        .phone, .email, .routingNumber, .medicalRecord, .dateOfBirth,
        .itin, .creditCard, .driversLicense, .passport, .licensePlate,
    ]

    /// Cell category key = PIICategory.rawValue, lowercased, spaces stripped.
    /// (ssn, name, address, account, ein, npi, dea, phone, email,
    /// routingnumber, medicalrecord, dateofbirth, itin, creditcard,
    /// driver'slicense, passport, licenseplate — the apostrophe survives.)
    static func cellCategoryKey(for kind: RedactionRegion.PIIKind) -> String? {
        guard let cat = PIICategory(piiKind: kind) else { return nil }
        return cat.rawValue.lowercased().replacingOccurrences(of: " ", with: "")
    }

    // MARK: - Loader (own; Bundle.module corpus/g8_corpus.json)

    static func loadBaselineCorpus() throws -> BaselineG8Corpus? {
        guard let url = Bundle.module.url(
            forResource: "g8_corpus",
            withExtension: "json",
            subdirectory: "corpus"
        ) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BaselineG8Corpus.self, from: data)
    }

    // MARK: - Output path resolution
    //
    // Base via RESECTA_BASELINE_OUT (+ TEST_RUNNER_-prefixed fallback that
    // xcodebuild forwards to the runner), default /tmp/resecta_s3_baseline.
    // Files: <base>_cells.json and <base>_raw_scores.json.

    static func baselineOutBase() -> String {
        let env = ProcessInfo.processInfo.environment
        if let p = env["RESECTA_BASELINE_OUT"], !p.isEmpty { return p }
        if let p = env["TEST_RUNNER_RESECTA_BASELINE_OUT"], !p.isEmpty { return p }
        return "/tmp/resecta_s3_baseline"
    }

    static func writeJSON<T: Encodable>(_ value: T, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Half-open [start, end) overlap

    static func rangesOverlap(_ a: NSRange, _ b: NSRange) -> Bool {
        let aEnd = a.location + a.length
        let bEnd = b.location + b.length
        return a.location < bEnd && b.location < aEnd
    }

    // MARK: - Per-span outcome sidecar (one JSONL per site)
    //
    // Beside the trio, each emitter writes one JSON-Lines file with ONE row
    // per ground-truth span of every corpus family plus one row per surfaced
    // detection that overlaps no ground-truth span of its family. Rows carry
    // offsets only -- never the span or match text:
    //
    //   {doc_id, family, start, end, tier, outcome}
    //     outcome "tp" / "fn"  a positive span covered / not covered by at
    //                          least one surfaced detection (the trio's
    //                          true_positives / false_negatives, span by span);
    //                          "tp" rows add det_start / det_end -- the hull
    //                          of EVERY surfaced same-family detection that
    //                          overlaps the span -- and det_spans, those
    //                          detections' own [start, end] pairs in start
    //                          order (the name path emits one detection per
    //                          token, so a two-token name is usually covered
    //                          by two detections; the pairs keep that split
    //                          derivable while the hull keeps the row simple).
    //     outcome "fp"         tier null: a surfaced detection overlapping no
    //                          ground truth (start / end are the detection's);
    //                          tier "must_not": a planted decoy that fired
    //                          (with the same det fields as a "tp" row).
    //     outcome "tn"         a planted decoy (tier must_not) that stayed quiet.
    //
    // `family` is the corpus category string (the inverse of
    // baselineMapCategory), so the datapipeline reader joins rows back to the
    // corpus by (doc_id, start, end) without a second vocabulary. The join is
    // the SAME binary overlap the counters use; the sidecar preserves what the
    // tally loops compute and discard. Rows are sorted by (doc_id, family,
    // start, end, outcome, det_start) with sorted keys per line and LF line
    // ends -- that ordering is the file's determinism, since it bypasses
    // writeJSON.

    struct SpanOutcomeRow: Encodable, Sendable {
        let doc_id: String
        let family: String
        let start: Int
        let end: Int
        let tier: String?        // nil on detection-only rows -> JSON null
        let outcome: String      // "tp" | "fn" | "fp" | "tn"
        let det_start: Int?      // present on covered rows only: the hull
        let det_end: Int?
        let det_spans: [[Int]]?  // every overlapping detection's [start, end]

        private enum CodingKeys: String, CodingKey {
            case doc_id, family, start, end, tier, outcome, det_start, det_end, det_spans
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(doc_id, forKey: .doc_id)
            try c.encode(family, forKey: .family)
            try c.encode(start, forKey: .start)
            try c.encode(end, forKey: .end)
            try c.encode(tier, forKey: .tier)           // Optional -> explicit null
            try c.encode(outcome, forKey: .outcome)
            try c.encodeIfPresent(det_start, forKey: .det_start)
            try c.encodeIfPresent(det_end, forKey: .det_end)
            try c.encodeIfPresent(det_spans, forKey: .det_spans)
        }
    }

    /// The corpus category string for a kind (inverse of `baselineMapCategory`).
    static func corpusCategory(for kind: RedactionRegion.PIIKind) -> String? {
        Self.corpusCategoryByKind[kind]
    }

    private static let corpusCategoryByKind: [RedactionRegion.PIIKind: String] = {
        let names = [
            "ssn", "npi", "dea", "dob", "address", "account", "mrn", "name", "phone",
            "email", "routingNumber", "ein", "itin", "creditCard", "driversLicense",
            "passport", "licensePlate",
        ]
        var map: [RedactionRegion.PIIKind: String] = [:]
        for name in names {
            if let kind = baselineMapCategory(name) { map[kind] = name }
        }
        return map
    }()

    /// The sidecar bytes: one sorted-key JSON object per line, rows in
    /// (doc_id, family, start, end, outcome, det_start) order, LF-terminated.
    static func spanSidecarData(_ rows: [SpanOutcomeRow]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let ordered = rows.sorted { a, b in
            if a.doc_id != b.doc_id { return a.doc_id < b.doc_id }
            if a.family != b.family { return a.family < b.family }
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end < b.end }
            if a.outcome != b.outcome { return a.outcome < b.outcome }
            return (a.det_start ?? -1) < (b.det_start ?? -1)
        }
        var data = Data()
        for row in ordered {
            data.append(try encoder.encode(row))
            data.append(0x0A)
        }
        return data
    }

    static func writeSpanSidecar(_ rows: [SpanOutcomeRow], to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try spanSidecarData(rows).write(to: url, options: .atomic)
    }

    /// Fold one kind's ground truth and surfaced detections into sidecar rows
    /// (the same overlap predicate the cell counters apply).
    static func appendSpanRows(
        into rows: inout [SpanOutcomeRow],
        docID: String,
        family: String,
        groundTruth: [(NSRange, String, Bool)],   // (range, tier, isDecoy)
        surfaced: [(NSRange, Bool)],
        allGT: [NSRange]
    ) {
        for (gt, tier, isDecoy) in groundTruth {
            // Every surfaced detection overlapping this span (the counters
            // ask only whether there is at least one), in start order.
            let hits = surfaced
                .map { $0.0 }
                .filter { rangesOverlap($0, gt) }
                .sorted { ($0.location, $0.length) < ($1.location, $1.length) }
            let covered = !hits.isEmpty
            let outcome: String
            if isDecoy { outcome = covered ? "fp" : "tn" }
            else       { outcome = covered ? "tp" : "fn" }
            rows.append(SpanOutcomeRow(
                doc_id: docID, family: family,
                start: gt.location, end: gt.location + gt.length,
                tier: tier, outcome: outcome,
                det_start: hits.map(\.location).min(),
                det_end: hits.map { $0.location + $0.length }.max(),
                det_spans: covered ? hits.map { [$0.location, $0.location + $0.length] } : nil
            ))
        }
        for (det, _) in surfaced where !allGT.contains(where: { rangesOverlap(det, $0) }) {
            rows.append(SpanOutcomeRow(
                doc_id: docID, family: family,
                start: det.location, end: det.location + det.length,
                tier: nil, outcome: "fp", det_start: nil, det_end: nil, det_spans: nil
            ))
        }
    }

    @Test("Span sidecar line format is sorted, keyed and null-explicit")
    func spanSidecarLineFormat() throws {
        let rows = [
            SpanOutcomeRow(doc_id: "b", family: "name", start: 8, end: 16, tier: "should",
                           outcome: "fn", det_start: nil, det_end: nil, det_spans: nil),
            SpanOutcomeRow(doc_id: "a", family: "phone", start: 30, end: 41, tier: nil,
                           outcome: "fp", det_start: nil, det_end: nil, det_spans: nil),
            SpanOutcomeRow(doc_id: "a", family: "name", start: 10, end: 24, tier: "must",
                           outcome: "tp", det_start: 10, det_end: 24,
                           det_spans: [[10, 15], [16, 24]]),
        ]
        let text = String(decoding: try Self.spanSidecarData(rows), as: UTF8.self)
        #expect(text == """
            {"det_end":24,"det_spans":[[10,15],[16,24]],"det_start":10,"doc_id":"a","end":24,"family":"name","outcome":"tp","start":10,"tier":"must"}
            {"doc_id":"a","end":41,"family":"phone","outcome":"fp","start":30,"tier":null}
            {"doc_id":"b","end":16,"family":"name","outcome":"fn","start":8,"tier":"should"}

            """)
        #expect(Self.corpusCategory(for: .medicalRecord) == "mrn")
        #expect(Self.corpusCategory(for: .dateOfBirth) == "dob")
    }

    // MARK: - The emit

    @Test("Emit G8 baseline cells + raw scores")
    func emitBaseline() async throws {
        guard let corpus = try Self.loadBaselineCorpus() else {
            print("[detection-baseline] g8_corpus.json not bundled; emit skipped " +
                  "until `make install-assets` runs.")
            return
        }

        let detector = PIIDetector()
        let sortedDocs = corpus.documents.sorted { $0.id < $1.id }

        // cellKey = "<categoryKey>_<doctype>_<bucket>"
        var cells: [String: BaselineCell] = [:]
        var rawRows: [RawScoreRow] = []
        // File 5: per-fire rows for the five scored families only.
        var fireRows: [FireFeatureRow] = []
        // Per-span outcome sidecar rows (offsets only; every family).
        var spanRows: [SpanOutcomeRow] = []

        for doc in sortedDocs {
            guard let doctype = gateDoctypeClass(doc.doctype) else { continue }
            let bucket = doc.demographic_bucket

            let matches = await detector.detect(in: doc.text, doctype: doctype)

            // Ground truth grouped by kind, split by expected_outcome.
            // suppress → decoy; everything else (redact/flag/nil) → positive.
            var positiveGTByKind: [RedactionRegion.PIIKind: [NSRange]] = [:]
            var decoyGTByKind:    [RedactionRegion.PIIKind: [NSRange]] = [:]
            // All GT of a kind (positive ∪ decoy) — used to decide a generic FP
            // (a surfaced detection overlapping NO GT span of any label).
            var allGTByKind:      [RedactionRegion.PIIKind: [NSRange]] = [:]
            // Every GT span of a kind with its packet tier (the additive
            // per-tier counters, 1.2 P1.10).
            var tierGTByKind:     [RedactionRegion.PIIKind: [(NSRange, String)]] = [:]
            // Every GT span with its tier and its positive/decoy split, for
            // the per-span sidecar (same split the counters use).
            var spanGTByKind:     [RedactionRegion.PIIKind: [(NSRange, String, Bool)]] = [:]
            for span in doc.pii_spans {
                guard let kind = Self.baselineMapCategory(span.category) else { continue }
                let r = NSRange(location: span.start, length: span.end - span.start)
                allGTByKind[kind, default: []].append(r)
                tierGTByKind[kind, default: []].append((r, span.bridgedTier))
                spanGTByKind[kind, default: []].append(
                    (r, span.bridgedTier, span.expected_outcome == "suppress"))
                if span.expected_outcome == "suppress" {
                    decoyGTByKind[kind, default: []].append(r)
                } else {
                    positiveGTByKind[kind, default: []].append(r)
                }
            }

            // Surfaced detections grouped by kind. "Surfaced" = confidence clears
            // the balanced cutoff (nil cutoff → passes unfiltered).
            // Each entry carries (range, neg-context-suppressed self-report).
            var surfacedByKind: [RedactionRegion.PIIKind: [(NSRange, Bool)]] = [:]
            for match in matches {
                let cutoff = balancedCutoff(for: match.kind)
                let surfaced = cutoff.map { match.confidence >= $0 } ?? true

                // Raw scores: EVERY match (pre-cutoff), tagged by overlap class
                // against same-kind GT. positive ∪ decoy → check decoy first so a
                // decoy overlap classifies as "suppress" even if a positive of the
                // same kind also overlaps (decoy is the stricter signal).
                if let catKey = Self.cellCategoryKey(for: match.kind) {
                    let gtClass: String
                    let decoys = decoyGTByKind[match.kind] ?? []
                    let positives = positiveGTByKind[match.kind] ?? []
                    if decoys.contains(where: { Self.rangesOverlap(match.range, $0) }) {
                        gtClass = "suppress"
                    } else if positives.contains(where: { Self.rangesOverlap(match.range, $0) }) {
                        gtClass = "positive"
                    } else {
                        gtClass = "none"
                    }
                    rawRows.append(RawScoreRow(
                        category: catKey,
                        doctype: doc.doctype,
                        bucket: bucket,
                        raw: match.confidence,
                        gt_class: gtClass
                    ))

                    // File 5: append a per-fire row ONLY for the five
                    // scored families, keyed by `family` (= wireName). This
                    // split keeps `cell_category_key` (= catKey) distinct — both
                    // come from functions, neither literal. `gtClass` and
                    // `surfaced` are reused (not recomputed). `features` is the
                    // production builder over the doctype passed to detect()
                    // (gateDoctypeClass(doc.doctype), == `doctype` here) for both
                    // the doctype and effectiveDoctype params.
                    if let family = PIICategory(piiKind: match.kind)
                        .flatMap({ PresetThresholdVector.wireName(for: $0) }),
                        ContextFeatureContract.scoredFamilies.contains(family) {
                        let feats = contextFeatures(
                            match: match,
                            effectiveDoctype: doctype,
                            pageText: doc.text
                        )
                        fireRows.append(FireFeatureRow(
                            family: family,
                            cell_category_key: catKey,
                            doctype: doc.doctype,
                            bucket: bucket,
                            start: match.range.location,
                            end: match.range.location + match.range.length,
                            raw: match.confidence,
                            gt_class: gtClass,
                            surfaced: surfaced,
                            features: feats
                        ))
                    }
                }

                if surfaced {
                    surfacedByKind[match.kind, default: []]
                        .append((match.range, isNegativeContextSuppressed(match)))
                }
            }

            // Score each kind present in any GT bucket or in surfaced detections.
            var kinds = Set(allGTByKind.keys)
            kinds.formUnion(surfacedByKind.keys)

            for kind in kinds {
                guard let catKey = Self.cellCategoryKey(for: kind) else { continue }
                let cellKey = "\(catKey)_\(doc.doctype)_\(bucket)"
                var cell = cells[cellKey] ?? BaselineCell()

                let positives = positiveGTByKind[kind] ?? []
                let decoys    = decoyGTByKind[kind] ?? []
                let allGT     = allGTByKind[kind] ?? []
                let surfaced  = surfacedByKind[kind] ?? []

                // TP / FN: positive GT covered (or not) by ≥1 surfaced detection.
                for gt in positives {
                    let covered = surfaced.contains { Self.rangesOverlap($0.0, gt) }
                    if covered { cell.true_positives += 1 } else { cell.false_negatives += 1 }
                }

                // Adversarial suppression: decoy GT, and which fired.
                cell.adversarial_suppress_total += decoys.count
                for decoy in decoys {
                    let fired = surfaced.contains { Self.rangesOverlap($0.0, decoy) }
                    if fired { cell.adversarial_suppress_fired += 1 }
                }

                // Generic FP: surfaced detection overlapping NO GT span (any label).
                // Neg-context self-report: surfaced det carrying the suppressed
                // signal (recorded for comparison; NOT used in GT-keyed FP).
                for (det, suppressed) in surfaced {
                    let overlapsAnyGT = allGT.contains { Self.rangesOverlap(det, $0) }
                    if !overlapsAnyGT { cell.false_positives += 1 }
                    if suppressed { cell.suppressed_by_negative_context += 1 }
                }

                // Per-tier counters (additive): the same overlap rule, split
                // by the packet-tier bridge.
                for (gt, tier) in tierGTByKind[kind] ?? [] {
                    let hit = surfaced.contains { Self.rangesOverlap($0.0, gt) }
                    cell.tally(tier: tier, hit: hit)
                }

                // Per-span outcome sidecar: the verdicts the loops above fold
                // into counters, preserved span by span (offsets only).
                if let family = Self.corpusCategory(for: kind) {
                    Self.appendSpanRows(
                        into: &spanRows, docID: doc.id, family: family,
                        groundTruth: spanGTByKind[kind] ?? [],
                        surfaced: surfaced, allGT: allGT
                    )
                }

                cells[cellKey] = cell
            }
        }

        // Balanced cutoff map for the raw_scores header — one entry per cell
        // category key that has a non-nil balanced cutoff (nil omitted).
        var cutoffMap: [String: Double] = [:]
        for kind in Self.allCorpusKinds {
            guard let catKey = Self.cellCategoryKey(for: kind) else { continue }
            if let c = balancedCutoff(for: kind) { cutoffMap[catKey] = c }
        }

        let base = Self.baselineOutBase()

        let cellsReport = BaselineCellsReport(
            schema_version: 1,
            generated_by: "G8BaselineHarness.sweepG8Corpus",
            g8_corpus_seed: corpus.seed,
            cutoff_preset: "balanced",
            site: "detector",
            doc_count: sortedDocs.count,
            cells: cells
        )
        try Self.writeJSON(cellsReport, to: "\(base)_cells.json")

        let rawReport = RawScoresReport(
            schema_version: 1,
            site: "detector",
            balanced_cutoffs: cutoffMap,
            absorbing_state_floor: DetectionOrchestrator.absorbingStateFloor,
            rows: rawRows
        )
        try Self.writeJSON(rawReport, to: "\(base)_raw_scores.json")

        // File 5: per-fire feature dump. OWN provenance string; the
        // frozen detection-baseline cells report keeps "G8BaselineHarness.sweepG8Corpus"
        // untouched above. feature_order references the single contract authority.
        let fireReport = FireFeaturesReport(
            schema_version: 1,
            generated_by: "G8BaselineHarness.fireFeatures",
            site: "detector",
            feature_order: ContextFeatureContract.featureOrder,
            fires: fireRows
        )
        try Self.writeJSON(fireReport, to: "\(base)_fire_features.json")

        // Per-span outcome sidecar (one JSONL per site; additive, offsets only).
        try Self.writeSpanSidecar(spanRows, to: "\(base)_detector_spans.jsonl")

        print("[detection-baseline] cells → \(base)_cells.json (\(cells.count) cells)")
        print("[detection-baseline] raw_scores → \(base)_raw_scores.json (\(rawRows.count) rows)")
        print("[detection-baseline] fire_features → \(base)_fire_features.json (\(fireRows.count) fires)")
        print("[detection-baseline] spans → \(base)_detector_spans.jsonl (\(spanRows.count) rows)")

        // Emitter sanity only (this is NOT a pass/fail quality gate).
        #expect(!cells.isEmpty, "no cells emitted — corpus loaded but produced nothing")
        #expect(sortedDocs.count == 1100,
                "G8 doc_count expected 1100; got \(sortedDocs.count)")
        // Emitter sanity only: the sidecar carries one row per corpus span the
        // tally saw (tp + fn + must_not) and one per generic false positive.
        let corpusSpans = sortedDocs
            .filter { gateDoctypeClass($0.doctype) != nil }
            .reduce(0) { $0 + $1.pii_spans.filter { Self.baselineMapCategory($0.category) != nil }.count }
        let groundTruthRows = spanRows.filter { $0.tier != nil }.count
        let cellGroundTruth = cells.values.reduce(0) {
            $0 + $1.true_positives + $1.false_negatives + $1.tier_must_not_total
        }
        #expect(groundTruthRows == corpusSpans,
                "sidecar ground-truth rows \(groundTruthRows) != corpus spans \(corpusSpans)")
        #expect(groundTruthRows == cellGroundTruth,
                "sidecar ground-truth rows \(groundTruthRows) != cells tp+fn+must_not \(cellGroundTruth)")
        #expect(spanRows.filter { $0.tier == nil }.count
                == cells.values.reduce(0) { $0 + $1.false_positives },
                "sidecar detection-only rows != cells false_positives")
        let nameSpans = sortedDocs
            .filter { gateDoctypeClass($0.doctype) != nil }
            .reduce(0) { $0 + $1.pii_spans.filter { $0.category == "name" }.count }
        #expect(spanRows.filter { $0.family == "name" && $0.tier != nil }.count == nameSpans,
                "every name ground-truth span must have a sidecar row")
    }
}
