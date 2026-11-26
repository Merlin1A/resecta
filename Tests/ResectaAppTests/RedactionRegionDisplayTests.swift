import Testing
import UIKit
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// Accessible names for PII detection types, and the twin kind tables.

@Suite("RedactionRegion Display Properties", .tags(.display))
@MainActor
struct RedactionRegionDisplayTests {

    // MARK: - PII Kind Accessibility Names

    // MARK: - Twin display tables

    /// Every `DetectionResult.Kind` the app can stage. The exhaustive
    /// switch below stops compiling when a PII case is added, so this
    /// list cannot silently go stale.
    private static let everyKind: [DetectionResult.Kind] = {
        let pii: [RedactionRegion.PIIKind] = [
            .ssn, .creditCard, .name, .address, .email, .phone, .ein, .itin,
            .driversLicense, .passport, .medicalRecord, .dateOfBirth, .npi, .dea,
            .account, .routingNumber, .licensePlate, .other,
        ]
        for kind in pii {
            switch kind {
            case .ssn, .creditCard, .name, .address, .email, .phone, .ein, .itin,
                 .driversLicense, .passport, .medicalRecord, .dateOfBirth, .npi, .dea,
                 .account, .routingNumber, .licensePlate, .other:
                break
            }
        }
        return pii.map { .pii($0) } + [.searchMatch(term: "term")]
    }()

    @Test("RegionMetadata's kind tables mirror DetectionKind+Display for every kind")
    func regionMetadataMirrorsDisplayTables() {
        for kind in Self.everyKind {
            let metadata = RegionMetadata(
                piiKind: kind, confidence: 0.95, matchedText: nil, recognitionLevel: .fast
            )
            #expect(metadata.badgeLabel == kind.badge, "badge label drift for \(kind)")
            // "<full name>, <tier descriptor>" — 0.95 is the high band.
            #expect(metadata.accessibilityDescription == "\(kind.fullName), high confidence",
                    "full-name drift for \(kind)")
        }
    }

    @Test("PIIKind accessibilityName is correct",
          arguments: [
            (RedactionRegion.PIIKind.ssn, "social security number"),
            (RedactionRegion.PIIKind.creditCard, "credit card number"),
            (RedactionRegion.PIIKind.name, "personal name"),
            (RedactionRegion.PIIKind.address, "address"),
            (RedactionRegion.PIIKind.email, "email address"),
            (RedactionRegion.PIIKind.phone, "phone number"),
            (RedactionRegion.PIIKind.ein, "employer identification number"),
            (RedactionRegion.PIIKind.other, "sensitive content"),
          ])
    func piiKindAccessibilityNames(kind: RedactionRegion.PIIKind, expected: String) {
        #expect(kind.accessibilityName == expected)
    }

    @Test("All PIIKind accessibilityNames are non-empty",
          arguments: [
            RedactionRegion.PIIKind.ssn,
            RedactionRegion.PIIKind.creditCard,
            RedactionRegion.PIIKind.name,
            RedactionRegion.PIIKind.address,
            RedactionRegion.PIIKind.email,
            RedactionRegion.PIIKind.phone,
            RedactionRegion.PIIKind.ein,
            RedactionRegion.PIIKind.other,
          ])
    func allPIIKindNamesNonEmpty(kind: RedactionRegion.PIIKind) {
        #expect(!kind.accessibilityName.isEmpty)
    }
}
