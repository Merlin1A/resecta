import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

// The verification schedule as the product and the corpus harness run it:
// the event order the app's progress UI relies on (one `.layerStarted`
// for the parallel batch, its results published in canonical order, then
// each sequential layer started → finished), the report's canonical layer
// order, and the page-count gate short-circuit.

@Suite("VerificationOrchestrator — the schedule and its events")
struct VerificationOrchestratorTests {

    private enum FixtureError: Error { case context, image, open }

    /// A small secure-raster-style output: solid gray pages, no text layer.
    private func makeGrayOutput(pages: Int) async throws -> (PDFDocument, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orchestrator_\(UUID().uuidString).pdf")
        let recon = PDFStreamReconstructor(tempURL: url)
        let size = CGSize(width: 200, height: 300)
        try await recon.begin(firstPageSize: size)
        for _ in 0..<pages {
            guard let ctx = createBitmapContext(width: 200, height: 300) else {
                throw FixtureError.context
            }
            ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            guard let image = ctx.makeImage() else { throw FixtureError.image }
            try await recon.appendPage(
                PageOutput(image: image, size: size, textLayerEntries: nil))
        }
        await recon.finalize()
        guard let doc = PDFDocument(url: url) else { throw FixtureError.open }
        return (doc, url)
    }

    private func shape(_ event: VerificationRunEvent) -> String {
        switch event {
        case .layerStarted(let layer, let ordinal, let total, let completed):
            return "S\(ordinal)/\(total) \(layer.rawValue) after:\(completed.count)"
        case .layerFinished(let layer, let ordinal, _):
            return "F\(ordinal) \(layer.rawValue)"
        }
    }

    @Test("Secure mode: the batch starts once, publishes in canonical order, then each sequential layer starts and finishes; the report is in layers(for:) order")
    func eventsFollowTheSchedule() async throws {
        let (doc, url) = try await makeGrayOutput(pages: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let modes: [PipelineMode] = [.secureRasterization, .secureRasterization]
        var events: [VerificationRunEvent] = []
        let report = try await VerificationOrchestrator().run(
            outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 2,
            regions: [:],
            sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [nil, nil],
            perPageModes: modes,
            perPageFallbackReasons: [nil, nil],
            appliedSearches: [],
            provisionLayerDocuments: { layers in
                var docs: [VerificationLayer: SendablePDFDocument] = [:]
                for layer in layers {
                    guard let d = PDFDocument(url: url) else { return nil }
                    docs[layer] = SendablePDFDocument(d)
                }
                return docs
            },
            events: { events.append($0) }
        )

        let layers = VerificationEngine().layers(for: .secureRasterization)
        #expect(report.layers.map(\.name) == layers.map(\.name),
                "the report lists every layer in canonical order")
        #expect(events.map(shape) == [
            "S1/6 textExtraction after:0",
            "F1 textExtraction", "F2 ocrCheck", "F3 binaryStringSearch",
            "S4/6 structureCheck after:3", "F4 structureCheck",
            "S5/6 metadataCheck after:4", "F5 metadataCheck",
            "S6/6 searchRecheck after:5", "F6 searchRecheck",
        ])
        // The results a `.layerStarted` carries are exactly the ones published before it.
        for case .layerStarted(_, let ordinal, _, let completed) in events {
            #expect(completed.map(\.name) == Array(report.layers.prefix(ordinal - 1)).map(\.name))
        }
    }

    @Test("Page-count mismatch: one FAIL layer, an overall FAIL, and no layer events")
    func pageCountGateShortCircuits() async throws {
        let (doc, url) = try await makeGrayOutput(pages: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        var events: [VerificationRunEvent] = []
        let report = try await VerificationOrchestrator().run(
            outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 3,
            regions: [:],
            sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [nil, nil, nil],
            perPageModes: Array(repeating: .secureRasterization, count: 3),
            perPageFallbackReasons: [nil, nil, nil],
            appliedSearches: [],
            provisionLayerDocuments: { _ in nil },
            events: { events.append($0) }
        )
        #expect(report.layers.count == 1)
        #expect(report.layers.first?.name == "Page Count Check")
        #expect(report.overallStatus.isFail)
        #expect(events.isEmpty)
    }

    @Test("Provisioning failure: the batch runs sequentially on the shared instance and the schedule is unchanged")
    func sequentialFallbackKeepsTheSchedule() async throws {
        let (doc, url) = try await makeGrayOutput(pages: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        var events: [VerificationRunEvent] = []
        let report = try await VerificationOrchestrator().run(
            outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1,
            regions: [:],
            sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [nil],
            perPageModes: [.secureRasterization],
            perPageFallbackReasons: [nil],
            appliedSearches: [],
            provisionLayerDocuments: { _ in nil },
            events: { events.append($0) }
        )
        let layers = VerificationEngine().layers(for: .secureRasterization)
        #expect(report.layers.map(\.name) == layers.map(\.name))
        #expect(events.count == 10)
    }
}
