import Foundation
import RedactionEngine

// GAP §2.3: Metadata about a detected region, preserved separately from
// RedactionRegion to avoid leaking UI concerns into the RedactionEngine
// SPM package. Keyed by RedactionRegion.id in RedactionState.regionMetadata.

// nonisolated: a pure Sendable value type (kind/confidence/labels — no region
// geometry) constructed off MainActor inside `prepareApply` and carried back in
// the Sendable `PreparedApply`. Its explicit `init` (and the static label helpers
// it calls) would otherwise become MainActor-isolated under the s04 SE-0466
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

    /// Phase 3 §A5: set to true when this region is part of an ambiguous
    /// bare-surname cluster (≥15 entities, no disambiguating first-initial).
    /// Populated post-clustering in PipelineCoordinator.runDetectionPipeline.
    var isAmbiguousSurname: Bool = false

    /// Human-readable label for the PII kind (used in badges and triage list).
    /// Cached at init — all inputs are `let`, so the value never changes.
    let kindLabel: String

    /// Abbreviated label for canvas badge (max 4 characters).
    let badgeLabel: String

    /// Full description for accessibility and hover tooltip.
    /// F2-1: Labels MUST match `DetectionResult.Kind.fullName`
    /// (Extensions/DetectionKind+Display.swift) exactly — VoiceOver
    /// users encounter both surfaces for the same detection.
    let accessibilityDescription: String

    init(piiKind: DetectionResult.Kind, confidence: Double,
         matchedText: String?, recognitionLevel: DetectionResult.RecognitionLevel,
         isAmbiguousSurname: Bool = false) {
        self.piiKind = piiKind
        self.confidence = confidence
        self.matchedText = matchedText
        self.recognitionLevel = recognitionLevel
        self.isAmbiguousSurname = isAmbiguousSurname

        self.kindLabel = Self.computeKindLabel(piiKind)
        self.badgeLabel = Self.computeKindLabel(piiKind)

        let conf = Int(min(max(confidence, 0.0), 1.0) * 100)
        self.accessibilityDescription = "\(Self.computeFullDescription(piiKind)), \(conf)% confidence"
    }

    private static func computeKindLabel(_ kind: DetectionResult.Kind) -> String {
        switch kind {
        case .pii(let k):
            switch k {
            case .ssn:            "SSN"
            case .creditCard:     "Card"
            case .name:           "Name"
            case .address:        "Addr"
            case .email:          "Email"
            case .phone:          "Phone"
            case .ein:            "EIN"
            case .itin:           "ITIN"
            case .driversLicense: "DL"
            case .passport:       "PP"
            case .medicalRecord:  "MRN"
            case .dateOfBirth:    "DOB"
            case .npi:            "NPI"
            case .dea:            "DEA"
            case .account:        "Acct"
            case .routingNumber:  "RTN"
            case .licensePlate:   "LP"
            case .barcode:        "Code"
            // DRAW-3 — heuristic signature suggestion (triage-only).
            case .signatureCandidate: "Sig"
            case .other:          "PII"
            }
        case .face: "Face"
        case .searchMatch: "Find"
        }
    }

    private static func computeFullDescription(_ kind: DetectionResult.Kind) -> String {
        switch kind {
        case .pii(let k):
            switch k {
            case .ssn:            "Social Security Number"
            case .creditCard:     "Credit Card Number"
            case .name:           "Personal Name"
            case .address:        "Physical Address"
            case .email:          "Email Address"
            case .phone:          "Phone Number"
            case .ein:            "Employer ID Number"
            case .itin:           "Individual Taxpayer ID"
            case .driversLicense: "Driver's License Number"
            case .passport:       "Passport Number"
            case .medicalRecord:  "Medical Record Number"
            case .dateOfBirth:    "Date of Birth"
            case .npi:            "National Provider ID"
            case .dea:            "DEA Registration"
            case .account:        "Account Number"
            case .routingNumber:  "ABA Routing Number"
            case .licensePlate:   "License Plate"
            case .barcode:        "Barcode / QR"
            // DRAW-3 — mechanism-description copy (I6): describes what the
            // heuristic suggests, no outcome promise.
            case .signatureCandidate: "Possible Signature"
            case .other:          "Personal Information"
            }
        case .face: "Detected Face"
        case .searchMatch: "Search Match"
        }
    }
}
