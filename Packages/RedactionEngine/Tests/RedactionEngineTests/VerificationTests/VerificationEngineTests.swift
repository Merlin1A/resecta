import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
@testable import RedactionEngine

// Verification engine tests.

@Suite("Verification Engine")
struct VerificationEngineTests {

    // MARK: - Layer Count (never hardcoded)

    @Test("Secure Rasterization has 7 layers, Searchable has 12")
    func layerCounts() {
        let engine = VerificationEngine()
        #expect(engine.layers(for: .secureRasterization).count == 7)
        #expect(engine.layers(for: .searchableRedaction).count == 12)
        // The two post-sequential checks close both orders.
        #expect(engine.layers(for: .searchableRedaction).suffix(2) == [.searchRecheck, .detectionSweep])
        #expect(engine.layers(for: .searchableRedaction)[10].name == "Search Re-check")
        #expect(engine.layers(for: .searchableRedaction)[11].name == "Detection Sweep")
        #expect(engine.layers(for: .secureRasterization)[5].name == "Search Re-check")
        #expect(engine.layers(for: .secureRasterization)[6].name == "Detection Sweep")
    }

    // MARK: - Layer Names and Symbols

    @Test("Every Searchable-mode layer has a non-empty name and symbol")
    func layerNamesAndSymbols() {
        let engine = VerificationEngine()
        let layers = engine.layers(for: .searchableRedaction)
        for i in 0..<engine.layers(for: .searchableRedaction).count {
            #expect(!layers[i].name.isEmpty)
            #expect(!layers[i].symbolName.isEmpty)
        }
    }

    // MARK: - End-to-End: Reconstruct then Verify

    @Test("Full raster verification passes on reconstructed output")
    func fullVerificationOnReconstructedPDF() async throws {
        let (doc, url) = try await makeCleanPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        var layers: [LayerResult] = []

        for layer in engine.layers(for: .secureRasterization) {
            let result = await engine.runLayer(
                layer, outputDocument: SendablePDFDocument(doc),
                sourcePageCount: 1, regions: [:], sensitiveTerms: [],
                pipelineMode: .secureRasterization,
                filterDigests: [], perPageModes: [.secureRasterization]
            )
            layers.append(result)
        }

        let overall = engine.aggregateStatus(layers)
        // Should be PASS or WARN (Apple metadata). Never FAIL on clean output.
        #expect(overall != .fail(""),
                "Clean reconstructed PDF should not FAIL verification")
    }

    // MARK: - Layer Name and Symbol Coverage

    @Test("All layer names are non-empty for both modes",
          arguments: [PipelineMode.secureRasterization, PipelineMode.searchableRedaction])
    func allLayerNamesNonEmpty(mode: PipelineMode) {
        let engine = VerificationEngine()
        let layers = engine.layers(for: mode)
        for (i, layer) in layers.enumerated() {
            #expect(!layer.name.isEmpty,
                    "Layer \(i) name should be non-empty for \(mode)")
        }
    }

    @Test("All layer symbols are non-empty for both modes",
          arguments: [PipelineMode.secureRasterization, PipelineMode.searchableRedaction])
    func allLayerSymbolsNonEmpty(mode: PipelineMode) {
        let engine = VerificationEngine()
        let layers = engine.layers(for: mode)
        #expect(layers.count == engine.layers(for: mode).count)
        for (i, layer) in layers.enumerated() {
            #expect(!layer.symbolName.isEmpty,
                    "Layer \(i) symbol should be non-empty for \(mode)")
        }
    }

    @Test("aggregateStatus with only skipped layers returns skipped")
    func allSkippedReturnsSkipped() {
        let engine = VerificationEngine()
        let layers = [makeResult(.skipped), makeResult(.skipped)]
        // All-skipped is the .skipped sentinel, not a silent .pass.
        #expect(engine.aggregateStatus(layers) == .skipped)
    }

    // MARK: - Unopenable-page honesty

    /// A document whose page 2 (index 1) cannot be opened.
    /// PDFKit synthesizes a PDFPage even for a broken /Kids entry (measured
    /// on macOS 15 / iOS 26.4), so an unopenable page cannot be produced
    /// from fixture bytes; overriding `page(at:)` models the same runtime
    /// condition through the public `runLayer` API.
    private final class UnopenablePageDocument: PDFDocument {
        override func page(at index: Int) -> PDFPage? {
            index == 1 ? nil : super.page(at: index)
        }
    }

    private func makeUnopenableSecondPageDoc() throws -> (PDFDocument, URL) {
        let data = TestFixtures.twoBlankPages()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unopenable_\(UUID().uuidString).pdf")
        try data.write(to: url)
        guard let doc = UnopenablePageDocument(url: url) else { throw TestError.failed }
        return (doc, url)
    }

    @Test("Layer 1 WARNs when a page cannot be read, with the page referenced")
    func layer1UnreadablePageWarns() async throws {
        let (doc, url) = try makeUnopenableSecondPageDoc()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .textExtraction, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 2, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization, .secureRasterization])
        #expect(result.status.isWarn,
                "an unreadable page must WARN, not fold into PASS; got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg.contains("could not be read"), "got: \(msg)")
            #expect(msg.contains("2"), "copy prints the 1-based page number; got: \(msg)")
        }
        #expect(result.pageReferences == [1],
                "0-based reference to the unreadable page; got \(String(describing: result.pageReferences))")
    }

    @Test("Layer 2 buckets an unopenable page as unchecked")
    func layer2UnopenablePageUnchecked() async throws {
        let (doc, url) = try makeUnopenableSecondPageDoc()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .ocrCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 2, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization, .secureRasterization])
        #expect(result.status.isWarn,
                "an unopenable page was never OCR-checked → unchecked WARN; got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg.contains("OCR could not be run"), "got: \(msg)")
            #expect(result.couldNotVerify, "OCR could not be run: the check did not fully run")
        }
        #expect(result.pageReferences == [1],
                "got \(String(describing: result.pageReferences))")
    }

    @Test("Layer 6 WARNs when an eligible page cannot be read")
    func layer6UnreadablePageWarns() async throws {
        let (doc, url) = try makeUnopenableSecondPageDoc()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .spatialVerification, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 2, regions: [:], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil, nil],
            perPageModes: [.searchableRedaction, .searchableRedaction])
        #expect(result.status.isWarn, "got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg.contains("could not be read"), "got: \(msg)")
        }
        #expect(result.pageReferences == [1],
                "got \(String(describing: result.pageReferences))")
    }

    @Test("Layer 8 WARNs when an eligible page cannot be read")
    func layer8UnreadablePageWarns() async throws {
        let (doc, url) = try makeUnopenableSecondPageDoc()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .fontVerification, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 2, regions: [:], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil, nil],
            perPageModes: [.searchableRedaction, .searchableRedaction])
        #expect(result.status.isWarn, "got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg.contains("could not be read"), "got: \(msg)")
        }
        #expect(result.pageReferences == [1],
                "got \(String(describing: result.pageReferences))")
    }

    private func makeResult(_ status: VerificationStatus) -> LayerResult {
        LayerResult(name: "Test", symbolName: "circle", status: status,
                    shortDescription: "", detailDescription: "",
                    pageReferences: nil, durationSeconds: 0)
    }
}
