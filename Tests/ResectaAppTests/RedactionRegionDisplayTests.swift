import Testing
import UIKit
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// Visual distinction by region type.
// Accessible names for PII detection types.

@Suite("RedactionRegion Display Properties", .tags(.display))
@MainActor
struct RedactionRegionDisplayTests {

    // MARK: - Display Colors

    @Test("Selected region is always systemBlue regardless of source",
          arguments: [
            RedactionRegion.Source.manual,
            RedactionRegion.Source.detectedPII(kind: .ssn),
            RedactionRegion.Source.detectedFace,
          ])
    func selectedRegionAlwaysBlue(source: RedactionRegion.Source) {
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3),
            source: source)
        #expect(region.displayColor(isSelected: true) == .systemBlue)
    }

    @Test("Manual region unselected is systemRed")
    func manualUnselectedIsRed() {
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3),
            source: .manual)
        #expect(region.displayColor(isSelected: false) == .systemRed)
    }

    @Test("Detected PII region unselected is systemOrange")
    func detectedPIIUnselectedIsOrange() {
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3),
            source: .detectedPII(kind: .ssn))
        #expect(region.displayColor(isSelected: false) == .systemOrange)
    }

    @Test("Detected face region unselected is systemPurple")
    func detectedFaceUnselectedIsPurple() {
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3),
            source: .detectedFace)
        #expect(region.displayColor(isSelected: false) == .systemPurple)
    }

    // The prior per-source tests above never covered
    // `.searchMatch` — the dominant flow's own color, reached by every
    // Scan-applied AND Search-applied region. Full 4-source ×
    // selected/unselected table pin so the render contract stays frozen
    // exactly as shipped, `.searchMatch` included.
    @Test("displayColor — full 4-source x selection-state render contract",
          arguments: [
            (RedactionRegion.Source.manual, false, UIColor.systemRed),
            (RedactionRegion.Source.manual, true, UIColor.systemBlue),
            (RedactionRegion.Source.detectedPII(kind: .ssn), false, UIColor.systemOrange),
            (RedactionRegion.Source.detectedPII(kind: .ssn), true, UIColor.systemBlue),
            (RedactionRegion.Source.detectedFace, false, UIColor.systemPurple),
            (RedactionRegion.Source.detectedFace, true, UIColor.systemBlue),
            (RedactionRegion.Source.searchMatch(term: "example"), false, UIColor.systemGreen),
            (RedactionRegion.Source.searchMatch(term: "example"), true, UIColor.systemBlue),
          ])
    func displayColorFullRenderContractTable(
        source: RedactionRegion.Source, isSelected: Bool, expected: UIColor
    ) {
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3),
            source: source)
        #expect(region.displayColor(isSelected: isSelected) == expected)
    }

    // MARK: - PII Kind Accessibility Names

    // MARK: - Twin display tables

    /// Every `DetectionResult.Kind` the app can stage. The exhaustive
    /// switch below stops compiling when a PII case is added, so this
    /// list cannot silently go stale.
    private static let everyKind: [DetectionResult.Kind] = {
        let pii: [RedactionRegion.PIIKind] = [
            .ssn, .creditCard, .name, .address, .email, .phone, .ein, .itin,
            .driversLicense, .passport, .medicalRecord, .dateOfBirth, .npi, .dea,
            .account, .routingNumber, .licensePlate, .barcode, .signatureCandidate, .other,
        ]
        for kind in pii {
            switch kind {
            case .ssn, .creditCard, .name, .address, .email, .phone, .ein, .itin,
                 .driversLicense, .passport, .medicalRecord, .dateOfBirth, .npi, .dea,
                 .account, .routingNumber, .licensePlate, .barcode, .signatureCandidate, .other:
                break
            }
        }
        return pii.map { .pii($0) } + [.face, .searchMatch(term: "term")]
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
