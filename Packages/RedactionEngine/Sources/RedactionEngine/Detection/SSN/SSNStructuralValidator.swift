import Foundation

// A6: Structural validation for SSN candidates.
// Rejects invalid area/group/serial combinations per SSA assignment rules.

/// Validates SSN candidates against SSA structural rules.
/// All rejection rules are independent — a candidate must pass ALL checks.
public struct SSNStructuralValidator: Sendable {

    public init() {}

    /// Returns true if the candidate passes all structural validation checks.
    public func isValid(_ candidate: SSNCandidate) -> Bool {
        let area = candidate.area
        let group = candidate.group
        let serial = candidate.serial

        // Rule 1: Area "000" — never assigned by SSA
        if area == "000" { return false }

        // Rule 2: Area "666" — never assigned (historically excluded)
        if area == "666" { return false }

        // Rule 3: Area 900–999 — reserved for ITIN (handled by detectITINs)
        if let areaInt = Int(area), areaInt >= 900 { return false }

        // Rule 4: Group "00" — never assigned
        if group == "00" { return false }

        // Rule 5: Serial "0000" — never assigned
        if serial == "0000" { return false }

        // Rule 6: Woolworth/Wallet SSN — the most widely known invalid SSN.
        // SSA confirmed this was never a valid SSN. Appears in many test documents.
        if area == "078" && group == "05" && serial == "1120" { return false }

        // Rule 7: All-same-digit sequences — never valid, common in test/placeholder data.
        // Check: all 9 digits are the same character.
        let allDigits = area + group + serial
        if let first = allDigits.first, allDigits.allSatisfy({ $0 == first }) {
            return false
        }

        return true
    }
}
