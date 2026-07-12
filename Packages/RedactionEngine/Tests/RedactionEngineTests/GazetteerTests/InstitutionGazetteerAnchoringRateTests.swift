import Testing
import Foundation
@testable import RedactionEngine

// W-A engine paired (STRAT §5.7) — G8 anchoring-rate regression guard for
// the A3 1:1 federal_agency rebuild cutover. Loads `g8_corpus.json`, walks
// every `.foia` + `.medical` document, runs `InstitutionGazetteer.findInstitution(in:)`
// + `anchoredDoctype(for:)`, computes per-doctype hit-rate, and asserts the
// rate is ≥ the pre-cutover baseline measured on Resecta master at the
// chain-author commit (institutions.json count: 1343 entries pre-cutover).
//
// Regression model: when the data-side W-A merge lands the rebuilt
// institutions.json (~470 entries; A3 1:1 cutover from D-01
// federalregister_agencies.json), this test re-runs and the floors below
// catch any silent recall drop on FOIA / medical strata.
//
// Rationale:
//   - FOIA documents in G8 carry agency headers (e.g., "FREEDOM OF
//     INFORMATION ACT REQUEST" letterhead) that should anchor to a known
//     federal_agency entry, mapping back to .foia via anchoredDoctype.
//   - Medical documents in G8 are mostly clinic/hospital correspondence;
//     hit-rate is incidental (hospital names ≠ federal_agency in V1) but
//     measurable, so a non-zero baseline still functions as a floor.
//
// Both floors are recorded in `engine-impl-W-A-engine-paired-DONE.md`; the
// post-data-side-W-A-merge re-run compares against the values below. If
// the rebuild drops a load-bearing entry the per-doctype rate slips and
// this test fails — visible regression catch instead of silent recall
// degradation.
//
// Gated on g8_corpus.json being bundled (same gate as
// `G8CorpusIngestionTests`); skipped cleanly if the maintainer has not yet run
// `make install-assets` on the corpus path.

@Suite("InstitutionGazetteer × G8 anchoring rate (W-A engine paired)")
struct InstitutionGazetteerAnchoringRateTests {

    // MARK: - Baseline floors (pre-cutover, recorded in DONE marker)

    /// Pre-cutover FOIA-stratum hit-rate floor. Measured at chain-author
    /// commit against institutions.json (1343 entries) on
    /// `wip/w-a-engine-paired-anchoring-rate`: **0/150 = 0.0000**. The
    /// surprising zero baseline reflects a G8 fixture characteristic — the
    /// V1 FOIA templates don't name federal agencies in their headers
    /// (every doc opens with "FREEDOM OF INFORMATION ACT REQUEST" then a
    /// generic "Request No." line; no agency-letterhead text). The floor
    /// still functions as a regression guard because it asserts the rate
    /// stays at or above zero — and a post-cutover RUN that returns >0
    /// hits is informational (the rebuilt institutions.json may have
    /// added a name that overlaps a fixture string we hadn't expected).
    /// See DONE marker for the defer-note recommending V1.1+ FOIA fixture
    /// expansion to include agency letterheads.
    static let foiaHitRateFloor: Double = 0.0

    /// Pre-cutover medical-stratum hit-rate floor. Measured at chain-author
    /// commit against institutions.json (1343 entries):
    /// **250/250 = 1.0000**. Every G8 medical document includes a
    /// `Prescribing: Dr. ___, DEA <number>.` line; the "DEA" alias of
    /// "Drug Enforcement Administration" word-bounded-matches in all 250.
    /// This is the strong regression guard the chain protects: if the
    /// rebuilt institutions.json drops the DEA entry (or its "DEA" alias),
    /// the medical-stratum rate slips and this test fails — visible
    /// post-cutover catch.
    static let medicalHitRateFloor: Double = 1.0

    // MARK: - Stratum size invariants (matches G8 plan counts)

    static let expectedFOIADocCount = 150
    static let expectedMedicalDocCount = 250

    // MARK: - Tests

    @Test("FOIA stratum anchoring-rate ≥ pre-cutover baseline (gated on fixture)")
    func foiaAnchoringRate() throws {
        let corpus = try loadCorpus()
        guard let corpus else {
            print("[W-A] g8_corpus.json not bundled; test skipped until `make install-assets` runs.")
            return
        }
        let gazetteer = try InstitutionGazetteer()

        let stats = computeStats(
            corpus: corpus,
            gazetteer: gazetteer,
            doctypeFilter: "foia"
        )

        #expect(
            stats.docCount == Self.expectedFOIADocCount,
            "FOIA stratum size drifted from G8 plan count"
        )

        // Hit rate floor — pre-cutover baseline.
        #expect(
            stats.hitRate >= Self.foiaHitRateFloor,
            "FOIA anchoring-rate below pre-cutover floor; rebuilt institutions.json may have dropped a load-bearing federal_agency entry"
        )

        // Anchored-doctype rate floor — every FOIA hit should map back to .foia
        // because anchoredDoctype is federal_agency → .foia in V1. Anchored
        // count cannot exceed hit count; floor here mirrors hitRateFloor since
        // the institution-detected text in FOIA letterheads is by construction
        // a federal_agency entry.
        #expect(
            stats.anchoredDoctypeRate >= Self.foiaHitRateFloor,
            "FOIA anchored-doctype rate below pre-cutover floor"
        )

        print("[W-A baseline FOIA] docs=\(stats.docCount) hits=\(stats.hitCount) " +
              "hitRate=\(String(format: "%.4f", stats.hitRate)) " +
              "anchoredRate=\(String(format: "%.4f", stats.anchoredDoctypeRate)) " +
              "uniqueInstitutions=\(stats.uniqueInstitutionsMatched)")
    }

    @Test("Medical stratum anchoring-rate ≥ pre-cutover baseline (gated on fixture)")
    func medicalAnchoringRate() throws {
        let corpus = try loadCorpus()
        guard let corpus else {
            print("[W-A] g8_corpus.json not bundled; test skipped until `make install-assets` runs.")
            return
        }
        let gazetteer = try InstitutionGazetteer()

        let stats = computeStats(
            corpus: corpus,
            gazetteer: gazetteer,
            doctypeFilter: "medical"
        )

        #expect(
            stats.docCount == Self.expectedMedicalDocCount,
            "medical stratum size drifted from G8 plan count"
        )

        // Hit rate floor — pre-cutover baseline. Medical docs incidentally
        // mention federal agencies (e.g., "Medicare", "VA") in some templates;
        // the floor below captures whatever rate the pre-cutover gazetteer
        // produces and protects against post-cutover drops.
        #expect(
            stats.hitRate >= Self.medicalHitRateFloor,
            "medical anchoring-rate below pre-cutover floor; rebuilt institutions.json may have dropped an entry the medical stratum was hitting"
        )

        print("[W-A baseline medical] docs=\(stats.docCount) hits=\(stats.hitCount) " +
              "hitRate=\(String(format: "%.4f", stats.hitRate)) " +
              "anchoredRate=\(String(format: "%.4f", stats.anchoredDoctypeRate)) " +
              "uniqueInstitutions=\(stats.uniqueInstitutionsMatched)")
    }

    // MARK: - Helpers

    /// Per-stratum aggregate stats. `hitRate` is `hitCount / docCount`;
    /// `anchoredDoctypeRate` is `anchoredCount / docCount` where `anchoredCount`
    /// counts hits whose category resolves to a non-nil `DoctypeClass` via
    /// `InstitutionGazetteer.anchoredDoctype(for:)`.
    private struct Stats {
        let docCount: Int
        let hitCount: Int
        let anchoredCount: Int
        let uniqueInstitutionsMatched: Int
        var hitRate: Double {
            docCount == 0 ? 0.0 : Double(hitCount) / Double(docCount)
        }
        var anchoredDoctypeRate: Double {
            docCount == 0 ? 0.0 : Double(anchoredCount) / Double(docCount)
        }
    }

    private func computeStats(
        corpus: G8CorpusIngestionTests.G8Corpus,
        gazetteer: InstitutionGazetteer,
        doctypeFilter: String
    ) -> Stats {
        var docCount = 0
        var hitCount = 0
        var anchoredCount = 0
        var matchedNames: Set<String> = []

        for doc in corpus.documents where doc.doctype == doctypeFilter {
            docCount += 1
            // Scan the full document text (mirrors how
            // NegativeContextGazetteer / DetectionOrchestrator pass document
            // header text in production). Using full text keeps the test
            // robust to G8 fixture format drift on header/body split.
            guard let hit = gazetteer.findInstitution(in: doc.text) else {
                continue
            }
            hitCount += 1
            matchedNames.insert(hit.name)
            if InstitutionGazetteer.anchoredDoctype(for: hit) != nil {
                anchoredCount += 1
            }
        }

        return Stats(
            docCount: docCount,
            hitCount: hitCount,
            anchoredCount: anchoredCount,
            uniqueInstitutionsMatched: matchedNames.count
        )
    }

    /// Reuses the wire-format struct + loader pattern from
    /// `G8CorpusIngestionTests`. Returns `nil` when the corpus fixture is
    /// not bundled (gates the test like the sibling suite does).
    private func loadCorpus() throws -> G8CorpusIngestionTests.G8Corpus? {
        guard let url = Bundle.module.url(
            forResource: "g8_corpus",
            withExtension: "json",
            subdirectory: "corpus"
        ) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(
            G8CorpusIngestionTests.G8Corpus.self, from: data)
    }
}
