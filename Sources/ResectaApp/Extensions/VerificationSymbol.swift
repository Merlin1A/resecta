import SwiftUI
import RedactionEngine

/// App-side router from verification-layer identity to the
/// custom symbol assets in Resources/Assets.xcassets.
///
/// Keyed on `VerificationLayer` — the engine's identity for a check —
/// never on a name or the stored `symbolName`. A result without an
/// identity (the Page Count gate row) and an identity without a custom
/// asset both fall back to the stored system symbol.
enum VerificationSymbol {
    /// Layer identity → asset name, numbered in the canonical order of the
    /// first ten checks. The post-sequential checks (the Search Re-check
    /// and later ones) ship on their SF symbols until their glyphs land.
    static let layerAssets: [VerificationLayer: String] = [
        .textExtraction: "resecta.verify.layer01",
        .ocrCheck: "resecta.verify.layer02",
        .binaryStringSearch: "resecta.verify.layer03",
        .structureCheck: "resecta.verify.layer04",
        .metadataCheck: "resecta.verify.layer05",
        .spatialVerification: "resecta.verify.layer06",
        .characterCount: "resecta.verify.layer07",
        .fontVerification: "resecta.verify.layer08",
        .characterLineage: "resecta.verify.layer09",
        .operatorReExtraction: "resecta.verify.layer10",
    ]

    /// Asset name for a result's layer identity; nil for a result without
    /// an identity or for an identity without a custom asset.
    static func assetName(for layer: LayerResult) -> String? {
        layer.layer.flatMap { layerAssets[$0] }
    }

    /// Whether the row icon is one of the custom assets (drawn at its
    /// optical size — the sources render ≈ 15 % smaller than an SF symbol
    /// at the same point size) rather than the stored SF fallback.
    static func isCustom(_ layer: LayerResult) -> Bool {
        assetName(for: layer) != nil
    }

    /// Row icon: custom asset by identity, stored-symbol fallback otherwise.
    static func icon(for layer: LayerResult) -> Image {
        if let asset = assetName(for: layer) {
            return Image(asset)
        }
        return Image(systemName: layer.symbolName)
    }
}
