import Foundation

// See ARCH §2.3 for DetectionResult definition.

/// Output from the PII/face detection pipeline for a single detected item.
/// Produced by Detection/ components, consumed by the app target to create
/// RedactionRegions.
public struct DetectionResult: Sendable, Identifiable {
    public let id: UUID
    /// Bounding box in normalized coordinates (0–1, bottom-left origin),
    /// matching Vision framework output and RedactionRegion.normalizedRect.
    public let normalizedRect: CGRect
    public let kind: Kind
    /// Detection confidence (0.0–1.0). Used for UI display and filtering.
    public let confidence: Double

    // --- GAP §2.1: New fields for triage support ---

    /// The matched text string (e.g., "123-45-6789" for SSN, "John Smith" for name).
    /// Nil for face detections (no text match). Populated by the detection orchestration
    /// wrapper from PIIMatch.text during the PIIMatch → DetectionResult conversion.
    public let matchedText: String?

    /// The Vision OCR recognition level used to produce this detection.
    /// Enables the triage UI to indicate whether a detection came from a
    /// quick scan (.fast) or an enhanced scan (.accurate).
    public let recognitionLevel: RecognitionLevel

    /// PERF-4 — Audit record describing how this detection was produced.
    /// Records whether Vision OCR was skipped in favor of the embedded text
    /// layer (with the reason) so the triage UI / logs can explain the
    /// detection's lineage. Defaulted so existing constructors stay valid.
    public let provenance: Provenance

    public init(
        id: UUID = UUID(),
        normalizedRect: CGRect,
        kind: Kind,
        confidence: Double,
        matchedText: String? = nil,
        recognitionLevel: RecognitionLevel = .fast,
        provenance: Provenance = .ocrRan
    ) {
        self.id = id
        self.normalizedRect = normalizedRect
        self.kind = kind
        self.confidence = confidence
        self.matchedText = matchedText
        self.recognitionLevel = recognitionLevel
        self.provenance = provenance
    }

    public enum Kind: Sendable, Equatable, Hashable {
        case pii(PIIKind)
        case face
        case searchMatch(term: String)  // SEARCH-AND-REDACT §D3
    }

    public enum RecognitionLevel: String, Sendable {
        case fast
        case accurate
    }

    // MARK: - PERF-4 — Detection provenance

    /// Records how a detection was produced. For PERF-4 the audit field of
    /// interest is whether Vision OCR was skipped in favor of the embedded
    /// text layer; the reason enum captures the trigger condition so the
    /// triage UI / audit export can describe the branch decision.
    ///
    /// Adds an inspectable record on every `DetectionResult`; does not change
    /// the existing public surface beyond the new optional init parameter
    /// (defaulted to `.ocrRan`).
    public struct Provenance: Sendable, Equatable, Hashable {
        /// True iff the detection was produced from the embedded text layer
        /// without running Vision OCR on the page raster.
        public let ocrSkipped: Bool
        /// The reason OCR was skipped. Nil iff `ocrSkipped == false`.
        public let ocrSkipReason: OCRSkipReason?

        public init(ocrSkipped: Bool, ocrSkipReason: OCRSkipReason?) {
            self.ocrSkipped = ocrSkipped
            self.ocrSkipReason = ocrSkipReason
        }

        /// Vision OCR ran for this page (the default path).
        public static let ocrRan = Provenance(ocrSkipped: false, ocrSkipReason: nil)

        /// OCR was skipped because the embedded text layer covers the page.
        public static let ocrSkippedDueToCoverage = Provenance(
            ocrSkipped: true, ocrSkipReason: .coverageHighEnough
        )

        /// OCR was skipped because the pipeline mode treats embedded text as
        /// authoritative. Reserved for future modes; the locked PERF-4 gate
        /// emits `.coverageHighEnough` paired with `.searchableRedaction`.
        public static let ocrSkippedDueToMode = Provenance(
            ocrSkipped: true, ocrSkipReason: .modeForcesEmbeddedText
        )

        /// Why Vision OCR was skipped on this detection's page.
        public enum OCRSkipReason: String, Sendable, Equatable, Hashable {
            /// Selectable-text coverage exceeded the locked 0.95 threshold
            /// in `.searchableRedaction` mode (PERF-4 fast path).
            case coverageHighEnough
            /// The pipeline mode treats embedded text as authoritative.
            /// Reserved; not emitted by the current gate.
            case modeForcesEmbeddedText
            /// ST-83 — the page's raster exceeded the OCR pixel caps
            /// (`maxOCRPixelDimension` / `maxOCRPixelCount`), so Vision
            /// OCR never ran and the page's image content was not
            /// text-scanned. Surfaced to the user via the triage banner.
            case pixelCapExceeded
        }
    }

    /// PIIKind values matching RedactionRegion.PIIKind for consistency.
    public typealias PIIKind = RedactionRegion.PIIKind

    /// Convert to a RedactionRegion for storage in RedactionState.regions.
    /// The detection result's coordinate system matches the region's coordinate
    /// system (both normalized, bottom-left origin), so no conversion is needed.
    /// See ARCH §2.3.
    public func toRegion() -> RedactionRegion {
        let source: RedactionRegion.Source = switch kind {
        case .pii(let piiKind): .detectedPII(kind: piiKind)
        case .face: .detectedFace
        case .searchMatch(let term): .searchMatch(term: term)
        }
        return RedactionRegion(
            id: UUID(),   // Fresh ID — the region is a new entity
            normalizedRect: normalizedRect,
            source: source
        )
    }
}
