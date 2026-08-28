/// Pipeline mode selection. Secure Rasterization is the default and recommended
/// mode for users who want the simplest, most battle-tested redaction approach.
public enum PipelineMode: String, Sendable, CaseIterable {
    case secureRasterization   // Image-only output
    case searchableRedaction   // Preserves non-redacted text as invisible layer
}

/// Per-page text layer detection result from import-time analysis.
/// Used to determine per-page pipeline mode eligibility.
public enum TextLayerStatus: Sendable {
    case rich     // Substantial text layer — sandwich candidate
    case sparse   // Fewer than 10 meaningful characters — treat as image-only
    case none     // No text at all
}
