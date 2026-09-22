import CryptoKit
import Foundation

/// The trailer's `/ID` pair as a content-derived identifier.
///
/// The system PDF writer ends every file with `trailer << … /ID [ <32 hex>
/// <32 hex> ] >>` — two equal 16-byte strings it draws at random for each
/// export. The finalize step (`PDFStreamReconstructor.overwriteFileIdentifier
/// (at:)`) replaces both payloads, at their exact offsets, with the first 16
/// bytes of SHA-256 over the whole file computed with both payloads zeroed,
/// so the identifier is a function of the file's own bytes: it carries
/// nothing about the device, the build or the moment of export; two exports
/// of identical content carry the same identifier; and the rewrite is
/// idempotent (zeroing the payload before hashing makes the digest
/// independent of what the pair held). Layer 5 recomputes the same digest
/// and reports a pair that does not match. The shared home for both sides,
/// so Verification never depends on Pipeline for it.
public enum PDFFileIdentifier {
    /// Hex characters per payload: 16 bytes.
    public static let hexLength = 32

    /// Bytes of the identifier: the digest's leading bytes.
    public static let identifierLength = 16

    /// How far from the end of the file the pair is looked for — the same
    /// window as the `/Info` literal rewrite (the writer places both in the
    /// file's tail; Searchable mode's subset font can land between them and
    /// the cross-reference table).
    public static let tailWindowLength = 262_144

    /// The two payload ranges, in the indices of the `Data` they were
    /// located in (a slice keeps its parent's indices, so a tail slice of a
    /// whole-file `Data` yields whole-file offsets).
    public struct Location: Equatable, Sendable {
        public let first: Range<Int>
        public let second: Range<Int>
    }

    /// The payload ranges of the single `/ID [ <…> <…> ]` pair in `data`,
    /// or nil when the marker is absent or appears more than once, or the
    /// pair is not two hex strings of exactly 32 characters closed by `]` —
    /// the producer patch's guard discipline: a shape this writer does not
    /// produce is left alone.
    public static func locate(in data: Data) -> Location? {
        let marker = Data("/ID".utf8)
        var payloadStarts: [Int] = []
        var searchFrom = data.startIndex
        while searchFrom < data.endIndex,
              let hit = data.range(of: marker, in: searchFrom..<data.endIndex) {
            searchFrom = hit.upperBound
            var index = hit.upperBound
            while index < data.endIndex, isWhitespace(data[index]) { index += 1 }
            // `/IDTree`, `/IDS` and the like continue with a regular character.
            if index < data.endIndex, data[index] == 0x5B { payloadStarts.append(index + 1) }  // "["
        }
        guard payloadStarts.count == 1, var index = payloadStarts.first else { return nil }

        func hexString() -> Range<Int>? {
            while index < data.endIndex, isWhitespace(data[index]) { index += 1 }
            guard index < data.endIndex, data[index] == 0x3C else { return nil }  // "<"
            index += 1
            let start = index
            while index < data.endIndex, isHexDigit(data[index]) { index += 1 }
            guard index < data.endIndex, data[index] == 0x3E, index - start == hexLength else {  // ">"
                return nil
            }
            let range = start..<index
            index += 1
            return range
        }
        guard let first = hexString(), let second = hexString() else { return nil }
        while index < data.endIndex, isWhitespace(data[index]) { index += 1 }
        guard index < data.endIndex, data[index] == 0x5D else { return nil }  // "]"
        return Location(first: first, second: second)
    }

    /// SHA-256 over `fileData` with the bytes at both payload ranges replaced
    /// by ASCII `0`. `location` is expressed in `fileData`'s indices.
    public static func digest(of fileData: Data, zeroing location: Location) -> Data {
        var hasher = SHA256()
        let zeros = Data(repeating: 0x30, count: hexLength)
        hasher.update(data: fileData[fileData.startIndex..<location.first.lowerBound])
        hasher.update(data: zeros)
        hasher.update(data: fileData[location.first.upperBound..<location.second.lowerBound])
        hasher.update(data: zeros)
        hasher.update(data: fileData[location.second.upperBound..<fileData.endIndex])
        return Data(hasher.finalize())
    }

    /// The identifier a digest yields: its first 16 bytes.
    public static func identifier(from digest: Data) -> Data {
        digest.prefix(identifierLength)
    }

    /// The 32 lowercase hex characters that spell `identifier` inside a hex
    /// string, as the bytes to write.
    public static func hexPayload(for identifier: Data) -> Data {
        Data(identifier.map { String(format: "%02x", $0) }.joined().utf8)
    }

    /// The bytes a 32-character hex payload spells, or nil when it is not
    /// hex of that length.
    public static func bytes(fromHexPayload payload: Data) -> Data? {
        guard payload.count == hexLength else { return nil }
        var out = Data(capacity: identifierLength)
        var iterator = payload.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            guard let h = hexValue(high), let l = hexValue(low) else { return nil }
            out.append(h << 4 | l)
        }
        return out
    }

    /// The identifier recomputed from a whole file, or nil when the file
    /// carries no pair in the writer's shape.
    public static func recomputedIdentifier(for fileData: Data) -> Data? {
        let tailStart = max(fileData.startIndex, fileData.endIndex - tailWindowLength)
        guard let location = locate(in: fileData[tailStart...]) else { return nil }
        return identifier(from: digest(of: fileData, zeroing: location))
    }

    // PDF 1.7 §7.2.2 white-space characters.
    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 || byte == 0x0C || byte == 0x00
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool { hexValue(byte) != nil }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}
