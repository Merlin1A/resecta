import Testing
import Foundation
@testable import RedactionEngine

// S3 detection-quality baseline — standing emitter (NOT a pass/fail gate).
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
// Privacy (ARCH §12.2, contract §Privacy): every emitted record carries
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
    }

    // MARK: - Output JSON shapes (CONTRACT.md File 1 + File 2)

    /// One (category, doctype, bucket) cell. Field names + semantics are pinned
    /// by CONTRACT.md File 1.
    struct BaselineCell: Encodable, Sendable {
        var true_positives: Int = 0
        var false_negatives: Int = 0
        var false_positives: Int = 0
        var adversarial_suppress_total: Int = 0
        var adversarial_suppress_fired: Int = 0
        var suppressed_by_negative_context: Int = 0
    }

    struct BaselineCellsReport: Encodable, Sendable {
        let schema_version: Int
        let generated_by: String
        let g8_corpus_seed: Int
        let cutoff_preset: String
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
        let balanced_cutoffs: [String: Double]
        let absorbing_state_floor: Double
        let rows: [RawScoreRow]
    }

    // MARK: - File 5: per-fire feature dump (B02, plan 04 §5.4)
    //
    // Offset-only, emitted ONLY for the five scored families
    // (account, phone, mrn, ein, itin). The `features` array is produced by the
    // @testable-imported production builder `contextFeatures(...)`, so these are
    // LITERALLY the features the C1 seam will compute (no test re-implementation).
    // Privacy (ARCH §12.2): category / offset / bucket / aggregate / raw-score /
    // doctype only — never match or span TEXT.
    //
    // D-5 split: `family` is the scorer/trainer block key (= wireName(for:),
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
        let feature_order: [String]
        let fires: [FireFeatureRow]
    }

    // MARK: - Category map (ALL 12 G8 categories, incl. phone/email)
    //
    // G8 corpus category strings (G8CorpusIngestionTests.allowedCategories):
    //   ssn, npi, dea, dob, address, account, mrn, name, phone, email,
    //   routingNumber, ein.
    // This is the baseline's OWN map (the gate's gateMapCategory drops
    // phone/email and the detector emits both with no doctype gate).

    static func baselineMapCategory(_ s: String) -> RedactionRegion.PIIKind? {
        switch s {
        case "ssn":           return .ssn
        case "npi":           return .npi
        case "dea":           return .dea
        case "dob":           return .dateOfBirth
        case "address":       return .address
        case "account":       return .account
        case "mrn":           return .medicalRecord
        case "name":          return .name
        case "phone":         return .phone
        case "email":         return .email
        case "routingNumber": return .routingNumber
        case "ein":           return .ein
        default:              return nil
        }
    }

    /// Cell category key = PIICategory.rawValue, lowercased, spaces stripped.
    /// (ssn, name, address, account, ein, npi, dea, phone, email,
    /// routingnumber, medicalrecord, dateofbirth.)
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

    // MARK: - The emit

    @Test("Emit G8 baseline cells + raw scores")
    func emitBaseline() async throws {
        guard let corpus = try Self.loadBaselineCorpus() else {
            print("[S3 baseline] g8_corpus.json not bundled; emit skipped " +
                  "until `make install-assets` runs.")
            return
        }

        let detector = PIIDetector()
        let sortedDocs = corpus.documents.sorted { $0.id < $1.id }

        // cellKey = "<categoryKey>_<doctype>_<bucket>"
        var cells: [String: BaselineCell] = [:]
        var rawRows: [RawScoreRow] = []
        // File 5 (B02): per-fire rows for the five scored families only.
        var fireRows: [FireFeatureRow] = []

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
            for span in doc.pii_spans {
                guard let kind = Self.baselineMapCategory(span.category) else { continue }
                let r = NSRange(location: span.start, length: span.end - span.start)
                allGTByKind[kind, default: []].append(r)
                if span.expected_outcome == "suppress" {
                    decoyGTByKind[kind, default: []].append(r)
                } else {
                    positiveGTByKind[kind, default: []].append(r)
                }
            }

            // Surfaced detections grouped by kind. "Surfaced" = confidence clears
            // the balanced cutoff (nil cutoff → passes W4 unfiltered).
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

                    // File 5 (B02): append a per-fire row ONLY for the five
                    // scored families, keyed by `family` (= wireName). The D-5
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
                            doctype: doctype,
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

                cells[cellKey] = cell
            }
        }

        // Balanced cutoff map for the raw_scores header — one entry per cell
        // category key that has a non-nil balanced cutoff (nil omitted, per
        // CONTRACT File 2).
        var cutoffMap: [String: Double] = [:]
        let allKinds: [RedactionRegion.PIIKind] = [
            .ssn, .name, .address, .account, .ein, .npi, .dea,
            .phone, .email, .routingNumber, .medicalRecord, .dateOfBirth,
        ]
        for kind in allKinds {
            guard let catKey = Self.cellCategoryKey(for: kind) else { continue }
            if let c = balancedCutoff(for: kind) { cutoffMap[catKey] = c }
        }

        let base = Self.baselineOutBase()

        let cellsReport = BaselineCellsReport(
            schema_version: 1,
            generated_by: "G8BaselineHarness.sweepG8Corpus",
            g8_corpus_seed: corpus.seed,
            cutoff_preset: "balanced",
            doc_count: sortedDocs.count,
            cells: cells
        )
        try Self.writeJSON(cellsReport, to: "\(base)_cells.json")

        let rawReport = RawScoresReport(
            schema_version: 1,
            balanced_cutoffs: cutoffMap,
            absorbing_state_floor: DetectionOrchestrator.absorbingStateFloor,
            rows: rawRows
        )
        try Self.writeJSON(rawReport, to: "\(base)_raw_scores.json")

        // File 5 (B02): per-fire feature dump. OWN provenance string; the
        // frozen S3 cells report keeps "G8BaselineHarness.sweepG8Corpus"
        // untouched above. feature_order references the single contract authority.
        let fireReport = FireFeaturesReport(
            schema_version: 1,
            generated_by: "G8BaselineHarness.fireFeatures",
            feature_order: ContextFeatureContract.featureOrder,
            fires: fireRows
        )
        try Self.writeJSON(fireReport, to: "\(base)_fire_features.json")

        print("[S3 baseline] cells → \(base)_cells.json (\(cells.count) cells)")
        print("[S3 baseline] raw_scores → \(base)_raw_scores.json (\(rawRows.count) rows)")
        print("[S3 baseline] fire_features → \(base)_fire_features.json (\(fireRows.count) fires)")

        // Emitter sanity only (this is NOT a pass/fail quality gate).
        #expect(!cells.isEmpty, "no cells emitted — corpus loaded but produced nothing")
        #expect(sortedDocs.count == 1100,
                "G8 doc_count expected 1100; got \(sortedDocs.count)")
    }
}
