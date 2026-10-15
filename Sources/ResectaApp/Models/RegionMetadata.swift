import Foundation
import RedactionEngine

// Metadata about a detected region, preserved separately from
// RedactionRegion to avoid leaking UI concerns into the RedactionEngine
// SPM package. Keyed by RedactionRegion.id in RedactionState.regionMetadata.

// nonisolated: a pure Sendable value type (kind/confidence/labels — no region
// geometry) constructed off MainActor inside `prepareApply` and carried back in
// the Sendable `PreparedApply`. Its explicit `init` (and the label reads it
// makes) would otherwise become MainActor-isolated under the SE-0466
// MainActor-default flip, breaking the detached apply-prepare path; pin the type
// nonisolated to restore its pre-flip status (mirrors UserTermsBlob et al.).
nonisolated struct RegionMetadata: Sendable {
    /// The detection kind (e.g., .pii(.ssn), .face).
    let piiKind: DetectionResult.Kind
    /// Detection confidence (0.0–1.0).
    let confidence: Double
    /// The matched text (e.g., "123-45-6789"), if available.
    let matchedText: String?
    /// The OCR recognition level used for this detection.
    let recognitionLevel: DetectionResult.RecognitionLevel

    /// Set to true when this region is part of an ambiguous
    /// bare-surname cluster (≥15 entities, no disambiguating first-initial).
    /// Set by the staged-review path's clustering.
    var isAmbiguousSurname: Bool = false

    /// Abbreviated label for canvas badge (max 4 characters).
    /// Cached at init — all inputs are `let`, so the value never changes.
    let badgeLabel: String

    /// Full description for accessibility and hover tooltip. Read from
    /// `DetectionResult.Kind.fullName` (Extensions/DetectionKind+Display.swift),
    /// the one label table, so VoiceOver users hear the same words on
    /// both surfaces for the same detection.
    let accessibilityDescription: String

    init(piiKind: DetectionResult.Kind, confidence: Double,
         matchedText: String?, recognitionLevel: DetectionResult.RecognitionLevel,
         isAmbiguousSurname: Bool = false) {
        self.piiKind = piiKind
        self.confidence = confidence
        self.matchedText = matchedText
        self.recognitionLevel = recognitionLevel
        self.isAmbiguousSurname = isAmbiguousSurname

        self.badgeLabel = piiKind.badge

        // A qualitative descriptor replaces the raw
        // percent. `SearchResultRow.absoluteConfidenceTier` is the one
        // threshold source (same-target reference; acceptable — the
        // thresholds themselves must not be duplicated here).
        let descriptor = SearchResultRow.absoluteConfidenceTier(confidence).descriptor
        self.accessibilityDescription = "\(piiKind.fullName), \(descriptor)"
    }
}
