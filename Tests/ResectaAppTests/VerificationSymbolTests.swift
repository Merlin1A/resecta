import Testing
import UIKit
import RedactionEngine
@testable import ResectaApp

// Symbol-router pins. The router is keyed on layer identity
// (never the stored symbolName), so these pin (a) router ↔ engine name
// agreement, (b) the fallback path for unmapped identities, and (c) all
// 12 custom symbol assets resolving from the APP bundle (C-A pattern,
// same Bundle(for:) resolution as BundleContentsTests).
@Suite("Verification symbol router")
struct VerificationSymbolTests {

    private var appBundle: Bundle { Bundle(for: AppCoordinator.self) }

    @Test("every engine layer name routes to its numbered custom asset")
    func engineNamesAllRoute() {
        let engine = VerificationEngine()
        for index in 0..<10 {
            let name = engine.layerName(at: index)
            let expected = String(format: "resecta.verify.layer%02d", index + 1)
            #expect(VerificationSymbol.assetName(forLayerNamed: name) == expected)
        }
    }

    @Test("router covers exactly the ten engine layers")
    func routerCoversExactlyTen() {
        #expect(VerificationSymbol.layerAssets.count == 10)
    }

    @Test("unmapped identities route to nil (stored-symbol fallback)")
    func unknownNameFallsBack() {
        #expect(VerificationSymbol.assetName(forLayerNamed: "Unknown Layer") == nil)
        #expect(VerificationSymbol.assetName(forLayerNamed: "") == nil)
        // Symbol strings must never be accepted as identity keys.
        #expect(VerificationSymbol.assetName(forLayerNamed: "01.rectangle.fill") == nil)
        #expect(VerificationSymbol.assetName(forLayerNamed: "doc.text.magnifyingglass") == nil)
    }

    @Test("the search re-check has no custom asset yet: identity-keyed lookup falls back to its SF symbol")
    func searchRecheckFallsBackToSFSymbol() {
        #expect(VerificationEngine().layerName(at: 10) == VerificationLayer.searchRecheck.name)
        #expect(VerificationSymbol.assetName(forLayerNamed: VerificationLayer.searchRecheck.name) == nil)
        let recheck = LayerResult(
            name: VerificationLayer.searchRecheck.name,
            symbolName: VerificationLayer.searchRecheck.symbolName,
            status: .pass, shortDescription: "", detailDescription: "",
            pageReferences: nil, durationSeconds: 0, layer: .searchRecheck)
        #expect(VerificationSymbol.assetName(for: recheck) == nil)
        #expect(recheck.symbolName == "text.page.badge.magnifyingglass")
        // Identity outranks the stored name; a result without identity keys on its name.
        let stamped = LayerResult(
            name: "Legacy Name", symbolName: "x", status: .pass, shortDescription: "",
            detailDescription: "", pageReferences: nil, durationSeconds: 0, layer: .ocrCheck)
        #expect(VerificationSymbol.assetName(for: stamped) == "resecta.verify.layer02")
        let legacy = LayerResult(
            name: "OCR Check", symbolName: "x", status: .pass, shortDescription: "",
            detailDescription: "", pageReferences: nil, durationSeconds: 0)
        #expect(VerificationSymbol.assetName(for: legacy) == "resecta.verify.layer02")
        // The router still maps exactly the ten custom assets (pin unchanged).
        #expect(VerificationSymbol.layerAssets.count == 10)
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
