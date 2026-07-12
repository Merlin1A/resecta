import Foundation

// See ARCH §2.3 for RedactionRegion definition.

/// A single redaction region in normalized PDF page coordinates.
/// Defined in the engine Models/ directory — used by the overlay, the
/// character filter, the verification engine, and the state layer.
///
/// Coordinate conversion: Use normalizedToPDFPageCoordinates() (ENGINE §5B.1a)
/// to convert normalizedRect to PDF-point-space before passing to the character
/// filter or verification spatial check.
///
/// UI-4-1: Equatable conformance needed for VoiceOver geometry-change detection
/// in the overlay's configure() function.
///
/// WU-71 / [P10] path (a): Codable + the optional `rationale` field on the
/// detection-bearing cases (`detectedPII`, `searchMatch`). Per RR-42 the
/// `Source` enum uses custom `init(from:)` / `encode(to:)` with
/// `decodeIfPresent(_:forKey:)` so a serialized region without the rationale
/// key decodes with `rationale == nil`. Synthesized Codable would throw
/// `DecodingError.keyNotFound` for the missing optional key — pinned by
/// `RedactionRegionRationaleTests.missingRationaleKeyDecodesAsNil`.
///
/// DRAW-1 / plan §0.3: `vertices: [CGPoint]?` is a top-level optional field
/// on the struct (not on the `Source` enum). For a top-level struct optional
/// field, synthesized struct Codable already decodes a missing key as `nil`
/// — the RR-42 custom Codable shape applies only to the `Source` enum's
/// optional associated value, where synthesized Codable would throw
/// `DecodingError.keyNotFound`. The struct's synthesized Codable stays.
/// Pinned by `RedactionRegionPolygonTests.testMissingVerticesKeyDecodesAsNil`.
public struct RedactionRegion: Sendable, Identifiable, Equatable, Codable {
    public let id: UUID
    public var normalizedRect: CGRect  // 0–1, bottom-left origin
    public let source: Source

    /// DRAW-1: Polygon vertices in normalized PDF coordinates (0–1, bottom-left
    /// origin). When non-nil, the region is rendered as a filled polygon
    /// (even-odd rule) and `normalizedRect` is the polygon's bounding box.
    /// Cap of 32 vertices is enforced upstream by Douglas-Peucker simplification
    /// in `RedactionOverlayView`. When nil, the region is a rectangle.
    /// See plan §4 DRAW-1 and `specs/REDACTION_ENGINE.md §3.1`.
    public let vertices: [CGPoint]?

    public init(
        id: UUID,
        normalizedRect: CGRect,
        source: Source,
        vertices: [CGPoint]? = nil
    ) {
        self.id = id
        self.normalizedRect = normalizedRect
        self.source = source
        self.vertices = vertices
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
        // DRAW-2 — Vision-framework barcode / QR detection. Nested under
        // `Source.detectedPII(kind:)` so the existing triage / accessibility
        // / display surface picks up the new kind without a new `Source`
        // case. See `BarcodeDetector.swift` and `specs/REDACTION_ENGINE.md §4.19`.
        case barcode
        // DRAW-3 — Heuristic signature suggestion (triage-only; never auto-applied).
        // Confidence is heuristic — derived from ink-density + curvature scores on
        // the candidate region adjacent to a labeled "Signature:" OCR block. The
        // detector is designed to suggest plausible signature areas; the user must
        // accept in the triage sheet before a redaction region is created. See
        // `SignatureHeuristicDetector` and plan §4 DRAW-3.
        case signatureCandidate
        case other
    }
}

// MARK: - Normalized Coordinate Clamping

extension CGRect {
    /// Clamp a normalized rectangle to the [0,1] range. Prevents floating-point
    /// edge cases where user-drawn regions extend slightly past page bounds.
    /// Used by coordinate conversion functions across the pipeline
    /// (PixelOperations, CharacterFilter, PipelineCoordinator). See ENGINE §3.1a.
    public func clampedToNormalized() -> CGRect {
        let cx = max(0, min(minX, 1))
        let cy = max(0, min(minY, 1))
        let cw = max(0, min(width, 1 - cx))
        let ch = max(0, min(height, 1 - cy))
        return CGRect(x: cx, y: cy, width: cw, height: ch)
    }
}
