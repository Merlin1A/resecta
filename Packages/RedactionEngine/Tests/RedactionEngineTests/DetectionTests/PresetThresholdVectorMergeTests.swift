import Testing
@testable import RedactionEngine

// W4 — merged(overriding:) layers per-category overrides on top of the
// preset vector. Non-calibration categories are silently dropped;
// values are clamped to [0, 1].

@Suite("PresetThresholdVector.merged(overriding:) (W4)")
struct PresetThresholdVectorMergeTests {

    private var baseline: PresetThresholdVector {
        PresetThresholdVector(thresholdsByWireName: [
            "ssn": 0.80, "name": 0.70, "dob": 0.70, "address": 0.70,
            "account": 0.70, "mrn": 0.70, "npi": 0.70, "dea": 0.70,
        ])
    }

    @Test("Empty override is identity")
    func emptyOverrideIsIdentity() {
        let merged = baseline.merged(overriding: [:])
        #expect(merged.thresholdsByWireName == baseline.thresholdsByWireName)
    }

    @Test("Calibration-category override replaces preset value")
    func calibrationOverrideApplied() {
        let merged = baseline.merged(overriding: [
            .ssn: 0.92, .name: 0.60,
        ])
        #expect(merged.threshold(for: .ssn) == 0.92)
        #expect(merged.threshold(for: .name) == 0.60)
        // Untouched keys preserved.
        #expect(merged.threshold(for: .dateOfBirth) == 0.70)
    }

    // S3 §1.7: email / phone / creditCard now have wire names, so they ARE
    // applied by merged(overriding:). The test verifies the new behavior:
    // all three overrides are reflected in the merged vector.
    @Test("S3: email / phone / creditCard now have wire names — overrides are applied")
    func calibrationCategoriesWithS3WireNamesApplied() {
        let merged = baseline.merged(overriding: [
            .email: 0.95, .phone: 0.10, .creditCard: 0.50,
        ])
        #expect(merged.threshold(for: .email) == 0.95,
                "email now has a wire name — override must be applied")
        #expect(merged.threshold(for: .phone) == 0.10,
                "phone now has a wire name — override must be applied")
        #expect(merged.threshold(for: .creditCard) == 0.50,
                "creditCard now has a wire name — override must be applied")
    }

    @Test("Values are clamped to [0, 1]")
    func valuesAreClamped() {
        let merged = baseline.merged(overriding: [
            .ssn: 1.42,     // above upper bound
            .name: -0.25,   // below lower bound
        ])
        #expect(merged.threshold(for: .ssn) == 1.0)
        #expect(merged.threshold(for: .name) == 0.0)
    }

    // S3 §1.7: email now has a wire name, so all three overrides apply.
    @Test("S3: mixed override with email — all three applied")
    func mixedOverrideAllApplied() {
        let merged = baseline.merged(overriding: [
            .ssn: 0.95,      // applied (was calibration before)
            .email: 0.50,    // applied (S3: now has wire name)
            .name: 0.55,     // applied (was calibration before)
        ])
        #expect(merged.threshold(for: .ssn) == 0.95)
        #expect(merged.threshold(for: .name) == 0.55)
        // email is now applied — the vector gains the "email" key.
        #expect(merged.threshold(for: .email) == 0.50,
                "email override must be applied in S3+")
    }

    @Test("Overriding a missing-from-baseline calibration category adds it")
    func overrideAddsMissingKey() {
        // Baseline without "mrn"; override adds it.
        let sparse = PresetThresholdVector(thresholdsByWireName: ["ssn": 0.80])
        let merged = sparse.merged(overriding: [.medicalRecord: 0.65])
        #expect(merged.threshold(for: .medicalRecord) == 0.65)
        #expect(merged.threshold(for: .ssn) == 0.80)
    }
}
