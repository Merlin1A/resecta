import Foundation
@testable import RedactionEngine

// Raw fixtures in the shape the producer leaves an export in. The Document
// Metadata check reads a file with no identifier, or without one of the three
// fixed fields, as not the writer's; a test of another property of that check
// starts from this shape.

extension TestFixtures {

    /// The three fixed fields as the producer leaves them.
    static var fixedWriterFields: String {
        let date = PDFStreamReconstructor.fixedDateValue
        return "/Producer (\(PDFStreamReconstructor.fixedProducerValue)) /CreationDate (\(date)) /ModDate (\(date))"
    }

    /// `data` with an `/ID` pair derived from its own bytes in the trailer,
    /// as the producer writes it. The pair goes into the trailer, after the
    /// cross-reference table, so no offset moves. Nil when `data` has no
    /// trailer with a `/Root` entry.
    static func withDerivedIdentifier(_ data: Data) -> Data? {
        var bytes = Data(data)
        guard let trailer = bytes.range(of: Data("trailer".utf8), options: .backwards),
              let root = bytes.range(of: Data("/Root".utf8), in: trailer.upperBound..<bytes.endIndex) else { return nil }
        let zero = String(repeating: "0", count: PDFFileIdentifier.hexLength)
        bytes.insert(contentsOf: Data("/ID [<\(zero)> <\(zero)>] ".utf8), at: root.lowerBound)
        guard let location = PDFFileIdentifier.location(in: bytes) else { return nil }
        let payload = PDFFileIdentifier.hexPayload(
            for: PDFFileIdentifier.identifier(from: PDFFileIdentifier.digest(of: bytes, zeroing: location)))
        bytes.replaceSubrange(location.first, with: payload)
        bytes.replaceSubrange(location.second, with: payload)
        return bytes
    }

    /// `withMetadataRaw(infoDictBody:)` in the writer's shape: the body, any
    /// of the three fixed fields it does not name, and a derived identifier.
    static func writerShapedMetadata(infoDictBody: String) -> Data {
        let date = PDFStreamReconstructor.fixedDateValue
        var body = infoDictBody
        for (key, value) in [("Producer", PDFStreamReconstructor.fixedProducerValue),
                             ("CreationDate", date), ("ModDate", date)] where !body.contains("/\(key)") {
            body += " /\(key) (\(value))"
        }
        let raw = withMetadataRaw(infoDictBody: body)
        return withDerivedIdentifier(raw) ?? raw
    }
}
