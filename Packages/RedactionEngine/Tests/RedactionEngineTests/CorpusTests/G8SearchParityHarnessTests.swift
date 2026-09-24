import Testing
import Foundation
@testable import RedactionEngine

// Site-B (Search-and-Redact) BEFORE twin for the per-family divergence
// measurement, extended into a BEFORE/AFTER leg now that the search path
// composes the posterior (see `searchParitySiteBBeforeAfter` below).
//
// Site B (DocumentSearcher) gates RAW match.confidence via
// `ThresholdFilter.applyingCountingDrops(thresholdVector:)` (DocumentSearcher.swift:1146 /
// :1338 → ThresholdFilter.swift:28-44) with NO posterior, NO prior, NO learned
// term. Site A (DetectionOrchestrator.swift:432-446) composes the posterior
// before its cutoff. Measurement showed the context scorer reaching none of the five
// families at Site B (the divergence is 0 per family — the scorer's value is at the
// posterior, not at the raw gate). This suite routes the five scored families at Site B
// through that SAME composition (DocumentSearcher.composedSurvivors), so Site B
// surfaces on the composed posterior rather than the raw gate. The search path is
// doctype-blind (no classifier output), so the feature builder is fed `.generic`:
// parity with Site A is exact for generic-doctype documents and for `account`, and
// approximate for `phone` (its trained doctype one-hots are non-zero, so a phone
// match on a court/medical/foia document composes a different posterior at Site B).
//
// Methodology (the faithful mirror):
//   - SAME detector matches as the Site-A baseline (detect(in:doctype:) over the
//     same 1,100 G8 docs, same gateDoctypeClass doctype).
//   - Site-B surfacing: route those matches through
//     `[PIIMatch].applyingCountingDrops(thresholdVector:)` (the EXACT Site-B gate call) using
//     the SAME balanced PresetThresholdVector the baseline harness reads.
//   - Aggregate the IDENTICAL BaselineCell schema, keyed <cat>_<doctype>_<bucket>.
//   - Site-A surfacing (for the delta): match.confidence >= balancedCutoff —
//     the existing baseline `surfaced` rule.
//   - The divergence is per-family (Site-B FP − Site-A FP) for {account, phone, mrn, ein, itin}.
//
// Offset-only: overlap arithmetic on NSRange locations;
// no document text, no PII value, no coordinate is read or emitted.

@Suite("G8 Site-B parity twin (standing emitter)", .serialized)
struct G8SearchParityHarnessTests {

    // Reuse the baseline suite's cell schema by reference.
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

    // MARK: - BEFORE/AFTER leg (Site-B parity)

    /// Per-family Site-B tallies for the predicate + the Search recall floor.
    private struct FamilyTally {
        var falsePositives = 0
        var truePositives = 0   // positive GT covered by a surviving detection
        var falseNegatives = 0  // positive GT not covered
        var recall: Double { truePositives + falseNegatives == 0 ? 1.0 : Double(truePositives) / Double(truePositives + falseNegatives) }
    }

    /// One BEFORE/AFTER pass over the G8 corpus at Site B, parameterised by how a
    /// scored family is gated:
    ///   - `.raw`       → `applyingCountingDrops(thresholdVector:)` (today's
    ///     Site-B gate; the literal BEFORE).
    ///   - `.identity`  → the production `composedSurvivors` core driven with
    ///     `ContextScorerWeights.identity` (the w=0 control — composed == raw).
    ///   - `.installed` → the same core with the installed calibrated
    ///     scorer (the AFTER).
    /// In every variant, NON-scored families flow through
    /// `applyingCountingDrops(...)` untouched, so the recombined survivor SET differs only by the scored
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
        let families = ContextFeatureContract.scoredFamilyWireNames

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
            // recall kill switch) regardless of variant.
            let (scoredAll, rest) = matches.partitionedByScoredFamily()
            let scored: [PIIDetector.PIIMatch]
            switch variant {
            case .raw:
                scored = scoredAll.applyingCountingDrops(thresholdVector: vector).survivors
            case .identity, .installed:
                let scorer: ContextScorerWeights = (variant == .identity) ? .identity : installedScorer
                // Split off any recall-zeroed family → raw path; the rest → composed.
                var composedInput: [PIIDetector.PIIMatch] = []
                var rawInput: [PIIDetector.PIIMatch] = []
                for m in scoredAll {
                    let fam = m.category.flatMap { PresetThresholdVector.wireName(for: $0) } ?? ""
                    if zeroedFamilies.contains(fam) { rawInput.append(m) } else { composedInput.append(m) }
                }
                scored = DocumentSearcher._testComposeSiteB(
                    composedInput, pageText: doc.text, thresholdVector: vector, scorer: scorer
                ) + rawInput.applyingCountingDrops(thresholdVector: vector).survivors
            }
            let survivors = rest.applyingCountingDrops(thresholdVector: vector).survivors + scored

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

    /// Site-B BEFORE/AFTER. Drives the PRODUCTION composition
    /// (`DocumentSearcher.composedSurvivors`, via the observation-only
    /// `_testComposeSiteB` seam) over the same 1,100-doc G8 corpus:
    ///
    ///   1. w=0 IDENTITY CONTROL — compose the scored families with
    ///      `ContextScorerWeights.identity`. At identity, empty priors give
    ///      priorMean 0.5 (logit 0) and contextLogit 0, so the posterior == raw
    ///      and the composed Site-B gate MUST reproduce today's raw-gated Site-B
    ///      cells BYTE-FOR-BYTE. This is the literal Site-B BEFORE and the
    ///      non-destructive proof the rewiring is correct.
    ///   2. AFTER — compose with the installed calibrated scorer; emit
    ///      `<base>_siteb_cells_after.json` and the per-family FP BEFORE→AFTER +
    ///      the Search recall.
    ///   3. RECALL FLOOR at Search — recomputed independently (Search has no
    ///      second pass, so the over-suppression risk is higher). Any family
    ///      whose AFTER Search recall regresses beyond ε=1pt is ZEROED at Site B
    ///      (routed raw) and the AFTER is re-derived; the report names it.
    ///
    /// Tests-only, additive; never touches the frozen Site-A baseline files.
    @Test("Site-B BEFORE/AFTER: w=0 identity control + composed AFTER + recall floor")
    func searchParitySiteBBeforeAfter() async throws {
        let corpus = try #require(try G8BaselineHarnessTests.loadBaselineCorpus(), "g8_corpus.json not bundled")
        let vector = try #require(Self.balancedVector(), "balanced preset vector not bundled")
        let sortedDocs = corpus.documents.sorted { $0.id < $1.id }
        let installed = ContextScorerWeights.loadFromEngineBundle()
        let families = ContextFeatureContract.scoredFamilyWireNames.sorted()
        let epsilon = 0.01  // Recall floor ε = 1pt.

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
            seed: corpus.seed, gate: "ThresholdFilter.applyingCountingDrops(thresholdVector:)"
        )
        let identityData = try encodeCells(
            identityCells, generatedBy: "G8SearchParityHarness.searchG8Corpus",
            seed: corpus.seed, gate: "ThresholdFilter.applyingCountingDrops(thresholdVector:)"
        )

        let base = G8BaselineHarnessTests.baselineOutBase()
        try identityData.write(to: URL(fileURLWithPath: "\(base)_siteb_cells_identity.json"), options: .atomic)
        print("[site-b-before-after] identity-control cells → \(base)_siteb_cells_identity.json")

        let identityMatchesRaw = identityData == rawData
        print("[site-b-before-after] w=0 IDENTITY CONTROL (composed-at-identity == raw Site-B cells): " +
              (identityMatchesRaw ? "MATCH (byte-for-byte)" : "MISMATCH"))
        #expect(identityMatchesRaw,
                "Site-B w=0 identity control must reproduce the raw-gated Site-B cells byte-for-byte")

        // (2) AFTER (no family zeroed yet).
        var (afterCells, afterByFamily) = await runSiteB(
            .installed, sortedDocs: sortedDocs, vector: vector,
            installedScorer: installed, zeroedFamilies: []
        )

        // (3) Recall floor at Search — zero any family that regresses recall.
        var zeroed: Set<String> = []
        for family in families {
            let before = rawByFamily[family]?.recall ?? 1.0
            let after = afterByFamily[family]?.recall ?? 1.0
            if after < before - epsilon {
                zeroed.insert(family)
                print("[site-b-before-after] RECALL FLOOR: family \(family) Search recall \(before) → \(after) " +
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
                print("[site-b-before-after]   zeroed \(family): raw_FP=\(rawFP) zeroed_AFTER_FP=\(zFP) " +
                      (rawFP == zFP ? "(reproduces BEFORE)" : "(DOES NOT reproduce BEFORE)"))
                #expect(rawFP == zFP, "zeroed family \(family) must reproduce the raw Site-B FP")
            }
        } else {
            print("[site-b-before-after] RECALL FLOOR: no family regressed Search recall beyond ε=\(epsilon); none zeroed.")
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
        print("[site-b-before-after] AFTER cells → \(base)_siteb_cells_after.json (\(afterCells.count) cells)")

        // Per-family FP BEFORE→AFTER + the recomputed Search recall.
        print("[site-b-before-after] per-family Site-B FP BEFORE(raw) → AFTER(composed) + Search recall:")
        for family in families {
            let b = rawByFamily[family] ?? FamilyTally()
            let a = afterByFamily[family] ?? FamilyTally()
            let zeroedTag = zeroed.contains(family) ? " [ZEROED@SiteB]" : ""
            print(String(
                format: "[site-b-before-after]   %@: FP %d → %d (cut %d) · recall %.4f → %.4f%@",
                family, b.falsePositives, a.falsePositives,
                b.falsePositives - a.falsePositives, b.recall, a.recall, zeroedTag
            ))
        }

        #expect(!afterCells.isEmpty, "no AFTER cells emitted")
        #expect(sortedDocs.count == 1100, "G8 doc_count expected 1100; got \(sortedDocs.count)")
    }

    // MARK: - H1.1 — the Site-B G8 baseline trio (1.2 measurement program)
    //
    // D12-24: Site B (Search-and-Redact) IS the product's detection surface, so
    // the 1.2 baseline measures the PRODUCT semantics end to end:
    //   - detection is doctype-blind (`detect(in:)`, doctype nil — the search
    //     path carries no classifier output), unlike the Site-A emitter's
    //     `detect(in:doctype:)`;
    //   - the five scored families surface through the PRODUCTION composition
    //     (`DocumentSearcher.composedSurvivors` via the observation-only
    //     `_testComposeSiteB` seam: installed calibrated scorer, empty priors,
    //     `.generic` doctype features, posterior floor);
    //   - every other family surfaces through the raw W4 gate
    //     (`applyingCountingDrops(thresholdVector:)`), exactly as
    //     `performSearch(.piiScan)` recombines them.
    //
    // Output: the SAME trio schema as `G8BaselineHarnessTests.emitBaseline`
    // (cells / raw_scores / fire_features) with `site: "siteB"`, at
    // `<base>_siteb_cells.json` / `_siteb_raw_scores.json` /
    // `_siteb_fire_features.json`. The detector-direct emitter keeps writing
    // its trio with `site: "detector"`; dp `eval-baseline` scores both, and
    // the per-category difference is the M12-02 "site gap".
    //
    // Semantics notes, pinned so the numbers are interpretable:
    //   - `raw` in raw_scores/fire rows stays the detector's PRE-composition
    //     confidence (the same signal the Site-A emitter records); for scored
    //     families the SURFACING decision is on the composed posterior, so
    //     `surfaced` here cannot be re-derived from `raw` vs any cutoff.
    //   - fire-row `features` are computed at `.generic` (the doctype-blind
    //     search path), not at the corpus doctype.
    //   - docs are filtered by the same `gateDoctypeClass` guard as the Site-A
    //     emitter, so both trios cover the identical document set and the
    //     site gap is a like-for-like join.

    @Test("H1.1 — emit Site-B G8 baseline trio (product semantics)")
    func emitSiteBBaseline() async throws {
        let corpus = try #require(try G8BaselineHarnessTests.loadBaselineCorpus(), "g8_corpus.json not bundled")
        let vector = try #require(Self.balancedVector(), "balanced preset vector not bundled")

        let detector = PIIDetector()
        let sortedDocs = corpus.documents.sorted { $0.id < $1.id }
        let installed = ContextScorerWeights.loadFromEngineBundle()

        var cells: [String: Cell] = [:]
        var rawRows: [G8BaselineHarnessTests.RawScoreRow] = []
        var fireRows: [G8BaselineHarnessTests.FireFeatureRow] = []
        // Per-span outcome sidecar rows (offsets only; every family).
        var spanRows: [G8BaselineHarnessTests.SpanOutcomeRow] = []

        for doc in sortedDocs {
            // Same doc filter as the Site-A emitter (identical coverage).
            guard gateDoctypeClass(doc.doctype) != nil else { continue }
            let bucket = doc.demographic_bucket

            // PRODUCT detection: doctype-blind.
            let matches = await detector.detect(in: doc.text)

            var positiveGTByKind: [RedactionRegion.PIIKind: [NSRange]] = [:]
            var decoyGTByKind:    [RedactionRegion.PIIKind: [NSRange]] = [:]
            var allGTByKind:      [RedactionRegion.PIIKind: [NSRange]] = [:]
            // Every GT span with its packet tier (additive per-tier counters,
            // 1.2 P1.10 — same bridge as the detector-site emitter).
            var tierGTByKind:     [RedactionRegion.PIIKind: [(NSRange, String)]] = [:]
            // Every GT span with its tier and its positive/decoy split, for
            // the per-span sidecar (same split the counters use).
            var spanGTByKind:     [RedactionRegion.PIIKind: [(NSRange, String, Bool)]] = [:]
            for span in doc.pii_spans {
                guard let kind = G8BaselineHarnessTests.baselineMapCategory(span.category) else { continue }
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

            // PRODUCT surfacing: scored families through the composed gate,
            // the rest through the raw W4 gate.
            let (scoredAll, rest) = matches.partitionedByScoredFamily()
            let scoredSurvivors = DocumentSearcher._testComposeSiteB(
                scoredAll, pageText: doc.text, thresholdVector: vector, scorer: installed
            )
            let survivors = rest.applyingCountingDrops(thresholdVector: vector).survivors + scoredSurvivors

            // Identity of a match for survived-set membership (fire rows).
            func matchKey(_ m: PIIDetector.PIIMatch) -> String {
                "\(m.kind)|\(m.range.location)|\(m.range.length)|\(m.confidence)"
            }
            let scoredSurvivorKeys = Set(scoredSurvivors.map(matchKey))

            // Raw scores + fire rows over EVERY detected match (pre-gate).
            for match in matches {
                guard let catKey = G8BaselineHarnessTests.cellCategoryKey(for: match.kind) else { continue }
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
                    raw: match.confidence,
                    gt_class: gtClass
                ))

                if let family = PIICategory(piiKind: match.kind)
                    .flatMap({ PresetThresholdVector.wireName(for: $0) }),
                    ContextFeatureContract.scoredFamilyWireNames.contains(family) {
                    let feats = contextFeatures(
                        match: match,
                        effectiveDoctype: .generic,
                        pageText: doc.text
                    )
                    fireRows.append(G8BaselineHarnessTests.FireFeatureRow(
                        family: family,
                        cell_category_key: catKey,
                        doctype: doc.doctype,
                        bucket: bucket,
                        start: match.range.location,
                        end: match.range.location + match.range.length,
                        raw: match.confidence,
                        gt_class: gtClass,
                        surfaced: scoredSurvivorKeys.contains(matchKey(match)),
                        features: feats
                    ))
                }
            }

            // Cells over the Site-B survivor set.
            var surfacedByKind: [RedactionRegion.PIIKind: [(NSRange, Bool)]] = [:]
            for m in survivors {
                surfacedByKind[m.kind, default: []].append((m.range, isNegativeContextSuppressed(m)))
            }

            var kinds = Set(allGTByKind.keys)
            kinds.formUnion(surfacedByKind.keys)
            for kind in kinds {
                guard let catKey = G8BaselineHarnessTests.cellCategoryKey(for: kind) else { continue }
                let cellKey = "\(catKey)_\(doc.doctype)_\(bucket)"
                var cell = cells[cellKey] ?? Cell()

                let positives = positiveGTByKind[kind] ?? []
                let decoys    = decoyGTByKind[kind] ?? []
                let allGT     = allGTByKind[kind] ?? []
                let surfaced  = surfacedByKind[kind] ?? []

                for gt in positives {
                    let covered = surfaced.contains { G8BaselineHarnessTests.rangesOverlap($0.0, gt) }
                    if covered { cell.true_positives += 1 } else { cell.false_negatives += 1 }
                }
                cell.adversarial_suppress_total += decoys.count
                for decoy in decoys {
                    let fired = surfaced.contains { G8BaselineHarnessTests.rangesOverlap($0.0, decoy) }
                    if fired { cell.adversarial_suppress_fired += 1 }
                }
                for (det, suppressed) in surfaced {
                    let overlapsAnyGT = allGT.contains { G8BaselineHarnessTests.rangesOverlap(det, $0) }
                    if !overlapsAnyGT { cell.false_positives += 1 }
                    if suppressed { cell.suppressed_by_negative_context += 1 }
                }
                // Per-tier counters (additive), same overlap rule.
                for (gt, tier) in tierGTByKind[kind] ?? [] {
                    let hit = surfaced.contains { G8BaselineHarnessTests.rangesOverlap($0.0, gt) }
                    cell.tally(tier: tier, hit: hit)
                }
                // Per-span outcome sidecar: the verdicts the loops above fold
                // into counters, preserved span by span (offsets only).
                if let family = G8BaselineHarnessTests.corpusCategory(for: kind) {
                    G8BaselineHarnessTests.appendSpanRows(
                        into: &spanRows, docID: doc.id, family: family,
                        groundTruth: spanGTByKind[kind] ?? [],
                        surfaced: surfaced, allGT: allGT
                    )
                }
                cells[cellKey] = cell
            }
        }

        // Balanced cutoff map (raw_scores header) — same construction as the
        // Site-A emitter; informational at Site B (see semantics notes above).
        var cutoffMap: [String: Double] = [:]
        for kind in G8BaselineHarnessTests.allCorpusKinds {
            guard let catKey = G8BaselineHarnessTests.cellCategoryKey(for: kind) else { continue }
            if let c = balancedCutoff(for: kind) { cutoffMap[catKey] = c }
        }

        let base = G8BaselineHarnessTests.baselineOutBase()

        let cellsReport = G8BaselineHarnessTests.BaselineCellsReport(
            schema_version: 1,
            generated_by: "G8SearchParityHarness.emitSiteBBaseline",
            g8_corpus_seed: corpus.seed,
            cutoff_preset: "balanced",
            site: "siteB",
            doc_count: sortedDocs.count,
            cells: cells
        )
        try G8BaselineHarnessTests.writeJSON(cellsReport, to: "\(base)_siteb_cells.json")

        let rawReport = G8BaselineHarnessTests.RawScoresReport(
            schema_version: 1,
            site: "siteB",
            balanced_cutoffs: cutoffMap,
            absorbing_state_floor: DetectionOrchestrator.absorbingStateFloor,
            rows: rawRows
        )
        try G8BaselineHarnessTests.writeJSON(rawReport, to: "\(base)_siteb_raw_scores.json")

        let fireReport = G8BaselineHarnessTests.FireFeaturesReport(
            schema_version: 1,
            generated_by: "G8SearchParityHarness.emitSiteBBaseline",
            site: "siteB",
            feature_order: ContextFeatureContract.featureOrder,
            fires: fireRows
        )
        try G8BaselineHarnessTests.writeJSON(fireReport, to: "\(base)_siteb_fire_features.json")

        // Per-span outcome sidecar (one JSONL per site; additive, offsets only).
        try G8BaselineHarnessTests.writeSpanSidecar(spanRows, to: "\(base)_siteb_spans.jsonl")

        print("[H1.1 siteB baseline] cells → \(base)_siteb_cells.json (\(cells.count) cells)")
        print("[H1.1 siteB baseline] raw_scores → \(base)_siteb_raw_scores.json (\(rawRows.count) rows)")
        print("[H1.1 siteB baseline] fire_features → \(base)_siteb_fire_features.json (\(fireRows.count) fires)")
        print("[H1.1 siteB baseline] spans → \(base)_siteb_spans.jsonl (\(spanRows.count) rows)")

        // Emitter sanity only (standing emitter, not a quality gate).
        #expect(!cells.isEmpty, "no Site-B cells emitted — corpus loaded but produced nothing")
        #expect(sortedDocs.count == 1100,
                "G8 doc_count expected 1100; got \(sortedDocs.count)")
        // Emitter sanity only: one sidecar row per corpus span the tally saw
        // (tp + fn + must_not) and one per generic false positive.
        let corpusSpans = sortedDocs
            .filter { gateDoctypeClass($0.doctype) != nil }
            .reduce(0) {
                $0 + $1.pii_spans.filter { G8BaselineHarnessTests.baselineMapCategory($0.category) != nil }.count
            }
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
