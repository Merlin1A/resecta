import Foundation

// ENGINE §6.3a — Byte-oriented Aho-Corasick multi-pattern matcher for Layer 3.
// Pure Swift on UnsafeBufferPointer. Length-prefixed patterns (null-byte safe).
// Overlapping match support via output links.

/// A match found by the Aho-Corasick automaton.
public struct AhoCorasickMatch: Sendable {
    /// Byte offset in the input where the match starts.
    public let position: Int
    /// Index of the pattern that matched (in the order added).
    public let patternIndex: Int
    /// Length of the matched pattern in bytes.
    public let length: Int
}

/// Byte-oriented Aho-Corasick automaton for multi-pattern string search.
/// Operates on raw bytes, not Swift Strings. Each pattern is a `[UInt8]`
/// array (length-prefixed, null-byte safe for UTF-16 encodings).
/// See ENGINE §6.3a for requirements.
public struct AhoCorasick: Sendable {
    private let goto: [[UInt8: Int]]     // goto function: state × byte → state
    private let fail: [Int]               // failure function
    private let output: [[Int]]           // output function: state → pattern indices
    private let patternLengths: [Int]     // length of each pattern

    /// True when total pattern bytes exceeded maxTotalPatternBytes and the
    /// automaton was constructed as a no-op. Callers should treat matches
    /// as incomplete when this is set. See ENGINE §6.3a.
    public let isDegraded: Bool

    /// Maximum total pattern bytes before the automaton degrades to a no-op.
    /// 1 MB supports ~250K terms in UTF-8 — far beyond any realistic PII set.
    /// Guards against pathological input causing unbounded memory allocation.
    private static let maxTotalPatternBytes = 1_000_000

    /// Build the automaton from a set of byte patterns.
    /// Construction is O(sum of pattern lengths).
    /// If total pattern bytes exceed maxTotalPatternBytes, produces an empty
    /// automaton (zero matches) to prevent unbounded memory allocation.
    public init(patterns: [[UInt8]]) {
        // ENGINE §6.3a: Bounds check — prevent pathological automaton construction
        let totalBytes = patterns.reduce(0) { $0 + $1.count }
        if totalBytes > Self.maxTotalPatternBytes {
            self.goto = [[:]]
            self.fail = [0]
            self.output = [[]]
            self.patternLengths = []
            self.isDegraded = true
            return
        }

        var gotoTable: [[UInt8: Int]] = [[:]]  // State 0 = root
        var outputTable: [[Int]] = [[]]
        var lengths: [Int] = []

        // Phase 1: Build goto function (trie)
        for (patIdx, pattern) in patterns.enumerated() {
            lengths.append(pattern.count)
            var state = 0
            for byte in pattern {
                if let next = gotoTable[state][byte] {
                    state = next
                } else {
                    let newState = gotoTable.count
                    gotoTable.append([:])
                    outputTable.append([])
                    gotoTable[state][byte] = newState
                    state = newState
                }
            }
            outputTable[state].append(patIdx)
        }

        // Phase 2: Build failure function via BFS
        let stateCount = gotoTable.count
        var failTable = Array(repeating: 0, count: stateCount)
        var queue: [Int] = []

        // Depth-1 states: failure → root
        for (_, nextState) in gotoTable[0] {
            failTable[nextState] = 0
            queue.append(nextState)
        }

        // BFS for deeper states
        var queueIdx = 0
        while queueIdx < queue.count {
            let r = queue[queueIdx]
            queueIdx += 1

            for (byte, s) in gotoTable[r] {
                queue.append(s)
                var state = failTable[r]
                while state != 0 && gotoTable[state][byte] == nil {
                    state = failTable[state]
                }
                failTable[s] = gotoTable[state][byte] ?? 0
                if failTable[s] == s { failTable[s] = 0 }
                // Merge output links (dictionary suffix links)
                outputTable[s] += outputTable[failTable[s]]
            }
        }

        self.goto = gotoTable
        self.fail = failTable
        self.output = outputTable
        self.patternLengths = lengths
        self.isDegraded = false
    }

    /// Search input bytes for all pattern occurrences.
    /// Returns matches in order of position. Overlapping matches are reported.
    /// Time: O(n + z) where n = input length, z = number of matches.
    public func search(_ data: UnsafeBufferPointer<UInt8>) -> [AhoCorasickMatch] {
        var matches: [AhoCorasickMatch] = []
        var state = 0

        for i in 0..<data.count {
            let byte = data[i]

            // Follow failure links until we find a transition or reach root
            while state != 0 && goto[state][byte] == nil {
                state = fail[state]
            }
            state = goto[state][byte] ?? 0

            // Report all patterns that end at position i
            for patIdx in output[state] {
                matches.append(AhoCorasickMatch(
                    position: i - patternLengths[patIdx] + 1,
                    patternIndex: patIdx,
                    length: patternLengths[patIdx]
                ))
            }
        }

        return matches
    }

    /// Convenience: search a Data value.
    public func search(_ data: Data) -> [AhoCorasickMatch] {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return []
            }
            let buffer = UnsafeBufferPointer(start: baseAddress, count: rawBuffer.count)
            return search(buffer)
        }
    }

    /// Encode a string into byte patterns for Layer 3 / Layer 10 search.
    ///
    /// The term is NFC-normalized (`precomposedStringWithCanonicalMapping`) so
    /// a decomposed term matches composed output bytes, then expanded into
    /// case variants — as-normalized, lowercase, UPPERCASE, and Title Case —
    /// because the byte-level automaton cannot fold case at search time and
    /// the term the user typed need not match the document's casing (a
    /// lowercase query redacts a Title Case occurrence). Arbitrary mixed case
    /// (e.g. "aCmE") is out of scope for byte search; Layer 2's OCR gate is
    /// fully case-insensitive. Each variant is emitted in all 5 encodings
    /// (UTF-8, UTF-16BE, UTF-16LE, ASCII, Latin-1), skipping encodings where
    /// it cannot be represented, and the whole set is deduplicated by byte
    /// equality (UTF-8 ≡ ASCII ≡ Latin-1 for ASCII text; case variants of a
    /// caseless term collapse) so one physical occurrence registers one
    /// pattern, keeping user-facing match counts honest. Order-stable.
    /// See ENGINE §6.3.
    public static func encodeForSearch(_ term: String) -> [[UInt8]] {
        let nfc = term.precomposedStringWithCanonicalMapping
        // lowercased()/uppercased() are the locale-independent String methods
        // (not localizedLowercase); Title Case pinned to en_US_POSIX.
        let posix = Locale(identifier: "en_US_POSIX")
        let caseVariants = [
            nfc,
            nfc.lowercased().precomposedStringWithCanonicalMapping,
            nfc.uppercased().precomposedStringWithCanonicalMapping,
            nfc.capitalized(with: posix).precomposedStringWithCanonicalMapping
        ]
        let encodings: [String.Encoding] = [
            .utf8, .utf16BigEndian, .utf16LittleEndian, .ascii, .isoLatin1
        ]
        var seen = Set<[UInt8]>()
        var patterns: [[UInt8]] = []
        for variant in caseVariants {
            for encoding in encodings {
                guard let data = variant.data(using: encoding) else { continue }
                let bytes = Array(data)
                if seen.insert(bytes).inserted {
                    patterns.append(bytes)
                }
            }
        }
        return patterns
    }

    /// True when a sensitive term is long enough for byte search (ENGINE
    /// §6.3): at least 3 Unicode scalars (supports 3-letter PII abbreviations
    /// like SSN, DOB, PHI), or exactly 2 scalars that are all CJK
    /// (≥ U+2E80) — a 2-character CJK/Korean full name is high-entropy where
    /// a 2-letter Latin fragment is noise. Counts scalars of the
    /// NFC-normalized term so composed and decomposed spellings of the same
    /// text get the same verdict. Shared by Layer 3, Layer 10, and Layer 2's
    /// `classifyPageOCR`.
    public static func isSearchableTerm(_ term: String) -> Bool {
        let scalars = term.precomposedStringWithCanonicalMapping.unicodeScalars
        if scalars.count >= 3 { return true }
        return scalars.count == 2 && scalars.allSatisfy { $0.value >= 0x2E80 }
    }

    /// Number of distinct physical occurrences among `matches`: unique
    /// (position, length) pairs. `encodeForSearch`'s pattern dedupe already
    /// prevents byte-identical patterns from multi-counting one occurrence;
    /// this guards the counting surface independently so user-facing
    /// "(N match(es))" counts stay physical. Genuine overlaps (different
    /// position or length) still count separately.
    public static func uniqueOccurrenceCount(_ matches: [AhoCorasickMatch]) -> Int {
        struct Occurrence: Hashable {
            let position: Int
            let length: Int
        }
        return Set(matches.map { Occurrence(position: $0.position, length: $0.length) }).count
    }

    /// True for ASCII digits and letters — the byte class that CONTINUES a
    /// token under the PD-3 boundary rule. Every other byte value (PDF
    /// delimiters, whitespace, punctuation, 0x1F separators, and any
    /// non-ASCII byte) terminates a token.
    static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)     // 0-9
            || (0x41...0x5A).contains(byte)  // A-Z
            || (0x61...0x7A).contains(byte)  // a-z
    }
}

/// Aho-Corasick automaton over a `SensitiveTerm` set that remembers, per
/// encoded pattern, whether the source term requires token-boundary
/// matching — so byte hits of a bare single-word term embedded inside a
/// longer alphanumeric run can be discarded (PD-3). Shared by Layer 3
/// (structural + SVT-3 decoded passes) and Layer 10.
struct SensitiveTermAutomaton {
    let automaton: AhoCorasick
    /// Aligned with the automaton's pattern order: true when the pattern
    /// derives from a `requiresTokenBoundary` term.
    private let patternRequiresBoundary: [Bool]
    /// Aligned with the automaton's pattern order: the source term's display
    /// text, so a match can be traced back to the term it derives from
    /// (every encoding variant of one term maps to the same text). Feeds
    /// `LayerResult.reviewTermTexts` — display-only, never logged (ARCH §12.2:
    /// status messages themselves stay content-free).
    private let patternTermText: [String]
    /// True when at least one pattern was produced.
    let hasPatterns: Bool

    var isDegraded: Bool { automaton.isDegraded }

    /// Build from terms already filtered by `AhoCorasick.isSearchableTerm`.
    init(validTerms: [SensitiveTerm]) {
        var patterns: [[UInt8]] = []
        var boundaryFlags: [Bool] = []
        var termTexts: [String] = []
        for term in validTerms {
            let encoded = AhoCorasick.encodeForSearch(term.text)
            patterns.append(contentsOf: encoded)
            boundaryFlags.append(
                contentsOf: repeatElement(term.requiresTokenBoundary, count: encoded.count))
            termTexts.append(
                contentsOf: repeatElement(term.text, count: encoded.count))
        }
        self.automaton = AhoCorasick(patterns: patterns)
        self.patternRequiresBoundary = boundaryFlags
        self.patternTermText = termTexts
        self.hasPatterns = !patterns.isEmpty
    }

    /// Source term texts behind `matches`, deduplicated, in first-match
    /// order. Case/encoding variants of one term collapse to its single
    /// display text.
    func matchedTermTexts(_ matches: [AhoCorasickMatch]) -> [String] {
        var seen = Set<String>()
        var texts: [String] = []
        for match in matches {
            let text = patternTermText[match.patternIndex]
            if seen.insert(text).inserted { texts.append(text) }
        }
        return texts
    }

    /// Search `data`, discarding matches of boundary-required terms whose
    /// adjacent bytes continue an alphanumeric token. A byte before the
    /// match start or after the match end that is absent (buffer edge) or
    /// non-alphanumeric ASCII qualifies as a boundary. Matches of plain
    /// (substring) terms are returned unfiltered.
    func tokenFilteredMatches(in data: Data) -> [AhoCorasickMatch] {
        let matches = automaton.search(data)
        guard matches.contains(where: { patternRequiresBoundary[$0.patternIndex] }) else {
            return matches
        }
        return data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return matches.filter { match in
                guard patternRequiresBoundary[match.patternIndex] else { return true }
                return Self.isTokenBounded(match, in: bytes)
            }
        }
    }

    /// Two-sided adjacency test for one match (buffer-offset positions,
    /// matching `AhoCorasick.search`'s convention).
    static func isTokenBounded(
        _ match: AhoCorasickMatch, in bytes: UnsafeBufferPointer<UInt8>
    ) -> Bool {
        if match.position > 0,
           AhoCorasick.isASCIIAlphanumeric(bytes[match.position - 1]) {
            return false
        }
        let end = match.position + match.length
        if end < bytes.count, AhoCorasick.isASCIIAlphanumeric(bytes[end]) {
            return false
        }
        return true
    }
}
