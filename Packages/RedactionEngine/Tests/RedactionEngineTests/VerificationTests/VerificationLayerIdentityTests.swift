import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// Layer identity: `VerificationLayer` + `VerificationEngine.layers(for:)`
// replace index arithmetic. These pins hold the per-mode order and counts,
// the phase partition, the index adapters' parity with the identity entry,
// and the mode-aware names.

@Suite("Verification layer identity")
struct VerificationLayerIdentityTests {

    private let engine = VerificationEngine()

    @Test("Secure Rasterization runs 6 layers, Searchable 11; the search re-check is last in both")
    func countsAndLastLayer() {
        let raster = engine.layers(for: .secureRasterization)
        let searchable = engine.layers(for: .searchableRedaction)
        #expect(raster.count == 6)
        #expect(searchable.count == 11)
        #expect(raster.last == .searchRecheck)
        #expect(searchable.last == .searchRecheck)
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
        #expect(VerificationLayer.allCases.filter { $0.phase == .postSequential } == [.searchRecheck])
        // Raster mode carries no sandwich layer and no operator re-extraction.
        let raster = engine.layers(for: .secureRasterization)
        #expect(!raster.contains { $0.phase == .sandwichSequential })
        #expect(!raster.contains(.operatorReExtraction))
    }

    @Test("Mode-aware names: index 5 is the re-check in raster and Spatial Verification in searchable")
    func modeAwareNames() {
        #expect(engine.layerName(at: 5, mode: .secureRasterization) == "Search Re-check")
        #expect(engine.layerName(at: 5, mode: .searchableRedaction) == "Spatial Verification")
        #expect(engine.layerName(at: 10, mode: .searchableRedaction) == "Search Re-check")
        #expect(engine.layerSymbol(at: 5, mode: .secureRasterization) == "text.page.badge.magnifyingglass")
        // Out of range keeps the historical fallbacks.
        #expect(engine.layerName(at: 6, mode: .secureRasterization) == "Unknown Layer")
        #expect(engine.layerSymbol(at: 11, mode: .searchableRedaction) == "questionmark.circle")
        // The index-only adapters read the Searchable order.
        #expect(engine.layerName(at: 10) == "Search Re-check")
        #expect(engine.layerName(at: 5) == "Spatial Verification")
        #expect(engine.layerName(at: 11) == "Unknown Layer")
        #expect(engine.layerSymbol(at: 11) == "questionmark.circle")
        for (index, layer) in VerificationLayer.allCases.enumerated() {
            #expect(engine.layerName(at: index) == layer.name)
            #expect(engine.layerSymbol(at: index) == layer.symbolName)
        }
    }

    @Test("Index adapter parity: runLayer(i) ≡ runLayer(layers(for:)[i]) for every index in both modes",
          arguments: [PipelineMode.secureRasterization, PipelineMode.searchableRedaction])
    func indexAdapterParity(mode: PipelineMode) async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(TestFixtures.blankPage(), prefix: "identity_")
        defer { try? FileManager.default.removeItem(at: url) }
        let wrapped = SendablePDFDocument(doc)
        let ordered = engine.layers(for: mode)
        for (index, layer) in ordered.enumerated() {
            let byIndex = await engine.runLayer(
                index, outputDocument: wrapped, sourcePageCount: 1, regions: [:],
                sensitiveTerms: [], pipelineMode: mode, filterDigests: [nil],
                perPageModes: [mode])
            let byIdentity = await engine.runLayer(
                layer, outputDocument: wrapped, sourcePageCount: 1, regions: [:],
                sensitiveTerms: [], pipelineMode: mode, filterDigests: [nil],
                perPageModes: [mode])
            #expect(byIndex.status == byIdentity.status, "\(mode) index \(index) / \(layer)")
            #expect(byIndex.name == layer.name)
            #expect(byIdentity.name == layer.name)
            #expect(byIndex.layer == layer, "the adapter must stamp the identity")
            #expect(byIdentity.layer == layer)
            #expect(byIndex.symbolName == layer.symbolName)
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
        _ = await spy.runLayer(
            .searchRecheck, outputDocument: SendablePDFDocument(doc), sourcePageCount: 1,
            regions: [:], sensitiveTerms: [], pipelineMode: .secureRasterization,
            filterDigests: [nil], perPageModes: [.secureRasterization])
        _ = await spy.runLayer(
            .searchRecheck, outputDocument: SendablePDFDocument(doc), sourcePageCount: 1,
            regions: [:], sensitiveTerms: [], pipelineMode: .searchableRedaction,
            filterDigests: [nil], perPageModes: [.searchableRedaction])
        #expect(box.seen == [5, 10])
    }
}
