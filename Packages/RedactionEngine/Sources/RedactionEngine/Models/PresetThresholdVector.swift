import Foundation
import OSLog

// Plan A8 / G9 — per-category thresholds for Conservative / Balanced / Aggressive
// presets. Schema defined at
// DataPipeline/schemas/preset_thresholds.schema.json; Phase 3 ships placeholders
// (status == "placeholder"), Phase 3b G9 sweep replaces with calibrated values.
//
// Phase 1 scope: loader exists; SettingsState holds the decoded dict; Stage 6
// CalibratedScorer (Phase 3) is the actual consumer. Missing JSON degrades
// gracefully to built-in defaults.

public struct PresetThresholdVector: Sendable, Equatable {
    /// Threshold by schema category name ("ssn", "npi", "dea", "dob",
    /// "address", "account", "mrn", "name"). Intentionally keyed by the
    /// wire format — lets Phase 1 ship before `PIICategory` gains
    /// `.npi` / `.dea` / `.account` in Phase 3.
    public let thresholdsByWireName: [String: Double]

    public init(thresholdsByWireName: [String: Double]) {
        self.thresholdsByWireName = thresholdsByWireName
    }

    /// Lookup by the schema wire name. Returns nil if the category isn't in
    /// this vector (not all categories are required to be present).
    public func threshold(forWireName name: String) -> Double? {
        thresholdsByWireName[name]
    }

    /// Convenience lookup by `PIICategory`. Returns nil when the category
    /// has no mapping to the schema wire names (e.g., `.creditCard`,
    /// `.email`, `.phone`, `.ein`, `.itin`, `.driversLicense`, `.passport`
    /// — these are v1.0 regex+checksum-only and not on the calibration path).
    public func threshold(for category: PIICategory) -> Double? {
        guard let wire = Self.wireName(for: category) else { return nil }
        return thresholdsByWireName[wire]
    }

    public static func wireName(for category: PIICategory) -> String? {
        switch category {
        case .ssn:            "ssn"
        case .address:        "address"
        case .name:           "name"
        case .dateOfBirth:    "dob"
        case .medicalRecord:  "mrn"
        case .npi:            "npi"
        case .dea:            "dea"
        case .account:        "account"
        case .routingNumber:  "routingNumber"
        // S3 §1.7: 8 previously ungated categories now have wire names so the
        // W4 preset gate applies. The threshold values are hand-set (not swept)
        // because these detectors are not in the score-dump _CATEGORIES list.
        case .ein:            "ein"
        case .itin:           "itin"
        case .creditCard:     "creditCard"
        case .email:          "email"
        case .phone:          "phone"
        case .driversLicense: "driversLicense"
        case .passport:       "passport"
        case .licensePlate:   "licensePlate"
        }
    }

    // W4 — per-category overrides layered on top of the preset vector.
    // Non-calibration categories (no wire-name) are silently dropped — they
    // have no threshold to override. Values clamped to [0, 1] defensively
    // even though the UI slider enforces the range.
    public func merged(overriding overrides: [PIICategory: Double]) -> PresetThresholdVector {
        var merged = thresholdsByWireName
        for (category, value) in overrides {
            guard let wire = Self.wireName(for: category) else { continue }
            merged[wire] = min(max(value, 0.0), 1.0)
        }
        return PresetThresholdVector(thresholdsByWireName: merged)
    }
}

public struct PresetThresholdBundle: Sendable, Equatable {
    public let presets: [SettingsPreset: PresetThresholdVector]
    public let status: Status
    public let version: Int

    public enum Status: String, Sendable, Codable, Equatable {
        case placeholder
        case calibrated
    }

    /// Load from `Resources/Classifier/preset-thresholds.json` in the engine
    /// bundle. Returns built-in defaults on any error (missing file, decode
    /// failure, missing required preset). Errors are logged via os.Logger at
    /// warning level with no document content — just mechanism metadata.
    public static func loadFromEngineBundle() -> PresetThresholdBundle {
        load(from: .module)
    }

    /// Testable loader — inject a custom bundle for fixture tests.
    public static func load(from bundle: Bundle) -> PresetThresholdBundle {
        guard let url = bundle.url(
            forResource: "preset-thresholds",
            withExtension: "json",
            subdirectory: "Classifier"
        ) else {
            logger.info("preset-thresholds.json not bundled; using built-in defaults")
            return .builtInDefaults
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(WireFormat.self, from: data)
            return try decoded.toBundle()
        } catch {
            logger.warning("preset-thresholds.json load failed; using defaults: \(String(describing: error), privacy: .public)")
            return .builtInDefaults
        }
    }

    /// Phase-1 placeholder values — flat across calibrated categories per preset;
    /// hand-set values for the 8 previously-ungated categories (S3 §1.7).
    /// Phase 3b G9 sweep produces per-category calibrated vectors for the swept set.
    public static let builtInDefaults: PresetThresholdBundle = {
        // routingNumber included so the degrade path still gates it — the W4
        // gate passes nil-threshold categories through unfiltered (S2 §4c).
        let calibratedCategories: [String] = ["ssn", "npi", "dea", "dob",
                                              "address", "account", "mrn", "name",
                                              "routingNumber"]
        // S3 §1.7: 8 ungated categories with hand-set thresholds matching
        // the committed preset-thresholds.json (aggressive/balanced/conservative).
        // RECALL NOTE for ein: balanced 0.55 is above base 0.50; an unlabeled
        // EIN without context context will be suppressed at balanced. Intentional:
        // WS1 1.9 EIN context profile pushes labeled EINs to 0.85 before W4.
        // The aggressive preset 0.45 preserves full recall for power users.
        let handSetAggressive: [String: Double] = [
            "ein": 0.45, "itin": 0.50, "creditCard": 0.85, "email": 0.80,
            "phone": 0.55, "driversLicense": 0.65, "passport": 0.65, "licensePlate": 0.50,
        ]
        let handSetBalanced: [String: Double] = [
            "ein": 0.55, "itin": 0.65, "creditCard": 0.88, "email": 0.83,
            "phone": 0.70, "driversLicense": 0.72, "passport": 0.72, "licensePlate": 0.65,
        ]
        let handSetConservative: [String: Double] = [
            "ein": 0.70, "itin": 0.78, "creditCard": 0.90, "email": 0.85,
            "phone": 0.75, "driversLicense": 0.75, "passport": 0.75, "licensePlate": 0.80,
        ]
        func vector(uniform t: Double, handSet: [String: Double]) -> PresetThresholdVector {
            var d = Dictionary(uniqueKeysWithValues: calibratedCategories.map { ($0, t) })
            for (k, v) in handSet { d[k] = v }
            return PresetThresholdVector(thresholdsByWireName: d)
        }
        let bundle = PresetThresholdBundle(
            presets: [
                .conservative: vector(uniform: 0.85, handSet: handSetConservative),
                .balanced:     vector(uniform: 0.70, handSet: handSetBalanced),
                .aggressive:   vector(uniform: 0.55, handSet: handSetAggressive),
            ],
            status: .placeholder,
            version: 0
        )
        #if DEBUG
        // Wire-name residue guard. Every wire-named
        // PIICategory must carry a threshold row in each preset: a wire-named
        // category with no row makes the threshold gate (DetectionOrchestrator /
        // ThresholdFilter) read a nil cutoff and pass the category through
        // ungated. That nil pass-through is INTENTIONAL for categories without
        // a wire name (exercised by ThresholdFilterTests), so the gate's
        // optional-chain stays as-is; this debug check instead pins the
        // *authoritative defaults* complete, surfacing a future category added
        // with a wireName but no defaults row at integration time rather than
        // shipping a silently ungated detector. Uses `threshold(forWireName:)`
        // (the plain dict lookup), so it is independent of `threshold(for:)`
        // and never trips on a partial instance vector. Permanent regression
        // guard: PresetThresholdVectorTests
        // .testAllWireNamedCategoriesHaveNonNilBuiltInThresholds.
        for category in PIICategory.allCases {
            guard let wire = PresetThresholdVector.wireName(for: category) else { continue }
            for (preset, vector) in bundle.presets where vector.threshold(forWireName: wire) == nil {
                assertionFailure(
                    "PIICategory.\(category.rawValue) (wire '\(wire)') has no \(preset) builtInDefaults threshold — add it to the hand-set tables")
            }
        }
        #endif
        return bundle
    }()
}

// MARK: - Wire format (matches DataPipeline/schemas/preset_thresholds.schema.json)

private struct WireFormat: Decodable {
    let version: Int
    let status: PresetThresholdBundle.Status
    let categories: [String]
    let presets: Presets

    struct Presets: Decodable {
        let conservative: [String: Double]
        let balanced: [String: Double]
        let aggressive: [String: Double]
    }

    func toBundle() throws -> PresetThresholdBundle {
        PresetThresholdBundle(
            presets: [
                .conservative: PresetThresholdVector(thresholdsByWireName: presets.conservative),
                .balanced:     PresetThresholdVector(thresholdsByWireName: presets.balanced),
                .aggressive:   PresetThresholdVector(thresholdsByWireName: presets.aggressive),
            ],
            status: status,
            version: version
        )
    }
}

private let logger = Logger(subsystem: "app.resecta.engine", category: "PresetThresholds")
