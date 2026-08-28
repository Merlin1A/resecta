import UIKit
import RedactionEngine

// Visual distinction by region type.
// Defined in app target — engine package has zero UI dependencies.

extension RedactionRegion {

    /// Display color for the overlay based on region source and selection
    /// state.
    ///
    /// This table used to omit `.searchMatch`. At tip,
    /// the one-tap Scan flow applies through the search path, so every
    /// Scan-applied AND Search-applied region renders `.searchMatch`
    /// green; `.detectedPII` orange / `.detectedFace` purple are
    /// reachable only through the vestigial auto-apply pipeline path.
    /// The render contract the dominant flow actually shows is
    /// therefore a two-color reality — green (applied) / blue
    /// (selected) — plus manual red; selection always wins
    /// (`.systemBlue`) regardless of source.
    ///
    /// | Source          | Unselected     | Selected |
    /// |-----------------|----------------|------------|
    /// | Manual          | .systemRed     | .systemBlue |
    /// | Detected PII    | .systemOrange  | .systemBlue |
    /// | Detected Face   | .systemPurple  | .systemBlue |
    /// | Search Match    | .systemGreen   | .systemBlue |
    ///
    /// This color carries no per-tap ORIGIN (which detector/mechanism
    /// produced the region) — that lives on the canvas badge
    /// (`RedactionOverlayView.drawRegionBadge`) and the context-menu
    /// info title instead. The green→blue tint residue on select (a
    /// separate rendering-layer gap, not in this function) is a known,
    /// deferred issue not addressed here.
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

// Accessible names for PII detection types.
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
        // Heuristic visual suggestion; surfaced in VoiceOver labels.
        case .signatureCandidate: "possible signature"
        case .other:          "sensitive content"
        }
    }
}
