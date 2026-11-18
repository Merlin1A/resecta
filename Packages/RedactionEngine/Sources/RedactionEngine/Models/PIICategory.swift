import Foundation

// Engine-layer types for document search.
// All types are Sendable value types for safe cross-isolation transfer.

/// PII category for search-level filtering. Maps to RedactionRegion.PIIKind
/// but provides a stable, CaseIterable type for UI pickers and filter chips.
public enum PIICategory: String, CaseIterable, Sendable, Equatable, Hashable, Codable {
    case ssn = "SSN"
    case creditCard = "Credit Card"
    case email = "Email"
    case phone = "Phone"
    case address = "Address"
    case ein = "EIN"
    case itin = "ITIN"
    case driversLicense = "Driver's License"
    case name = "Name"
    case dateOfBirth = "Date of Birth"
    case passport = "Passport"
    case medicalRecord = "Medical Record"
    case npi = "NPI"
    case dea = "DEA"
    case account = "Account"
    // ABA routing number.
    case routingNumber = "Routing Number"
    case licensePlate = "License Plate"

    /// Convert to RedactionRegion.PIIKind for region creation.
    public var piiKind: RedactionRegion.PIIKind {
        switch self {
        case .ssn: .ssn
        case .creditCard: .creditCard
        case .email: .email
        case .phone: .phone
        case .address: .address
        case .ein: .ein
        case .itin: .itin
        case .driversLicense: .driversLicense
        case .name: .name
        case .dateOfBirth: .dateOfBirth
        case .passport: .passport
        case .medicalRecord: .medicalRecord
        case .npi: .npi
        case .dea: .dea
        case .account: .account
        case .routingNumber: .routingNumber
        case .licensePlate: .licensePlate
        }
    }

    /// Map from PIIKind to PIICategory.
    public init?(piiKind: RedactionRegion.PIIKind) {
        switch piiKind {
        case .ssn: self = .ssn
        case .creditCard: self = .creditCard
        case .email: self = .email
        case .phone: self = .phone
        case .address: self = .address
        case .ein: self = .ein
        case .itin: self = .itin
        case .driversLicense: self = .driversLicense
        case .name: self = .name
        case .dateOfBirth: self = .dateOfBirth
        case .passport: self = .passport
        case .medicalRecord: self = .medicalRecord
        case .npi: self = .npi
        case .dea: self = .dea
        case .account: self = .account
        case .routingNumber: self = .routingNumber
        case .licensePlate: self = .licensePlate
        case .other: return nil
        }
    }

    /// SF Symbol name for category badge display.
    public var symbolName: String {
        switch self {
        case .ssn: "number.circle"
        case .creditCard: "creditcard"
        case .email: "envelope"
        case .phone: "phone"
        case .address: "house"
        case .ein: "building.2"
        case .itin: "person.text.rectangle"
        case .driversLicense: "car"
        case .name: "person"
        case .dateOfBirth: "calendar"
        case .passport: "airplane"
        case .medicalRecord: "cross.case"
        case .npi: "stethoscope"
        case .dea: "pills"
        case .account: "number.square"
        case .routingNumber: "arrow.triangle.branch"
        case .licensePlate: "car"
        }
    }
}
