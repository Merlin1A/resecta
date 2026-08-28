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
