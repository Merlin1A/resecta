import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// Sensitive term absence — what the redaction removes, proved on the mode
// whose output carries a text layer.
//
// In Searchable Redaction mode the output keeps an invisible text layer of
// the characters that survive the regions, so a planted term's absence
// from that layer is the redaction's doing: the same fixture exported with
// NO region carries the term (the control below — the assertion can fail).
// Secure Rasterization output has no text layer at all, so a byte scan of
// it is true of the mode, not of the redaction; the two mode-invariant
// tests state exactly that.
//
// The text layer is read back through PDFKit (`page.string`): the output is
// written by `CGPDFContext`, whose content streams are Flate-compressed, so
// no raw-byte scan can see the layer's text either way.

struct SensitiveTermCase: Sendable, CustomTestStringConvertible {
    let name: String
    let terms: [String]
    var testDescription: String { name }
}

@Suite("Sensitive Term Absence", .tags(.security, .critical))
struct SensitiveTermAbsenceTests {

    /// The planted line sits at the top of the page (`textLayerPDF` draws
    /// at 72 pt from the top-left at 12 pt); this band covers it.
    private static let plantedLineBand = CGRect(x: 0, y: 0.85, width: 1, height: 0.12)

    private static func plantedFixture(_ term: String) -> Data {
        TestFixtures.textLayerPDF(text: "Record for \(term) on file.", fontSize: 12)
    }

    private static func textLayer(of output: URL) throws -> String {
        let outputDoc = try #require(PDFDocument(url: output))
        return outputDoc.page(at: 0)?.string ?? ""
    }

    @Test("Searchable output's text layer drops a planted term under a region", arguments: [
        SensitiveTermCase(name: "SSN", terms: ["123-45-6789"]),
        SensitiveTermCase(name: "Name", terms: ["Jane A. Sample"]),
        SensitiveTermCase(name: "Address", terms: ["742 Evergreen Terrace"]),
        SensitiveTermCase(name: "Credit Card", terms: ["4111-1111-1111-1111"]),
    ])
    func verifySensitiveTermAbsent(_ tc: SensitiveTermCase) async throws {
        for term in tc.terms {
            let fixture = Self.plantedFixture(term)
            let region = RedactionRegion(
                id: UUID(), normalizedRect: Self.plantedLineBand, source: .manual)
            let output = try await TestPipeline.processAndExport(
                fixture, mode: .searchableRedaction, regions: [0: [region]])
            defer { try? FileManager.default.removeItem(at: output) }

            let text = try Self.textLayer(of: output)
            #expect(!text.contains(term),
                    "'\(term)' survived in the searchable output's text layer under a covering region")
        }
    }

    /// The control: the same fixture and read-back with no region carries
    /// the term, so the assertion above can fail.
    @Test("Searchable output's text layer carries the planted term when nothing is redacted", arguments: [
        SensitiveTermCase(name: "SSN", terms: ["123-45-6789"]),
        SensitiveTermCase(name: "Name", terms: ["Jane A. Sample"]),
    ])
    func plantedTermSurvivesWithoutRegions(_ tc: SensitiveTermCase) async throws {
        for term in tc.terms {
            let fixture = Self.plantedFixture(term)
            let output = try await TestPipeline.processAndExport(
                fixture, mode: .searchableRedaction, regions: [0: []])
            defer { try? FileManager.default.removeItem(at: output) }

            let text = try Self.textLayer(of: output)
            #expect(text.contains(term),
                    "the control fixture must carry '\(term)' in its text layer when no region covers it")
        }
    }

    // MARK: - Secure Rasterization: the mode's invariants

    @Test("Secure output carries no term bytes in any encoding (a mode invariant: no text layer)", arguments: [
        SensitiveTermCase(name: "SSN", terms: ["123-45-6789"]),
        SensitiveTermCase(name: "Name", terms: ["Jane A. Sample"]),
        SensitiveTermCase(name: "Address", terms: ["742 Evergreen Terrace"]),
        SensitiveTermCase(name: "Credit Card", terms: ["4111-1111-1111-1111"]),
    ])
    func secureOutputBytesCarryNoTerm(_ tc: SensitiveTermCase) async throws {
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
