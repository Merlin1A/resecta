import Testing
import Foundation
@testable import RedactionEngine

// One detector per family behind one registry: every category has exactly
// one row, the rows run in the documented order, and each family's doctype
// gate reads as the page scan documents it (the reverse-rationale mirror
// reads the same gates).

@Suite("Detector registry")
struct DetectorRegistryTests {

    @Test("Every PIICategory has exactly one row")
    func everyCategoryHasOneRow() {
        let registry = PIIDetector().families
        let categories = registry.rows.map(\.category)
        #expect(categories.count == PIICategory.allCases.count)
        #expect(Set(categories).count == categories.count)
        for category in PIICategory.allCases {
            #expect(registry[category] != nil, "\(category) has no detector")
            #expect(registry[category]?.category == category)
        }
    }

    @Test("Rows run in the page scan's evaluation order")
    func rowsRunInEvaluationOrder() {
        let expected: [PIICategory] = [
            .ssn, .creditCard, .email, .phone, .ein, .address, .dateOfBirth, .itin,
            .driversLicense, .passport, .medicalRecord, .npi, .dea, .account,
            .routingNumber, .licensePlate, .name,
        ]
        #expect(PIIDetector().families.rows.map(\.category) == expected)
    }

    @Test("The doctype gates read as documented; nil runs every family")
    func doctypeGates() {
        let registry = PIIDetector().families
        // The families with a gate and the doctypes they run on; every other
        // family runs on every doctype.
        let gated: [PIICategory: Set<DoctypeClass>] = [
            .npi: [.medical, .foia],
            .dea: [.medical],
            .account: [.financial, .medical, .court, .generic],
            .routingNumber: [.financial, .generic],
            .medicalRecord: [.medical],
            .licensePlate: [.court, .foia, .generic],
        ]
        for family in registry.rows {
            #expect(family.runs(doctype: nil), "\(family.category) must run with no doctype")
            for doctype in DoctypeClass.allCases {
                let expected = gated[family.category]?.contains(doctype) ?? true
                #expect(family.runs(doctype: doctype) == expected,
                        "\(family.category) on \(doctype): expected runs == \(expected)")
            }
        }
    }

    @Test("The DOB family names the path its telemetry takes")
    func dobTelemetryNamesThePath() {
        let dob = PIIDetector().families.dateOfBirth
        #expect(dob.telemetryName(doctype: nil) == "dob")
        #expect(dob.telemetryName(doctype: .medical) == "dob")
        #expect(dob.telemetryName(doctype: .financial) == "dob.label")
    }
}
