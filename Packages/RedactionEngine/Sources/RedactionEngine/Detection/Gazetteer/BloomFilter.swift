import Foundation

// G2a: Bloom filter with MurmurHash3_x64_128 double-hashing.
// Binary format is specified in the Binary Format section below.

/// A read-only Bloom filter loaded from a pre-built binary file.
///
/// ## Binary Format (63-byte header + bit array)
/// ```
/// Offset  Size   Field
/// [0..3]  4B     Magic "RSBF" (ASCII)
/// [4..5]  u16 LE Version (currently 1)
/// [6]     u8     k — number of hash functions
/// [7..14] u64 LE m — number of bits in the filter
/// [15..22] u64 LE Seed for MurmurHash3 (lower 32 bits used)
/// [23..30] u64 LE Row count — entries inserted
/// [31..62] 32B   SHA-256 of sorted, NFKC-lowercased source rows
/// [63..]  ⌈m/8⌉B Bit array, little-endian bit ordering
/// ```
///
/// Membership queries use Kirsch-Mitzenmacher double-hashing:
/// `pos_i = ((h1 + i * h2) mod 2^64) mod m` for `i` in `0..<k`,
/// where `(h1, h2) = MurmurHash3_x64_128(utf8_bytes, seed)`.
public struct BloomFilter: Sendable {

    // MARK: - Format Constants

    static let headerSize = 63
    static let currentVersion: UInt16 = 1
    private static let magicBytes: [UInt8] = [0x52, 0x53, 0x42, 0x46] // "RSBF"

    // MARK: - Properties

    /// Number of hash functions.
    public let hashCount: Int
    /// Number of bits in the filter.
    public let bitCount: UInt64
    /// MurmurHash3 seed (lower 32 bits used as hash seed).
    public let seed: UInt64
    /// Number of entries inserted during construction.
    public let rowCount: UInt64
    /// SHA-256 of sorted source rows.
    public let sourceHash: Data

    private let bitArray: Data

    // MARK: - Errors

    public enum FormatError: Swift.Error, Equatable {
        case dataTooShort
        case invalidMagic
        case unsupportedVersion(UInt16)
        case bitArraySizeMismatch
    }

    // MARK: - Init

    /// Load a Bloom filter from binary data in RSBF format.
    public init(data: Data) throws {
        guard data.count >= Self.headerSize else {
            throw FormatError.dataTooShort
        }

        // Magic: bytes [0..3] must be "RSBF"
        guard data[data.startIndex] == 0x52,
              data[data.startIndex + 1] == 0x53,
              data[data.startIndex + 2] == 0x42,
              data[data.startIndex + 3] == 0x46 else {
            throw FormatError.invalidMagic
        }

        // Version: u16 LE at offset 4
        let version = data.loadLE(UInt16.self, at: 4)
        guard version == Self.currentVersion else {
            throw FormatError.unsupportedVersion(version)
        }

        // k: u8 at offset 6
        self.hashCount = Int(data[data.startIndex + 6])

        // m: u64 LE at offset 7
        self.bitCount = data.loadLE(UInt64.self, at: 7)

        // Seed: u64 LE at offset 15
        self.seed = data.loadLE(UInt64.self, at: 15)

        // Row count: u64 LE at offset 23
        self.rowCount = data.loadLE(UInt64.self, at: 23)

        // SHA-256: 32 bytes at offset 31
        let hashStart = data.startIndex + 31
        self.sourceHash = Data(data[hashStart..<(hashStart + 32)])

        // Bit array: offset 63 onward
        let expectedBytes = Int((bitCount + 7) / 8)
        let bodyStart = data.startIndex + Self.headerSize
        guard data.count - Self.headerSize >= expectedBytes else {
            throw FormatError.bitArraySizeMismatch
        }
        self.bitArray = Data(data[bodyStart..<(bodyStart + expectedBytes)])
    }

    // MARK: - Membership Query

    /// Check whether a key might be in the set.
    ///
    /// The key is NFKC-normalized and lowercased before hashing,
    /// matching the Python build pipeline's preprocessing.
    /// Returns `true` if the key is probably in the set (FPR ≈ 0.1%),
    /// or `false` if definitively not.
    public func contains(_ key: String) -> Bool {
        let normalized = TextNormalizer.normalize(key).lowercased()
        let bytes = Array(normalized.utf8)
        let (h1, h2) = Self.murmurHash3_x64_128(bytes, seed: UInt32(seed & 0xFFFF_FFFF))

        for i: UInt64 in 0..<UInt64(hashCount) {
            let pos = (h1 &+ i &* h2) % bitCount
            let byteIndex = Int(pos / 8)
            let bitIndex = Int(pos % 8)
            if bitArray[byteIndex] & (1 << bitIndex) == 0 {
                return false
            }
        }
        return true
    }

    #if DEBUG
    /// Test seam: base address of the backing bit-array buffer. Two
    /// `BloomFilter` values copied from one source share this address (`Data`
    /// is copy-on-write); independently loaded filters do not. Used to prove
    /// the process-shared PIIDetector reuses a single Bloom allocation.
    internal var _testBufferBaseAddress: Int {
        bitArray.withUnsafeBytes { Int(bitPattern: $0.baseAddress) }
    }
    #endif

    // MARK: - MurmurHash3_x64_128

    /// Pure-Swift port of MurmurHash3_x64_128 (Austin Appleby, public domain).
    /// Cross-language consistency with Python `mmh3.hash128(key, seed)`.
    static func murmurHash3_x64_128(_ data: [UInt8], seed: UInt32) -> (UInt64, UInt64) {
        let len = data.count
        let nblocks = len / 16

        var h1 = UInt64(seed)
        var h2 = UInt64(seed)

        let c1: UInt64 = 0x87c3_7b91_1142_53d5
        let c2: UInt64 = 0x4cf5_ad43_2745_937f

        // Body — 16-byte blocks
        for i in 0..<nblocks {
            var k1 = loadLE64(data, offset: i &* 16)
            var k2 = loadLE64(data, offset: i &* 16 &+ 8)

            k1 = k1 &* c1; k1 = rotl64(k1, 31); k1 = k1 &* c2; h1 ^= k1
            h1 = rotl64(h1, 27); h1 = h1 &+ h2; h1 = h1 &* 5 &+ 0x52dc_e729

            k2 = k2 &* c2; k2 = rotl64(k2, 33); k2 = k2 &* c1; h2 ^= k2
            h2 = rotl64(h2, 31); h2 = h2 &+ h1; h2 = h2 &* 5 &+ 0x3849_5ab5
        }

        // Tail — remaining bytes
        let tail = nblocks &* 16
        var k1: UInt64 = 0
        var k2: UInt64 = 0

        switch len & 15 {
        case 15: k2 ^= UInt64(data[tail + 14]) << 48; fallthrough
        case 14: k2 ^= UInt64(data[tail + 13]) << 40; fallthrough
        case 13: k2 ^= UInt64(data[tail + 12]) << 32; fallthrough
        case 12: k2 ^= UInt64(data[tail + 11]) << 24; fallthrough
        case 11: k2 ^= UInt64(data[tail + 10]) << 16; fallthrough
        case 10: k2 ^= UInt64(data[tail + 9]) << 8; fallthrough
        case 9:
            k2 ^= UInt64(data[tail + 8])
            k2 = k2 &* c2; k2 = rotl64(k2, 33); k2 = k2 &* c1; h2 ^= k2
            fallthrough
        case 8: k1 ^= UInt64(data[tail + 7]) << 56; fallthrough
        case 7: k1 ^= UInt64(data[tail + 6]) << 48; fallthrough
        case 6: k1 ^= UInt64(data[tail + 5]) << 40; fallthrough
        case 5: k1 ^= UInt64(data[tail + 4]) << 32; fallthrough
        case 4: k1 ^= UInt64(data[tail + 3]) << 24; fallthrough
        case 3: k1 ^= UInt64(data[tail + 2]) << 16; fallthrough
        case 2: k1 ^= UInt64(data[tail + 1]) << 8; fallthrough
        case 1:
            k1 ^= UInt64(data[tail])
            k1 = k1 &* c1; k1 = rotl64(k1, 31); k1 = k1 &* c2; h1 ^= k1
        default: break
        }

        // Finalization
        h1 ^= UInt64(len); h2 ^= UInt64(len)

        h1 = h1 &+ h2; h2 = h2 &+ h1
        h1 = fmix64(h1); h2 = fmix64(h2)
        h1 = h1 &+ h2; h2 = h2 &+ h1

        return (h1, h2)
    }

    private static func rotl64(_ x: UInt64, _ r: Int) -> UInt64 {
        (x << r) | (x >> (64 - r))
    }

    private static func fmix64(_ k: UInt64) -> UInt64 {
        var k = k
        k ^= k >> 33; k = k &* 0xff51_afd7_ed55_8ccd
        k ^= k >> 33; k = k &* 0xc4ce_b9fe_1a85_ec53
        k ^= k >> 33
        return k
    }

    private static func loadLE64(_ data: [UInt8], offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(data[offset + i]) << (i * 8) }
        return v
    }
}

// MARK: - Data Little-Endian Helper

private extension Data {
    func loadLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        let size = MemoryLayout<T>.size
        for i in 0..<size {
            value |= T(self[startIndex + offset + i]) << (i * 8)
        }
        return value
    }
}
