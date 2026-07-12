import Foundation

// CMS NPI Luhn-80840 checksum. Defined in CMS Publication 65/45 (2005):
// prepend the constant prefix "80840" to the 10-digit NPI, then apply the
// standard Luhn algorithm (mod-10). Result must be divisible by 10.
//
// Isolated from NPIDetector so unit tests can exercise the checksum
// against `Fixtures/vectors/npi_test_vectors.json` without regex plumbing.

enum NPILuhn80840 {
    /// Validate a 10-character NPI string. Returns true iff all characters
    /// are digits and the Luhn-80840 checksum passes.
    static func isValid(_ npi: String) -> Bool {
        guard npi.count == 10 else { return false }
        var digits: [Int] = Array("80840".compactMap { $0.wholeNumberValue })
        for char in npi {
            guard let d = char.wholeNumberValue, (0...9).contains(d) else { return false }
            digits.append(d)
        }
        // Standard Luhn over the 15-digit string. Double every second digit
        // from the right (i.e., starting at index 14 - 1 = 13, stepping back by 2).
        var sum = 0
        for (i, digit) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }
}
