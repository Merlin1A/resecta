import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// TEST §3.1 — Parameterized sensitive term absence tests.
// Verifies that PII terms are completely absent from output PDF bytes
// across UTF-8, UTF-16BE, and UTF-16LE encodings.

struct SensitiveTermCase: Sendable, CustomTestStringConvertible {
    let name: String
    let terms: [String]
    var testDescription: String { name }
}

@Suite("Sensitive Term Absence", .tags(.security, .critical))
struct SensitiveTermAbsenceTests {

    @Test("Sensitive terms absent from output bytes", arguments: [
        SensitiveTermCase(name: "SSN", terms: ["123-45-6789"]),
        SensitiveTermCase(name: "Name", terms: ["Jane A. Sample"]),
        SensitiveTermCase(name: "Address", terms: ["742 Evergreen Terrace"]),
        SensitiveTermCase(name: "Credit Card", terms: ["4111-1111-1111-1111"]),
    ])
    func verifySensitiveTermAbsent(_ tc: SensitiveTermCase) async throws {
        let fixture = TestFixtures.documentWithPII(terms: tc.terms)
        let output = try await TestPipeline.processAndExport(fixture)
        defer { try? FileManager.default.removeItem(at: output) }

        let outputData = try Data(contentsOf: output)

        for term in tc.terms {
            for encoding: String.Encoding in [.utf8, .utf16BigEndian, .utf16LittleEndian] {
                guard let termData = term.data(using: encoding) else { continue }
                #expect(outputData.range(of: termData) == nil,
                        "Found '\(term)' as \(encoding) in output PDF")
            }
        }
    }

    @Test("Output text layer is empty after secure rasterization of PII document")
    func noTextLayerInOutput() async throws {
        let fixture = TestFixtures.documentWithPII(terms: ["123-45-6789"])
        let output = try await TestPipeline.processAndExport(fixture)
        defer { try? FileManager.default.removeItem(at: output) }

        let outputDoc = try #require(PDFDocument(url: output))
        let text = outputDoc.page(at: 0)?.string ?? ""
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Secure rasterization output should have no text layer")
    }
}
