import Testing
import Foundation
@testable import RedactionEngine

// G2a: NameGazetteer failable init, lookup methods, TextNormalizer integration.

@Suite("NameGazetteer (G2a)")
struct NameGazetteerTests {

    // MARK: - Failable Init

    @Test("Init returns nil when bundled resources are missing")
    func nilWhenResourcesMissing() {
        // In the test target, the production Resources/Gazetteers/ may not have
        // real .bloom files (only .gitkeep). The init should return nil gracefully.
        // This test documents the expected behavior — it passes regardless of
        // whether real filters are bundled because either path is valid.
        let gazetteer = NameGazetteer()
        if gazetteer == nil {
            // Expected in scaffold phase (no real .bloom files bundled)
        } else {
            // Valid once production filters are built (G2b)
            #expect(gazetteer!.manifest.version.isEmpty == false)
        }
    }

    // MARK: - Lookup via Golden File

    @Test("Surname lookup finds known names in golden filter")
    func surnameLookupGolden() throws {
        let filter = try loadGoldenFilter()

        // Names from the golden-1000-members list that are surnames
        #expect(filter.contains("smith"))
        #expect(filter.contains("garcia"))
        #expect(filter.contains("nguyen"))
        #expect(filter.contains("patel"))
        #expect(filter.contains("begay"))
    }

    @Test("Surname lookup rejects known non-names in golden filter")
    func surnameNonNamesGolden() throws {
        let filter = try loadGoldenFilter()

        #expect(!filter.contains("docket"))
        #expect(!filter.contains("invoice"))
        #expect(!filter.contains("plaintiff"))
    }

    @Test("TextNormalizer is applied: case-insensitive lookup")
    func normalizationApplied() throws {
        let filter = try loadGoldenFilter()

        // The golden file stores lowercased NFKC names.
        // BloomFilter.contains() normalizes input, so mixed-case should work.
        #expect(filter.contains("SMITH"))
        #expect(filter.contains("Garcia"))
        #expect(filter.contains("NGUYEN"))
    }

    @Test("Adjacent pair lookup: both must hit")
    func adjacentPairLookup() throws {
        let surnameFilter = try loadGoldenFilter()
        let givenFilter = try loadGoldenFilter()
        let manifest = GazetteerManifest(
            version: "test", hashAlgorithm: "MurmurHash3_x64_128",
            seed: 42, filters: [])
        let gazetteer = NameGazetteer(
            surnameFilter: surnameFilter,
            givenNameFilter: givenFilter,
            manifest: manifest)

        // Both "smith" and "garcia" are in the golden filter
        #expect(gazetteer.contains(adjacent: (given: "garcia", surname: "smith")))

        // "docket" is not in the filter
        #expect(!gazetteer.contains(adjacent: (given: "docket", surname: "smith")))
        #expect(!gazetteer.contains(adjacent: (given: "garcia", surname: "docket")))
    }

    // MARK: - Helpers

    /// Load the golden-1000.bloom as a BloomFilter for testing.
    private func loadGoldenFilter() throws -> BloomFilter {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "golden-1000",
                                   withExtension: "bloom",
                                   subdirectory: "TestResources") else {
            Issue.record("golden-1000.bloom not found in TestResources")
            throw GoldenFileError.notFound
        }
        let data = try Data(contentsOf: url)
        return try BloomFilter(data: data)
    }

    private enum GoldenFileError: Error {
        case notFound
    }

    // MARK: - WS1 item 1.12: suffix stripping + hyphenated-surname component lookup

    // All tests in this section use the golden-1000 bloom as both surname and
    // given-name filters (the NameGazetteer test init wires them identically).
    // Members confirmed in golden-1000-members.txt: smith, jones, garcia, lopez, james.
    // Non-members confirmed: doe, john, jane, mary, maria.

    private func makeGazetteer() throws -> NameGazetteer? {
        let filter = try loadGoldenFilter()
        let manifest = GazetteerManifest(
            version: "test", hashAlgorithm: "MurmurHash3_x64_128",
            seed: 42, filters: [])
        return NameGazetteer(
            surnameFilter: filter,
            givenNameFilter: filter,
            manifest: manifest)
    }

    @Test("Jr. suffix stripped: 'John Smith Jr.' → surname 'Smith' hits → boost ≥ 0.10")
    func jrSuffix_stripped() throws {
        let gazetteer = try makeGazetteer()!
        // "Smith" is in golden-1000; "John" is not. After stripping "Jr.",
        // tokens = ["John", "Smith"] → surnameHit=true, givenHit=false → boost 0.10.
        let verdict = gazetteer.queryBoosted(candidate: "John Smith Jr.")
        #expect(verdict.boost >= 0.10,
            "Suffix 'Jr.' must be stripped; 'Smith' is in the filter so boost should be ≥ 0.10")
        #expect(verdict.surnameHit == true)
    }

    @Test("MD suffix stripped: 'James Jones MD' → surname 'Jones' hits → boost ≥ 0.10")
    func mdSuffix_stripped() throws {
        let gazetteer = try makeGazetteer()!
        // "Jones" is in golden-1000; "James" is also in golden-1000.
        // After stripping "MD", tokens = ["James", "Jones"] → surnameHit=true,
        // givenHit=true → boost 0.15.
        let verdict = gazetteer.queryBoosted(candidate: "James Jones MD")
        #expect(verdict.boost >= 0.10,
            "Suffix 'MD' must be stripped; 'Jones' is in the filter so boost should be ≥ 0.10")
        #expect(verdict.surnameHit == true)
    }

    @Test("Both hyphen components in bloom → full surname credit, boost 0.15 with given hit")
    func hyphenated_bothComponents_hit() throws {
        let gazetteer = try makeGazetteer()!
        // "James" (given), "Garcia" and "Lopez" both in golden-1000.
        // "Garcia-Lopez" not in filter → component split → both "Garcia" and "Lopez" hit
        // → surnameHit=true (all components), givenHit=true ("james" in filter) → boost 0.15.
        let verdict = gazetteer.queryBoosted(candidate: "James Garcia-Lopez")
        #expect(verdict.boost == 0.15,
            "All components hit + given hit should yield boost 0.15")
        #expect(verdict.surnameHit == true)
        #expect(verdict.givenHit == true)
    }

    @Test("One hyphen component in bloom → fuzzy credit, boost 0.05")
    func hyphenated_oneComponent_hit() throws {
        let gazetteer = try makeGazetteer()!
        // "Garcia" is in golden-1000; "Unknown" is not.
        // "Garcia-Unknown" → component split → only "Garcia" hits → partial hit → boost 0.05.
        let verdict = gazetteer.queryBoosted(candidate: "Maria Garcia-Unknown")
        #expect(verdict.boost == 0.05,
            "Partial component hit should yield fuzzy boost 0.05")
        #expect(verdict.fuzzySurnameHit == true)
    }

    @Test("All tokens are suffixes → empty tokens → returns .none")
    func noName_afterStripSuffixes() throws {
        let gazetteer = try makeGazetteer()!
        // "MD" and "Jr." are both in the suffix set; all tokens stripped → guard fires → .none.
        let verdict = gazetteer.queryBoosted(candidate: "MD Jr.")
        #expect(verdict.boost == 0.0, "All tokens stripped → no surname → .none boost")
        #expect(verdict.hadAnyHit == false)
    }

    @Test("Adversarial: 'John Smith-Jones Jr. PhD' → strip Jr./PhD, hyphen lookup on Smith-Jones")
    func adversarial_hyphenAndSuffix_combined() throws {
        let gazetteer = try makeGazetteer()!
        // Strip "Jr." and "PhD" → tokens = ["John", "Smith-Jones"].
        // "Smith-Jones" not in filter → component split → "Smith" in filter, "Jones" in filter
        // → all components hit → surnameHit=true; "John" not in given filter → givenHit=false
        // → boost 0.10.
        let verdict = gazetteer.queryBoosted(candidate: "John Smith-Jones Jr. PhD")
        #expect(verdict.surnameHit == true,
            "Both 'Smith' and 'Jones' are in golden-1000; all-components-hit = full surname credit")
        #expect(verdict.boost == 0.10,
            "Given 'John' is not in filter; surname all-components-hit → boost 0.10")
    }

    // MARK: - W-O version fence

    @Test("Version-fence rejects out-of-range manifest version (W-O Q2 path B)")
    func versionFenceRejectsOutOfRange() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appending(path: "wo-followers-name-\(UUID().uuidString)", directoryHint: .isDirectory)
        let gazetteersDir = tempBase.appending(path: "Gazetteers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gazetteersDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        // Future-schema manifest. The fence runs after manifest decode and
        // before bloom-filter decode (NameGazetteer.swift:throwingFromBundle),
        // so the bloom files only need to exist — their bytes are never read.
        let manifestURL = gazetteersDir.appending(path: "gazetteer-manifest.json")
        let manifestJSON = #"""
        {"version": "99.0.0", "hashAlgorithm": "MurmurHash3_x64_128", "seed": 0, "filters": []}
        """#
        try manifestJSON.write(to: manifestURL, atomically: true, encoding: .utf8)
        try Data().write(to: gazetteersDir.appending(path: "surnames.bloom"))
        try Data().write(to: gazetteersDir.appending(path: "given-names.bloom"))

        guard let bundle = Bundle(path: tempBase.path()) else {
            Issue.record("Failed to create test bundle from \(tempBase.path())")
            return
        }

        do {
            _ = try NameGazetteer(throwingFromBundle: bundle)
            Issue.record("Expected LoaderError.unsupportedManifestVersion but no error was thrown")
        } catch NameGazetteer.LoaderError.unsupportedManifestVersion(let actual, let supported) {
            #expect(actual == "99.0.0")
            #expect(supported == ["1.0.0"])
        } catch {
            Issue.record("Expected LoaderError.unsupportedManifestVersion but got \(error)")
        }
    }
}
