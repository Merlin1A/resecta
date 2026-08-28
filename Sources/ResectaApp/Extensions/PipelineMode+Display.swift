import SwiftUI
import RedactionEngine

// UI display properties for PipelineMode. Centralized here following
// the same pattern as VerificationStatus+Display.swift.

extension PipelineMode {
    /// Short label for badges and sidebar indicators.
    var shortDisplayName: String {
        switch self {
        case .secureRasterization: "Rasterized"
        case .searchableRedaction: "Searchable"
        }
    }

    /// Custom mode glyph asset. Replaces the stock symbols
    /// (`photo`/`doc.text`) at every mode-glyph site: editor picker menu,
    /// results legend, per-page badges. Monochrome template symbol sets in
    /// Resources/Assets.xcassets, tinted at the call site.
    var symbolAssetName: String {
        switch self {
        case .secureRasterization: "resecta.verify.mode.rasterized"
        case .searchableRedaction: "resecta.verify.mode.searchable"
        }
    }

    /// Mode glyph for `Label { } icon:` composition — custom symbols
    /// cannot ride `Label(_:systemImage:)` / `Image(systemName:)`.
    var glyph: Image { Image(symbolAssetName) }

    /// Badge tint color. Blue for Searchable (active capability),
    /// secondary for Secure (default fallback).
    var badgeColor: Color {
        switch self {
        case .secureRasterization: .secondary
        case .searchableRedaction: .blue
        }
    }
}

extension Array where Element == PipelineMode {
    /// True when at least one page used a different mode than the rest.
    /// O(n) worst-case but short-circuits on first mismatch.
    var hasMixedModes: Bool {
        guard let first = self.first else { return false }
        return contains(where: { $0 != first })
    }
}
