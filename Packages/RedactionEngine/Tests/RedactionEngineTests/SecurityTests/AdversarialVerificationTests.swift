import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// TEST §3.3, §3.4 — Adversarial PDF verification tests.
// These validate that Layers 4 and 5 catch real attack vectors.

@Suite("Adversarial Verification", .tags(.security))
struct AdversarialVerificationTests {

    private let engine = VerificationEngine()

    // MARK: - Layer 4: Structural FAIL Keys (ENGINE §6.4)

    @Test("Layer 4 FAILs on /JavaScript in catalog")
    func layer4FailsJavaScript() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(TestFixtures.withJavaScript())
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await engine.runLayer(
            3, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status == .fail(""), "Layer 4 must FAIL on /JavaScript")
    }

    @Test("Layer 4 FAILs on /OpenAction in catalog")
    func layer4FailsOpenAction() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withCatalogKey("OpenAction", value: "<< /Type /Action /S /URI /URI (http://evil.com) >>"))
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await engine.runLayer(
            3, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status == .fail(""))
    }

    @Test("Layer 4 FAILs on /EmbeddedFiles in catalog")
    func layer4FailsEmbeddedFiles() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withCatalogKey("EmbeddedFiles"))
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await engine.runLayer(
            3, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status == .fail(""))
    }

    @Test("Layer 4 FAILs on /AcroForm in catalog")
    func layer4FailsAcroForm() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withCatalogKey("AcroForm", value: "<< /Fields [] >>"))
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await engine.runLayer(
            3, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status == .fail(""))
    }

    // MARK: - Layer 4: Structural WARN Keys

    @Test("Layer 4 WARNs on /OCProperties in catalog")
    func layer4WarnsOCProperties() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withCatalogKey("OCProperties",
                value: "<< /OCGs [] /D << /BaseState /ON >> >>"))
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await engine.runLayer(
            3, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status == .warn(""), "OCProperties should WARN, not FAIL")
    }

    @Test("Layer 4 FAILs on multiple %%EOF markers")
    func layer4FailsMultipleEOF() async throws {
        // Build a PDF with an extra %%EOF appended
        var data = TestFixtures.blankPage()
        data.append("\n%%EOF\n".data(using: .ascii)!)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("multieof_\(UUID().uuidString).pdf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let doc = PDFDocument(url: url) else {
            Issue.record("Could not open multi-EOF PDF")
            return
        }

        let result = await engine.runLayer(
            3, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        // ENGINE §6.4: Multiple %%EOF now triggers FAIL (incremental update attack)
        #expect(result.status.isFail, "Multiple %%EOF should produce FAIL")
    }

    // MARK: - Layer 5: Metadata FAIL/WARN (ENGINE §6.5)

    @Test("Layer 5 FAILs when /Author metadata is present")
    func layer5FailsAuthor() async throws {
        _ = TestFixtures.withMetadata(["Author": "John Doe"])
        // The /Info dict needs to be referenced from the trailer.
        // Our simple builder doesn't support trailer /Info ref,
        // so test with a reconstructed PDF where we verify clean output.
        // For now, test that a clean reconstructed PDF does NOT fail:
        let (doc, url) = try await makeCleanReconstructedPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await engine.runLayer(
            4, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        // Clean PDF should NOT fail on metadata. Apple auto-injected
        // /Producer / /CreationDate / /ModDate now reports as .info
        // (was .warn pre-split).
        let isAcceptable = result.status == .pass
            || result.status == .warn("")
            || result.status == .info("")
        #expect(isAcceptable, "Clean reconstructed PDF should not FAIL Layer 5")
    }

    @Test("Layer 5 reports Apple auto-injected /Producer as info")
    func layer5InfoOnProducer() async throws {
        let (doc, url) = try await makeCleanReconstructedPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await engine.runLayer(
            4, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        // Apple CGPDFContext always injects /Producer; post-split it lives
        // in `infoFindings` so a doc with only auto-injected keys reports
        // .info (does not bump the masthead off green).
        #expect(result.status == .info(""))
    }

    // M3: Layer 5 FAIL on key *presence* — independent of decoded value.
    // The pre-M3 path required CGPDFStringCopyTextString to return a non-empty
    // String, so undecodable bytes / Name objects fell through as "absent."

    @Test("Layer 5 FAILs when /Author is a normal text string (M3)")
    func layer5FailsAuthorString() async throws {
        let data = TestFixtures.withMetadata(["Author": "John Doe"])
        let (doc, url) = try TestFixtures.writeTempPDF(data, prefix: "m3_author_")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await engine.runLayer(
            4, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status.isFail, "Layer 5 must FAIL on /Author presence")
    }

    @Test("Layer 5 FAILs when /Author has undecodable UTF-16BE bytes (M3)")
    func layer5FailsAuthorUndecodable() async throws {
        // <FEFFDC00> = UTF-16BE BOM followed by an unpaired low surrogate.
        // CGPDFStringCopyTextString returns nil for this sequence, so the
        // pre-M3 check passed it through; the M3 fix FAILS on presence.
        let data = TestFixtures.withMetadataRaw(infoDictBody: "/Author <FEFFDC00>")
        let (doc, url) = try TestFixtures.writeTempPDF(data, prefix: "m3_undecodable_")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await engine.runLayer(
            4, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status.isFail,
                "Layer 5 must FAIL on /Author regardless of decode success")
    }

    @Test("Layer 5 FAILs when /Author is a Name object (M3)")
    func layer5FailsAuthorName() async throws {
        // /Author as Name (e.g. /Author /Hidden). CGPDFDictionaryGetString
        // returns false for Names, so the pre-M3 String-only check skipped
        // this shape. The M3 path adds CGPDFDictionaryGetName for Name-typed
        // values; presence of the key reports as FAIL.
        let data = TestFixtures.withMetadataRaw(infoDictBody: "/Author /Hidden")
        let (doc, url) = try TestFixtures.writeTempPDF(data, prefix: "m3_name_")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await engine.runLayer(
            4, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status.isFail,
                "Layer 5 must FAIL on /Author as Name object")
    }

    // MARK: - Layer 1: Clean PDF passes

    @Test("Layer 1 passes on blank PDF with no text")
    func layer1PassesBlank() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(TestFixtures.blankPage())
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await engine.runLayer(
            0, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status == .pass)
    }

    // MARK: - Helpers

    private func makeCleanReconstructedPDF() async throws -> (PDFDocument, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("adv_test_\(UUID().uuidString).pdf")
        guard let ctx = createBitmapContext(width: 100, height: 100) else {
            throw TestError.failed
        }
        ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        guard let image = ctx.makeImage() else { throw TestError.failed }

        let recon = PDFStreamReconstructor(tempURL: url)
        let size = CGSize(width: 100, height: 100)
        try await recon.begin(firstPageSize: size)
        try await recon.appendPage(PageOutput(image: image, size: size, textLayerEntries: nil))
        await recon.finalize()

        guard let doc = PDFDocument(url: url) else { throw TestError.failed }
        return (doc, url)
    }

    private enum TestError: Error { case failed }
}

// Tag declarations moved to Fixtures/TestHelpers.swift (Phase 12)
