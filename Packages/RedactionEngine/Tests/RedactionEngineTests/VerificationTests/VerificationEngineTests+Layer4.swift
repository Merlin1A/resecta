import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
@testable import RedactionEngine

extension VerificationEngineTests {

    // MARK: - Layer 4: Structural Verification

    @Test("Layer 4 passes on clean reconstructed PDF")
    func layer4PassesClean() async throws {
        let (doc, url) = try await makeCleanPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .structureCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        // Clean PDF should have no JavaScript, no forms, etc.
        let isClean = result.status == .pass
            || result.status == .warn("")
            || result.status == .info("")
        #expect(isClean, "Clean PDF should pass, warn, or be info-only (not fail) structural check")
    }

    // MARK: - Layer 4: /Names name-dictionary carriers

    @Test("Layer 4 FAILs on active-content subtrees under /Names",
          arguments: ["EmbeddedFiles", "JavaScript"])
    func layer4FailsOnNamesTreeCarrier(carrier: String) async throws {
        // The real-world carrier location for embedded files and document
        // JavaScript is /Names → /<carrier>, not the catalog top level.
        // Pre-fix this surfaced only as the generic "Structural findings:
        // Names" WARN.
        let fixture = TestFixtures.withCatalogKey(
            "Names", value: "<< /\(carrier) << /Names [] >> >>")
        let (doc, url) = try TestFixtures.writeTempPDF(fixture, prefix: "names_carrier_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .structureCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status.isFail,
                "/Names → /\(carrier) must FAIL; got \(result.status)")
        if case .fail(let msg) = result.status {
            #expect(msg == "\(carrier) found under /Names in document catalog",
                    "FAIL message should name the carrier under /Names; got \(msg)")
        }
    }

    @Test("Layer 4 keeps generic WARN for plain /Names without carriers")
    func layer4WarnsOnPlainNames() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withCatalogKey("Names"), prefix: "names_plain_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .structureCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status.isWarn,
                "Plain /Names with no carrier subtrees stays WARN; got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg.contains("Names"), "WARN message should name /Names; got \(msg)")
        }
    }

    @Test("Layer 4 still FAILs on top-level EmbeddedFiles")
    func layer4FailsTopLevelEmbeddedFiles() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withCatalogKey("EmbeddedFiles"), prefix: "embedded_top_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .structureCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status.isFail,
                "Top-level EmbeddedFiles must FAIL unchanged; got \(result.status)")
        if case .fail(let msg) = result.status {
            #expect(msg == "EmbeddedFiles found in document catalog",
                    "Top-level FAIL message unchanged; got \(msg)")
        }
    }

    // MARK: - Layer 4: Incremental Update Detection

    @Test("Layer 4 FAILs on PDF with incremental update (multiple %%EOF)")
    func layer4FailsIncrementalUpdate() async throws {
        let fixture = TestFixtures.incrementalUpdate(
            originalText: "ORIGINAL SECRET", updatedText: "REDACTED"
        )
        let (doc, url) = try TestFixtures.writeTempPDF(fixture, prefix: "incremental_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .structureCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        // Incremental update produces multiple %%EOF → FAIL.
        #expect(result.status.isFail,
                "Layer 4 should FAIL on incremental update (multiple %%EOF)")
    }

    // MARK: - Stream-range EOL gate

    @Test("Layer 3: a /Downstream token cannot open a phantom stream range")
    func layer3DownstreamPhantomRangeGated() async throws {
        // Structural term sits between a /Downstream name and the document's
        // only real stream. Pre-gate, the "stream" letters inside
        // "Downstream" opened a phantom range to the real `endstream`, and
        // the term inside that span was excluded from the structural pass —
        // the layer reported nothing.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.downstreamPhantomRange(term: "DELIAHARTWELL"),
            prefix: "phantom_range_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .binaryStringSearch, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: ["DELIAHARTWELL"].map { SensitiveTerm(text: $0) },
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isFail,
                "structural term after a /Downstream token must FAIL; got \(result.status)")
        if case .fail(let msg) = result.status {
            #expect(msg.contains("structural data"), "got: \(msg)")
        }
    }

    @Test("Layer 3: malformed stream keyword EOL still excludes stream data (fallback)")
    func layer3MalformedStreamEOLFallback() async throws {
        // The only `stream` keyword is followed by a bare CR (spec-invalid),
        // so the strict pass yields no ranges. The permissive fallback must
        // still exclude the stream data: a term living only inside it stays
        // out of the structural FAIL path (compressed-stream bytes would
        // otherwise become false-positive fodder on malformed files).
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.malformedStreamKeywordEOL(term: "DELIAHARTWELL"),
            prefix: "malformed_eol_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .binaryStringSearch, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: ["DELIAHARTWELL"].map { SensitiveTerm(text: $0) },
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(!result.status.isFail,
                "term inside malformed stream data must stay excluded; got \(result.status)")
    }
}
