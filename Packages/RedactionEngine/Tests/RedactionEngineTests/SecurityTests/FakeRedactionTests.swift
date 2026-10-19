import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// Fake redaction detection (Manafort/Calipari attack).
// Text drawn under an opaque annotation stays extractable in the source.
// In Searchable mode the output keeps a text layer, so the text leaves it
// only when a redaction region covers it: the region tests below depend on
// the redaction, and the no-region control shows the same read-back reads
// the text when nothing is redacted. In Secure mode the output carries no
// text layer at all (a mode invariant).

@Suite("Fake Redaction Detection", .tags(.security, .critical))
struct FakeRedactionTests {

    /// The fixture's annotation rectangle (x 70, y 690, 300 × 40 pt on the
    /// 612 × 792 pt page), normalized with a bottom-left origin: the region
    /// over the text the annotation hides.
    static func annotationRegion() -> RedactionRegion {
        RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 70.0 / 612, y: 690.0 / 792, width: 300.0 / 612, height: 40.0 / 792),
            source: .manual)
    }

    @Test("Searchable: text under an opaque annotation leaves the text layer when a region covers it")
    func detectFakeRedaction() async throws {
        let fixture = TestFixtures.fakeRedaction(text: "TOP SECRET")
        let doc = try #require(PDFDocument(data: fixture))

        // Self-validate the attack: text IS extractable in the fixture
        #expect(doc.page(at: 0)?.string?.contains("TOP SECRET") == true,
                "Fixture broken: text must be extractable under annotation")

        let output = try await TestPipeline.processAndExport(
            fixture, mode: .searchableRedaction, regions: [0: [Self.annotationRegion()]])
        defer { try? FileManager.default.removeItem(at: output) }

        let outputDoc = try #require(PDFDocument(url: output))
        let outputText = outputDoc.page(at: 0)?.string ?? ""
        #expect(!outputText.contains("TOP SECRET"),
                "Fake-redacted text must not survive a covering region")
    }

    @Test("Searchable: text under an opaque annotation is absent from the raw output bytes when a region covers it")
    func fakeRedactionBytesAbsent() async throws {
        let fixture = TestFixtures.fakeRedaction(text: "CLASSIFIED SECRET")
        let output = try await TestPipeline.processAndExport(
            fixture, mode: .searchableRedaction, regions: [0: [Self.annotationRegion()]])
        defer { try? FileManager.default.removeItem(at: output) }

        let outputData = try Data(contentsOf: output)
        let term = "CLASSIFIED SECRET"
        for encoding: String.Encoding in [.utf8, .utf16BigEndian, .utf16LittleEndian] {
            guard let termData = term.data(using: encoding) else { continue }
            #expect(outputData.range(of: termData) == nil,
                    "Found fake-redacted text as \(encoding) in output bytes")
        }
    }

    /// The control: the same fixture and read-back with no region carries
    /// the text, so the two assertions above can fail.
    @Test("Searchable with no region: the text under the annotation stays in the text layer")
    func fakeRedactionTextSurvivesWithoutRegion() async throws {
        let fixture = TestFixtures.fakeRedaction(text: "TOP SECRET")
        let output = try await TestPipeline.processAndExport(
            fixture, mode: .searchableRedaction, regions: [0: []])
        defer { try? FileManager.default.removeItem(at: output) }

        let outputDoc = try #require(PDFDocument(url: output))
        let outputText = outputDoc.page(at: 0)?.string ?? ""
        #expect(outputText.contains("TOP SECRET"),
                "the control output must carry the text when no region covers it")
    }

    @Test("Secure output carries no text under the annotation (a mode invariant: no text layer)")
    func secureOutputCarriesNoText() async throws {
        let fixture = TestFixtures.fakeRedaction(text: "CLASSIFIED SECRET")
        let output = try await TestPipeline.processAndExport(fixture)
        defer { try? FileManager.default.removeItem(at: output) }

        let outputDoc = try #require(PDFDocument(url: output))
        let outputText = outputDoc.page(at: 0)?.string ?? ""
        #expect(outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Secure output has no text layer")
        let outputData = try Data(contentsOf: output)
        for encoding: String.Encoding in [.utf8, .utf16BigEndian, .utf16LittleEndian] {
            guard let termData = "CLASSIFIED SECRET".data(using: encoding) else { continue }
            #expect(outputData.range(of: termData) == nil,
                    "Found the text as \(encoding) in Secure output bytes")
        }
    }

    @Test("Output has zero annotations after processing fake redaction")
    func noAnnotationsInOutput() async throws {
        let fixture = TestFixtures.fakeRedaction(text: "ANNOTATED")
        let output = try await TestPipeline.processAndExport(fixture)
        defer { try? FileManager.default.removeItem(at: output) }

        let outputDoc = try #require(PDFDocument(url: output))
        let page = try #require(outputDoc.page(at: 0))
        #expect(page.annotations.isEmpty, "Output should have zero annotations")
    }
}
