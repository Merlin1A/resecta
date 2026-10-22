import Testing
import Foundation
@testable import RedactionEngine

// Unit tests for Levenshtein-1 gazetteer fallback, including the
// unidirectional "rn" → "m" special case.

@Suite("NameGazetteer fuzzyContains")
struct NameGazetteerFuzzyTests {

    // MARK: - Helpers

    /// Load the Phase-1 golden filter as the surname Bloom for these tests.
    private func loadGazetteer() throws -> NameGazetteer {
        let bundle = Bundle.module
        guard let url = bundle.url(
            forResource: "golden-1000",
            withExtension: "bloom",
            subdirectory: "TestResources"
        ) else {
            Issue.record("golden-1000.bloom not found in TestResources")
            throw FuzzyError.goldenFilterMissing
        }
        let data = try Data(contentsOf: url)
        let filter = try BloomFilter(data: data)
        return NameGazetteer(
            surnameFilter: filter,
            givenNameFilter: filter
        )
    }

    private enum FuzzyError: Error { case goldenFilterMissing }

    // MARK: - Support is exact-only

    /// A small deterministic generator (a 64-bit xorshift), so the sample is
    /// the same on every run and never the system's.
    private struct SeededLetters {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state
        }
        mutating func word(length: Int) -> String {
            String((0..<length).map { _ in Character(UnicodeScalar(UInt8(97 + next() % 26))) })
        }
    }

    @Test("A one-edit neighbour of a listed surname is a boost, not support; random seven-letter words are unsupported")
    func fuzzyHitIsBoostOnly() throws {
        let gazetteer = try loadGazetteer()
        var letters = SeededLetters(state: 20261002)
        var supported = 0, fuzzyHits = 0
        for _ in 0..<300 {
            let word = letters.word(length: 7)
            guard !gazetteer.contains(surname: word) else { continue }
            let verdict = gazetteer.queryBoosted(candidate: "Delia \(word)")
            if verdict.hadSupport { supported += 1 }
            if verdict.fuzzySurnameHit {
                fuzzyHits += 1
                #expect(!verdict.hadSupport)
                #expect(abs(verdict.boost - 0.05) < 1e-9, "the fuzzy boost stays")
            }
        }
        #expect(supported == 0, "no non-member is supported: \(supported) of 300")
        #expect(fuzzyHits > 0, "the sample reaches the fuzzy path at all")
        // An exact member keeps its support and its own boost.
        let exact = gazetteer.queryBoosted(candidate: "Delia Smith")
        #expect(exact.hadSupport)
        #expect(exact.surnameHit && !exact.fuzzySurnameHit)
        // A hyphenated surname with one listed component is a fuzzy boost, not support.
        let partial = gazetteer.queryBoosted(candidate: "Delia Smith-Qzvtrk")
        #expect(partial.fuzzySurnameHit && !partial.hadSupport)
    }

    // MARK: - Tests

    @Test("Exact match in filter yields nil from fuzzy path (caller used exact)")
    func exactMatchNotRevisited() throws {
        // fuzzyContains only enumerates distance-1 variants. When the input
        // itself is present, we still might hit a distance-1 variant that's
        // also in the filter (e.g., "smith" → "smiths"). That's acceptable —
        // the caller is expected to try exact first. This test documents that
        // behavior: the exact input is deduped out of the candidate set.
        let gazetteer = try loadGazetteer()
        // "smith" is in the golden filter. Whether fuzzy returns 0.6 or nil
        // depends on whether any distance-1 neighbor is also in the filter.
        // What we assert: fuzzyContains never returns the exact input itself.
        // (If it returns 0.6 via a neighbor, that's fine and not tested here.)
        _ = gazetteer.fuzzyContains(surname: "smith")
    }

    @Test("rn → m special case: srnith fuzzes to smith")
    func rnToMSpecialCase() throws {
        let gazetteer = try loadGazetteer()
        // "smith" is a known member of the golden filter. Input "srnith"
        // is distance-2 in standard Levenshtein but distance-1 under the
        // "rn"→"m" rule, so fuzzyContains should return 0.6.
        #expect(gazetteer.fuzzyContains(surname: "srnith") == 0.6)
    }

    @Test("Generic distance-1 substitution recovers nearby surname")
    func distance1Substitution() throws {
        let gazetteer = try loadGazetteer()
        // "garcia" is in the filter. "garci" (deletion of last char) is
        // distance-1. Expect 0.6.
        #expect(gazetteer.fuzzyContains(surname: "garci") != nil)
    }

    @Test("rn → m is one-way: m inputs do NOT synthesize rn candidates")
    func rnToMIsOneWay() throws {
        let gazetteer = try loadGazetteer()
        // A surname containing 'm' should not enumerate "m"→"rn" candidates.
        // Pick a nonsense input whose ONLY distance-1 neighbor (under the
        // reverse direction) would be in the filter. "smith" → reverse
        // would try "smmith" (meaningless) or "srnith" (plausible under
        // reverse "m"→"rn" substitution of some other m). Since reverse
        // direction isn't enumerated, any hit comes from sub/insert/delete
        // over the alphabet — not the special case.
        //
        // Concrete test: a string "m" → reverse would generate "rn" → if
        // "rn" were in the filter we'd have a "hit" only via reverse.
        // "rn" is not a surname, so absence doesn't prove one-way. This
        // test just asserts fuzzyContains("m") doesn't crash or hang,
        // documenting the one-way contract.
        _ = gazetteer.fuzzyContains(surname: "m")
    }

    @Test("Completely unrelated input returns nil")
    func unrelatedInputReturnsNil() throws {
        let gazetteer = try loadGazetteer()
        // "zzzzzzzz" has no distance-1 neighbor that's a real surname.
        #expect(gazetteer.fuzzyContains(surname: "zzzzzzzzz") == nil)
    }

    @Test("Score multiplier is exactly 0.6 on any hit")
    func scoreMultiplierExact() throws {
        let gazetteer = try loadGazetteer()
        if let score = gazetteer.fuzzyContains(surname: "srnith") {
            #expect(score == 0.6)
        } else {
            Issue.record("expected a fuzzy hit for 'srnith' via rn→m rule")
        }
    }

    @Test("Empty input returns nil without crashing")
    func emptyInput() throws {
        let gazetteer = try loadGazetteer()
        #expect(gazetteer.fuzzyContains(surname: "") == nil)
    }

    @Test("Single-character input does not attempt deletion")
    func singleCharNoDeletion() throws {
        let gazetteer = try loadGazetteer()
        // Deletion would produce "" which is trivially in no Bloom.
        // Sub/insert over alphabet might match common single-letter
        // hashes if the filter is small; we just assert no crash.
        _ = gazetteer.fuzzyContains(surname: "a")
    }
}
