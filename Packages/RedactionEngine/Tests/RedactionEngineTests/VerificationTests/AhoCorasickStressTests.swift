import Testing
import Foundation
@testable import RedactionEngine

@Suite("Aho-Corasick Stress Tests")
struct AhoCorasickStressTests {

    @Test("1000 random patterns on 1MB input finds correct matches")
    func largePatternSet() {
        // Generate 1000 random 8-byte patterns
        var patterns: [[UInt8]] = []
        for _ in 0..<1000 {
            let pattern = (0..<8).map { _ in UInt8.random(in: 32...126) }
            patterns.append(pattern)
        }

        // Generate 1MB of random input
        var input: [UInt8] = (0..<1_000_000).map { _ in UInt8.random(in: 0...255) }

        // Plant one known pattern at a known position
        let knownPattern: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE]
        patterns.append(knownPattern)
        let plantPosition = 500_000
        for (i, b) in knownPattern.enumerated() {
            input[plantPosition + i] = b
        }

        let ac = AhoCorasick(patterns: patterns)
        let matches = input.withUnsafeBufferPointer { ac.search($0) }

        // The planted pattern must be found
        let knownIdx = patterns.count - 1
        let plantedMatch = matches.first { $0.patternIndex == knownIdx }
        #expect(plantedMatch != nil, "Planted pattern must be found")
        #expect(plantedMatch?.position == plantPosition)
    }

    @Test("Empty pattern array does not crash")
    func emptyPatterns() {
        let ac = AhoCorasick(patterns: [])
        let input = Array("test data".utf8)
        let matches = input.withUnsafeBufferPointer { ac.search($0) }
        #expect(matches.isEmpty)
    }

    @Test("Single-byte patterns find all occurrences")
    func singleBytePatterns() {
        let ac = AhoCorasick(patterns: [[0x41], [0x42]]) // 'A', 'B'
        let input = Array("ABBA".utf8)
        let matches = input.withUnsafeBufferPointer { ac.search($0) }
        // A at 0, B at 1, B at 2, A at 3
        #expect(matches.count == 4)
    }

    @Test("Identical duplicate patterns both report matches")
    func duplicatePatterns() {
        let pattern = Array("test".utf8)
        let ac = AhoCorasick(patterns: [pattern, pattern])
        let input = Array("this is a test".utf8)
        let matches = input.withUnsafeBufferPointer { ac.search($0) }
        // Both pattern indices should match at the same position
        #expect(matches.count == 2)
        #expect(matches[0].position == matches[1].position)
        #expect(matches[0].patternIndex != matches[1].patternIndex)
    }

    @Test("Binary data with interleaved null bytes (UTF-16 simulation)")
    func nullByteInterspersed() {
        // Simulate UTF-16LE "AB" = [0x41, 0x00, 0x42, 0x00]
        let pattern: [UInt8] = [0x41, 0x00, 0x42, 0x00]
        let ac = AhoCorasick(patterns: [pattern])

        var input: [UInt8] = [0xFF, 0xFF]
        input.append(contentsOf: pattern)
        input.append(contentsOf: [0xFF, 0xFF])

        let matches = input.withUnsafeBufferPointer { ac.search($0) }
        #expect(matches.count == 1)
        #expect(matches[0].position == 2)
        #expect(matches[0].length == 4)
    }

    @Test("Pattern longer than input returns no matches")
    func patternLongerThanInput() {
        let ac = AhoCorasick(patterns: [Array("very long pattern".utf8)])
        let input = Array("short".utf8)
        let matches = input.withUnsafeBufferPointer { ac.search($0) }
        #expect(matches.isEmpty)
    }
}
