import Testing
import Foundation
import Darwin
@testable import RedactionEngine

// Search-impl S5 / design 02 §7 — NicknameGazetteer loader + lookup tests,
// and NameGazetteer nickname-widening integration tests.

// MARK: - NicknameGazetteer unit tests

@Suite("NicknameGazetteer (search-impl S5)")
struct NicknameGazetteerTests {

    // MARK: - Direct-init normalization

    @Test("Direct-init: keys are normalized at construction")
    func directInit_keysNormalized() {
        let g = NicknameGazetteer(entries: [
            "BILL": ["william"],
            "  Bob  ": ["robert"],
        ])
        // Mixed-case and padded keys must normalize.
        #expect(g.canonicals(for: "bill") == ["william"],
                "'bill' lookup should resolve to 'william' after key normalization")
        #expect(g.canonicals(for: "bob") == ["robert"],
                "'bob' lookup should resolve to 'robert' after key normalization")
    }

    @Test("Direct-init: lookup is case-insensitive")
    func directInit_lookupCaseInsensitive() {
        let g = NicknameGazetteer(entries: ["liz": ["elizabeth"]])
        #expect(g.canonicals(for: "LIZ") == ["elizabeth"])
        #expect(g.canonicals(for: "Liz") == ["elizabeth"])
        #expect(g.canonicals(for: "liz") == ["elizabeth"])
    }

    @Test("Direct-init: unknown alias returns empty array")
    func directInit_unknownAlias_returnsEmpty() {
        let g = NicknameGazetteer(entries: ["bill": ["william"]])
        #expect(g.canonicals(for: "xyz_unknown_alias") == [],
                "Unknown alias must return empty array, not nil")
    }

    @Test("Direct-init: multi-canonical alias is preserved")
    func directInit_multiCanonical() {
        let g = NicknameGazetteer(entries: ["al": ["albert", "alfred", "allen"]])
        let canonicals = g.canonicals(for: "al")
        #expect(canonicals.contains("albert"))
        #expect(canonicals.contains("alfred"))
        #expect(canonicals.contains("allen"))
    }

    @Test("Direct-init: empty lookup returns empty")
    func directInit_emptyAlias() {
        let g = NicknameGazetteer(entries: ["bill": ["william"]])
        #expect(g.canonicals(for: "") == [])
    }

    // MARK: - Bundle-missing path

    @Test("Bundle init throws resourceMissing when not bundled")
    func bundleInit_throwsWhenMissing() {
        // Bundle() is the empty main bundle in test context and will not have
        // Gazetteers/nicknames.json — expect resourceMissing.
        #expect(throws: NicknameGazetteer.LoaderError.self) {
            _ = try NicknameGazetteer(bundle: Bundle())
        }
    }

    // MARK: - Version fence (direct-path; bundle-fixture path skipped — no test bundle infra needed)

    @Test("Version-fence rejects unsupported version (W-O)")
    func versionFence_rejectsOutOfRange() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appending(path: "wo-nicknames-\(UUID().uuidString)", directoryHint: .isDirectory)
        let gazetteersDir = tempBase.appending(path: "Gazetteers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gazetteersDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let fixtureURL = gazetteersDir.appending(path: "nicknames.json")
        // version 99 is outside the supported 1...1 range.
        let fixtureJSON = #"{"version": 99, "generated_by": "test", "seed": 0, "sources": [], "entries": {}}"#
        try fixtureJSON.write(to: fixtureURL, atomically: true, encoding: .utf8)

        guard let bundle = Bundle(path: tempBase.path()) else {
            Issue.record("Failed to create test bundle from \(tempBase.path())")
            return
        }

        do {
            _ = try NicknameGazetteer(bundle: bundle)
            Issue.record("Expected LoaderError.unsupportedVersion but no error was thrown")
        } catch NicknameGazetteer.LoaderError.unsupportedVersion(let actual, let supported) { // LegalPhrases:safe
            #expect(actual == 99)
            #expect(supported == 1...1)
        } catch { // LegalPhrases:safe
            Issue.record("Expected LoaderError.unsupportedVersion but got \(error)")
        }
    }

    @Test("Valid bundle fixture loads and returns canonicals")
    func bundleFixture_loadsAndLooksUp() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appending(path: "nicknames-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        let gazetteersDir = tempBase.appending(path: "Gazetteers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gazetteersDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let fixtureURL = gazetteersDir.appending(path: "nicknames.json")
        let fixtureJSON = """
        {
          "version": 1,
          "generated_by": "test",
          "seed": 20260416,
          "sources": [{"id": "test", "sha256": "abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234", "retrieval_date": "2026-06-10"}],
          "entries": {
            "bill": ["william"],
            "bob": ["robert"],
            "liz": ["elizabeth"]
          }
        }
        """
        try fixtureJSON.write(to: fixtureURL, atomically: true, encoding: .utf8)

        guard let bundle = Bundle(path: tempBase.path()) else {
            Issue.record("Failed to create test bundle from \(tempBase.path())")
            return
        }

        let g = try NicknameGazetteer(bundle: bundle)
        #expect(g.canonicals(for: "bill") == ["william"])
        #expect(g.canonicals(for: "bob") == ["robert"])
        #expect(g.canonicals(for: "liz") == ["elizabeth"])
        #expect(g.canonicals(for: "unknown_xyz") == [])
    }
}

// MARK: - NameGazetteer + NicknameGazetteer integration tests

@Suite("NameGazetteer nickname integration (S5)")
struct NameGazetteerNicknameIntegrationTests {

    // Helper: build a BloomFilter containing exactly the given keys.
    // Mirrors BloomFilterTests.buildBloomData; duplicated here because
    // that helper is file-private in BloomFilterTests.swift.
    private func buildFilter(keys: [String], seed: UInt64 = 42) throws -> BloomFilter {
        let normalizedKeys = keys.map { TextNormalizer.normalize($0).lowercased() }
        let n = normalizedKeys.count
        let fpr = 0.001
        let mBits = max(64, Int(ceil(-Double(n) * log(fpr) / pow(log(2), 2))))
        let byteCount = (mBits + 7) / 8
        var bits = [UInt8](repeating: 0, count: byteCount)
        let k = 10
        let hashSeed = UInt32(seed & 0xFFFF_FFFF)
        for key in normalizedKeys {
            let bytes = Array(key.utf8)
            let (h1, h2) = BloomFilter.murmurHash3_x64_128(bytes, seed: hashSeed)
            for i: UInt64 in 0..<UInt64(k) {
                let pos = Int((h1 &+ i &* h2) % UInt64(mBits))
                bits[pos / 8] |= 1 << (pos % 8)
            }
        }
        var data = Data()
        data.append(contentsOf: [0x52, 0x53, 0x42, 0x46]) // "RSBF"
        data.appendTestLE(UInt16(1))
        data.append(UInt8(k))
        data.appendTestLE(UInt64(mBits))
        data.appendTestLE(seed)
        data.appendTestLE(UInt64(n))
        data.append(contentsOf: [UInt8](repeating: 0, count: 32)) // SHA-256 placeholder
        data.append(contentsOf: bits)
        return try BloomFilter(data: data)
    }

    private func makeManifest() -> GazetteerManifest {
        GazetteerManifest(
            version: "test", hashAlgorithm: "MurmurHash3_x64_128",
            seed: 42, filters: [])
    }

    // MARK: - testBillResolvesToWilliam

    @Test("Bill resolves to william via nickname table: boost 0.15 with table, 0.10 without")
    func testBillResolvesToWilliam() throws {
        // Filters contain "william" (canonical) and "smith" (surname), but NOT "bill".
        let surnameFilter = try buildFilter(keys: ["smith"])
        let givenFilter = try buildFilter(keys: ["william"])

        // Without nickname table: "Bill Smith" → givenHit=false → boost 0.10
        let withoutNicknames = NameGazetteer(
            surnameFilter: surnameFilter,
            givenNameFilter: givenFilter,
            manifest: makeManifest(),
            nicknameGazetteer: nil)
        let withoutVerdict = withoutNicknames.queryBoosted(candidate: "Bill Smith")
        #expect(withoutVerdict.boost == 0.10,
                "Without nickname table, 'Bill' misses the given-name filter → surname-only boost 0.10")
        #expect(withoutVerdict.surnameHit == true)
        #expect(withoutVerdict.givenHit == false)

        // With nickname table mapping "bill" → ["william"]: givenHit becomes true → boost 0.15
        let nicknames = NicknameGazetteer(entries: ["bill": ["william"]])
        let withNicknames = NameGazetteer(
            surnameFilter: surnameFilter,
            givenNameFilter: givenFilter,
            manifest: makeManifest(),
            nicknameGazetteer: nicknames)
        let withVerdict = withNicknames.queryBoosted(candidate: "Bill Smith")
        #expect(withVerdict.boost == 0.15,
                "With nickname table, 'bill' → 'william' which is in the given filter → boost 0.15")
        #expect(withVerdict.surnameHit == true)
        #expect(withVerdict.givenHit == true)
    }

    // MARK: - testUnknownNicknameNoFalseBoost

    @Test("Unknown nickname 'Xyz' does not trigger false boost")
    func testUnknownNicknameNoFalseBoost() throws {
        // Filters contain "smith" and "william"; "xyz" is not in the table.
        let surnameFilter = try buildFilter(keys: ["smith"])
        let givenFilter = try buildFilter(keys: ["william"])
        let nicknames = NicknameGazetteer(entries: ["bill": ["william"]])

        let gazetteer = NameGazetteer(
            surnameFilter: surnameFilter,
            givenNameFilter: givenFilter,
            manifest: makeManifest(),
            nicknameGazetteer: nicknames)

        // "Xyz Smith" → surname=smith (hit), given=xyz (miss), xyz not in table → no canonical hit
        let verdict = gazetteer.queryBoosted(candidate: "Xyz Smith")
        #expect(verdict.boost == 0.10,
                "'Xyz' is not in the nickname table; given-name lookup must not fire → boost 0.10")
        #expect(verdict.surnameHit == true)
        #expect(verdict.givenHit == false,
                "givenHit should stay false when alias is unknown and no canonical resolves")
    }

    // MARK: - Adversarial: bob → robert

    @Test("Adversarial: 'bob' tagged as personalName → canonical 'robert' in filter → boost fires")
    func testBobToRobertAdversarial() throws {
        // This exercises the design's adversarial case (design line 1038):
        // "bob jones" — bob is a name here (NLTagger context assumed), not a verb phrase.
        // Filter has "jones" (surname) and "robert" (given). Table maps bob → robert.
        let surnameFilter = try loadGoldenFilter()  // "jones" is in golden-1000
        let givenFilter = try buildFilter(keys: ["robert"])
        let nicknames = NicknameGazetteer(entries: ["bob": ["robert"]])

        let gazetteer = NameGazetteer(
            surnameFilter: surnameFilter,
            givenNameFilter: givenFilter,
            manifest: makeManifest(),
            nicknameGazetteer: nicknames)

        let verdict = gazetteer.queryBoosted(candidate: "Bob Jones")
        #expect(verdict.boost == 0.15,
                "'bob' resolves to 'robert' which is in the given filter, 'jones' in surname → 0.15")
        #expect(verdict.surnameHit == true)
        #expect(verdict.givenHit == true,
                "givenHit must be true when nickname resolution produces a canonical bloom hit")
    }

    // MARK: - nil nicknameGazetteer: behavior byte-identical to today

    @Test("nil nicknameGazetteer: queryBoosted output is unchanged from pre-S5")
    func testNilNicknameGazetteerPreservesExistingBehavior() throws {
        let filter = try loadGoldenFilter()
        let manifest = makeManifest()
        // Baseline: no nickname gazetteer.
        let g = NameGazetteer(
            surnameFilter: filter,
            givenNameFilter: filter,
            manifest: manifest,
            nicknameGazetteer: nil)
        // "garcia smith" — both in golden-1000 → boost 0.15 as before.
        let verdict = g.queryBoosted(candidate: "garcia smith")
        #expect(verdict.boost == 0.15)
        #expect(verdict.surnameHit == true)
        #expect(verdict.givenHit == true)
    }

    // MARK: - Helpers

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
}

// MARK: - LE append helper (test-only; mirrors BloomFilterTests private extension)

private extension Data {
    mutating func appendTestLE<T: FixedWidthInteger>(_ value: T) {
        let le = value.littleEndian
        let size = MemoryLayout<T>.size
        for i in 0..<size {
            append(UInt8(truncatingIfNeeded: le >> (i * 8)))
        }
    }
}
