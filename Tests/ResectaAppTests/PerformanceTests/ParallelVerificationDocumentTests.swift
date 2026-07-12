import Testing
import Foundation
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// CAT-363 — guard suite for the per-layer `PDFDocument` provisioning of the
// parallel verification base batch. Co-located with the PERF-2 orchestration
// suite (`PageParallelRasterizationTests`) and driving the same kind of
// internal coordinator seam directly (`collectParallelBaseLayerResults`).
//
// The race these guards stand in for is nondeterministic, so the proof bar is
// a STRUCTURAL assertion on the production dispatch — which `PDFDocument`
// instance each `runLayer` call receives — not on race manifestation. G1 is
// red while the seam fans every layer onto the shared document and green once
// each layer gets its own instance; G1b pins the sequential-on-shared
// fallback when per-layer provisioning fails.

/// Thread-safe collector for the `onRunLayerDispatch` spy. `nonisolated` so the
/// `@Sendable` spy can call it off MainActor (the app target defaults to
/// MainActor isolation, SE-0466); the spy fires from the concurrent fan-out, so
/// appends are lock-guarded.
private nonisolated final class DispatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var pairs: [(layer: Int, doc: ObjectIdentifier)] = []
    func record(_ layer: Int, _ doc: ObjectIdentifier) {
        lock.lock(); pairs.append((layer, doc)); lock.unlock()
    }
    var snapshot: [(layer: Int, doc: ObjectIdentifier)] {
        lock.lock(); defer { lock.unlock() }; return pairs
    }
}

@Suite("CAT-363 Per-Layer Verification Documents", .tags(.critical, .coordination))
@MainActor
struct ParallelVerificationDocumentTests {

    // MARK: - G1: distinct instances per parallel layer

    @Test("Each parallel base layer is dispatched against its own PDFDocument instance")
    func parallelBaseLayersReceiveDistinctDocumentInstances() async throws {
        let layers = [0, 1, 2]
        let url = try makeOutputFixtureURL(pages: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let doc = PDFDocument(url: url) else {
            Issue.record("Failed to load output fixture"); return
        }
        let wrapped = SendablePDFDocument(doc)
        let coord = makeCoordinator()

        let recorder = DispatchRecorder()
        var verifier = VerificationEngine()
        // ADV-2 A2-10: install the spy on the verifier VALUE before it crosses
        // into the seam; the per-task copies the fan-out makes carry the closure.
        verifier.onRunLayerDispatch = { layer, id in recorder.record(layer, id) }

        let parallel = try await coord.collectParallelBaseLayerResults(
            layers: layers,
            outputURL: url,
            shared: wrapped,
            verifier: verifier,
            sourcePageCount: doc.pageCount,
            regions: [:],
            sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [],
            perPageModes: Array(repeating: .secureRasterization, count: doc.pageCount)
        )

        let recorded = recorder.snapshot
        #expect(recorded.count == layers.count,
                "expected one dispatch per layer, got \(recorded.count)")

        // Distinct instances: pairwise distinct AND none equal to the shared doc.
        let identities = recorded.map(\.doc)
        let uniqueIdentities = Set(identities)
        #expect(uniqueIdentities.count == layers.count,
                "parallel layers must each receive a distinct PDFDocument instance (got \(uniqueIdentities.count) distinct of \(layers.count))")
        let sharedID = ObjectIdentifier(wrapped.document)
        #expect(!identities.contains(sharedID),
                "no parallel layer may run against the shared verification document")

        // Cross-instance result parity vs a sequential reference on the shared doc.
        let reference = try await sequentialReference(
            layers: layers, shared: wrapped, verifier: VerificationEngine(),
            sourcePageCount: doc.pageCount)
        for layer in layers {
            #expect(status(of: layer, in: parallel) == reference[layer],
                    "layer \(layer) status must match the sequential reference run")
        }
    }

    // MARK: - G1b: provisioning failure → sequential on shared

    @Test("Per-layer provisioning failure falls back to sequential execution on the shared doc")
    func provisioningFailureFallsBackToSequentialOnSharedDoc() async throws {
        let layers = [0, 1, 2]
        // A valid shared doc for the layers to run against, but a non-existent
        // outputURL so per-layer `PDFDocument(url:)` provisioning fails.
        let sharedURL = try makeOutputFixtureURL(pages: 3)
        defer { try? FileManager.default.removeItem(at: sharedURL) }
        guard let doc = PDFDocument(url: sharedURL) else {
            Issue.record("Failed to load shared fixture"); return
        }
        let wrapped = SendablePDFDocument(doc)
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cf-s1-missing-\(UUID().uuidString).pdf")

        let coord = makeCoordinator()
        let recorder = DispatchRecorder()
        var verifier = VerificationEngine()
        verifier.onRunLayerDispatch = { layer, id in recorder.record(layer, id) }

        let results = try await coord.collectParallelBaseLayerResults(
            layers: layers,
            outputURL: missingURL,
            shared: wrapped,
            verifier: verifier,
            sourcePageCount: doc.pageCount,
            regions: [:],
            sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [],
            perPageModes: Array(repeating: .secureRasterization, count: doc.pageCount)
        )

        // Fallback: every layer ran against the shared instance, all present, no throw.
        let sharedID = ObjectIdentifier(wrapped.document)
        let identities = recorder.snapshot.map(\.doc)
        #expect(identities.count == layers.count)
        #expect(identities.allSatisfy { $0 == sharedID },
                "on provisioning failure every layer must run against the shared doc")
        #expect(Set(results.map { $0.0 }) == Set(layers),
                "all requested layer results must be present after fallback")
    }

    // MARK: - Helpers

    private func status(of layer: Int, in results: [(Int, LayerResult)]) -> VerificationStatus? {
        results.first { $0.0 == layer }?.1.status
    }

    private func sequentialReference(
        layers: [Int], shared: SendablePDFDocument, verifier: VerificationEngine,
        sourcePageCount: Int
    ) async throws -> [Int: VerificationStatus] {
        var out: [Int: VerificationStatus] = [:]
        for layer in layers {
            let result = await verifier.runLayer(
                layer,
                outputDocument: shared,
                sourcePageCount: sourcePageCount,
                regions: [:],
                sensitiveTerms: [],
                pipelineMode: .secureRasterization,
                filterDigests: [],
                perPageModes: Array(repeating: .secureRasterization, count: sourcePageCount)
            )
            out[layer] = result.status
        }
        return out
    }

    private func makeOutputFixtureURL(pages: Int) throws -> URL {
        let data = makeMultiPagePDFData(pages: pages)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cf-s1-output-\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }
}
