import Testing
import UIKit
import RedactionEngine
@testable import ResectaApp

// Symbol-router pins. The router is keyed on the layer's identity
// (`VerificationLayer`), never on a name or the stored symbol string, so
// these pin (a) every custom asset lands on its numbered layer in
// canonical order, (b) the fallback path for identities without an asset
// and for the identity-less Page Count gate row, and (c) all 12 custom
// symbol assets resolving from the APP bundle (same Bundle(for:)
// resolution as BundleContentsTests).
@Suite("Verification symbol router")
struct VerificationSymbolTests {

    private var appBundle: Bundle { Bundle(for: AppCoordinator.self) }

    private func result(for layer: VerificationLayer?, symbolName: String = "x") -> LayerResult {
        LayerResult(
            name: layer?.name ?? "Page Count", symbolName: symbolName,
            status: .pass, shortDescription: "", detailDescription: "",
            pageReferences: nil, durationSeconds: 0, layer: layer)
    }

    @Test("the first ten layers of the canonical schedule route to their numbered custom assets")
    func canonicalLayersRoute() {
        let schedule = VerificationEngine().layers(for: .searchableRedaction)
        #expect(schedule.count >= 10)
        for (index, layer) in schedule.prefix(10).enumerated() {
            let expected = String(format: "resecta.verify.layer%02d", index + 1)
            #expect(VerificationSymbol.layerAssets[layer] == expected, "\(layer)")
            #expect(VerificationSymbol.assetName(for: result(for: layer)) == expected)
            #expect(VerificationSymbol.isCustom(result(for: layer)))
        }
    }

    @Test("router covers exactly the ten layers with a glyph")
    func routerCoversExactlyTen() {
        #expect(VerificationSymbol.layerAssets.count == 10)
        #expect(!VerificationSymbol.layerAssets.keys.contains(.searchRecheck))
    }

    @Test("the post-sequential checks ship on their SF symbols until their glyphs land")
    func postSequentialFallsBackToSFSymbol() {
        let schedule = VerificationEngine().layers(for: .searchableRedaction)
        for layer in schedule.dropFirst(10) {
            let stored = result(for: layer, symbolName: layer.symbolName)
            #expect(VerificationSymbol.assetName(for: stored) == nil, "\(layer)")
            #expect(!VerificationSymbol.isCustom(stored))
        }
        #expect(VerificationLayer.searchRecheck.symbolName == "text.page.badge.magnifyingglass")
    }

    @Test("identity outranks the stored name; a result without identity (the Page Count gate row) keeps its SF symbol")
    func identityKeyedLookup() {
        // A stamped identity routes regardless of the stored name.
        let stamped = LayerResult(
            name: "Legacy Name", symbolName: "x", status: .pass, shortDescription: "",
            detailDescription: "", pageReferences: nil, durationSeconds: 0, layer: .ocrCheck)
        #expect(VerificationSymbol.assetName(for: stamped) == "resecta.verify.layer02")
        // No identity, no asset — even when the name matches a layer's.
        let gateRow = LayerResult(
            name: "OCR Check", symbolName: "doc.text.magnifyingglass", status: .pass,
            shortDescription: "", detailDescription: "", pageReferences: nil, durationSeconds: 0)
        #expect(gateRow.layer == nil)
        #expect(VerificationSymbol.assetName(for: gateRow) == nil)
        #expect(!VerificationSymbol.isCustom(gateRow))
    }

    @Test("mode glyphs route to the two custom mode assets")
    func modeAssetNames() {
        #expect(PipelineMode.searchableRedaction.symbolAssetName == "resecta.verify.mode.searchable")
        #expect(PipelineMode.secureRasterization.symbolAssetName == "resecta.verify.mode.rasterized")
    }

    @Test("all 12 custom symbol assets resolve from the app bundle")
    func symbolAssetsAreBundled() {
        var names = Array(VerificationSymbol.layerAssets.values)
        names.append(PipelineMode.searchableRedaction.symbolAssetName)
        names.append(PipelineMode.secureRasterization.symbolAssetName)
        #expect(names.count == 12)
        for name in names {
            #expect(UIImage(named: name, in: appBundle, with: nil) != nil,
                    "missing symbol asset: \(name)")
        }
    }
}
