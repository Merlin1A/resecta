import Foundation
import Testing
@testable import RedactionEngine

/// The privacy policy and the README state the fixed producer value an export
/// carries. They are read from the repository, found from this file's own
/// path, so a change to the value that leaves either document behind turns
/// this suite red. Neither document gives the fixed date's value (both say
/// only that the dates are a constant date), so there is no date here to
/// read; the date's words are pinned by `FixedMetadataValuesTests`.
@Suite("The fixed metadata values, as the documents state them")
struct FixedValuesInTheDocumentsTests {
    static func document(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent(name)
        try #require(FileManager.default.fileExists(atPath: url.path), "\(name) is read at the repository root")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Each document states the producer value the export carries",
          arguments: ["PRIVACY.md", "README.md"])
    func producerAsStated(_ name: String) throws {
        let text = try Self.document(name)
        let stated = "fixed value (\"\(PDFStreamReconstructor.fixedProducerValue)\")"
        #expect(text.contains(stated), "\(name) states \(stated)")
    }
}
