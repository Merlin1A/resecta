import SwiftUI
import RedactionEngine

// §4.2-§4.3: Shared display properties for DetectionResult.Kind.
// Used by ScanReviewSection (kind filter chips, review-row badges).

extension DetectionResult.Kind {

    /// Short badge label for compact display (filter chips, row badges).
    var badge: String {
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
            case .barcode: "Code"
            // DRAW-3 — short label for triage filter chip + canvas badge.
            case .signatureCandidate: "Sig"
            case .other: "PII"
            }
        case .face: "Face"
        case .searchMatch: "Find"
        }
    }

    /// Full descriptive name for detail display and sorting.
    var fullName: String {
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
            case .barcode: "Barcode / QR"
            // DRAW-3 — mechanism-description copy (I6): the detector
            // suggests; the user confirms in triage.
            case .signatureCandidate: "Possible Signature"
            case .other: "Personal Information"
            }
        case .face: "Detected Face"
        case .searchMatch: "Search Match"
        }
    }

    /// Stable sort order for filter chip display.
    var sortOrder: Int {
        switch self {
        case .pii(let k):
            switch k {
            case .ssn: 0
            case .creditCard: 1
            case .name: 2
            case .email: 3
            case .phone: 4
            case .address: 5
            case .ein: 6
            case .itin: 7
            case .driversLicense: 8
            case .passport: 9
            case .medicalRecord: 10
            case .npi: 11
            case .dea: 12
            case .dateOfBirth: 13
            case .account: 14
            // Financial cluster: chip sits beside Account.
            case .routingNumber: 15
            case .licensePlate: 16
            case .barcode: 17
            // DRAW-3 — distinct chip slot between barcode and .other.
            case .signatureCandidate: 18
            case .other: 19
            }
        case .face: 20
        case .searchMatch: 21
        }
    }

    /// Badge background color for the detection kind.
    var badgeColor: Color {
        // F2-2: UIColor.system* for accessibility increased-contrast compatibility.
        switch self {
        case .pii: Color(uiColor: .systemOrange)
        case .face: Color(uiColor: .systemPurple)
        case .searchMatch: Color(uiColor: .systemGreen)
        }
    }
}
