import Testing
import Foundation
@testable import RedactionEngine

// The common-word curation sidecar (`name-common-words.json`) and what the
// name gazetteer does with it: a surname candidate that is an exact member
// earns no surname credit — not the exact credit, not the fuzzy fallback —
// while its Bloom membership is still reported (the strict pass's hit set
// is unchanged; only the score and the first pass's support reading move).
// The Bloom filters are never edited: demote, never strip.
//
// Section A: the loader (bundle, fence, normalization).
// Section B: the withholding on the golden-1000 filter (deterministic).
// Section C: the pins — the list is exactly the engine's `nonNames` sample
// (the two cannot drift), the G8 corpus's name tokens are disjoint from it
// (the TP-held invariant of the pass-1 gate), and dictionary words that are
// common surnames stay outside it (the list is not a dictionary gate).
// Section D: the production filter — reports how many members the shipped
// inventory carries (a membership number, not a false-positive rate).
//
// Synthetic Hartwell/Sablebrook cast only (repo test-data policy).

@Suite("Name common-word curation (surname credit withheld for list members)")
struct NameCommonWordsTests {

    // MARK: - A. Loader

    @Test("The shipped sidecar loads: 546 unique NFKC-lowercased words, fence 1...1")
    func shippedSidecarLoads() throws {
        let words = try NameCommonWords()
        #expect(words.count == 546)
        #expect(NameCommonWords.supportedVersions == 1...1)
        for w in words.entries {
            #expect(w == TextNormalizer.normalize(w).lowercased())
            #expect(!w.isEmpty && !w.contains(" "))
        }
        for w in ["the", "table", "employer", "river"] {
            #expect(words.contains(w), "\(w) must be a member")
        }
    }

    @Test("Empty bundle throws resourceMissing")
    func emptyBundleThrows() {
        let empty = Bundle(for: NSObject.self)
        #expect(throws: NameCommonWords.LoaderError.self) {
            _ = try NameCommonWords(bundle: empty)
        }
    }

    @Test("Lookup normalizes case and compatibility forms like the Bloom key")
    func lookupNormalizes() {
        let words = NameCommonWords(words: ["The", "Table", "ﬁle"])
        #expect(words.contains("THE"))
        #expect(words.contains("table"))
        #expect(words.contains("file"))   // NFKC folds the ligature
        #expect(!words.contains("thee"))
        #expect(words.count == 3)
    }

    // MARK: - B. Withholding on the golden filter

    private func goldenFilter() throws -> BloomFilter {
        let url = try #require(Bundle.module.url(forResource: "golden-1000",
                                                 withExtension: "bloom",
                                                 subdirectory: "TestResources"))
        return try BloomFilter(data: Data(contentsOf: url))
    }

    /// golden-1000 members: smith, jones, garcia, lopez, james. The curation
    /// list here names `smith` and `garcia` as common words so the withholding
    /// is exercised on a token the filter genuinely contains.
    private func gazetteer(curating words: [String]) throws -> NameGazetteer {
        let filter = try goldenFilter()
        return NameGazetteer(surnameFilter: filter, givenNameFilter: filter,
                             commonWords: NameCommonWords(words: words))
    }

    @Test("A list member that the filter contains: membership reported, credit withheld, no support")
    func memberInFilter_creditWithheld() throws {
        let g = try gazetteer(curating: ["smith"])
        let v = g.queryBoosted(candidate: "Smith")
        #expect(v.surnameHit, "the Bloom membership is a fact the verdict keeps")
        #expect(v.commonWordSurname)
        #expect(v.boost == 0.0)
        #expect(v.hadAnyHit, "the strict pass still counts the membership")
        #expect(!v.hadSupport, "the first pass does not")
        #expect(!v.fuzzySurnameHit && !v.givenHit)
    }

    @Test("A list member with a given-name hit: the pair credit is withheld too")
    func memberWithGiven_pairWithheld() throws {
        let g = try gazetteer(curating: ["smith"])
        let v = g.queryBoosted(candidate: "James Smith")
        #expect(v.commonWordSurname)
        #expect(v.boost == 0.0)
        #expect(!v.hadSupport)
    }

    @Test("A list member the filter does not contain: no fuzzy fallback, verdict is unsupported")
    func memberNotInFilter_noFuzzy() throws {
        // "jone" is Levenshtein-1 from golden member "jones": without the
        // curation it would earn the fuzzy 0.05; as a member it earns nothing.
        let plain = try gazetteer(curating: [])
        #expect(plain.queryBoosted(candidate: "Jone", fuzzy: true).fuzzySurnameHit)
        let curated = try gazetteer(curating: ["jone"])
        let v = curated.queryBoosted(candidate: "Jone", fuzzy: true)
        #expect(!v.surnameHit && !v.fuzzySurnameHit)
        #expect(v.commonWordSurname)
        #expect(v.boost == 0.0)
        #expect(!v.hadAnyHit && !v.hadSupport)
    }

    @Test("A non-member surname is unchanged: exact credit, pair credit, fuzzy credit")
    func nonMember_unchanged() throws {
        let g = try gazetteer(curating: ["smith"])
        #expect(g.queryBoosted(candidate: "Garcia").boost == 0.10)
        #expect(g.queryBoosted(candidate: "James Garcia").boost == 0.15)
        let fuzzy = g.queryBoosted(candidate: "Garcio", fuzzy: true)
        #expect(fuzzy.fuzzySurnameHit && fuzzy.boost == 0.05)
        for v in [g.queryBoosted(candidate: "Garcia"), g.queryBoosted(candidate: "James Garcia"), fuzzy] {
            #expect(!v.commonWordSurname && v.hadSupport)
        }
    }

    @Test("No sidecar → no demotion (fail-open)")
    func noSidecar_noDemotion() throws {
        let filter = try goldenFilter()
        let g = NameGazetteer(surnameFilter: filter, givenNameFilter: filter)
        let v = g.queryBoosted(candidate: "Smith")
        #expect(v.boost == 0.10 && !v.commonWordSurname && v.hadSupport)
    }

    @Test("The curation reads the surname token only: a hyphenated surname is not a member")
    func hyphenatedSurname_notMember() throws {
        let g = try gazetteer(curating: ["smith"])
        // "Garcia-Smith": the joined token is not a member; components split
        // as before (garcia hits, smith hits) → full surname credit.
        let v = g.queryBoosted(candidate: "Garcia-Smith")
        #expect(!v.commonWordSurname)
        #expect(v.surnameHit && v.boost == 0.10)
    }

    // MARK: - C. Pins

    @Test("The sidecar is exactly the engine's non-name sample (no drift)")
    func sidecarEqualsNonNamesSample() throws {
        let words = try NameCommonWords()
        let sample = Set(BloomFilterFPRTests.nonNames.map { TextNormalizer.normalize($0).lowercased() })
        #expect(sample == words.entries)
        #expect(BloomFilterFPRTests.nonNames.count == 549)
        #expect(sample.count == 546, "three authored duplicates collapse")
    }

    @Test("The 129 distinct G8 corpus name tokens are all outside the list")
    func g8NameTokensDisjoint() throws {
        let words = try NameCommonWords()
        let url = try #require(Bundle.module.url(forResource: "g8_corpus", withExtension: "json",
                                                 subdirectory: "corpus"))
        let corpus = try JSONDecoder().decode(G8BaselineHarnessTests.BaselineG8Corpus.self,
                                              from: Data(contentsOf: url))
        var tokens = Set<String>()
        for doc in corpus.documents {
            let ns = doc.text as NSString
            for span in doc.pii_spans where span.category == "name" {
                let value = ns.substring(with: NSRange(location: span.start, length: span.end - span.start))
                for raw in value.replacingOccurrences(of: ",", with: " ").split(separator: " ") {
                    let t = TextNormalizer.normalize(String(raw)).lowercased()
                        .trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
                    if !t.isEmpty { tokens.insert(t) }
                }
            }
        }
        #expect(tokens.count == 129, "the G8 name-token inventory moved (\(tokens.count)); re-pin with the corpus")
        let overlap = tokens.intersection(words.entries)
        #expect(overlap.isEmpty, "G8 name tokens in the common-word list: \(overlap.sorted())")
    }

    @Test("Dictionary words that are common surnames are NOT members (not a dictionary gate)")
    func commonSurnamesStayOut() throws {
        let words = try NameCommonWords()
        for w in ["brown", "park", "hill", "bill", "clinton", "madison"] {
            #expect(!words.contains(w), "\(w) must stay outside the curation")
        }
    }

    // MARK: - D. The production filter (report-only membership count)

    @Test("Production inventory: list members the surname filter carries are demoted, never stripped")
    func productionMembersDemoted() throws {
        guard let g = NameGazetteer() else {
            print("[common-words] NameGazetteer resources absent; skipped until `make install-assets` runs.")
            return
        }
        let words = try NameCommonWords()
        let members = words.entries.filter { g.surnameFilter.contains($0) }.sorted()
        print("[common-words] production surname-filter membership of the list: \(members.count)/\(words.count)")
        #expect(!members.isEmpty, "the multilingual inventory carries some English words")
        for w in members.prefix(50) {
            let v = g.queryBoosted(candidate: w.capitalized)
            #expect(v.surnameHit && v.commonWordSurname && v.boost == 0.0 && !v.hadSupport,
                    "\(w): membership must be reported and the credit withheld")
        }
        // A curated word the filter does NOT carry stays unsupported and gets
        // no fuzzy fallback either.
        if let absent = words.entries.first(where: { !g.surnameFilter.contains($0) }) {
            let v = g.queryBoosted(candidate: absent.capitalized, fuzzy: true)
            #expect(!v.hadAnyHit && v.commonWordSurname && v.boost == 0.0)
        }
        // Dictionary surnames keep their credit.
        #expect(g.queryBoosted(candidate: "Brown").boost >= 0.10)
        #expect(g.queryBoosted(candidate: "Park").boost >= 0.10)
    }
}
