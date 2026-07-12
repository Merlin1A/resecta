import Foundation

// ONE shared detector-ID → human-name
// mapping consumed by every rationale surface (ReverseRationalePopover,
// SearchResultRow inline expander, MatchRationaleSheet, plus the canvas
// viewers RegionRationaleSheet / RegionInfoPopover). Display vocabulary
// ONLY: the audit-export vocabulary is a contract surface and keeps the
// raw engine ruleIDs (RuleCatalog owns that translation).
//
// Fail-open contract: an unmapped ruleID renders the raw ID verbatim —
// never blank. Surfaces keep the raw ID available in a secondary /
// disclosure position for power users and audit correlation.

enum DetectorNameCatalog {

    /// Engine ruleID → human-readable detector name. Keys mirror the
    /// engine-emission vocabulary that `RuleCatalog.engineToCatalog`
    /// aliases, plus the synthetic IDs (`user.alwaysFlag`, `pii.other`)
    /// that intentionally have no catalog entry.
    static let names: [String: String] = [
        // SSN — state-machine pass + regex fallback.
        "ssn.state-machine":    "SSN pattern check",
        "ssn.regex":            "SSN format check",
        // Financial.
        "cc.luhn":              "Card number check (Luhn)",
        "account.regex":        "Account number format",
        "routingNumber.aba-checksum": "Routing number check (ABA)",
        // Contact.
        "email.regex":          "Email format",
        "phone.regex":          "Phone number format",
        "address.regex":        "Address format",
        // Identity numbers.
        "ein.regex":            "EIN format",
        "itin.regex":           "ITIN format",
        "itin.yy-bucket":       "ITIN year-group check",
        "dob.regex":            "Date-of-birth format",
        "passport.regex":       "Passport number format",
        "dl.regex":             "Driver's license format",
        "licensePlate.labeled": "License plate check",
        // Medical.
        "mrn.labeled":          "Medical record number (labeled)",
        "mrn.patientID":        "Medical record number (patient ID)",
        "mrn.institution":      "Medical record number (institution)",
        "mrn.regex":            "Medical record number format",
        "npi.80840":            "NPI number check",
        "dea.letter-check":     "DEA number check",
        // Names.
        "name.nltagger":        "Name recognition",
        // Visual detectors.
        "barcode.vision":       "Barcode detection",
        "signature.heuristic":  "Signature detection",
        // Synthetic / fallback IDs.
        "user.alwaysFlag":      "Your always-flag term",
        "pii.other":            "Other detector",
    ]

    /// Human name for a ruleID, or nil when unmapped. Tolerates a
    /// trailing `.vN` version suffix (e.g. `ssn.state-machine.v2`) so a
    /// future versioned emission still resolves to its family name.
    static func humanName(forRuleID ruleID: String) -> String? {
        if let name = names[ruleID] { return name }
        // Strip one trailing ".v<digits>" component and retry.
        if let range = ruleID.range(of: #"\.v\d+$"#, options: .regularExpression) {
            let base = String(ruleID[..<range.lowerBound])
            return names[base]
        }
        return nil
    }

    /// Display name — human name when mapped, raw ID otherwise
    /// (fail-open: never blank).
    static func displayName(forRuleID ruleID: String) -> String {
        humanName(forRuleID: ruleID) ?? ruleID
    }
}
