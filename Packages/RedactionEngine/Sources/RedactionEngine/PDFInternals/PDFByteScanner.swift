import Foundation

// Phase 1: Raw byte operations on PDF data.
// Detects incremental updates (%%EOF count) and XMP metadata presence.

/// Scans raw PDF bytes for structural markers. Stateless, nonisolated struct.
public struct PDFByteScanner: Sendable {

    public init() {}

    /// Count `%%EOF` markers in raw PDF data.
    /// A normal PDF has exactly 1. Multiple markers indicate incremental updates,
    /// meaning original content may persist in the file bytes after editing.
    @concurrent
    public func countEOFMarkers(in data: Data) async -> Int {
        // %%EOF = [0x25, 0x25, 0x45, 0x4F, 0x46]
        let pattern: [UInt8] = [0x25, 0x25, 0x45, 0x4F, 0x46]
        return countOccurrences(of: pattern, in: data)
    }

    /// Detect XMP metadata presence via `<?xpacket` byte pattern.
    @concurrent
    public func detectXMP(in data: Data) async -> Bool {
        // <?xpacket = [0x3C, 0x3F, 0x78, 0x70, 0x61, 0x63, 0x6B, 0x65, 0x74]
        let pattern: [UInt8] = [0x3C, 0x3F, 0x78, 0x70, 0x61, 0x63, 0x6B, 0x65, 0x74]
        return countOccurrences(of: pattern, in: data) > 0
    }

    /// Search raw PDF bytes for Known Terms via AhoCorasick multi-pattern matching.
    /// Encodes each term as UTF-8, UTF-16BE, and UTF-16LE for coverage across
    /// PDF text encodings. Terms shorter than 4 characters are silently excluded.
    /// Term text is NEVER echoed in results (ARCH §12.2, security requirement).
    @concurrent
    public func searchKnownTerms(in data: Data, terms: [String]) async -> KnownTermsSearchResult {
        let validTerms = terms.filter { $0.count >= 4 }
        guard !validTerms.isEmpty else {
            return KnownTermsSearchResult(termsSearched: 0, termsFound: 0)
        }

        // Build byte patterns: each term encoded in 3 ways.
        // Pattern indices: term i → patterns [i*3, i*3+1, i*3+2] = [UTF-8, UTF-16BE, UTF-16LE]
        //
        // UTF-16 patterns use String.utf16 (not unicodeScalars) so that
        // supplementary-plane scalars (e.g. emoji, U+1F534 🔴) emit correct
        // surrogate-pair code units. The unicodeScalars approach was a trap:
        // UInt16(scalar.value) triggers a debug-mode precondition failure for
        // any scalar whose value exceeds 0xFFFF and silently truncates in
        // release, emitting malformed patterns to Aho-Corasick. (ARCH §12.2:
        // user custom always-flag terms can contain emoji.)
        var patterns: [[UInt8]] = []
        for term in validTerms {
            patterns.append(Array(term.utf8))
            // UTF-16BE: each code unit → high byte then low byte.
            // String.utf16 emits surrogate pairs for supplementary-plane scalars.
            var be: [UInt8] = []
            for codeUnit in term.utf16 {
                be.append(UInt8(codeUnit >> 8))
                be.append(UInt8(codeUnit & 0xFF))
            }
            patterns.append(be)
            // UTF-16LE: each code unit → low byte then high byte.
            var le: [UInt8] = []
            for codeUnit in term.utf16 {
                le.append(UInt8(codeUnit & 0xFF))
                le.append(UInt8(codeUnit >> 8))
            }
            patterns.append(le)
        }

        let automaton = AhoCorasick(patterns: patterns)
        guard !automaton.isDegraded else {
            return KnownTermsSearchResult(termsSearched: validTerms.count, termsFound: 0)
        }

        let matches = automaton.search(data)

        // Deduplicate by original term index
        var matchedTermIndices: Set<Int> = []
        for match in matches {
            matchedTermIndices.insert(match.patternIndex / 3)
        }

        return KnownTermsSearchResult(
            termsSearched: validTerms.count,
            termsFound: matchedTermIndices.count
        )
    }

    // MARK: - Private

    private func countOccurrences(of pattern: [UInt8], in data: Data) -> Int {
        guard pattern.count <= data.count else { return 0 }

        var count = 0
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let len = buffer.count
            let patLen = pattern.count
            let limit = len - patLen

            var i = 0
            while i <= limit {
                var match = true
                for j in 0..<patLen {
                    if base[i + j] != pattern[j] {
                        match = false
                        break
                    }
                }
                if match {
                    count += 1
                    i += patLen // skip past this match
                } else {
                    i += 1
                }
            }
        }
        return count
    }
}
