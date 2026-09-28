import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// Layer identity: `VerificationLayer` + `VerificationEngine.layers(for:)`
// replace index arithmetic. These pins hold the per-mode order and counts,
// the phase partition, the two post-sequential checks last, and the
// mode-aware names. The index adapters are gone: every caller names the
// layer.

@Suite("Verification layer identity")
struct VerificationLayerIdentityTests {

    private let engine = VerificationEngine()

    @Test("Secure Rasterization runs 7 layers, Searchable 12; the search re-check then the detection sweep are last in both")
    func countsAndLastLayers() {
        let raster = engine.layers(for: .secureRasterization)
        let searchable = engine.layers(for: .searchableRedaction)
        #expect(raster.count == 7)
        #expect(searchable.count == 12)
        #expect(raster.suffix(2) == [.searchRecheck, .detectionSweep])
        #expect(searchable.suffix(2) == [.searchRecheck, .detectionSweep])
        #expect(raster.last == .detectionSweep)
        #expect(searchable.last == .detectionSweep)
        #expect(engine.layerCount(for: .secureRasterization) == raster.count)
        #expect(engine.layerCount(for: .searchableRedaction) == searchable.count)
        // The Searchable order IS the declaration order.
        #expect(searchable == VerificationLayer.allCases)
        // Indices 0–4 agree across modes (the five base checks).
        #expect(Array(raster.prefix(5)) == Array(searchable.prefix(5)))
    }

    @Test("Every layer has a non-empty name and symbol, and names are unique")
    func namesAndSymbols() {
        for layer in VerificationLayer.allCases {
            #expect(!layer.name.isEmpty)
            #expect(!layer.symbolName.isEmpty)
        }
        #expect(Set(VerificationLayer.allCases.map(\.name)).count == VerificationLayer.allCases.count)
        #expect(VerificationLayer.searchRecheck.name == "Search Re-check")
        #expect(VerificationLayer.searchRecheck.symbolName == "text.page.badge.magnifyingglass")
        #expect(VerificationLayer.detectionSweep.name == "Detection Sweep")
        #expect(VerificationLayer.detectionSweep.symbolName == "rectangle.and.text.magnifyingglass")
        // Layer 3's fallback is a real SF Symbol name (the app masks nothing).
        #expect(VerificationLayer.binaryStringSearch.symbolName == "01.square.fill")
    }

    @Test("The phase partition covers every layer exactly once")
    func phasePartition() {
        var seen: [VerificationLayer] = []
        for phase in VerificationLayer.ExecutionPhase.allCases {
            seen += VerificationLayer.allCases.filter { $0.phase == phase }
        }
        #expect(seen.count == VerificationLayer.allCases.count)
        #expect(Set(seen).count == VerificationLayer.allCases.count)
        #expect(VerificationLayer.allCases.filter { $0.phase == .parallelBase }
                == [.textExtraction, .ocrCheck, .binaryStringSearch, .operatorReExtraction])
        #expect(VerificationLayer.allCases.filter { $0.phase == .catalogSequential }
                == [.structureCheck, .metadataCheck])
        #expect(VerificationLayer.allCases.filter { $0.phase == .sandwichSequential }
                == [.spatialVerification, .characterCount, .fontVerification, .characterLineage])
        #expect(VerificationLayer.allCases.filter { $0.phase == .postSequential }
                == [.searchRecheck, .detectionSweep])
        // Raster mode carries no sandwich layer and no operator re-extraction.
        let raster = engine.layers(for: .secureRasterization)
        #expect(!raster.contains { $0.phase == .sandwichSequential })
        #expect(!raster.contains(.operatorReExtraction))
        #expect(raster.contains(.detectionSweep))
    }

    @Test("Mode-aware names: index 5 is the re-check in raster and Spatial Verification in searchable")
    func modeAwareNames() {
        #expect(engine.layerName(at: 5, mode: .secureRasterization) == "Search Re-check")
        #expect(engine.layerName(at: 6, mode: .secureRasterization) == "Detection Sweep")
        #expect(engine.layerName(at: 5, mode: .searchableRedaction) == "Spatial Verification")
        #expect(engine.layerName(at: 10, mode: .searchableRedaction) == "Search Re-check")
        #expect(engine.layerName(at: 11, mode: .searchableRedaction) == "Detection Sweep")
        #expect(engine.layers(for: .secureRasterization)[5].symbolName == "text.page.badge.magnifyingglass")
        // Out of range keeps the historical fallback.
        #expect(engine.layerName(at: 7, mode: .secureRasterization) == "Unknown Layer")
        for (index, layer) in VerificationLayer.allCases.enumerated() {
            #expect(engine.layers(for: .searchableRedaction)[index].name == layer.name)
            #expect(engine.layers(for: .searchableRedaction)[index].symbolName == layer.symbolName)
        }
    }

    @Test("Every layer runs by identity and stamps it on its result, in both modes",
          arguments: [PipelineMode.secureRasterization, PipelineMode.searchableRedaction])
    func identityRunStampsTheLayer(mode: PipelineMode) async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(TestFixtures.blankPage(), prefix: "identity_")
        defer { try? FileManager.default.removeItem(at: url) }
        let wrapped = SendablePDFDocument(doc)
        for layer in engine.layers(for: mode) {
            let result = await engine.runLayer(
                layer, outputDocument: wrapped, sourcePageCount: 1, regions: [:],
                sensitiveTerms: [], pipelineMode: mode, filterDigests: [nil],
                perPageModes: [mode])
            #expect(result.name == layer.name, "\(mode) / \(layer)")
            #expect(result.layer == layer)
            #expect(result.symbolName == layer.symbolName)
        }
    }

    @Test("The dispatch seam reports the layer's ordinal in the mode's order")
    func dispatchSeamReportsOrdinal() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(TestFixtures.blankPage(), prefix: "identity_")
        defer { try? FileManager.default.removeItem(at: url) }
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var seen: [Int] = []
            func record(_ i: Int) { lock.lock(); seen.append(i); lock.unlock() }
        }
        let box = Box()
        var spy = VerificationEngine()
        spy.onRunLayerDispatch = { ordinal, _ in box.record(ordinal) }
        for layer in [VerificationLayer.searchRecheck, .detectionSweep] {
            _ = await spy.runLayer(
                layer, outputDocument: SendablePDFDocument(doc), sourcePageCount: 1,
                regions: [:], sensitiveTerms: [], pipelineMode: .secureRasterization,
                filterDigests: [nil], perPageModes: [.secureRasterization])
            _ = await spy.runLayer(
                layer, outputDocument: SendablePDFDocument(doc), sourcePageCount: 1,
                regions: [:], sensitiveTerms: [], pipelineMode: .searchableRedaction,
                filterDigests: [nil], perPageModes: [.searchableRedaction])
        }
        #expect(box.seen == [5, 10, 6, 11])
    }
}
