import SwiftUI
import RedactionEngine

// Shared display properties for DetectionResult.Kind.
// Used by `RegionMetadata` (the canvas badge and the region's full name).

extension DetectionResult.Kind {

    /// Short badge label for compact display (the canvas badge through
    /// `RegionMetadata`).
    nonisolated var badge: String {
        switch self {
        case .pii(let k):
            switch k {
            case .ssn: "SSN"
            case .creditCard: "Card"
            case .name: "Name"
            case .address: "Addr"
            case .email: "Email"
            case .phone: "Phone"
            case .ein: "EIN"
            case .itin: "ITIN"
            case .driversLicense: "DL"
            case .passport: "PP"
            case .medicalRecord: "MRN"
            case .dateOfBirth: "DOB"
            case .npi: "NPI"
            case .dea: "DEA"
            case .account: "Acct"
            case .routingNumber: "RTN"
            case .licensePlate: "LP"
            case .other: "PII"
            }
        case .face: "Face"
        case .searchMatch: "Find"
        }
    }

    /// Full descriptive name for detail display, sorting and the
    /// accessibility description `RegionMetadata` carries.
    nonisolated var fullName: String {
        switch self {
        case .pii(let k):
            switch k {
            case .ssn: "Social Security Number"
            case .creditCard: "Credit Card Number"
            case .name: "Personal Name"
            case .address: "Physical Address"
            case .email: "Email Address"
            case .phone: "Phone Number"
            case .ein: "Employer ID Number"
            case .itin: "Individual Taxpayer ID"
            case .driversLicense: "Driver's License"
            case .passport: "Passport Number"
            case .medicalRecord: "Medical Record Number"
            case .dateOfBirth: "Date of Birth"
            case .npi: "National Provider ID"
            case .dea: "DEA Registration"
            case .account: "Account Number"
            case .routingNumber: "ABA Routing Number"
            case .licensePlate: "License Plate"
            case .other: "Personal Information"
            }
        case .face: "Detected Face"
        case .searchMatch: "Search Match"
        }
    }
}
