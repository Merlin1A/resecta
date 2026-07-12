import Foundation

// A6: SSN-specific keyword profile for ContextWindowScorer.
// Per-category scoped per G4 — SSN keywords are NOT shared globally.
// Phase 3 categories will add their own keyword files.

/// SSN context keyword configuration.
/// Positive keywords: labels that confirm an SSN.
/// Negative keywords: labels near numeric sequences that are NOT SSNs
/// (case numbers, docket numbers, invoice numbers, etc.).
public enum SSNContextKeywords {

    /// The keyword profile for SSN context scoring.
    /// Window radius: ±5 tokens (per A1).
    /// Base confidence: 0.75 (no context).
    /// Boosted confidence: 0.95 (positive context).
    /// Floor: 0.25 (negative context cannot suppress below this, per A1 risk mitigation).
    public static let profile = KeywordProfile(
        positiveKeywords: [
            "ssn",
            "social security",
            "social security number",
            "social security no",
            "ss#",
            "ssan",
            "ssno",
            "ss no",
            "ss number",
            "ss num",
        ],
        negativeKeywords: [
            "case number", "case no", "case #",
            "docket", "docket no", "docket #", "docket number",
            "invoice", "invoice #", "invoice no", "invoice number",
            "reference", "reference #", "ref #", "ref no", "reference no", "reference number",
            "order no", "order #", "order number",
            "policy no", "policy #", "policy number",
            "file no", "file #", "file number",
            "claim no", "claim #", "claim number",
            "account no", "account #", "account number",
            "receipt", "confirmation",
            "tracking", "tracking #", "tracking no",
            "permit", "permit no", "permit #",
            "license no", "license #",
            "patent", "patent no",
            "serial no", "serial #",
            "model no", "part no",
            "item no", "item #",
            "transaction", "transaction id", "transaction #",
            "vin", "upc", "sku", "isbn",
        ],
        windowRadius: 5,
        baseConfidence: 0.75,
        boostedConfidence: 0.95,
        floor: 0.25
    )
}
