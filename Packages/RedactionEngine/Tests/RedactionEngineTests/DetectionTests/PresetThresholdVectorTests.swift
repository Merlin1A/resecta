import Testing
import Foundation
@testable import RedactionEngine

// S3 §1.7 — wireName extensions for 8 previously ungated categories +
// builtInDefaults rows + W4 gate integration.
//
// Design references:
//  - design 02 §2 "Item 1.7 — wireNames + Preset JSON for 8 Ungated Categories"
//  - design 02 §2 "Test Plan"

@Suite("PresetThresholdVector S3 §1.7 (wireName + threshold gate)")
struct PresetThresholdVectorTests {

    // MARK: - Wire name tests

    @Test("EIN has wire name 'ein'")
    func testEINWireName() {
        #expect(PresetThresholdVector.wireName(for: .ein) == "ein")
    }

    @Test("All 8 previously-ungated categories now have wire names")
    func testAllUngatedCategoriesHaveWireNames() {
        let ungated: [PIICategory] = [
            .ein, .itin, .creditCard, .email, .phone,
            .driversLicense, .passport, .licensePlate,
        ]
        for category in ungated {
            #expect(
                PresetThresholdVector.wireName(for: category) != nil,
                "\(category) must have a wireName after S3 §1.7"
            )
        }
    }

    @Test("ITIN has wire name 'itin'")
    func testITINWireName() {
        #expect(PresetThresholdVector.wireName(for: .itin) == "itin")
    }

    @Test("CreditCard has wire name 'creditCard'")
    func testCreditCardWireName() {
        #expect(PresetThresholdVector.wireName(for: .creditCard) == "creditCard")
    }

    @Test("Email has wire name 'email'")
    func testEmailWireName() {
        #expect(PresetThresholdVector.wireName(for: .email) == "email")
    }

    @Test("Phone has wire name 'phone'")
    func testPhoneWireName() {
        #expect(PresetThresholdVector.wireName(for: .phone) == "phone")
    }

    @Test("DriversLicense has wire name 'driversLicense'")
    func testDriversLicenseWireName() {
        #expect(PresetThresholdVector.wireName(for: .driversLicense) == "driversLicense")
    }

    @Test("Passport has wire name 'passport'")
    func testPassportWireName() {
        #expect(PresetThresholdVector.wireName(for: .passport) == "passport")
    }

    @Test("LicensePlate has wire name 'licensePlate'")
    func testLicensePlateWireName() {
        #expect(PresetThresholdVector.wireName(for: .licensePlate) == "licensePlate")
    }

    // MARK: - Built-in defaults contain the 8 new categories

    @Test("builtInDefaults balanced preset contains ein threshold 0.55")
    func testBuiltInDefaultsEINBalanced() {
        let bundle = PresetThresholdBundle.builtInDefaults
        let vector = bundle.presets[.balanced]
        #expect(vector?.threshold(for: .ein) == 0.55)
    }

    @Test("builtInDefaults aggressive preset contains ein threshold 0.45")
    func testBuiltInDefaultsEINAggressive() {
        let bundle = PresetThresholdBundle.builtInDefaults
        let vector = bundle.presets[.aggressive]
        #expect(vector?.threshold(for: .ein) == 0.45)
    }

    @Test("builtInDefaults conservative preset contains ein threshold 0.70")
    func testBuiltInDefaultsEINConservative() {
        let bundle = PresetThresholdBundle.builtInDefaults
        let vector = bundle.presets[.conservative]
        #expect(vector?.threshold(for: .ein) == 0.70)
    }

    // MARK: - W4 gate integration: EIN threshold gate (design §2 test plan)

    /// W4 gate with balanced ein=0.55: an EIN match at score 0.50 must be
    /// suppressed (below balanced threshold). Score 0.56 passes.
    @Test("Balanced EIN threshold 0.55 suppresses a 0.50-score EIN match")
    func testThresholdGateAppliesForEIN() {
        // Construct a vector with the balanced EIN threshold.
        let vector = PresetThresholdVector(thresholdsByWireName: ["ein": 0.55])

        // A 0.50-score EIN match: should be dropped (below 0.55).
        let suppressedMatch = PIIDetector.PIIMatch(
            text: "12-3456789",
            range: NSRange(location: 0, length: 10),
            kind: .ein,
            confidence: 0.50,
            rationale: MatchRationale(
                ruleID: "ein.regex",
                signals: [.regexPattern(name: "ein.regex")],
                preThresholdScore: 0.50,
                finalScore: 0.50
            )
        )
        let afterSuppressed = [suppressedMatch].applying(thresholdVector: vector)
        #expect(afterSuppressed.isEmpty,
                "EIN match at 0.50 must be dropped by balanced threshold 0.55")

        // Adversarial: a 0.56-score EIN match must pass.
        let passingMatch = PIIDetector.PIIMatch(
            text: "12-3456789",
            range: NSRange(location: 0, length: 10),
            kind: .ein,
            confidence: 0.56,
            rationale: MatchRationale(
                ruleID: "ein.regex",
                signals: [.regexPattern(name: "ein.regex")],
                preThresholdScore: 0.56,
                finalScore: 0.56
            )
        )
        let afterPassing = [passingMatch].applying(thresholdVector: vector)
        #expect(afterPassing.count == 1,
                "EIN match at 0.56 must pass the balanced threshold 0.55")
    }

    // MARK: - CAT-038 W4 residue guard

    /// Permanent regression guard for the W4 nil-bypass residue: every
    /// wire-named PIICategory must have a non-nil threshold in every preset of
    /// `builtInDefaults`. A wire-named category without a row would make the W4
    /// gate read a nil cutoff and pass the category through ungated. Pairs with
    /// the debug-only completeness assertion in `builtInDefaults`.
    @Test("All wireName-mapped categories have a non-nil builtInDefaults threshold (CAT-038)")
    func testAllWireNamedCategoriesHaveNonNilBuiltInThresholds() {
        let bundle = PresetThresholdBundle.builtInDefaults
        for category in PIICategory.allCases {
            guard PresetThresholdVector.wireName(for: category) != nil else { continue }
            for (preset, vector) in bundle.presets {
                #expect(
                    vector.threshold(for: category) != nil,
                    "Wire-named \(category) lacks a \(preset) builtInDefaults threshold — the W4 gate would read a nil cutoff and pass it through ungated")
            }
        }
    }

    // MARK: - D04 preset-cutoff invariant (guards 28921a52 against a threshold-lowering "fix")

    /// The D04-F1 (NPI) and D04-F2 A1 (DOB) margin fixes live entirely in
    /// detector Swift literals; the calibrated preset blob (git 28921a52) is NOT
    /// touched. This pins the shipped npi/dob cutoffs at their real values so a
    /// future "lower the gate" change that churns the blob trips here and is
    /// reviewed. NOTE: conservative.npi is 0.85 (NOT 0.602) — it intentionally
    /// requires the keyword boost; 0.602 is the balanced + aggressive cutoff.
    @Test("Preset npi/dob cutoffs are unchanged (guards 28921a52 against a threshold-lowering fix)")
    func presetNPIAndDOBCutoffsAreInvariant() {
        let bundle = PresetThresholdBundle.loadFromEngineBundle()
        // Reading the calibrated blob, not the placeholder degrade path.
        #expect(bundle.status == .calibrated)
        // npi cutoffs (gate the D04-F1 bare-NPI margin)
        #expect(bundle.presets[.aggressive]?.threshold(forWireName: "npi") == 0.602)
        #expect(bundle.presets[.balanced]?.threshold(forWireName: "npi") == 0.602)
        #expect(bundle.presets[.conservative]?.threshold(forWireName: "npi") == 0.85)
        // dob cutoffs (gate the D04-F2 A1 labeled-DOB margin)
        #expect(bundle.presets[.aggressive]?.threshold(forWireName: "dob") == 0.012)
        #expect(bundle.presets[.balanced]?.threshold(forWireName: "dob") == 0.30)
        #expect(bundle.presets[.conservative]?.threshold(forWireName: "dob") == 0.30)
    }
}
