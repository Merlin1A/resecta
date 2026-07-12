import Testing
import Foundation
@testable import RedactionEngine

// B02 — Site-B (Search-and-Redact) BEFORE twin for the M10 divergence number.
// B06 — extended into a BEFORE/AFTER leg now that the search path composes the
// posterior (see `searchParitySiteBBeforeAfter` below).
//
// Plan 04 §5.5 / D-13: Site B (DocumentSearcher) gated RAW match.confidence via
// `ThresholdFilter.applying(thresholdVector:)` (DocumentSearcher.swift:1146 /
// :1338 → ThresholdFilter.swift:28-44) with NO posterior, NO prior, NO learned
// term. Site A (DetectionOrchestrator.swift:432-446) composes the posterior
// before its cutoff. B02 measured the C1 scorer reaching none of the five
// families at Site B (M10 = 0 per family — the scorer's value is at the
// posterior, not at the raw gate). B06 routes the five scored families at Site B
// through that SAME composition (DocumentSearcher.composedSurvivors), so Site B
// surfaces on the composed posterior rather than the raw gate. The search path is
// doctype-blind (no classifier output), so the feature builder is fed `.generic`:
// parity with Site A is exact for generic-doctype documents and for `account`, and
// approximate for `phone` (its trained doctype one-hots are non-zero, so a phone
// match on a court/medical/foia document composes a different posterior at Site B).
//
// Methodology (the faithful mirror, plan §5.5 step 1):
//   - SAME detector matches as the Site-A baseline (detect(in:doctype:) over the
//     same 1,100 G8 docs, same gateDoctypeClass doctype).
//   - Site-B surfacing: route those matches through
//     `[PIIMatch].applying(thresholdVector:)` (the EXACT Site-B gate call) using
//     the SAME balanced PresetThresholdVector the baseline harness reads.
//   - Aggregate the IDENTICAL BaselineCell schema, keyed <cat>_<doctype>_<bucket>.
//   - Site-A surfacing (for the delta): match.confidence >= balancedCutoff —
//     the existing baseline `surfaced` rule.
//   - M10 = per-family (Site-B FP − Site-A FP) for {account, phone, mrn, ein, itin}.
//
// `searchG8Corpus` is BEFORE-only and Tests-only. It emits a DISTINCT output base
// (<base>_siteb_cells.json) and prints the per-family M10 deltas. It does NOT
// touch the frozen Site-A cells/raw_scores files.
//
// Privacy (ARCH §12.2): offset-only — overlap arithmetic on NSRange locations;
// no document text, no PII value, no coordinate is read or emitted.

@Suite("G8 Site-B parity twin (M10, standing emitter)", .serialized)
struct G8SearchParityHarnessTests {

    // Reuse the baseline suite's wire format + cell schema by reference.
    typealias Corpus = G8BaselineHarnessTests.BaselineG8Corpus
    typealias Cell = G8BaselineHarnessTests.BaselineCell

    struct SiteBCellsReport: Encodable, Sendable {
        let schema_version: Int
        let generated_by: String
        let g8_corpus_seed: Int
        let cutoff_preset: String
        let site: String          // "B" — the Search-and-Redact gate
        let gate_mechanism: String
        let doc_count: Int
        let cells: [String: Cell]
    }

    /// The balanced PresetThresholdVector the Site-B gate uses — the same source
    /// the baseline harness reads (PresetThresholdBundle.loadFromEngineBundle()).
    static func balancedVector() -> PresetThresholdVector? {
        PresetThresholdBundle.loadFromEngineBundle().presets[.balanced]
    }

    @Test("Emit Site-B BEFORE cells + the M10 per-family FP divergence")
    func searchG8Corpus() async throws {
        guard let corpus = try G8BaselineHarnessTests.loadBaselineCorpus() else {
            print("[M10] g8_corpus.json not bundled; Site-B twin skipped.")
            return
        }
        guard let vector = Self.balancedVector() else {
            print("[M10] balanced preset vector unavailable; Site-B twin skipped.")
            return
        }

        let detector = PIIDetector()
        let sortedDocs = corpus.documents.sorted { $0.id < $1.id }

        var siteBCells: [String: Cell] = [:]
        // Per-family false-positive tallies for the M10 delta.
        var siteAFP: [String: Int] = [:]
        var siteBFP: [String: Int] = [:]
        let families = ContextFeatureContract.scoredFamilies

        for doc in sortedDocs {
            guard let doctype = gateDoctypeClass(doc.doctype) else { continue }
            let bucket = doc.demographic_bucket

            let matches = await detector.detect(in: doc.text, doctype: doctype)

            // Ground truth grouped by kind (same split as the baseline harness:
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

            // Site-B surfacing: the EXACT search-path gate over the same matches.
            // ThresholdFilter passes a match through when its category has no
            // wire-name OR the vector has no entry; otherwise raw >= cutoff.
            let siteBSurvivors = matches.applying(thresholdVector: vector)
            var siteBByKind: [RedactionRegion.PIIKind: [NSRange]] = [:]
            for m in siteBSurvivors {
                siteBByKind[m.kind, default: []].append(m.range)
            }

            // Site-A surfacing: the baseline harness rule (raw vs balancedCutoff;
            // nil cutoff → passes unfiltered). Recomputed here only for the M10
            // FP tally so both sites are measured from the SAME matches.
            var siteAByKind: [RedactionRegion.PIIKind: [NSRange]] = [:]
            for m in matches {
                let cutoff = balancedCutoff(for: m.kind)
                let surfaced = cutoff.map { m.confidence >= $0 } ?? true
                if surfaced { siteAByKind[m.kind, default: []].append(m.range) }
            }

            var kinds = Set(allGTByKind.keys)
            kinds.formUnion(siteBByKind.keys)
            kinds.formUnion(siteAByKind.keys)

            for kind in kinds {
                guard let catKey = G8BaselineHarnessTests.cellCategoryKey(for: kind) else { continue }
                let cellKey = "\(catKey)_\(doc.doctype)_\(bucket)"
                var cell = siteBCells[cellKey] ?? Cell()

                let positives = positiveGTByKind[kind] ?? []
                let decoys = decoyGTByKind[kind] ?? []
                let allGT = allGTByKind[kind] ?? []
                let siteB = siteBByKind[kind] ?? []

                // TP / FN against Site-B survivors.
                for gt in positives {
                    let covered = siteB.contains { G8BaselineHarnessTests.rangesOverlap($0, gt) }
                    if covered { cell.true_positives += 1 } else { cell.false_negatives += 1 }
                }

                // Adversarial suppression (decoy GT fired at Site B).
                cell.adversarial_suppress_total += decoys.count
                for decoy in decoys {
                    let fired = siteB.contains { G8BaselineHarnessTests.rangesOverlap($0, decoy) }
                    if fired { cell.adversarial_suppress_fired += 1 }
                }

                // Generic FP: a Site-B survivor overlapping NO GT span (any label).
                for det in siteB {
                    let overlapsAnyGT = allGT.contains { G8BaselineHarnessTests.rangesOverlap(det, $0) }
                    if !overlapsAnyGT { cell.false_positives += 1 }
                }
                siteBCells[cellKey] = cell

                // M10 tally: per-family Site-A / Site-B FP for the five families.
                if let family = PIICategory(piiKind: kind)
                    .flatMap({ PresetThresholdVector.wireName(for: $0) }),
                    families.contains(family) {
                    let siteA = siteAByKind[kind] ?? []
                    for det in siteB {
                        if !allGT.contains(where: { G8BaselineHarnessTests.rangesOverlap(det, $0) }) {
                            siteBFP[family, default: 0] += 1
                        }
                    }
                    for det in siteA {
                        if !allGT.contains(where: { G8BaselineHarnessTests.rangesOverlap(det, $0) }) {
                            siteAFP[family, default: 0] += 1
                        }
                    }
                }
            }
        }

        let base = G8BaselineHarnessTests.baselineOutBase()
        let report = SiteBCellsReport(
            schema_version: 1,
            generated_by: "G8SearchParityHarness.searchG8Corpus",
            g8_corpus_seed: corpus.seed,
            cutoff_preset: "balanced",
            site: "B",
            gate_mechanism: "ThresholdFilter.applying(thresholdVector:)",
            doc_count: sortedDocs.count,
            cells: siteBCells
        )
        try G8BaselineHarnessTests.writeJSON(report, to: "\(base)_siteb_cells.json")

        print("[M10] Site-B cells → \(base)_siteb_cells.json (\(siteBCells.count) cells)")
        print("[M10] per-family FP divergence (Site-B − Site-A), five scored families:")
        for family in families.sorted() {
            let a = siteAFP[family, default: 0]
            let b = siteBFP[family, default: 0]
            print("[M10]   \(family): siteA_FP=\(a) siteB_FP=\(b) delta=\(b - a)")
        }

        #expect(!siteBCells.isEmpty, "no Site-B cells emitted — corpus loaded but produced nothing")
        #expect(sortedDocs.count == 1100,
                "G8 doc_count expected 1100; got \(sortedDocs.count)")
    }

    // MARK: - B06 BEFORE/AFTER leg (Site-B parity)

    /// Per-family Site-B tallies for the predicate + the C3 Search recall floor.
    private struct FamilyTally {
        var falsePositives = 0
        var truePositives = 0   // positive GT covered by a surviving detection
        var falseNegatives = 0  // positive GT not covered
        var recall: Double { truePositives + falseNegatives == 0 ? 1.0 : Double(truePositives) / Double(truePositives + falseNegatives) }
    }

    /// One BEFORE/AFTER pass over the G8 corpus at Site B, parameterised by how a
    /// scored family is gated:
    ///   - `.raw`       → `applying(thresholdVector:)` (today's Site-B gate; the
    ///     literal BEFORE).
    ///   - `.identity`  → the production `composedSurvivors` core driven with
    ///     `ContextScorerWeights.identity` (the w=0 control — composed == raw).
    ///   - `.installed` → the same core with the installed (B05) calibrated
    ///     scorer (the AFTER).
    /// In every variant, NON-scored families flow through `applying(...)`
    /// untouched, so the recombined survivor SET differs only by the scored
    /// families. Returns the aggregated cells plus the per-family tally.
    private enum SiteBVariant { case raw, identity, installed }

    private func runSiteB(
        _ variant: SiteBVariant,
        sortedDocs: [G8BaselineHarnessTests.BaselineG8Document],
        vector: PresetThresholdVector,
        installedScorer: ContextScorerWeights,
        zeroedFamilies: Set<String>
    ) async -> (cells: [String: Cell], byFamily: [String: FamilyTally]) {
        let detector = PIIDetector()
        var cells: [String: Cell] = [:]
        var byFamily: [String: FamilyTally] = [:]
        let families = ContextFeatureContract.scoredFamilies

        for doc in sortedDocs {
            guard let doctype = gateDoctypeClass(doc.doctype) else { continue }
            let bucket = doc.demographic_bucket
            let matches = await detector.detect(in: doc.text, doctype: doctype)

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

            // Site-B survivors under the requested variant: partition, gate, recombine.
            // `zeroedFamilies` are forced back onto the raw path (the per-family
            // C3 kill switch) regardless of variant.
            let (scoredAll, rest) = matches.partitionedByScoredFamily()
            let scored: [PIIDetector.PIIMatch]
            switch variant {
            case .raw:
                scored = scoredAll.applying(thresholdVector: vector)
            case .identity, .installed:
                let scorer: ContextScorerWeights = (variant == .identity) ? .identity : installedScorer
                // Split off any C3-zeroed family → raw path; the rest → composed.
                var composedInput: [PIIDetector.PIIMatch] = []
                var rawInput: [PIIDetector.PIIMatch] = []
                for m in scoredAll {
                    let fam = m.category.flatMap { PresetThresholdVector.wireName(for: $0) } ?? ""
                    if zeroedFamilies.contains(fam) { rawInput.append(m) } else { composedInput.append(m) }
                }
                scored = DocumentSearcher._testComposeSiteB(
                    composedInput, pageText: doc.text, thresholdVector: vector, scorer: scorer
                ) + rawInput.applying(thresholdVector: vector)
            }
            let survivors = rest.applying(thresholdVector: vector) + scored

            var byKind: [RedactionRegion.PIIKind: [NSRange]] = [:]
            for m in survivors { byKind[m.kind, default: []].append(m.range) }

            var kinds = Set(allGTByKind.keys)
            kinds.formUnion(byKind.keys)
            for kind in kinds {
                guard let catKey = G8BaselineHarnessTests.cellCategoryKey(for: kind) else { continue }
                let cellKey = "\(catKey)_\(doc.doctype)_\(bucket)"
                var cell = cells[cellKey] ?? Cell()

                let positives = positiveGTByKind[kind] ?? []
                let decoys = decoyGTByKind[kind] ?? []
                let allGT = allGTByKind[kind] ?? []
                let surfaced = byKind[kind] ?? []

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

                // Per-family tally for the five scored families.
                if let family = PIICategory(piiKind: kind).flatMap({ PresetThresholdVector.wireName(for: $0) }),
                   families.contains(family) {
                    var tally = byFamily[family] ?? FamilyTally()
                    for det in surfaced where !allGT.contains(where: { G8BaselineHarnessTests.rangesOverlap(det, $0) }) {
                        tally.falsePositives += 1
                    }
                    for gt in positives {
                        let covered = surfaced.contains { G8BaselineHarnessTests.rangesOverlap($0, gt) }
                        if covered { tally.truePositives += 1 } else { tally.falseNegatives += 1 }
                    }
                    byFamily[family] = tally
                }
            }
        }
        return (cells, byFamily)
    }

    /// Canonical encoding of a cells dict (the same encoder + key sort the
    /// emitter uses) so the identity-control vs raw comparison is a byte cmp.
    private func encodeCells(
        _ cells: [String: Cell], generatedBy: String, seed: Int, gate: String
    ) throws -> Data {
        let report = SiteBCellsReport(
            schema_version: 1,
            generated_by: generatedBy,
            g8_corpus_seed: seed,
            cutoff_preset: "balanced",
            site: "B",
            gate_mechanism: gate,
            doc_count: 1100,
            cells: cells
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }

    /// B06 — Site-B BEFORE/AFTER. Drives the PRODUCTION composition
    /// (`DocumentSearcher.composedSurvivors`, via the observation-only
    /// `_testComposeSiteB` seam) over the same 1,100-doc G8 corpus:
    ///
    ///   1. w=0 IDENTITY CONTROL — compose the scored families with
    ///      `ContextScorerWeights.identity`. At identity, empty priors give
    ///      priorMean 0.5 (logit 0) and contextLogit 0, so the posterior == raw
    ///      and the composed Site-B gate MUST reproduce today's raw-gated Site-B
    ///      cells BYTE-FOR-BYTE. This is the literal Site-B BEFORE and the
    ///      non-destructive proof the rewiring is correct.
    ///   2. AFTER — compose with the installed (B05) calibrated scorer; emit
    ///      `<base>_siteb_cells_after.json` and the per-family FP BEFORE→AFTER +
    ///      the Search recall.
    ///   3. C3 RECALL FLOOR at Search — recomputed independently (Search has no
    ///      second pass, so the over-suppression risk is higher). Any family
    ///      whose AFTER Search recall regresses beyond ε=1pt is ZEROED at Site B
    ///      (routed raw) and the AFTER is re-derived; the report names it.
    ///
    /// Tests-only, additive; never touches the frozen Site-A baseline files.
    @Test("Site-B BEFORE/AFTER: w=0 identity control + composed AFTER + C3 floor")
    func searchParitySiteBBeforeAfter() async throws {
        guard let corpus = try G8BaselineHarnessTests.loadBaselineCorpus() else {
            print("[B06] g8_corpus.json not bundled; Site-B BEFORE/AFTER skipped.")
            return
        }
        guard let vector = Self.balancedVector() else {
            print("[B06] balanced preset vector unavailable; skipped.")
            return
        }
        let sortedDocs = corpus.documents.sorted { $0.id < $1.id }
        let installed = ContextScorerWeights.loadFromEngineBundle()
        let families = ContextFeatureContract.scoredFamilies.sorted()
        let epsilon = 0.01  // §3 recall floor ε = 1pt.

        // (1) Raw BEFORE + identity control.
        let (rawCells, rawByFamily) = await runSiteB(
            .raw, sortedDocs: sortedDocs, vector: vector,
            installedScorer: installed, zeroedFamilies: []
        )
        let (identityCells, _) = await runSiteB(
            .identity, sortedDocs: sortedDocs, vector: vector,
            installedScorer: installed, zeroedFamilies: []
        )

        let rawData = try encodeCells(
            rawCells, generatedBy: "G8SearchParityHarness.searchG8Corpus",
            seed: corpus.seed, gate: "ThresholdFilter.applying(thresholdVector:)"
        )
        let identityData = try encodeCells(
            identityCells, generatedBy: "G8SearchParityHarness.searchG8Corpus",
            seed: corpus.seed, gate: "ThresholdFilter.applying(thresholdVector:)"
        )

        let base = G8BaselineHarnessTests.baselineOutBase()
        try identityData.write(to: URL(fileURLWithPath: "\(base)_siteb_cells_identity.json"), options: .atomic)
        print("[B06] identity-control cells → \(base)_siteb_cells_identity.json")

        let identityMatchesRaw = identityData == rawData
        print("[B06] w=0 IDENTITY CONTROL (composed-at-identity == raw Site-B cells): " +
              (identityMatchesRaw ? "MATCH (byte-for-byte)" : "MISMATCH"))
        #expect(identityMatchesRaw,
                "Site-B w=0 identity control must reproduce the raw-gated Site-B cells byte-for-byte")

        // (2) AFTER (no family zeroed yet).
        var (afterCells, afterByFamily) = await runSiteB(
            .installed, sortedDocs: sortedDocs, vector: vector,
            installedScorer: installed, zeroedFamilies: []
        )

        // (3) C3 recall floor at Search — zero any family that regresses recall.
        var zeroed: Set<String> = []
        for family in families {
            let before = rawByFamily[family]?.recall ?? 1.0
            let after = afterByFamily[family]?.recall ?? 1.0
            if after < before - epsilon {
                zeroed.insert(family)
                print("[B06] C3 FLOOR: family \(family) Search recall \(before) → \(after) " +
                      "regresses beyond ε=\(epsilon); ZEROING at Site B (route raw).")
            }
        }
        if !zeroed.isEmpty {
            let rederived = await runSiteB(
                .installed, sortedDocs: sortedDocs, vector: vector,
                installedScorer: installed, zeroedFamilies: zeroed
            )
            afterCells = rederived.cells
            afterByFamily = rederived.byFamily
            // Re-confirm each zeroed family now reproduces the raw BEFORE FP.
            for family in zeroed.sorted() {
                let rawFP = rawByFamily[family]?.falsePositives ?? 0
                let zFP = afterByFamily[family]?.falsePositives ?? 0
                print("[B06]   zeroed \(family): raw_FP=\(rawFP) zeroed_AFTER_FP=\(zFP) " +
                      (rawFP == zFP ? "(reproduces BEFORE)" : "(DOES NOT reproduce BEFORE)"))
                #expect(rawFP == zFP, "zeroed family \(family) must reproduce the raw Site-B FP")
            }
        } else {
            print("[B06] C3 FLOOR: no family regressed Search recall beyond ε=\(epsilon); none zeroed.")
        }

        // Emit the AFTER cells.
        let afterReport = SiteBCellsReport(
            schema_version: 1,
            generated_by: "G8SearchParityHarness.searchParitySiteBBeforeAfter",
            g8_corpus_seed: corpus.seed,
            cutoff_preset: "balanced",
            site: "B",
            gate_mechanism: "DocumentSearcher.composedSurvivors (posterior + learnedContextLogit) + W4",
            doc_count: sortedDocs.count,
            cells: afterCells
        )
        try G8BaselineHarnessTests.writeJSON(afterReport, to: "\(base)_siteb_cells_after.json")
        print("[B06] AFTER cells → \(base)_siteb_cells_after.json (\(afterCells.count) cells)")

        // Per-family FP BEFORE→AFTER + the recomputed Search recall.
        print("[B06] per-family Site-B FP BEFORE(raw) → AFTER(composed) + Search recall:")
        for family in families {
            let b = rawByFamily[family] ?? FamilyTally()
            let a = afterByFamily[family] ?? FamilyTally()
            let zeroedTag = zeroed.contains(family) ? " [ZEROED@SiteB]" : ""
            print(String(
                format: "[B06]   %@: FP %d → %d (cut %d) · recall %.4f → %.4f%@",
                family, b.falsePositives, a.falsePositives,
                b.falsePositives - a.falsePositives, b.recall, a.recall, zeroedTag
            ))
        }

        #expect(!afterCells.isEmpty, "no AFTER cells emitted")
        #expect(sortedDocs.count == 1100, "G8 doc_count expected 1100; got \(sortedDocs.count)")
    }
}
