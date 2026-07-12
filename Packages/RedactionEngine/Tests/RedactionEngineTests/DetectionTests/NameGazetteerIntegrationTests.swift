import Testing
import Foundation
import NaturalLanguage
@testable import RedactionEngine

// W2 — NameGazetteer wired into the NLTagger name path.
// Verifies per-candidate boost + strict-on-ALL-CAPS suppression + rationale
// signal emission. Tests that need the real bundled Bloom filters gate on
// `NameGazetteer.init?()` and skip cleanly when resources are stripped
// (same pattern as G8CorpusIngestionTests).

@Suite("NameGazetteer integration (W2)")
struct NameGazetteerIntegrationTests {

    // MARK: - Bundled-gazetteer tests (gated)

    @Test("Known surname triggers bloomSurnameHit + boost above baseline")
    func knownSurnameGetsBoostAndSignal() async throws {
        guard Self.nlTaggerNamesAvailable() else {
            print("[NLTagger gate] .nameType scheme unavailable on this build; "
                  + "skipping (REDACTION_ENGINE.md §4.5 'Experiment L3').")
            return
        }
        guard let gazetteer = NameGazetteer() else {
            print("[W2 gate] NameGazetteer bundle missing; skipping bundled test.")
            return
        }
        let detector = PIIDetector(nameGazetteer: gazetteer)
        // Clean subject-verb construction so NLTagger reliably emits a
        // .personalName candidate; "Smith" is in the bundled surname bloom
        // and "John" in the given-name bloom, exercising the +0.15 boost.
        let text = "John Smith filed a claim."
        let matches = await detector.detect(in: text)
        let name = try #require(matches.first { $0.kind == .name })
        let rationale = try #require(name.rationale)

        #expect(name.confidence >= 0.80 - 0.001,
                "boosted confidence should land at ~0.80 for a known surname")
        #expect(rationale.signals.contains(.bloomSurnameHit))
    }

    @Test("Given + surname on bundled gazetteer produces max boost (direct queryBoosted)")
    func bundledGazetteer_givenAndSurnameBoost() throws {
        guard let gazetteer = NameGazetteer() else {
            print("[W2 gate] NameGazetteer bundle missing; skipping bundled test.")
            return
        }
        // queryBoosted skips the NLTagger tokenization variability — the
        // boost path itself is what we're validating. "maria johnson" has
        // both common SSA + Census bundled keys.
        let verdict = gazetteer.queryBoosted(candidate: "maria johnson")
        #expect(verdict.surnameHit == true,
                "'johnson' must be in the bundled surname filter")
        #expect(verdict.givenHit == true,
                "'maria' must be in the bundled given-name filter")
        #expect(abs(verdict.boost - 0.15) < 0.0001,
                "surname + given should return max boost 0.15")
    }

    @Test("Unknown candidate keeps baseline 0.70 and emits no bloom signals")
    func unknownCandidateKeepsBaseline() async throws {
        guard let gazetteer = NameGazetteer() else {
            print("[W2 gate] NameGazetteer bundle missing; skipping bundled test.")
            return
        }
        let detector = PIIDetector(nameGazetteer: gazetteer)
        // Use a construction NLTagger is likely to flag as a person so we
        // actually exercise the non-strict path; two tokens absent from
        // the bundled Bloom keep the verdict empty.
        let text = "Zxqbwv Plomqvr signed the release."
        let matches = await detector.detect(in: text)
        let name = matches.first { $0.kind == .name }
        if let name, let rationale = name.rationale {
            #expect(abs(name.confidence - 0.70) < 0.001,
                    "unknown candidate must stay at 0.70 baseline")
            #expect(!rationale.signals.contains(.bloomSurnameHit))
            #expect(!rationale.signals.contains(.bloomGivenHit))
        }
        // If NLTagger doesn't flag it at all, that's also fine — the
        // guarantee is only that we don't BOOST unknown candidates.
    }

    @Test("ALL-CAPS strict pass suppresses gibberish candidates")
    func allCapsStrictPassSuppressesUnknown() async throws {
        guard let gazetteer = NameGazetteer() else {
            print("[W2 gate] NameGazetteer bundle missing; skipping bundled test.")
            return
        }
        let detector = PIIDetector(nameGazetteer: gazetteer)
        // Gibberish tokens NLTagger might flag in a title-cased pass must
        // not survive the strict gate.
        let text = "RECIPIENT: ZXQBWV PLOMQVR"
        let matches = await detector.detect(in: text)
        let gibberish = matches.first {
            $0.kind == .name && (
                $0.text.lowercased().contains("zxqbwv")
                || $0.text.lowercased().contains("plomqvr")
            )
        }
        #expect(gibberish == nil,
                "strict pass must drop candidates the gazetteer doesn't recognize")
    }

    // MARK: - Direct queryBoosted verdict table

    @Test("queryBoosted verdict table — exact surname only")
    func verdictTable_exactSurnameOnly() throws {
        let gazetteer = try loadGoldenGazetteer()
        // 'smith' is in golden-1000; a random-garbage given-name token
        // should not be.
        let verdict = gazetteer.queryBoosted(candidate: "Zqqzzzz Smith")
        #expect(verdict.surnameHit == true)
        #expect(verdict.givenHit == false)
        #expect(verdict.fuzzySurnameHit == false)
        #expect(abs(verdict.boost - 0.10) < 0.0001)
    }

    @Test("queryBoosted verdict table — exact surname + given")
    func verdictTable_exactSurnameAndGiven() throws {
        let gazetteer = try loadGoldenGazetteer()
        // Both 'garcia' and 'smith' are in golden-1000. Order in queryBoosted:
        // last token = surname, earlier tokens = given-name query.
        let verdict = gazetteer.queryBoosted(candidate: "garcia smith")
        #expect(verdict.surnameHit == true)
        #expect(verdict.givenHit == true)
        #expect(verdict.fuzzySurnameHit == false)
        #expect(abs(verdict.boost - 0.15) < 0.0001)
    }

    @Test("queryBoosted verdict table — no hit")
    func verdictTable_noHit() throws {
        let gazetteer = try loadGoldenGazetteer()
        let verdict = gazetteer.queryBoosted(
            candidate: "zqxwvutsr qpwoeiruyt", fuzzy: false)
        #expect(verdict.surnameHit == false)
        #expect(verdict.givenHit == false)
        #expect(verdict.fuzzySurnameHit == false)
        #expect(verdict.boost == 0.0)
    }

    @Test("queryBoosted verdict table — fuzzy: false disables fallback")
    func verdictTable_fuzzyDisabledRespectsFlag() throws {
        let gazetteer = try loadGoldenGazetteer()
        // Levenshtein-1 of 'smith' → candidates with a one-character edit
        // away from a known name. With fuzzy: false we should see a miss
        // even when the exact lookup fails.
        let verdict = gazetteer.queryBoosted(
            candidate: "smuth", fuzzy: false)  // 'smuth' is not in golden
        #expect(verdict.surnameHit == false)
        #expect(verdict.fuzzySurnameHit == false,
                "strict mode must not enumerate Levenshtein-1 candidates")
    }

    @Test("hadAnyHit convenience reflects each field")
    func hadAnyHitConvenience() {
        let none = NameGazetteer.NameGazetteerVerdict.none
        #expect(none.hadAnyHit == false)
        let surnameOnly = NameGazetteer.NameGazetteerVerdict(
            surnameHit: true, givenHit: false, fuzzySurnameHit: false,
            fuzzyScore: nil, boost: 0.10)
        #expect(surnameOnly.hadAnyHit == true)
        let fuzzyOnly = NameGazetteer.NameGazetteerVerdict(
            surnameHit: false, givenHit: false, fuzzySurnameHit: true,
            fuzzyScore: 0.6, boost: 0.05)
        #expect(fuzzyOnly.hadAnyHit == true)
    }

    // MARK: - Back-compat

    @Test("nil gazetteer preserves pre-W2 baseline and emits no bloom signals")
    func nilGazetteerBackCompat() async throws {
        guard Self.nlTaggerNamesAvailable() else {
            print("[NLTagger gate] .nameType scheme unavailable on this build; "
                  + "skipping (REDACTION_ENGINE.md §4.5 'Experiment L3').")
            return
        }
        let detector = PIIDetector(nameGazetteer: nil)
        // Clean subject-verb construction the NLTagger personal-name path
        // tags reliably across SDK builds; nil gazetteer means the +boost
        // wiring stays dormant so the result lands on the 0.70 baseline.
        let text = "John Smith filed a claim."
        let matches = await detector.detect(in: text)
        let name = try #require(matches.first { $0.kind == .name })
        let rationale = try #require(name.rationale)

        #expect(abs(name.confidence - 0.70) < 0.001,
                "nil gazetteer must keep the 0.70 baseline confidence")
        #expect(!rationale.signals.contains(.bloomSurnameHit))
        #expect(!rationale.signals.contains(.bloomGivenHit))
        // The W1 baseline signal is still present.
        #expect(rationale.signals.contains(.regexPattern(name: "name.nltagger")))
    }

    // MARK: - Helpers

    /// Build a NameGazetteer backed by the shared golden-1000.bloom on both
    /// the surname and given-name filter slots. Sufficient for exact-hit
    /// table tests since we only care about deterministic membership
    /// decisions against a known key set.
    private func loadGoldenGazetteer() throws -> NameGazetteer {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "golden-1000",
                                   withExtension: "bloom",
                                   subdirectory: "TestResources") else {
            Issue.record("golden-1000.bloom not found in TestResources")
            throw GoldenFileError.notFound
        }
        let data = try Data(contentsOf: url)
        let filter = try BloomFilter(data: data)
        let manifest = GazetteerManifest(
            version: "test", hashAlgorithm: "MurmurHash3_x64_128",
            seed: 42, filters: [])
        return NameGazetteer(
            surnameFilter: filter, givenNameFilter: filter, manifest: manifest)
    }

    private enum GoldenFileError: Error {
        case notFound
    }

    /// REDACTION_ENGINE.md §4.5 "Experiment L3" — the .nameType scheme is
    /// asset-gated on iOS 26 and is absent from the iPhone simulator's
    /// available schemes, so any test that needs NLTagger to emit a
    /// personalName candidate would observe an empty stream rather than
    /// the intended W2 wiring. Skipping here matches the bundle-missing
    /// gate above; on physical devices the scheme returns true and the
    /// assertions run normally.
    private static func nlTaggerNamesAvailable() -> Bool {
        NLTagger.availableTagSchemes(for: .word, language: .english)
            .contains(.nameType)
    }
}
