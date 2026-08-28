import Foundation

// License-plate keyword profile for ContextWindowScorer.
// Scoped per-category per G4; used by PIIDetector.detectLicensePlate.

/// License plate context keyword configuration.
/// Positive: vehicle/DMV labels that corroborate a plate.
/// Negative: inventory / product-code labels that share the
/// short alphanumeric shape.
public enum LicensePlateContextKeywords {

    /// Window radius ±5 tokens.
    /// Base 0.55 / boosted 0.88 / floor 0.20.
    /// The positive set mirrors the `licenseplate` positives in the bundled
    /// `context-keywords.json`; the loader is the runtime source and this
    /// profile is the fallback when no loader is available.
    public static let profile = KeywordProfile(
        positiveKeywords: [
            "license plate",
            "lp",
            "plate",
            "tag",
            "vehicle",
            "car",
            "truck",
            "motorcycle",
            "dmv",
            "registration",
            "vin",
            "make",
            "model",
            "driver",
            "owner",
        ],
        negativeKeywords: [
            "sku",
            "part number",
            "order",
            "product code",
            "barcode",
            "serial",
        ],
        windowRadius: 5,
        baseConfidence: 0.55,
        boostedConfidence: 0.88,
        floor: 0.20
    )
}
