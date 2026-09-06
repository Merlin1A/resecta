import SwiftUI
import RedactionEngine

/// App-side router from verification-layer identity to the
/// custom symbol assets in Resources/Assets.xcassets.
///
/// Keyed on the layer's intrinsic `name`, never the stored `symbolName`:
/// persisted reports carry whatever symbol string the engine wrote at run
/// time (including Layer 3's invalid `01.rectangle.fill`), so identity is
/// the only stable key. Anything unmapped falls back to the stored system
/// symbol — that path is what keeps old persisted reports rendering.
enum VerificationSymbol {
    /// Layer name → asset name. Names are the engine's
    /// `VerificationEngine.layerName(at:)` strings;
    /// VerificationSymbolTests pins the two lists against each other.
    static let layerAssets: [String: String] = [
        "Text Extraction": "resecta.verify.layer01",
        "OCR Check": "resecta.verify.layer02",
        "Binary String Search": "resecta.verify.layer03",
        "Structure Check": "resecta.verify.layer04",
        "Metadata Check": "resecta.verify.layer05",
        "Spatial Verification": "resecta.verify.layer06",
        "Character Count": "resecta.verify.layer07",
        "Font Verification": "resecta.verify.layer08",
        "Character Lineage": "resecta.verify.layer09",
        "Operator Re-Extraction": "resecta.verify.layer10",
    ]

    /// Asset name for a layer identity; nil routes to the fallback.
    static func assetName(forLayerNamed name: String) -> String? {
        layerAssets[name]
    }

    /// Asset name for a result: the engine's layer identity first, the
    /// stored name as the fallback for results built without one (legacy
    /// persisted reports). Nil for an identity without a custom asset (the
    /// Search Re-check ships on its SF symbol until its glyph lands).
    static func assetName(for layer: LayerResult) -> String? {
        assetName(forLayerNamed: layer.layer?.name ?? layer.name)
    }

    /// Row icon: custom asset by identity, stored-symbol fallback for
    /// unmapped identities (legacy persisted reports, future layers).
    static func icon(for layer: LayerResult) -> Image {
        if let asset = assetName(for: layer) {
            return Image(asset)
        }
        return Image(systemName: layer.symbolName)
    }
}
