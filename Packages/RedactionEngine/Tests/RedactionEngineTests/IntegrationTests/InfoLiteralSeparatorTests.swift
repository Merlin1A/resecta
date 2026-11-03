import Testing
import Foundation
@testable import RedactionEngine

// The /Info literal rewrite and the whitespace between a key and its value.
// PDF allows any whitespace, or none, between a name and the string that
// follows it. iOS 26's writer puts one space there; iOS 27's writer puts a
// newline after /CreationDate, and a rewrite that looked only for
// "/CreationDate (" left the export time in every file. The rewrite now
// takes any PDF whitespace between the key and the opening paren.

@Suite("Info literal rewrite: the separator after the key")
struct InfoLiteralSeparatorTests {

    static let producer = "iOS Version 27.2 \\(Build 24B8117\\) Quartz PDFContext"
    static let date = "D:20261031185415Z00'00'"

    private func tail(separator: String) -> String {
        "9 0 obj\n<< /Producer (\(Self.producer)) /CreationDate\(separator)(\(Self.date)) "
            + "/ModDate (\(Self.date)) >>\nendobj\nxref\n0 10\n0000000000 65535 f \ntrailer\n"
            + "<< /Size 10 /Root 8 0 R /Info 9 0 R >>\nstartxref\n28929\n%%EOF\n"
    }

    private func rewritten(_ text: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("info_separator_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(text.utf8).write(to: url)
        PDFStreamReconstructor.overwriteInfoLiterals(at: url)
        let after = try Data(contentsOf: url)
        #expect(after.count == text.utf8.count, "the rewrite keeps the file's length")
        return String(decoding: after, as: UTF8.self)
    }

    @Test("Each date is rewritten whatever whitespace, or none, follows its key",
          arguments: ["\n", " ", "\r\n", "\t", "", "  \n"])
    func dateRewrittenAfterAnySeparator(separator: String) throws {
        let before = tail(separator: separator)
        let after = try rewritten(before)
        let fixed = PDFStreamReconstructor.fixedDateValue
        let padding = String(repeating: " ", count: Self.producer.utf8.count - PDFStreamReconstructor.fixedProducerValue.utf8.count)
        let expected = before
            .replacingOccurrences(of: "(\(Self.producer))", with: "(\(PDFStreamReconstructor.fixedProducerValue))\(padding)")
            .replacingOccurrences(of: "(\(Self.date))", with: "(\(fixed))")
        #expect(after == expected, "only the three values change; the separator and every other byte stay")
        #expect(!after.contains(Self.date), "no export time is left in the file")
    }

    @Test("A longer key that starts with the same name is not taken for the date")
    func longerKeyIsNotMatched() throws {
        let text = "<< /CreationDateX (\(Self.date)) >>\nstartxref\n0\n%%EOF\n"
        #expect(try rewritten(text) == text)
    }

    @Test("Two date literals, one per separator, are both left alone")
    func twoLiteralsAcrossSeparatorsAreLeftAlone() throws {
        let text = "<< /CreationDate (\(Self.date)) /CreationDate\n(\(Self.date)) >>\nstartxref\n0\n%%EOF\n"
        #expect(try rewritten(text) == text)
    }
}
