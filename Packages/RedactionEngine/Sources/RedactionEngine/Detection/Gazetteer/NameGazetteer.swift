import Foundation
import OSLog

// G2a: Name gazetteer backed by dual Bloom filters.
// Loads pre-built .bloom files from Bundle.module at init time.
// Phase 2 staging — consumed by Phase 3 G1 detectors and A2 integration.

/// Bloom-filter-backed name gazetteer for surname and given-name membership queries.
///
/// Filters are pre-built by `Scripts/gazetteer/build_bloom.py` at dev time
/// and shipped as compiled resources in `Resources/Gazetteers/`.
/// All inputs are NFKC-normalized and lowercased before lookup,
/// matching the build pipeline's preprocessing.
public struct NameGazetteer: Sendable {

    public enum LoaderError: Error {
        case resourceMissing
        case decodingFailed(underlying: Error)
        case unsupportedManifestVersion(actual: String, supported: Set<String>)
    }

    // W-O — Q2 path (B). The manifest's `version` field is a semver String
    // (`"1.0.0"`, not an Int), so the standard `LoaderVersionFence.assert(...)`
    // helper (Int / ClosedRange<Int>) doesn't apply. Pattern uses Set<String>
    // and inlines the membership check.
    private static let supportedManifestVersions: Set<String> = ["1.0.0"]

    /// Surname Bloom filter (Census + Spanish + ParaNames + PopNames).
    public let surnameFilter: BloomFilter

    /// Given-name Bloom filter (SSA + ParaNames + PopNames).
    public let givenNameFilter: BloomFilter

    /// Manifest with provenance and filter parameters.
    public let manifest: GazetteerManifest

    /// Optional nickname sidecar — nil when the file is not yet bundled.
    /// When non-nil, `queryBoosted` uses it to widen given-name bloom queries
    /// via nickname→canonical resolution.
    private let nicknameGazetteer: NicknameGazetteer?

    // MARK: - Init

    /// Load gazetteer from bundled resources.
    /// Returns `nil` if any resource file is missing (safe for test contexts
    /// where Bundle.module resources may not be available).
    public init?() {
        guard let surnameURL = Bundle.module.url(
                  forResource: "surnames", withExtension: "bloom",
                  subdirectory: "Gazetteers"),
              let givenURL = Bundle.module.url(
                  forResource: "given-names", withExtension: "bloom",
                  subdirectory: "Gazetteers"),
              let manifestURL = Bundle.module.url(
                  forResource: "gazetteer-manifest", withExtension: "json",
                  subdirectory: "Gazetteers")
        else { return nil }

        do {
            let surnameData = try Data(contentsOf: surnameURL)
            let givenData = try Data(contentsOf: givenURL)
            let manifestData = try Data(contentsOf: manifestURL)

            self.surnameFilter = try BloomFilter(data: surnameData)
            self.givenNameFilter = try BloomFilter(data: givenData)
            self.manifest = try JSONDecoder().decode(
                GazetteerManifest.self, from: manifestData)
            // Nickname sidecar is optional: its absence does not fail the init.
            self.nicknameGazetteer = try? NicknameGazetteer(bundle: Bundle.module)
        } catch {
            return nil
        }
    }

    /// W-O — paired throwing init alongside `init?()`. Surfaces resource-
    /// missing, decode failure, and manifest-version-fence rejection as
    /// typed errors rather than collapsing them to nil. Closes the silent-
    /// decode-of-future-schema class for the manifest's String version field
    /// (Q2 path B; `Set<String>` rather than `ClosedRange<Int>`).
    public init(throwingFromBundle bundle: Bundle) throws {
        guard let manifestURL = bundle.url(
                  forResource: "gazetteer-manifest", withExtension: "json",
                  subdirectory: "Gazetteers"),
              let surnameURL = bundle.url(
                  forResource: "surnames", withExtension: "bloom",
                  subdirectory: "Gazetteers"),
              let givenURL = bundle.url(
                  forResource: "given-names", withExtension: "bloom",
                  subdirectory: "Gazetteers")
        else {
            logger.info("name-gazetteer assets not bundled; throwing resourceMissing")
            throw LoaderError.resourceMissing
        }

        // Decode + version-fence the manifest first so a future-schema bundle
        // is rejected before the (potentially expensive) Bloom-filter parse.
        let manifest: GazetteerManifest
        do {
            let manifestData = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(GazetteerManifest.self, from: manifestData)
        } catch {
            logger.warning("gazetteer-manifest.json decode failed: \(String(describing: error), privacy: .public)")
            throw LoaderError.decodingFailed(underlying: error)
        }

        guard Self.supportedManifestVersions.contains(manifest.version) else {
            logger.warning(
                "gazetteer-manifest.json version \(manifest.version, privacy: .public) outside supported set"
            )
            throw LoaderError.unsupportedManifestVersion(
                actual: manifest.version,
                supported: Self.supportedManifestVersions
            )
        }

        let surnameFilter: BloomFilter
        let givenFilter: BloomFilter
        do {
            let surnameData = try Data(contentsOf: surnameURL)
            let givenData = try Data(contentsOf: givenURL)
            surnameFilter = try BloomFilter(data: surnameData)
            givenFilter = try BloomFilter(data: givenData)
        } catch {
            logger.warning("name-gazetteer bloom decode failed: \(String(describing: error), privacy: .public)")
            throw LoaderError.decodingFailed(underlying: error)
        }

        self.surnameFilter = surnameFilter
        self.givenNameFilter = givenFilter
        self.manifest = manifest
        // Nickname sidecar is optional: its absence does not fail the init.
        self.nicknameGazetteer = try? NicknameGazetteer(bundle: bundle)
    }

    /// Init from explicit filter data (for testing with golden files).
    public init(surnameFilter: BloomFilter, givenNameFilter: BloomFilter,
                manifest: GazetteerManifest,
                nicknameGazetteer: NicknameGazetteer? = nil) {
        self.surnameFilter = surnameFilter
        self.givenNameFilter = givenNameFilter
        self.manifest = manifest
        self.nicknameGazetteer = nicknameGazetteer
    }

    // MARK: - Queries

    /// Check whether a surname is in the gazetteer.
    /// Input is NFKC-normalized and lowercased before lookup.
    public func contains(surname: String) -> Bool {
        surnameFilter.contains(surname)
    }

    /// Check whether a given name is in the gazetteer.
    /// Input is NFKC-normalized and lowercased before lookup.
    public func contains(givenName: String) -> Bool {
        givenNameFilter.contains(givenName)
    }

    /// Check whether both a given name and surname are in their respective filters.
    /// Used for NLTagger confirmation in Phase 3 A2 integration.
    public func contains(adjacent pair: (given: String, surname: String)) -> Bool {
        contains(givenName: pair.given) && contains(surname: pair.surname)
    }

    // MARK: - W2 Boosted Lookup

    /// Structured verdict for the NLTagger boost path: which filters hit,
    /// whether fuzzy was used, and the bounded confidence boost the caller
    /// should apply to its base score.
    public struct NameGazetteerVerdict: Sendable, Equatable {
        public let surnameHit: Bool
        public let givenHit: Bool
        public let fuzzySurnameHit: Bool
        /// Score multiplier returned by `fuzzyContains` when the fuzzy path
        /// hit; `nil` otherwise. Stable at 0.6 today but surfaced so callers
        /// can persist the value into `MatchRationale.bloomFuzzySurnameHit`.
        public let fuzzyScore: Double?
        /// 0.00, 0.05, 0.10, or 0.15. See W2 boost table in the plan.
        public let boost: Double

        public var hadAnyHit: Bool { surnameHit || givenHit || fuzzySurnameHit }

        public static let none = NameGazetteerVerdict(
            surnameHit: false, givenHit: false, fuzzySurnameHit: false,
            fuzzyScore: nil, boost: 0.0
        )
    }

    /// Name suffixes to strip before gazetteer lookup.
    /// Generational, professional credential, and retirement suffixes.
    /// Lowercased for case-insensitive comparison against lowercased token.
    /// ENGINE §4.12 / WS1 item 1.12 (2026-06-10).
    private static let nameSuffixes: Set<String> = [
        // Generational
        "jr", "jr.", "sr", "sr.", "ii", "iii", "iv", "v",
        // Professional credentials
        "esq", "esq.", "md", "m.d.", "do", "d.o.", "phd", "ph.d.",
        "jd", "j.d.", "llm", "l.l.m.", "mba", "m.b.a.",
        "rn", "r.n.", "np", "n.p.", "pa", "p.a.", "crna",
        "dds", "d.d.s.", "dmd", "d.m.d.", "od", "o.d.",
        "cpa", "c.p.a.", "cfa", "cfp",
        // Retirement
        "ret", "ret."
    ]

    /// Strip trailing name suffixes from a token array.
    /// Removes tokens (case-insensitively) that match the suffix set, working
    /// from the end. Stops at the first non-suffix token.
    /// Degradation: if all tokens are suffixes the result is empty;
    /// the caller's `guard let surname = tokens.last` returns .none.
    private static func stripSuffixes(from tokens: [String]) -> [String] {
        var result = tokens
        while let last = result.last,
              Self.nameSuffixes.contains(last.lowercased()) {
            result.removeLast()
        }
        return result
    }

    /// Resolve an NLTagger name candidate against both filters and return a
    /// bounded boost. Splits on whitespace; strips trailing name suffixes;
    /// the trailing token is queried as a surname, prior tokens joined with
    /// a space as a given-name query. Hyphenated surnames are decomposed into
    /// components for independent lookup when the joined form misses.
    ///
    /// Boost table (W2):
    /// - exact surname + given → +0.15
    /// - exact surname only    → +0.10
    /// - all hyphen components hit (+ given hit) → +0.15 / +0.10
    /// - partial hyphen component hit → +0.05
    /// - fuzzy surname only    → +0.05 (only when `fuzzy == true`)
    /// - otherwise             →  0.00
    ///
    /// `fuzzy: false` disables the Levenshtein-1 fallback — the ALL-CAPS
    /// strict pass passes `false` so suppress-on-miss behavior is consistent
    /// with an exact-membership check.
    ///
    /// Nickname widening: when `givenHit` is
    /// false and the given token is non-empty, the method re-queries each
    /// canonical form from the optional `nicknameGazetteer` table with early
    /// exit.  The FPR increase is bounded by the NLTagger `.personalName`
    /// pre-filter: common English words that share surface forms with
    /// nicknames ("bob", "bill") are filtered before the bloom query.
    public func queryBoosted(
        candidate: String,
        fuzzy: Bool = true
    ) -> NameGazetteerVerdict {
        // WS1 item 1.12: strip trailing suffixes before surname/given split.
        let rawTokens = candidate.split(separator: " ", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        let tokens = Self.stripSuffixes(from: rawTokens)

        guard let surname = tokens.last else { return .none }
        let given = tokens.dropLast().joined(separator: " ")

        let surnameHit = contains(surname: surname)
        let givenHit = !given.isEmpty && contains(givenName: given)

        // If the given-name bloom misses,
        // re-query each canonical form from the nickname table with early exit.
        let resolvedGivenHit = givenHit || (!given.isEmpty && (nicknameGazetteer?.canonicals(for: given) ?? []).contains { contains(givenName: $0) })

        if surnameHit && resolvedGivenHit {
            return NameGazetteerVerdict(
                surnameHit: true, givenHit: true, fuzzySurnameHit: false,
                fuzzyScore: nil, boost: 0.15
            )
        }
        if surnameHit {
            return NameGazetteerVerdict(
                surnameHit: true, givenHit: false, fuzzySurnameHit: false,
                fuzzyScore: nil, boost: 0.10
            )
        }

        // WS1 item 1.12: hyphenated surname component lookup.
        // "Garcia-Lopez" → check "Garcia" and "Lopez" independently.
        // All components hit → treat as exact surname hit (boost 0.15 if given also
        // hit, else 0.10). Any component hit → fuzzy boost 0.05.
        // Cite: design §8b (2026-06-10).
        if !surnameHit, surname.contains("-") {
            let components = surname.split(separator: "-").map(String.init)
            let componentHits = components.filter { contains(surname: $0) }
            if componentHits.count == components.count {
                // All components hit → full surname credit.
                return NameGazetteerVerdict(
                    surnameHit: true, givenHit: resolvedGivenHit, fuzzySurnameHit: false,
                    fuzzyScore: nil, boost: resolvedGivenHit ? 0.15 : 0.10
                )
            } else if !componentHits.isEmpty {
                // Partial component hit → fuzzy boost.
                return NameGazetteerVerdict(
                    surnameHit: false, givenHit: resolvedGivenHit, fuzzySurnameHit: true,
                    fuzzyScore: 0.8, boost: 0.05
                )
            }
        }

        if fuzzy, let fuzzyScore = fuzzyContains(surname: surname) {
            return NameGazetteerVerdict(
                surnameHit: false, givenHit: resolvedGivenHit, fuzzySurnameHit: true,
                fuzzyScore: fuzzyScore, boost: 0.05
            )
        }
        return .none
    }

    // MARK: - Fuzzy lookup (G6, Phase 2)

    /// Levenshtein-1 fallback over the surname filter. Called after
    /// `contains(surname:)` returns `false` when the caller wants to
    /// accept lower-confidence OCR errors.
    ///
    /// Enumerates all edit-distance-1 candidates (substitution, deletion,
    /// insertion across `a-z`) plus the `"rn" → "m"` special case (treated
    /// as a single logical edit, one-way only per plan text). Candidates
    /// are deduped and queried against the Bloom filter on the fly; returns
    /// `0.6` on the first hit (plan's score multiplier) or `nil` if no
    /// variant matches.
    ///
    /// The search is ASCII-only for the enumeration alphabet — non-ASCII
    /// inputs still work for exact matches (Bloom normalizes), but distance-1
    /// variants of diacritic surnames will not be enumerated. Document OCR
    /// is overwhelmingly ASCII so this is an acceptable simplification for
    /// Phase 2; Phase 3 can extend the alphabet if needed.
    ///
    /// Phase-2 scope: no production call site yet. Phase-3 name / address
    /// detectors will be first callers.
    internal func fuzzyContains(surname: String) -> Double? {
        let input = TextNormalizer.normalize(surname).lowercased()
        guard !input.isEmpty else { return nil }

        var tried: Set<String> = [input]

        // Special case first: "rn" → "m" (most common OCR name error).
        if input.contains("rn") {
            let chars = Array(input)
            var i = 0
            while i < chars.count - 1 {
                if chars[i] == "r" && chars[i + 1] == "n" {
                    var candidate = chars
                    candidate.replaceSubrange(i...(i + 1), with: ["m"])
                    let str = String(candidate)
                    if tried.insert(str).inserted, surnameFilter.contains(str) {
                        return 0.6
                    }
                }
                i += 1
            }
        }

        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        let chars = Array(input)

        // Substitutions: L * 26
        for pos in 0..<chars.count {
            for c in alphabet where c != chars[pos] {
                var candidate = chars
                candidate[pos] = c
                let str = String(candidate)
                if tried.insert(str).inserted, surnameFilter.contains(str) {
                    return 0.6
                }
            }
        }

        // Deletions: L
        if chars.count > 1 {
            for pos in 0..<chars.count {
                var candidate = chars
                candidate.remove(at: pos)
                let str = String(candidate)
                if tried.insert(str).inserted, surnameFilter.contains(str) {
                    return 0.6
                }
            }
        }

        // Insertions: (L+1) * 26
        for pos in 0...chars.count {
            for c in alphabet {
                var candidate = chars
                candidate.insert(c, at: pos)
                let str = String(candidate)
                if tried.insert(str).inserted, surnameFilter.contains(str) {
                    return 0.6
                }
            }
        }

        return nil
    }
}

private let logger = Logger(subsystem: "app.resecta.engine", category: "NameGazetteer")
