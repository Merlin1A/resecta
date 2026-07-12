import Testing
import UIKit
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// UI_UX §2.5: Visual distinction by region type.
// UI_UX §9.2: Accessible names for PII detection types.

@Suite("RedactionRegion Display Properties", .tags(.display))
@MainActor
struct RedactionRegionDisplayTests {

    // MARK: - Display Colors (UI_UX §2.5)

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

    // MARK: - PII Kind Accessibility Names (UI_UX §9.2)

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
