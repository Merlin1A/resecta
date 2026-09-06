import Foundation

/// Identity of one verification check.
///
/// Every check the engine can run is one case here, in canonical order. A
/// layer carries its own display name, SF Symbol fallback, execution phase
/// and mode applicability, so the per-mode order and count come from
/// `VerificationEngine.layers(for:)` and never from an index table: a
/// further check is one new case plus one body in `runLayer`, and no
/// consumer does index arithmetic.
///
/// The Searchable order is the declaration order. Secure Rasterization runs
/// the five base checks and the search re-check (six); Searchable Redaction
/// runs all eleven. `searchRecheck` is last in both modes.
public enum VerificationLayer: String, CaseIterable, Sendable, Hashable {
    case textExtraction
    case ocrCheck
    case binaryStringSearch
    case structureCheck
    case metadataCheck
    case spatialVerification
    case characterCount
    case fontVerification
    case characterLineage
    case operatorReExtraction
    case searchRecheck

    /// When a layer runs inside a verification pass. The coordinator groups
    /// `layers(for:)` by phase: the parallel base batch first (independent
    /// reads, one document instance each), then the two catalog readers in
    /// sequence, then the sandwich checks in sequence (inter-layer
    /// baselines), then the post-sequential checks last.
    public enum ExecutionPhase: Sendable, Hashable, CaseIterable {
        case parallelBase
        case catalogSequential
        case sandwichSequential
        case postSequential
    }

    /// Human-readable layer name (the results-row title after "Layer N:").
    public var name: String {
        switch self {
        case .textExtraction: "Text Extraction"
        case .ocrCheck: "OCR Check"
        case .binaryStringSearch: "Binary String Search"
        case .structureCheck: "Structure Check"
        case .metadataCheck: "Metadata Check"
        case .spatialVerification: "Spatial Verification"
        case .characterCount: "Character Count"
        case .fontVerification: "Font Verification"
        case .characterLineage: "Character Lineage"
        case .operatorReExtraction: "Operator Re-Extraction"
        case .searchRecheck: "Search Re-check"
        }
    }

    /// SF Symbol name stored on the layer's result. The app routes mapped
    /// identities to its custom assets and falls back to this symbol.
    public var symbolName: String {
        switch self {
        case .textExtraction: "doc.text.magnifyingglass"
        case .ocrCheck: "text.viewfinder"
        case .binaryStringSearch: "01.rectangle.fill"
        case .structureCheck: "rectangle.3.group"
        case .metadataCheck: "info.circle"
        case .spatialVerification: "character.textbox"
        case .characterCount: "number"
        case .fontVerification: "textformat"
        case .characterLineage: "checkmark.seal"
        case .operatorReExtraction: "doc.text.below.ecg"
        case .searchRecheck: "text.page.badge.magnifyingglass"
        }
    }

    /// Execution phase (see `ExecutionPhase`).
    public var phase: ExecutionPhase {
        switch self {
        case .textExtraction, .ocrCheck, .binaryStringSearch, .operatorReExtraction:
            .parallelBase
        case .structureCheck, .metadataCheck:
            .catalogSequential
        case .spatialVerification, .characterCount, .fontVerification, .characterLineage:
            .sandwichSequential
        case .searchRecheck:
            .postSequential
        }
    }

    /// Whether the layer runs on output produced in `mode`.
    public func appliesTo(_ mode: PipelineMode) -> Bool {
        switch mode {
        case .searchableRedaction:
            return true
        case .secureRasterization:
            switch self {
            case .textExtraction, .ocrCheck, .binaryStringSearch,
                 .structureCheck, .metadataCheck, .searchRecheck:
                return true
            case .spatialVerification, .characterCount, .fontVerification,
                 .characterLineage, .operatorReExtraction:
                return false
            }
        }
    }
}
