import Testing
import Foundation
@testable import RedactionEngine

// ENGINE §6.3a — Aho-Corasick correctness tests.

@Suite("Aho-Corasick Multi-Pattern Matcher")
struct AhoCorasickTests {

    @Test("Single pattern finds exact match")
    func singlePattern() {
        let ac = AhoCorasick(patterns: [Array("hello".utf8)])
        let input = Array("say hello world".utf8)
        let matches = input.withUnsafeBufferPointer { ac.search($0) }
        #expect(matches.count == 1)
        #expect(matches[0].position == 4)
        #expect(matches[0].length == 5)
    }

    @Test("Multiple patterns found in single pass")
    func multiplePatterns() {
        let patterns = [Array("cat".utf8), Array("dog".utf8), Array("fish".utf8)]
        let ac = AhoCorasick(patterns: patterns)
        let input = Array("the cat and dog ate fish".utf8)
        let matches = input.withUnsafeBufferPointer { ac.search($0) }
        #expect(matches.count == 3)
    }

    @Test("Overlapping patterns both reported")
    func overlappingMatches() {
        let patterns = [Array("he".utf8), Array("she".utf8), Array("her".utf8)]
        let ac = AhoCorasick(patterns: patterns)
        let input = Array("ushers".utf8)
        let matches = input.withUnsafeBufferPointer { ac.search($0) }
        // "she" at 1, "he" at 2, "her" at 2
        #expect(matches.count >= 3)
    }

    @Test("No match returns empty array")
    func noMatch() {
        let ac = AhoCorasick(patterns: [Array("xyz".utf8)])
        let input = Array("hello world".utf8)
        let matches = input.withUnsafeBufferPointer { ac.search($0) }
        #expect(matches.isEmpty)
    }

    @Test("Empty input returns no matches")
    func emptyInput() {
        let ac = AhoCorasick(patterns: [Array("test".utf8)])
        let empty: [UInt8] = []
        let matches = empty.withUnsafeBufferPointer { ac.search($0) }
        #expect(matches.isEmpty)
    }

    @Test("UTF-16BE patterns with null bytes work correctly")
    func utf16BEPatterns() {
        // "John" in UTF-16BE: 00 4A 00 6F 00 68 00 6E
        let pattern: [UInt8] = [0x00, 0x4A, 0x00, 0x6F, 0x00, 0x68, 0x00, 0x6E]
        let ac = AhoCorasick(patterns: [pattern])

        // Embed the UTF-16BE pattern in some surrounding bytes
        var input: [UInt8] = [0xFF, 0xFE]  // BOM
        input.append(contentsOf: pattern)
        input.append(contentsOf: [0x00, 0x00])

        let matches = input.withUnsafeBufferPointer { ac.search($0) }
        #expect(matches.count == 1)
        #expect(matches[0].position == 2)
        #expect(matches[0].length == 8)
    }

    @Test("encodeForSearch emits case variants across encodings, deduplicated")
    func encodeForSearchCaseVariantsDeduplicated() {
        let patterns = AhoCorasick.encodeForSearch("Hello")
        // 3 distinct case variants (Hello / hello / HELLO; Title Case
        // duplicates the original here) × 5 distinct encodings (UTF-8 ≡
        // ASCII ≡ Latin-1 for ASCII text, plus UTF-16BE, UTF-16LE,
        // UTF-32BE, and UTF-32LE).
        #expect(patterns.count == 15)
        #expect(patterns.allSatisfy { !$0.isEmpty })
        // Byte-identical duplicates are removed — one physical occurrence
        // must register exactly one pattern per matching byte shape.
        #expect(Set(patterns).count == patterns.count)
        #expect(patterns.contains(Array("Hello".utf8)))
        #expect(patterns.contains(Array("hello".utf8)))
        #expect(patterns.contains(Array("HELLO".utf8)))
    }

    @Test("encodeForSearch emits UTF-32 byte shapes in both endiannesses")
    func encodeForSearchUTF32Shapes() {
        let patterns = AhoCorasick.encodeForSearch("acme")
        // UTF-32BE: each ASCII scalar as 00 00 00 xx; LE mirrored. No BOM —
        // the explicit-endian encodings emit raw code units.
        let utf32BE: [UInt8] = "acme".unicodeScalars.flatMap {
            [0x00, 0x00, 0x00, UInt8($0.value)]
        }
        let utf32LE: [UInt8] = "acme".unicodeScalars.flatMap {
            [UInt8($0.value), 0x00, 0x00, 0x00]
        }
        #expect(patterns.contains(utf32BE))
        #expect(patterns.contains(utf32LE))
    }

    @Test("encodeForSearch covers Title Case for a lowercase term")
    func encodeForSearchTitleCaseVariant() {
        // The user's query is contributed as typed; a lowercase query must
        // still surface the document's Title Case occurrence in raw bytes.
        let patterns = AhoCorasick.encodeForSearch("acme")
        #expect(patterns.contains(Array("Acme".utf8)))
        #expect(patterns.contains(Array("ACME".utf8)))
        #expect(patterns.contains(Array("acme".utf8)))
    }

    @Test("encodeForSearch collapses variants of a caseless term")
    func encodeForSearchCaselessTerm() {
        // Digits have no case — all four variants are byte-identical, so
        // only the 5 distinct encodings remain (UTF-8/ASCII/Latin-1 merge;
        // UTF-16 and UTF-32 each contribute both endiannesses).
        let patterns = AhoCorasick.encodeForSearch("12345")
        #expect(patterns.count == 5)
    }

    @Test("encodeForSearch NFC-normalizes: decomposed term matches composed bytes")
    func encodeForSearchNFCNormalization() {
        // "é" typed decomposed (e + combining acute) must produce the
        // composed UTF-8 byte shape (0xC3 0xA9) that CGPDFContext output
        // carries.
        let patterns = AhoCorasick.encodeForSearch("Andre\u{0301}")
        #expect(patterns.contains(Array("Andr\u{00E9}".utf8)))
    }

    @Test("isSearchableTerm: ≥3 scalars, or a 2-character CJK name")
    func isSearchableTermRules() {
        #expect(AhoCorasick.isSearchableTerm("Kim"))
        #expect(AhoCorasick.isSearchableTerm("SSN"))
        #expect(AhoCorasick.isSearchableTerm("李明"),
                "2-character CJK full name is high-entropy — searchable")
        #expect(!AhoCorasick.isSearchableTerm("ab"))
        #expect(!AhoCorasick.isSearchableTerm("de"))
        #expect(!AhoCorasick.isSearchableTerm("王"),
                "single CJK character stays excluded")
        // Scalar count is taken after NFC so composed/decomposed spellings
        // of the same 2-character Latin fragment agree.
        #expect(!AhoCorasick.isSearchableTerm("e\u{0301}a"),
                "decomposed 3-scalar spelling of a 2-character Latin fragment is not searchable")
    }

    @Test("uniqueOccurrenceCount collapses duplicates, keeps genuine overlaps")
    func uniqueOccurrenceCountSemantics() {
        let duplicated = [
            AhoCorasickMatch(position: 10, patternIndex: 0, length: 4),
            AhoCorasickMatch(position: 10, patternIndex: 2, length: 4)
        ]
        #expect(AhoCorasick.uniqueOccurrenceCount(duplicated) == 1)
        let overlapping = [
            AhoCorasickMatch(position: 0, patternIndex: 0, length: 2),  // "AA" in "AAA"
            AhoCorasickMatch(position: 1, patternIndex: 0, length: 2)
        ]
        #expect(AhoCorasick.uniqueOccurrenceCount(overlapping) == 2)
        #expect(AhoCorasick.uniqueOccurrenceCount([]) == 0)
    }

    @Test("Degradation bound stays byte-based over the expanded variant set")
    func degradedBoundIsByteBased() {
        // Case variants roughly triple the pattern bytes for a cased ASCII
        // term; the 1 MB bound must count the actual emitted bytes. One
        // 100_000-character term → 3 variants × (100k UTF-8 + 200k UTF-16BE
        // + 200k UTF-16LE + 400k UTF-32BE + 400k UTF-32LE) = 3.9 MB > bound
        // → degraded no-op automaton. No ligature site, so the composed
        // form adds nothing.
        let bigTerm = String(repeating: "a", count: 100_000)
        let patterns = AhoCorasick.encodeForSearch(bigTerm)
        let totalBytes = patterns.reduce(0) { $0 + $1.count }
        #expect(totalBytes == 3_900_000)
        let ac = AhoCorasick(patterns: patterns)
        #expect(ac.isDegraded)

        // A ligature site adds the composed form's bytes to the count: only
        // the lowercase variant composes ("fi" + 99_998 × "a" → ﬁ + …; the
        // UPPERCASE and Title Case variants carry no lowercase site), so
        // 3.9 MB + (100_001 UTF-8 + 2 × 199_998 UTF-16 + 2 × 399_996 UTF-32)
        // = 5_199_989 bytes — still counted, still degraded.
        let ligatureTerm = "fi" + String(repeating: "a", count: 99_998)
        let ligaturePatterns = AhoCorasick.encodeForSearch(ligatureTerm)
        let ligatureBytes = ligaturePatterns.reduce(0) { $0 + $1.count }
        #expect(ligatureBytes == 5_199_989)
        #expect(AhoCorasick(patterns: ligaturePatterns).isDegraded)
    }

    @Test("encodeForSearch adds the ligature-composed form of each case variant")
    func encodeForSearchLigatureComposedForms() {
        // "confidential": 3 distinct case variants × 5 distinct encodings =
        // 15 as before, plus the composed forms of the two variants with a
        // lowercase "fi" site ("conﬁdential", "Conﬁdential") × the 5
        // encodings that can represent U+FB01 (UTF-8, UTF-16 ×2, UTF-32 ×2;
        // ASCII and Latin-1 cannot) = 10 → 25. The ceiling for a term with a
        // ligature site is 2 × 28 = 56.
        let patterns = AhoCorasick.encodeForSearch("confidential")
        #expect(patterns.count == 25)
        #expect(patterns.count <= 56)
        #expect(Set(patterns).count == patterns.count)
        #expect(patterns.contains(Array("con\u{FB01}dential".utf8)))
        #expect(patterns.contains(Array("Con\u{FB01}dential".utf8)))
        #expect(patterns.contains(Array("con\u{FB01}dential".data(using: .utf16BigEndian)!)))
        // No lowercase site in the UPPERCASE variant — no composed form.
        #expect(!patterns.contains(Array("CON\u{FB01}DENTIAL".utf8)))
        // A term with no ligature site is unchanged.
        #expect(AhoCorasick.encodeForSearch("Hello").count == 15)
    }

    @Test("encodeForSearch adds the search-normalized form of a term typed with a ligature")
    func encodeForSearchNormalizedFormOfLigatureTerm() {
        // The term carries U+FB01 itself: its NFC form keeps the ligature,
        // its search-normalized form is the plain spelling, and the composed
        // form of that spelling is the ligature form again (deduplicated).
        let patterns = AhoCorasick.encodeForSearch("con\u{FB01}dential")
        #expect(patterns.contains(Array("con\u{FB01}dential".utf8)))
        #expect(patterns.contains(Array("confidential".utf8)))
        #expect(patterns.contains(Array("Confidential".utf8)))
        #expect(patterns.count <= 56)
    }

    @Test("ligatureComposed replaces lowercase ligature sites, longest first")
    func ligatureComposedGreedy() {
        #expect(AhoCorasick.ligatureComposed("office") == "o\u{FB03}ce")
        #expect(AhoCorasick.ligatureComposed("raffle") == "ra\u{FB04}e")
        #expect(AhoCorasick.ligatureComposed("offer") == "o\u{FB00}er")
        #expect(AhoCorasick.ligatureComposed("file") == "\u{FB01}le")
        #expect(AhoCorasick.ligatureComposed("flow") == "\u{FB02}ow")
        #expect(AhoCorasick.ligatureComposed("OFFICE") == "OFFICE")
        #expect(AhoCorasick.ligatureComposed("12345") == "12345")
    }

    @Test("Data convenience search works correctly")
    func dataSearch() {
        let ac = AhoCorasick(patterns: [Array("secret".utf8)])
        let data = "this is a secret message".data(using: .utf8)!
        let matches = ac.search(data)
        #expect(matches.count == 1)
        #expect(matches[0].position == 10)
    }

    @Test("Multiple occurrences of same pattern all found")
    func repeatedPattern() {
        let ac = AhoCorasick(patterns: [Array("ab".utf8)])
        let input = Array("ababab".utf8)
        let matches = input.withUnsafeBufferPointer { ac.search($0) }
        #expect(matches.count == 3)
    }

    @Test("isDegraded is false for normal construction")
    func notDegraded() {
        let ac = AhoCorasick(patterns: [Array("test".utf8)])
        #expect(!ac.isDegraded)
    }

    @Test("isDegraded is true when pattern bytes exceed limit")
    func degradedOnOversize() {
        // Create patterns totaling > 1MB
        let bigPattern = Array(repeating: UInt8(0x41), count: 500_001)
        let ac = AhoCorasick(patterns: [bigPattern, bigPattern])
        #expect(ac.isDegraded)
        // Search should return no matches (degraded = empty automaton)
        let input = Array("test".utf8)
        let matches = input.withUnsafeBufferPointer { ac.search($0) }
        #expect(matches.isEmpty)
    }
}
