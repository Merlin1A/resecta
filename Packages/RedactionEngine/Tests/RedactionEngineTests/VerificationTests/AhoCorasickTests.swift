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
        // duplicates the original here) × 3 distinct encodings (UTF-8 ≡
        // ASCII ≡ Latin-1 for ASCII text, plus UTF-16BE and UTF-16LE).
        #expect(patterns.count == 9)
        #expect(patterns.allSatisfy { !$0.isEmpty })
        // Byte-identical duplicates are removed — one physical occurrence
        // must register exactly one pattern per matching byte shape.
        #expect(Set(patterns).count == patterns.count)
        #expect(patterns.contains(Array("Hello".utf8)))
        #expect(patterns.contains(Array("hello".utf8)))
        #expect(patterns.contains(Array("HELLO".utf8)))
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
        // only the 3 distinct encodings remain (UTF-8/ASCII/Latin-1 merge).
        let patterns = AhoCorasick.encodeForSearch("12345")
        #expect(patterns.count == 3)
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
        // + 200k UTF-16LE) = 1.5 MB > bound → degraded no-op automaton.
        let bigTerm = String(repeating: "a", count: 100_000)
        let patterns = AhoCorasick.encodeForSearch(bigTerm)
        let totalBytes = patterns.reduce(0) { $0 + $1.count }
        #expect(totalBytes == 1_500_000)
        let ac = AhoCorasick(patterns: patterns)
        #expect(ac.isDegraded)
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
