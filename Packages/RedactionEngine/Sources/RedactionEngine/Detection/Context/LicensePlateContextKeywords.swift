import Foundation

// W10: License-plate keyword profile for ContextWindowScorer.
// Scoped per-category per G4; used by PIIDetector.detectLicensePlate.

/// License plate context keyword configuration.
/// Positive: vehicle/DMV labels that corroborate a plate.
/// Negative: inventory / product-code labels that share the
/// short alphanumeric shape.
public enum LicensePlateContextKeywords {

    /// Window radius ±5 tokens.
    /// Base 0.55 / boosted 0.88 / floor 0.20.
    public static let profile = KeywordProfile(
        positiveKeywords: [
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
