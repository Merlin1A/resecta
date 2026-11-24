import UIKit
import RedactionEngine

// Accessible names for PII detection types, defined in the app target:
// the engine package has no UI dependencies.
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
        case .other:          "sensitive content"
        }
    }
}
