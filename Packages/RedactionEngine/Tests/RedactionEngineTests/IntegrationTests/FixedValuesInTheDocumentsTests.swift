import Foundation
import Testing
@testable import RedactionEngine

/// The privacy policy and the README state the fixed producer value an export
/// carries. They are read from the repository, found from this file's own
/// path, so a change to the value that leaves either document behind turns
/// this suite red. Neither document gives the fixed date's value (both say
/// only that the dates are a constant date); a `D:` date written into either
/// must be the fixed one.
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

    @Test("A date either document writes out is the fixed date",
          arguments: ["PRIVACY.md", "README.md"])
    func dateAsStated(_ name: String) throws {
        let text = try Self.document(name)
        var rest = text[...]
        while let found = rest.range(of: "D:") {
            let tail = rest[found.lowerBound...]
            #expect(tail.hasPrefix(PDFStreamReconstructor.fixedDateValue),
                    "\(name) writes a date that is not the fixed one: \(tail.prefix(24))")
            rest = rest[found.upperBound...]
        }
    }
}
