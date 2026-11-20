import Testing
import Foundation
import CoreGraphics
@testable import RedactionEngine

// The fixed values an export carries in place of the writer's own, read as
// words. The writer's rewrite and the metadata check both read the same
// constants, so a changed constant moves both together and every other test
// still passes; these two read the words themselves, from the constant and
// from an exported file's bytes.

@Suite("The fixed metadata values, by their words")
struct FixedMetadataValuesTests {

    static let producerWords = "Resecta"
    static let dateWords = "D:20000101000000Z00'00'"

    /// One page drawn through CoreGraphics, so the suite runs on the Mac host too.
    static func onePage() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.fill(CGRect(x: 72, y: 72, width: 100, height: 20))
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// The export's /Info value for `key`, as the system reader gives it.
    static func infoValue(_ key: String, in bytes: Data) -> String? {
        guard let provider = CGDataProvider(data: bytes as CFData), let doc = CGPDFDocument(provider),
              let info = doc.info else { return nil }
        var ref: CGPDFStringRef?
        guard CGPDFDictionaryGetString(info, key, &ref), let ref,
              let text = CGPDFStringCopyTextString(ref) else { return nil }
        var value = text as String
        while value.hasSuffix(" ") { value.removeLast() }
        return value
    }

    static func export() async throws -> Data {
        let url = try await TestPipeline.processAndExport(onePage(), mode: .secureRasterization)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }

    @Test("An export's producer reads Resecta")
    func producerIsResecta() async throws {
        #expect(PDFStreamReconstructor.fixedProducerValue == Self.producerWords)
        let bytes = try await Self.export()
        #expect(Self.infoValue("Producer", in: bytes) == Self.producerWords)
        #expect(bytes.range(of: Data("(\(Self.producerWords)".utf8)) != nil)
    }

    @Test("An export's creation and change dates read the fixed date")
    func datesAreTheFixedDate() async throws {
        #expect(PDFStreamReconstructor.fixedDateValue == Self.dateWords)
        let bytes = try await Self.export()
        #expect(Self.infoValue("CreationDate", in: bytes) == Self.dateWords)
        #expect(Self.infoValue("ModDate", in: bytes) == Self.dateWords)
    }
}
