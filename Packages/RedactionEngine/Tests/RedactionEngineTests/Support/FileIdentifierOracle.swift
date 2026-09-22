import CryptoKit
import Foundation

/// An independent reading of a file's trailer `/ID` pair for the tests: the
/// writer's `/ID [ <32 hex> <32 hex> ]` shape is located by the oracle's own
/// scan of the file's tail, and the content digest is recomputed with
/// CryptoKit directly, so no expectation below comes from the engine code
/// that writes or attests the identifier.
enum FileIdentifierOracle {
    struct Pair {
        let first: Range<Int>   // byte range of the first 32-character payload
        let second: Range<Int>  // byte range of the second
    }

    /// The single pair in the last 256 KB of `data`, or nil (absent, or more
    /// than one candidate).
    static func pair(in data: Data) -> Pair? {
        let tailStart = max(0, data.count - 262_144)
        let tail = data.subdata(in: tailStart..<data.count)
        // Latin-1 keeps one character per byte, so string offsets are byte offsets.
        guard let text = String(data: tail, encoding: .isoLatin1) else { return nil }
        let pattern = #"/ID\s*\[\s*<([0-9A-Fa-f]{32})>\s*<([0-9A-Fa-f]{32})>\s*\]"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        guard matches.count == 1, let m = matches.first else { return nil }
        let r1 = m.range(at: 1), r2 = m.range(at: 2)
        return Pair(first: (tailStart + r1.location)..<(tailStart + r1.location + r1.length),
                    second: (tailStart + r2.location)..<(tailStart + r2.location + r2.length))
    }

    /// The identifier the writer's policy yields for `data`: the first 16
    /// bytes of SHA-256 over the file with both payloads replaced by ASCII
    /// `0`, spelled as 32 lowercase hex characters.
    static func expectedHex(for data: Data, pair: Pair) -> String {
        var zeroed = data
        let zeros = Data(repeating: 0x30, count: 32)
        zeroed.replaceSubrange(pair.first, with: zeros)
        zeroed.replaceSubrange(pair.second, with: zeros)
        let digest = SHA256.hash(data: zeroed)
        return Data(digest).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The payload at `range`, lowercased.
    static func hex(_ data: Data, _ range: Range<Int>) -> String {
        String(decoding: data.subdata(in: range), as: UTF8.self).lowercased()
    }
}
