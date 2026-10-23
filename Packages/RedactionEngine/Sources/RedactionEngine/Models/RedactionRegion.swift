import Foundation

/// A single redaction region in normalized PDF page coordinates.
/// Defined in the engine Models/ directory — used by the overlay, the
/// character filter, the verification engine, and the state layer.
///
/// Coordinate conversion: Use normalizedToPDFPageCoordinates()
/// to convert normalizedRect to PDF-point-space before passing to the character
/// filter or verification spatial check.
///
/// Equatable conformance needed for VoiceOver geometry-change detection
/// in the overlay's configure() function.
///
/// Codable + the optional `rationale` field on the
/// detection-bearing cases (`detectedPII`, `searchMatch`). The
/// `Source` enum uses custom `init(from:)` / `encode(to:)` with
/// `decodeIfPresent(_:forKey:)` so a serialized region without the rationale
/// key decodes with `rationale == nil`. Synthesized Codable would throw
/// `DecodingError.keyNotFound` for the missing optional key — pinned by
/// `RedactionRegionRationaleTests.missingRationaleKeyDecodesAsNil`.
///
/// A region is a rectangle. A serialized region from an earlier version that
/// carries a `vertices` key still decodes: the struct's synthesized Codable
/// ignores the key, and the region is its bounding rectangle, which covers
/// at least the area the polygon covered.
public struct RedactionRegion: Sendable, Identifiable, Equatable, Codable {
    public let id: UUID
    public var normalizedRect: CGRect  // 0–1, bottom-left origin
    public let source: Source

    public init(
        id: UUID,
        normalizedRect: CGRect,
        source: Source
    ) {
        self.id = id
        self.normalizedRect = normalizedRect
        self.source = source
    }

    public enum Source: Sendable, Equatable, Codable {
        case manual
        case detectedPII(kind: PIIKind, rationale: MatchRationale? = nil)
        case detectedFace
        case searchMatch(term: String, rationale: MatchRationale? = nil)

        // CODABLE: explicit decodeIfPresent for additive optional.
        // Synthesized Codable on an enum with optional associated values does
        // NOT default-decode a missing key to `nil`; it throws
        // `DecodingError.keyNotFound(.rationale, ...)`. The custom shape below
        // is load-bearing — a future session must NOT "simplify" it back to
        // synthesized Codable. Pinned by
        // `RedactionRegionRationaleTests.missingRationaleKeyDecodesAsNil`.

        private enum CodingKeys: String, CodingKey {
            case type, kind, term, rationale
        }

        private enum CaseTag: String, Codable {
            case manual, detectedPII, detectedFace, searchMatch
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(CaseTag.self, forKey: .type)
            switch tag {
            case .manual:
                self = .manual
            case .detectedPII:
                let kind = try container.decode(PIIKind.self, forKey: .kind)
                let rationale = try container.decodeIfPresent(MatchRationale.self, forKey: .rationale)
                self = .detectedPII(kind: kind, rationale: rationale)
            case .detectedFace:
                self = .detectedFace
            case .searchMatch:
                let term = try container.decode(String.self, forKey: .term)
                let rationale = try container.decodeIfPresent(MatchRationale.self, forKey: .rationale)
                self = .searchMatch(term: term, rationale: rationale)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .manual:
                try container.encode(CaseTag.manual, forKey: .type)
            case .detectedPII(let kind, let rationale):
                try container.encode(CaseTag.detectedPII, forKey: .type)
                try container.encode(kind, forKey: .kind)
                try container.encodeIfPresent(rationale, forKey: .rationale)
            case .detectedFace:
                try container.encode(CaseTag.detectedFace, forKey: .type)
            case .searchMatch(let term, let rationale):
                try container.encode(CaseTag.searchMatch, forKey: .type)
                try container.encode(term, forKey: .term)
                try container.encodeIfPresent(rationale, forKey: .rationale)
            }
        }
    }

    public enum PIIKind: Sendable, Equatable, Codable {
        case ssn, creditCard, name, address, email, phone, ein, itin, driversLicense
        case passport, medicalRecord, dateOfBirth
        case npi, dea, account
        // ABA routing number (financial priority domain).
        case routingNumber
        case licensePlate
        case other
    }
}

// MARK: - Normalized Coordinate Clamping

extension CGRect {
    /// Clamp a normalized rectangle to the [0,1] range. Prevents floating-point
    /// edge cases where user-drawn regions extend slightly past page bounds.
    /// Used by coordinate conversion functions across the pipeline
    /// (PixelOperations, CharacterFilter, PipelineCoordinator).
    public func clampedToNormalized() -> CGRect {
        let cx = max(0, min(minX, 1))
        let cy = max(0, min(minY, 1))
        let cw = max(0, min(width, 1 - cx))
        let ch = max(0, min(height, 1 - cy))
        return CGRect(x: cx, y: cy, width: cw, height: ch)
    }
}
