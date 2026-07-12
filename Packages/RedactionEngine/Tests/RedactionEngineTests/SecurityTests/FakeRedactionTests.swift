import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// TEST §3.2 — Fake redaction detection (Manafort/Calipari attack).
// Verifies that text hidden under opaque annotations is destroyed
// after processing through the pipeline.

@Suite("Fake Redaction Detection", .tags(.security, .critical))
struct FakeRedactionTests {

    @Test("Text under opaque annotation is destroyed by pipeline")
    func detectFakeRedaction() async throws {
        let fixture = TestFixtures.fakeRedaction(text: "TOP SECRET")
        let doc = try #require(PDFDocument(data: fixture))

        // Self-validate the attack: text IS extractable in the fixture
        #expect(doc.page(at: 0)?.string?.contains("TOP SECRET") == true,
                "Fixture broken: text must be extractable under annotation")

        // Process through redaction pipeline
        let output = try await TestPipeline.processAndExport(fixture)
        defer { try? FileManager.default.removeItem(at: output) }

        // Verify text is gone from text layer
        let outputDoc = try #require(PDFDocument(url: output))
        let outputText = outputDoc.page(at: 0)?.string ?? ""
        #expect(!outputText.contains("TOP SECRET"),
                "Fake-redacted text must not survive pipeline")
    }

    @Test("Fake redaction text absent from raw output bytes")
    func fakeRedactionBytesAbsent() async throws {
        let fixture = TestFixtures.fakeRedaction(text: "CLASSIFIED SECRET")
        let output = try await TestPipeline.processAndExport(fixture)
        defer { try? FileManager.default.removeItem(at: output) }

        let outputData = try Data(contentsOf: output)
        let term = "CLASSIFIED SECRET"
        for encoding: String.Encoding in [.utf8, .utf16BigEndian, .utf16LittleEndian] {
            guard let termData = term.data(using: encoding) else { continue }
            #expect(outputData.range(of: termData) == nil,
                    "Found fake-redacted text as \(encoding) in output bytes")
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
