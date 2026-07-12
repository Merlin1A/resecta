import Testing
import Foundation
@testable import RedactionEngine

// B04/B05 — Site-A ORCHESTRATOR-PATH twin: the standing emitter that surfaces on
// the DetectionOrchestrator posterior (finalConfidence), NOT the raw
// match.confidence path the baseline harness (G8BaselineHarnessTests) uses.
//
// Why this exists (the B04 result): the C1 learned context scorer
// (ContextScorerWeights.learnedContextLogit) enters detection ONLY at the
// DetectionOrchestrator posterior seam (DetectionOrchestrator.swift:432-446),
// gated by W4 (`finalConfidence < cutoff { continue }`, :455-460). The G8 baseline
// harness drives PIIDetector directly and surfaces on raw match.confidence >=
// balancedCutoff, so it NEVER reaches the scorer — a posterior-level weight change
// is invisible to it (BEFORE == AFTER, byte-identical cells). This twin reproduces
// the orchestrator's posterior + W4 surfacing inline over the same 1,100-doc G8
// corpus, so a weight change IS observable and eval-compare can diff BEFORE (w=0)
// vs AFTER (w=1) at the seam where the scorer actually lives.
//
// Faithful mirror of DetectionOrchestrator.detectPage (the bypassScoring==false
// branch, :413-460), with G8-harness inputs:
//   - SAME detector matches as the baseline (detect(in:doctype:) over the same
//     1,100 docs, same gateDoctypeClass doctype).
//   - posterior = CalibratedScorer().posterior(raw:priorMean:contextLogit:);
//     priorMean = max(PerCategoryPriors().mean(category), absorbingStateFloor)
//     (empty priors ⇒ mean 0.5 ⇒ logit 0 — the W4 first-scan reality, design 03
//     §3.1 default `fresh`); contextLogit =
//     ContextScorerWeights.learnedContextLogit(family:, features: contextFeatures(...)),
//     the SAME builder + doctype the baseline's File-5 dump used.
//   - surfacing: finalConfidence >= balancedCutoff(for: kind) (nil cutoff → pass).
//     balancedCutoff(for: kind) is the SAME value the orchestrator's W4
//     vector.threshold(for: category) resolves to AND the SAME resolution the
//     baseline uses — so at w=0 (contextLogit == 0, priorMean 0.5) finalConfidence
//     == raw and this twin reproduces the frozen baseline cells (the 47b0e270
//     anchor) by construction. The BEFORE/AFTER delta isolates the learned term.
//   - Aggregate the IDENTICAL BaselineCell schema, keyed <cat>_<doctype>_<bucket>.
//
// Scorer source (the BEFORE/AFTER seam): RESECTA_CONTEXT_SCORER_PATH (+ the
// TEST_RUNNER_-prefixed twin xcodebuild forwards into the runner) points at weight
// bytes loaded via ContextScorerWeights.make(from:verifyingHash:nil) — the SHA
// fence is skipped because candidate bytes are not the compiled-in add576680.
// Absent/empty ⇒ the installed bundle (loadFromEngineBundle, the w=0 placeholder):
//   BEFORE  (no env)                                  → installed w=0 → finalConfidence == raw
//   AFTER   (env → context_scorer_candidates.json)    → w=1 → account/phone shift
//
// Tests-only, standing emitter (NOT a pass/fail gate). Emits a DISTINCT output
// base (<base>_orch_cells.json / <base>_orch_raw_scores.json); never touches the
// frozen Site-A baseline files.
//
// Privacy (ARCH §12.2): offset-only — overlap arithmetic on NSRange locations; no
// document text, no PII value, no coordinate is read or emitted. scorer_source is a
// file path / "installed-bundle", never document content.

@Suite("G8 orchestrator-path twin (Site-A posterior, standing emitter)", .serialized)
struct G8OrchestratorHarnessTests {

    // Reuse the baseline suite's wire format + cell schema by reference.
    typealias Corpus = G8BaselineHarnessTests.BaselineG8Corpus
    typealias Cell = G8BaselineHarnessTests.BaselineCell

    struct OrchCellsReport: Encodable, Sendable {
        let schema_version: Int
        let generated_by: String
        let g8_corpus_seed: Int
        let cutoff_preset: String
        let site: String           // "A" — the DetectionOrchestrator posterior gate
        let surfacing_rule: String
        let scorer_source: String  // "installed-bundle" | "override:<path>"
        let doc_count: Int
        let cells: [String: Cell]
    }

    /// The scorer under test. Default = installed bundle (the w=0 placeholder).
    /// Override via RESECTA_CONTEXT_SCORER_PATH (or the TEST_RUNNER_-prefixed twin
    /// xcodebuild forwards) → candidate weight bytes through
    /// make(from:verifyingHash:nil) (skips the add576680 self-check; candidate bytes
    /// are a different SHA by design). Unreadable/empty falls through to the bundle.
    static func loadScorer() -> (ContextScorerWeights, String) {
        let env = ProcessInfo.processInfo.environment
        let path = env["RESECTA_CONTEXT_SCORER_PATH"] ?? env["TEST_RUNNER_RESECTA_CONTEXT_SCORER_PATH"]
        if let p = path, !p.isEmpty, let data = try? Data(contentsOf: URL(fileURLWithPath: p)) {
            return (ContextScorerWeights.make(from: data, verifyingHash: nil), "override:\(p)")
        }
        return (ContextScorerWeights.loadFromEngineBundle(), "installed-bundle")
    }

    @Test("Emit G8 orchestrator-path (Site-A posterior) cells + raw scores")
    func emitOrchestratorBaseline() async throws {
        guard let corpus = try G8BaselineHarnessTests.loadBaselineCorpus() else {
            print("[orch] g8_corpus.json not bundled; orchestrator twin skipped.")
            return
        }

        let detector = PIIDetector()
        let calibrated = CalibratedScorer()
        let (scorer, scorerSource) = Self.loadScorer()
        let priors = PerCategoryPriors()
        let floor = DetectionOrchestrator.absorbingStateFloor
        let sortedDocs = corpus.documents.sorted { $0.id < $1.id }

        print("[orch] scorer source: \(scorerSource)")

        var cells: [String: Cell] = [:]
        var rawRows: [G8BaselineHarnessTests.RawScoreRow] = []

        for doc in sortedDocs {
            guard let doctype = gateDoctypeClass(doc.doctype) else { continue }
            let bucket = doc.demographic_bucket

            let matches = await detector.detect(in: doc.text, doctype: doctype)

            // Ground truth grouped by kind, split by expected_outcome (baseline rule:
            // suppress → decoy; everything else → positive; union = allGT).
            var positiveGTByKind: [RedactionRegion.PIIKind: [NSRange]] = [:]
            var decoyGTByKind: [RedactionRegion.PIIKind: [NSRange]] = [:]
            var allGTByKind: [RedactionRegion.PIIKind: [NSRange]] = [:]
            for span in doc.pii_spans {
                guard let kind = G8BaselineHarnessTests.baselineMapCategory(span.category) else { continue }
                let r = NSRange(location: span.start, length: span.end - span.start)
                allGTByKind[kind, default: []].append(r)
                if span.expected_outcome == "suppress" {
                    decoyGTByKind[kind, default: []].append(r)
                } else {
                    positiveGTByKind[kind, default: []].append(r)
                }
            }

            // Orchestrator-path surfacing: posterior + W4, replicating
            // DetectionOrchestrator.swift:413-460 (bypassScoring == false branch).
            var surfacedByKind: [RedactionRegion.PIIKind: [NSRange]] = [:]
            for match in matches {
                let finalConfidence: Double
                if let category = match.category {
                    let priorMean = max(priors.mean(category), floor)
                    let contextLogit = scorer.learnedContextLogit(
                        family: PresetThresholdVector.wireName(for: category) ?? "",
                        features: contextFeatures(
                            match: match,
                            doctype: doctype,
                            effectiveDoctype: doctype,
                            pageText: doc.text
                        )
                    )
                    finalConfidence = calibrated.posterior(
                        raw: match.confidence,
                        priorMean: priorMean,
                        contextLogit: contextLogit
                    )
                } else {
                    finalConfidence = match.confidence
                }

                let cutoff = balancedCutoff(for: match.kind)
                let surfaced = cutoff.map { finalConfidence >= $0 } ?? true

                // Raw scores: EVERY match (pre-cutoff), tagged by overlap class.
                // The twin carries the POST-posterior score in `raw` (the value the
                // W4 cutoff applied to) — distinct from the baseline's raw
                // match.confidence; the file lives at a distinct base so the two
                // never collide.
                if let catKey = G8BaselineHarnessTests.cellCategoryKey(for: match.kind) {
                    let gtClass: String
                    let decoys = decoyGTByKind[match.kind] ?? []
                    let positives = positiveGTByKind[match.kind] ?? []
                    if decoys.contains(where: { G8BaselineHarnessTests.rangesOverlap(match.range, $0) }) {
                        gtClass = "suppress"
                    } else if positives.contains(where: { G8BaselineHarnessTests.rangesOverlap(match.range, $0) }) {
                        gtClass = "positive"
                    } else {
                        gtClass = "none"
                    }
                    rawRows.append(G8BaselineHarnessTests.RawScoreRow(
                        category: catKey,
                        doctype: doc.doctype,
                        bucket: bucket,
                        raw: finalConfidence,
                        gt_class: gtClass
                    ))
                }

                if surfaced {
                    surfacedByKind[match.kind, default: []].append(match.range)
                }
            }

            // Score each kind present in GT or surfaced detections (baseline
            // aggregation, verbatim — same TP/FN, adversarial, generic-FP rules).
            var kinds = Set(allGTByKind.keys)
            kinds.formUnion(surfacedByKind.keys)

            for kind in kinds {
                guard let catKey = G8BaselineHarnessTests.cellCategoryKey(for: kind) else { continue }
                let cellKey = "\(catKey)_\(doc.doctype)_\(bucket)"
                var cell = cells[cellKey] ?? Cell()

                let positives = positiveGTByKind[kind] ?? []
                let decoys = decoyGTByKind[kind] ?? []
                let allGT = allGTByKind[kind] ?? []
                let surfaced = surfacedByKind[kind] ?? []

                for gt in positives {
                    let covered = surfaced.contains { G8BaselineHarnessTests.rangesOverlap($0, gt) }
                    if covered { cell.true_positives += 1 } else { cell.false_negatives += 1 }
                }

                cell.adversarial_suppress_total += decoys.count
                for decoy in decoys {
                    let fired = surfaced.contains { G8BaselineHarnessTests.rangesOverlap($0, decoy) }
                    if fired { cell.adversarial_suppress_fired += 1 }
                }

                for det in surfaced {
                    let overlapsAnyGT = allGT.contains { G8BaselineHarnessTests.rangesOverlap(det, $0) }
                    if !overlapsAnyGT { cell.false_positives += 1 }
                }

                cells[cellKey] = cell
            }
        }

        // Balanced cutoff map for the raw_scores header (same source as baseline).
        var cutoffMap: [String: Double] = [:]
        let allKinds: [RedactionRegion.PIIKind] = [
            .ssn, .name, .address, .account, .ein, .npi, .dea,
            .phone, .email, .routingNumber, .medicalRecord, .dateOfBirth,
        ]
        for kind in allKinds {
            guard let catKey = G8BaselineHarnessTests.cellCategoryKey(for: kind) else { continue }
            if let c = balancedCutoff(for: kind) { cutoffMap[catKey] = c }
        }

        let base = G8BaselineHarnessTests.baselineOutBase()

        let cellsReport = OrchCellsReport(
            schema_version: 1,
            generated_by: "G8OrchestratorHarness.sweepG8Corpus",
            g8_corpus_seed: corpus.seed,
            cutoff_preset: "balanced",
            site: "A",
            surfacing_rule: "finalConfidence >= balancedCutoff (posterior + W4)",
            scorer_source: scorerSource,
            doc_count: sortedDocs.count,
            cells: cells
        )
        try G8BaselineHarnessTests.writeJSON(cellsReport, to: "\(base)_orch_cells.json")

        let rawReport = G8BaselineHarnessTests.RawScoresReport(
            schema_version: 1,
            balanced_cutoffs: cutoffMap,
            absorbing_state_floor: floor,
            rows: rawRows
        )
        try G8BaselineHarnessTests.writeJSON(rawReport, to: "\(base)_orch_raw_scores.json")

        print("[orch] cells → \(base)_orch_cells.json (\(cells.count) cells, scorer=\(scorerSource))")
        print("[orch] raw_scores → \(base)_orch_raw_scores.json (\(rawRows.count) rows)")

        #expect(!cells.isEmpty, "no cells emitted — corpus loaded but produced nothing")
        #expect(sortedDocs.count == 1100, "G8 doc_count expected 1100; got \(sortedDocs.count)")
    }
}
