import Foundation

// W10: MRN-specific keyword profile for ContextWindowScorer.
// Mirrors SSNContextKeywords shape — scoped per-category per G4.

/// Medical Record Number context keyword configuration.
/// Positive: medical-document labels that corroborate an MRN.
/// Negative: receipts / ecommerce / tracking labels common in non-medical
/// docs that carry alphanumeric patient-ID-shaped strings.
public enum MRNContextKeywords {

    /// Window radius ±5 tokens (A1).
    /// Base 0.55 (no context), boosted 0.92 (positive context),
    /// floor 0.15 (negative context cannot suppress below this).
    public static let profile = KeywordProfile(
        positiveKeywords: [
            "patient",
            "medical record",
            "mrn",
            "mr#",
            "chart",
            "chart number",
            "dob",
            "date of birth",
            "admission",
            "discharge",
            "diagnosis",
            "physician",
            "hospital",
        ],
        negativeKeywords: [
            "invoice",
            "order",
            "order no",
            "order #",
            "receipt",
            "transaction",
            "purchase",
            "sku",
            "item",
            "shipping",
            "tracking",
        ],
        windowRadius: 5,
        baseConfidence: 0.55,
        boostedConfidence: 0.92,
        floor: 0.15
    )
}
