import Testing
@testable import RedactionEngine

// Envelope reachability regression gate.
//
// NameThresholdSurfacingTests pins only `name`. Two incidents (name=0.98,
// DOB dead under every preset) showed that any category can be silently
// killed by a pipeline sweep or threshold edit. This parametric sibling
// covers every wireName'd category: for each preset, a candidate matching
// at its detector's maximum achievable confidence must pass the W4 gate
// (posterior at fresh prior > cutoff), or the category can never surface.
//
// Pipeline twin: DataPipeline/tests/test_reachability_envelope.py pins the
// same invariant against the built artifact via the
// `_DETECTOR_ACHIEVABLE_MAX` table in sweep_thresholds.py — update both
// tables together when a detector's ceiling moves.
//
// S2 state (design 01 §12 staging note, all three flips applied):
//  * `dob` promoted from withKnownIssue(0.50) to a plain assert at 0.85 —
//    the label-anchored path ships (detectDOBs emits fixed 0.85) together
//    with the 0.30/0.40/0.45 dob thresholds (item 1.1, D4).
//  * `address` raised 0.70 → 0.80 — item 1.6 routes spatial addresses
//    (assembler max 0.80) through resolveOverlaps + posterior + W4.
//  * `routingNumber` rows added at 0.88 with presets 0.50/0.60/0.70
//    (item 1.8). S3 item 1.7 extends both tables to 17 categories.
@Suite("Envelope reachability")
struct EnvelopeReachabilityTests {

    /// Each entry: (wireName, maxAchievable, citation).
    /// maxAchievable = highest confidence any match can produce at fresh
    /// priorMean = 0.5. WS3 must keep every shipped threshold strictly
    /// below these values.
    ///
    /// S3 §1.7 additions: 8 previously-ungated categories now have wire names;
    /// ceilings verified against the cited detector source files below.
    private static let envelopeTable: [(wireName: String, maxAchievable: Double, citation: String)] = [
        ("ssn",     0.95, "SSNContextKeywords.swift boostedConfidence=0.95"),
        ("name",    0.85, "PIIDetector.swift boost max +0.15, base 0.70"),
        ("mrn",     0.92, "MRNContextKeywords.swift boostedConfidence=0.92"),
        ("npi",     0.90, "NPIDetector.swift boostedConfidence=0.90"),
        ("dea",     0.90, "DEADetector.swift boostedConfidence=0.90"),
        ("dob",     0.85, "PIIDetector.detectDOBs() fixed 0.85 (label-anchored path, D4)"),
        ("account", 0.75, "AccountDetector.swift boostedConfidence=0.75"),
        ("address", 0.80, "AddressSpatialAssembler.swift max 0.80 (item 1.6 gated)"),
        ("routingNumber", 0.88, "RoutingNumberDetector.swift boostedConfidence=0.88"),
        // S3 §1.7 — 8 newly-wired categories (hand-set ceilings):
        ("ein",           0.85, "PIIDetector.einProfile boostedConfidence=0.85"),
        ("itin",          0.85, "PIIDetector.itinProfile boostedConfidence=0.85"),
        ("creditCard",    0.95, "PIIDetector.detectCreditCards() fixed 0.95 (Luhn+prefix gate)"),
        ("email",         0.90, "PIIDetector.detectEmails() fixed 0.90"),
        ("phone",         0.80, "PIIDetector.detectPhones() max 0.80 (context-boosted path)"),
        ("driversLicense", 0.80, "PIIDetector.detectDriversLicenses() fixed 0.80"),
        ("passport",      0.80, "PIIDetector.detectPassports() fixed 0.80"),
        ("licensePlate",  0.88, "LicensePlateContextKeywords.swift boostedConfidence=0.88"),
    ]

    /// Test-local wireName → PIICategory reverse map — extended to all 17
    /// wired categories in S3 §1.7.
    private static let wireNameToCategoryTable: [String: PIICategory] = [
        "ssn":            .ssn,
        "name":           .name,
        "mrn":            .medicalRecord,
        "npi":            .npi,
        "dea":            .dea,
        "dob":            .dateOfBirth,
        "account":        .account,
        "address":        .address,
        "routingNumber":  .routingNumber,
        // S3 §1.7 additions:
        "ein":            .ein,
        "itin":           .itin,
        "creditCard":     .creditCard,
        "email":          .email,
        "phone":          .phone,
        "driversLicense": .driversLicense,
        "passport":       .passport,
        "licensePlate":   .licensePlate,
    ]

    /// W4-gate reproduction: posterior of the category's max achievable raw
    /// score at the fresh prior, compared against the preset cutoff.
    private static func maxPosterior(
        forWireName wireName: String, maxAchievable: Double
    ) -> Double {
        let priorMean: Double
        if let category = Self.wireNameToCategoryTable[wireName] {
            priorMean = PerCategoryPriors().mean(category)
        } else {
            priorMean = 0.5 // fresh prior for categories not yet in the table
        }
        return CalibratedScorer().posterior(raw: maxAchievable, priorMean: priorMean)
    }

    @Test(
        "Envelope reachability: every preset threshold is strictly below category max achievable",
        arguments: SettingsPreset.allCases
    )
    func allPresetsUnderMaxAchievable(preset: SettingsPreset) throws {
        // loadFromEngineBundle() is non-throwing (degrades to builtInDefaults
        // internally); no `try` here.
        let bundle = PresetThresholdBundle.loadFromEngineBundle()
        let vector = try #require(bundle.presets[preset])

        for entry in Self.envelopeTable {
            let cutoff = vector.threshold(forWireName: entry.wireName) ?? 0.0
            let posterior = Self.maxPosterior(
                forWireName: entry.wireName, maxAchievable: entry.maxAchievable
            )
            #expect(
                posterior > cutoff,
                """
                \(preset.rawValue) preset threshold \(cutoff) for '\(entry.wireName)' \
                meets or exceeds the maximum achievable posterior \(posterior) \
                (raw max: \(entry.maxAchievable), citation: \(entry.citation)). \
                A candidate matching this category at its peak score cannot pass \
                the W4 gate. Reduce the threshold or raise the detector ceiling.
                """
            )
        }
    }

    @Test("Envelope table and reverse map stay in lockstep")
    func tableAndReverseMapAgree() {
        for entry in Self.envelopeTable {
            #expect(
                Self.wireNameToCategoryTable[entry.wireName] != nil,
                "'\(entry.wireName)' is in envelopeTable but missing from wireNameToCategoryTable"
            )
        }
    }
}
