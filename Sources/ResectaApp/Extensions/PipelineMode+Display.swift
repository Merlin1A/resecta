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

    /// SF Symbol matching the pipeline mode picker in DocumentEditorView.
    var symbolName: String {
        switch self {
        case .secureRasterization: "photo"
        case .searchableRedaction: "doc.text"
        }
    }

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
