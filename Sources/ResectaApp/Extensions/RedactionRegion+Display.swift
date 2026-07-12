import UIKit
import RedactionEngine

// UI_UX §2.5: Visual distinction by region type.
// Defined in app target — engine package has zero UI dependencies.

extension RedactionRegion {

    /// Display color for the overlay based on region source and selection state.
    ///
    /// | Source          | Unselected | Selected |
    /// |-----------------|------------|----------|
    /// | Manual          | .systemRed | .systemBlue |
    /// | Detected PII    | .systemOrange | .systemBlue |
    /// | Detected Face   | .systemPurple | .systemBlue |
    func displayColor(isSelected: Bool) -> UIColor {
        if isSelected { return .systemBlue }
        switch source {
        case .manual:                return .systemRed
        case .detectedPII:           return .systemOrange
        case .detectedFace:          return .systemPurple
        case .searchMatch:           return .systemGreen
        }
    }
}

// UI_UX §9.2: Accessible names for PII detection types.
extension RedactionRegion.PIIKind {
    var accessibilityName: String {
        switch self {
        case .ssn:            "social security number"
        case .creditCard:     "credit card number"
        case .name:           "personal name"
        case .address:        "address"
        case .email:          "email address"
        case .phone:          "phone number"
        case .ein:            "employer identification number"
        case .itin:           "individual taxpayer identification number"
        case .driversLicense: "driver's license number"
        case .passport:       "passport number"
        case .medicalRecord:  "medical record number"
        case .dateOfBirth:    "date of birth"
        case .npi:            "national provider identifier"
        case .dea:            "DEA registration number"
        case .account:        "account number"
        case .routingNumber:  "bank routing number"
        case .licensePlate:   "license plate"
        case .barcode:        "barcode or QR code"
        // DRAW-3 — heuristic visual suggestion; surfaced in VoiceOver labels.
        case .signatureCandidate: "possible signature"
        case .other:          "sensitive content"
        }
    }
}
