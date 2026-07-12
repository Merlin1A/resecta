import Testing
import Foundation
@testable import RedactionEngine

// G2a: BloomFilter binary format, MurmurHash3 cross-language consistency, membership queries.

@Suite("BloomFilter (G2a)", .tags(.security))
struct BloomFilterTests {

    // MARK: - Format Parsing

    @Test("Rejects data shorter than header")
    func rejectsTooShort() {
        let data = Data(repeating: 0, count: 10)
        #expect(throws: BloomFilter.FormatError.self) {
            try BloomFilter(data: data)
        }
    }

    @Test("Rejects invalid magic bytes")
    func rejectsInvalidMagic() {
        var data = Data(repeating: 0, count: 100)
        // Write wrong magic
        data[0] = 0x00; data[1] = 0x00; data[2] = 0x00; data[3] = 0x00
        #expect(throws: BloomFilter.FormatError.self) {
            try BloomFilter(data: data)
        }
    }

    @Test("Rejects unsupported version")
    func rejectsUnsupportedVersion() throws {
        var data = try makeMinimalBloom()
        // Overwrite version to 99
        data[4] = 99; data[5] = 0
        #expect(throws: BloomFilter.FormatError.self) {
            try BloomFilter(data: data)
        }
    }

    @Test("Rejects truncated bit array")
    func rejectsTruncatedBits() throws {
        var data = try makeMinimalBloom()
        // Truncate — remove last byte of bit array
        data = data.dropLast()
        #expect(throws: BloomFilter.FormatError.self) {
            try BloomFilter(data: Data(data))
        }
    }

    @Test("Parses valid header fields")
    func parsesHeader() throws {
        let data = try makeMinimalBloom(k: 10, m: 1024, seed: 42, rowCount: 50)
        let filter = try BloomFilter(data: data)
        #expect(filter.hashCount == 10)
        #expect(filter.bitCount == 1024)
        #expect(filter.seed == 42)
        #expect(filter.rowCount == 50)
        #expect(filter.sourceHash.count == 32)
    }

    // MARK: - In-Memory Round-Trip

    @Test("Round-trip: inserted keys are found, non-keys are mostly not")
    func inMemoryRoundTrip() throws {
        // Build a small filter in Swift matching the Python binary format
        let keys = (0..<100).map { "testkey\($0)" }
        let data = try buildBloomData(keys: keys, k: 10, seed: 42)
        let filter = try BloomFilter(data: data)

        // All inserted keys must be found (no false negatives)
        for key in keys {
            #expect(filter.contains(key), "Expected \(key) to be found")
        }

        // Non-keys: expect very few false positives
        var fp = 0
        let nonKeys = (100..<200).map { "nonkey\($0)" }
        for key in nonKeys {
            if filter.contains(key) { fp += 1 }
        }
        // With 100 keys and optimal sizing, FPR should be near 0.1%
        #expect(fp < 5, "Too many false positives: \(fp)/100")
    }

    // MARK: - NFKC Case Normalization

    @Test("Contains normalizes case: SMITH, smith, Smith all match")
    func caseNormalization() throws {
        let keys = ["smith", "garcia", "nguyen"]
        let data = try buildBloomData(keys: keys, k: 10, seed: 42)
        let filter = try BloomFilter(data: data)

        #expect(filter.contains("SMITH"))
        #expect(filter.contains("Smith"))
        #expect(filter.contains("smith"))
        #expect(filter.contains("GARCIA"))
        #expect(filter.contains("Nguyen"))
    }

    // MARK: - Golden File Cross-Language Test

    @Test("Golden file: 1,000 members found, non-members miss")
    func goldenFileCrossLanguage() throws {
        let bundle = Bundle.module
        guard let bloomURL = bundle.url(forResource: "golden-1000",
                                        withExtension: "bloom",
                                        subdirectory: "TestResources"),
              let membersURL = bundle.url(forResource: "golden-1000-members",
                                          withExtension: "txt",
                                          subdirectory: "TestResources"),
              let nonMembersURL = bundle.url(forResource: "golden-1000-nonmembers",
                                             withExtension: "txt",
                                             subdirectory: "TestResources")
        else {
            Issue.record("Golden test files not found in TestResources")
            return
        }

        let bloomData = try Data(contentsOf: bloomURL)
        let filter = try BloomFilter(data: bloomData)

        // Verify header
        #expect(filter.hashCount == 10)
        #expect(filter.seed == 42)
        #expect(filter.rowCount == 1000)

        // All 1,000 members must hit
        let membersText = try String(contentsOf: membersURL, encoding: .utf8)
        let members = membersText.split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
        #expect(members.count == 1000, "Expected 1000 members, got \(members.count)")

        var misses = 0
        for member in members {
            if !filter.contains(member) {
                misses += 1
                Issue.record("FALSE NEGATIVE: '\(member)' not found in golden filter")
            }
        }
        #expect(misses == 0, "\(misses) false negatives in golden file")

        // Non-members should mostly miss
        let nonMembersText = try String(contentsOf: nonMembersURL, encoding: .utf8)
        let nonMembers = nonMembersText.split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
        #expect(nonMembers.count >= 90, "Expected ≥90 non-members")

        var falsePositives = 0
        for word in nonMembers {
            if filter.contains(word) { falsePositives += 1 }
        }
        // FPR on 99 items with 0.1% target → expect 0-1 FP
        #expect(falsePositives < 5,
                "Too many false positives: \(falsePositives)/\(nonMembers.count)")
    }

    // MARK: - Helpers

    /// Build a minimal valid RSBF binary in memory (for format parsing tests).
    private func makeMinimalBloom(
        k: UInt8 = 10, m: UInt64 = 64, seed: UInt64 = 42, rowCount: UInt64 = 0
    ) throws -> Data {
        var data = Data()
        // Magic
        data.append(contentsOf: [0x52, 0x53, 0x42, 0x46]) // "RSBF"
        // Version u16 LE
        data.appendLE(UInt16(1))
        // k u8
        data.append(k)
        // m u64 LE
        data.appendLE(m)
        // Seed u64 LE
        data.appendLE(seed)
        // Row count u64 LE
        data.appendLE(rowCount)
        // SHA-256 (32 zero bytes)
        data.append(contentsOf: [UInt8](repeating: 0, count: 32))
        // Bit array
        let byteCount = Int((m + 7) / 8)
        data.append(contentsOf: [UInt8](repeating: 0, count: byteCount))
        return data
    }

    /// Build a Bloom filter binary with real keys inserted.
    private func buildBloomData(keys: [String], k: Int, seed: UInt64) throws -> Data {
        let normalizedKeys = keys.map {
            TextNormalizer.normalize($0).lowercased()
        }
        let n = normalizedKeys.count

        // Optimal m
        let fpr = 0.001
        let mBits = max(64, Int(ceil(-Double(n) * log(fpr) / pow(log(2), 2))))
        let byteCount = (mBits + 7) / 8
        var bits = [UInt8](repeating: 0, count: byteCount)

        let hashSeed = UInt32(seed & 0xFFFF_FFFF)
        for key in normalizedKeys {
            let bytes = Array(key.utf8)
            let (h1, h2) = BloomFilter.murmurHash3_x64_128(bytes, seed: hashSeed)
            for i: UInt64 in 0..<UInt64(k) {
                let pos = Int((h1 &+ i &* h2) % UInt64(mBits))
                bits[pos / 8] |= 1 << (pos % 8)
            }
        }

        // SHA-256 of sorted keys
        var sha = [UInt8](repeating: 0, count: 32)
        // (simplified — just zero hash for test builds)

        var data = Data()
        data.append(contentsOf: [0x52, 0x53, 0x42, 0x46])
        data.appendLE(UInt16(1))
        data.append(UInt8(k))
        data.appendLE(UInt64(mBits))
        data.appendLE(seed)
        data.appendLE(UInt64(n))
        data.append(contentsOf: sha)
        data.append(contentsOf: bits)
        return data
    }
}

// MARK: - Data LE Append Helper (test-only)

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        let le = value.littleEndian
        let size = MemoryLayout<T>.size
        for i in 0..<size {
            append(UInt8(truncatingIfNeeded: le >> (i * 8)))
        }
    }
}
