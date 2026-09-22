import Testing
import Foundation
import CryptoKit
@testable import RedactionEngine

// The content-derived file identifier: the locator's guard discipline, the
// digest's independence from the pair's current value, the payload spelling,
// and the writer-side rewrite on synthetic tails (length preserved, only the
// two payloads change, idempotent, untouched on every guard). Real outputs
// are covered in ReconstructionTests and VerificationEngineTests.

@Suite("File identifier (content-derived /ID)")
struct PDFFileIdentifierTests {
    private let hexA = "82cf26c565acc557e6c401fb129cb808"
    private func tail(_ pair: String) -> Data {
        Data("HEADER…binary…\nstartxref\n161639\ntrailer\n<< /Size 10 /Root 8 0 R /Info 9 0 R /ID \(pair) >>\nstartxref\n161639\n%%EOF\n".utf8)
    }

    @Test("The locator returns the two 32-character payloads of the writer's pair")
    func locatorFindsThePair() throws {
        let data = tail("[ <\(hexA)>\n<\(hexA)> ]")
        let loc = try #require(PDFFileIdentifier.locate(in: data))
        #expect(String(decoding: data[loc.first], as: UTF8.self) == hexA)
        #expect(String(decoding: data[loc.second], as: UTF8.self) == hexA)
        #expect(loc.first.count == 32 && loc.second.count == 32)
        #expect(loc.first.upperBound < loc.second.lowerBound)
        // A tail slice keeps whole-file offsets.
        let slice = data[(data.count - 120)...]
        #expect(PDFFileIdentifier.locate(in: slice) == loc)
    }

    @Test("The locator refuses every shape the writer does not produce")
    func locatorGuards() {
        let short = String(hexA.prefix(16))
        let shapes: [(String, Data)] = [
            ("two markers", tail("[ <\(hexA)> <\(hexA)> ]") + Data("\n/ID [ <\(hexA)> <\(hexA)> ]\n".utf8)),
            ("16-character strings", tail("[ <\(short)> <\(short)> ]")),
            ("unequal lengths", tail("[ <\(hexA)> <\(short)> ]")),
            ("literal strings", tail("[ (\(hexA)) (\(hexA)) ]")),
            ("no closing bracket", tail("[ <\(hexA)> <\(hexA)>")),
            ("one string", tail("[ <\(hexA)> ]")),
            ("no pair at all", Data("no trailer here\n%%EOF\n".utf8)),
            ("a name-tree key is not the marker", Data("/IDTree [ <\(hexA)> <\(hexA)> ]".utf8)),
        ]
        for (name, data) in shapes {
            #expect(PDFFileIdentifier.locate(in: data) == nil, "\(name)")
        }
        // Whitespace variants of the writer's shape are accepted.
        #expect(PDFFileIdentifier.locate(in: tail("[<\(hexA)><\(hexA)>]")) != nil)
        #expect(PDFFileIdentifier.locate(in: Data("/ID\n[ <\(hexA)>\n<\(hexA)> ]".utf8)) != nil)
    }

    @Test("The digest ignores the pair's current value and tracks every other byte")
    func digestZeroesThePayloads() throws {
        let a = tail("[ <\(hexA)> <\(hexA)> ]")
        let other = "f5a35dae20182a4884673c1c71c391a0"
        let b = tail("[ <\(other)> <\(other)> ]")
        let la = try #require(PDFFileIdentifier.locate(in: a)), lb = try #require(PDFFileIdentifier.locate(in: b))
        #expect(PDFFileIdentifier.digest(of: a, zeroing: la) == PDFFileIdentifier.digest(of: b, zeroing: lb))
        var c = a; c[0] = UInt8(ascii: "h")
        #expect(PDFFileIdentifier.digest(of: c, zeroing: la) != PDFFileIdentifier.digest(of: a, zeroing: la))
        // Independent recomputation.
        var zeroed = a
        zeroed.replaceSubrange(la.first, with: Data(repeating: 0x30, count: 32))
        zeroed.replaceSubrange(la.second, with: Data(repeating: 0x30, count: 32))
        #expect(PDFFileIdentifier.digest(of: a, zeroing: la) == Data(SHA256.hash(data: zeroed)))
        #expect(PDFFileIdentifier.identifier(from: PDFFileIdentifier.digest(of: a, zeroing: la)).count == 16)
    }

    @Test("The payload spells the identifier as 32 lowercase hex characters and reads back")
    func payloadRoundTrip() {
        let id = Data((0..<16).map { UInt8($0 * 17 % 256) })
        let payload = PDFFileIdentifier.hexPayload(for: id)
        #expect(payload.count == 32)
        #expect(String(decoding: payload, as: UTF8.self) == String(decoding: payload, as: UTF8.self).lowercased())
        #expect(PDFFileIdentifier.bytes(fromHexPayload: payload) == id)
        #expect(PDFFileIdentifier.bytes(fromHexPayload: Data("zz".utf8)) == nil)
    }

    @Test("The rewrite changes only the two payloads, preserves the length, and is idempotent")
    func rewriteOnSyntheticTail() throws {
        let before = tail("[ <\(hexA)>\n<\(hexA)> ]")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fileid_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try before.write(to: url)
        PDFStreamReconstructor.overwriteFileIdentifier(at: url)
        let after = try Data(contentsOf: url)
        #expect(after.count == before.count)
        let loc = try #require(PDFFileIdentifier.locate(in: before))
        let expected = PDFFileIdentifier.hexPayload(
            for: PDFFileIdentifier.identifier(from: PDFFileIdentifier.digest(of: before, zeroing: loc)))
        #expect(after[loc.first] == expected)
        #expect(after[loc.second] == expected)
        var patched = before
        patched.replaceSubrange(loc.first, with: expected)
        patched.replaceSubrange(loc.second, with: expected)
        #expect(after == patched, "nothing outside the two payloads may move")
        PDFStreamReconstructor.overwriteFileIdentifier(at: url)
        #expect(try Data(contentsOf: url) == after, "a second pass changes no byte")
    }

    @Test("The rewrite leaves a file without the pair, or with two markers, untouched")
    func rewriteGuardsLeaveFileUntouched() throws {
        for (name, data) in [("no pair", Data("no trailer here\nstartxref\n0\n%%EOF\n".utf8)),
                             ("two markers", tail("[ <\(hexA)> <\(hexA)> ]") + Data("\n/ID [ <\(hexA)> <\(hexA)> ]\n".utf8))] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("fileid_guard_\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: url) }
            try data.write(to: url)
            PDFStreamReconstructor.overwriteFileIdentifier(at: url)
            #expect(try Data(contentsOf: url) == data, "\(name)")
        }
    }
}
