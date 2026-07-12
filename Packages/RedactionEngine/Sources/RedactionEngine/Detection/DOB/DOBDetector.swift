import Foundation

// Plan §4 — structured DOB with age-proximity heuristic. Replaces the
// inline `PIIDetector.dobPattern` once doctype-aware routing is live.
//
// Strategy:
//   • Broad regex for numeric dates (M/D/YY, MM-DD-YYYY, etc.) at base 0.01.
//   • Boost +0.30 when a "DOB|Date of Birth|Born" token lies within ±5
//     tokens of the match (A1 label boost).
//   • Boost +0.15 when a plausible age (1…120) appears on the same line.
//   • Structural date validation (month 1–12, day 1–31, year 1900–2030)
//     rejects obvious garbage.
//
// Doctype gating lives in PIIDetector.detect(in:doctype:); this struct is
// gate-agnostic.

struct DOBDetector: Sendable {

    /// Numeric MM/DD/YYYY (or M-D-YY, etc.). Structurally validated below.
    static let numericPattern = try! NSRegularExpression(
        pattern: #"(?<!\d)\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4}(?!\d)"#
    )

    /// Textual "Month DD, YYYY" and "Month DD YYYY" forms.
    static let textualPattern = try! NSRegularExpression(
        pattern: #"\b(?:January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\s+\d{1,2},?\s+\d{4}\b"#,
        options: [.caseInsensitive]
    )

    static let ageOnLine = try! NSRegularExpression(
        pattern: #"\b(?:age|aged)[\s:]*?(\d{1,3})\b"#,
        options: [.caseInsensitive]
    )

    private static let labelKeywords: Set<String> = [
        "dob", "d.o.b.", "date of birth", "born", "birth date", "birthdate"
    ]

    func detect(in text: NSString, range: NSRange) -> [PIIDetector.PIIMatch] {
        let fullText = text as String
        var results: [PIIDetector.PIIMatch] = []

        // Numeric dates pass structural validation (M 1–12, D 1–31, Y 1900–2030).
        for match in Self.numericPattern.matches(in: fullText, range: range) {
            let matchedText = text.substring(with: match.range)
            guard Self.isStructurallyValid(matchedText) else { continue }
            // D04-F2 A1: numeric base 0.01 -> 0.05 to match the textual path, so a
            // label-boosted numeric DOB clears the 0.30 Balanced/Conservative cutoff
            // with the same 0.05 margin the textual path already has (was 0.31, a
            // 0.01 razor). Unlabeled numeric (0.05) still does not clear 0.30 -> the
            // decision-boundary outcome is unchanged. Preset blob 28921a52 NOT touched.
            let confidence = Self.compositeConfidence(
                text: text, matchRange: match.range, base: 0.05
            )
            results.append(PIIDetector.PIIMatch(
                text: matchedText,
                range: match.range,
                kind: .dateOfBirth,
                confidence: confidence
            ))
        }

        // Textual dates (month name + day + year). Structural check: the year
        // capture sits in plausible 1900…2030 range (parsed from trailing \d{4}).
        for match in Self.textualPattern.matches(in: fullText, range: range) {
            let matchedText = text.substring(with: match.range)
            guard Self.textualYearInRange(matchedText) else { continue }
            let confidence = Self.compositeConfidence(
                text: text, matchRange: match.range, base: 0.05
            )
            results.append(PIIDetector.PIIMatch(
                text: matchedText,
                range: match.range,
                kind: .dateOfBirth,
                confidence: confidence
            ))
        }

        return results
    }

    private static func compositeConfidence(text: NSString, matchRange: NSRange, base: Double) -> Double {
        var confidence = base
        let contextRange = NSRange(
            location: max(0, matchRange.location - 80),
            length: min(text.length, matchRange.location + matchRange.length + 80) - max(0, matchRange.location - 80)
        )
        let contextLower = text.substring(with: contextRange).lowercased()
        let hasLabel = labelKeywords.contains { contextLower.contains($0) }
        if hasLabel { confidence += 0.30 }

        let lineRange = NSRange(
            location: max(0, matchRange.location - 40),
            length: min(text.length, matchRange.location + matchRange.length + 40) - max(0, matchRange.location - 40)
        )
        let lineContext = text.substring(with: lineRange)
        if ageOnLine.firstMatch(in: lineContext, range: NSRange(location: 0, length: (lineContext as NSString).length)) != nil {
            confidence += 0.15
        }
        return min(confidence, 0.95)
    }

    private static func textualYearInRange(_ text: String) -> Bool {
        let digits = text.split(whereSeparator: { !$0.isWholeNumber }).map(String.init)
        guard let year = digits.last.flatMap(Int.init) else { return false }
        return (1900...2030).contains(year)
    }

    /// Structural date validation. Accepts M/D/YY, MM/DD/YYYY, and dash/dot
    /// variants. Month 1–12, day 1–(28/29/30/31) depending on month and
    /// leap year, year 1900–2030.
    static func isStructurallyValid(_ date: String) -> Bool {
        let parts = date.components(separatedBy: CharacterSet(charactersIn: "/-."))
        guard parts.count == 3 else { return false }
        guard let month = Int(parts[0]), let day = Int(parts[1]), var year = Int(parts[2]) else { return false }
        guard (1...12).contains(month) else { return false }
        // L-03: expand the 2-digit year BEFORE the leap-year check, so the
        // Gregorian century rule (100-year exclusion with 400-year override)
        // uses the full year.
        if year < 100 {
            // Two-digit years: assume 20xx if ≤ 30, else 19xx.
            year += year <= 30 ? 2000 : 1900
        }
        // Per-month day caps + Gregorian leap-year rule for February.
        let daysInMonth = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        var maxDay = daysInMonth[month - 1]
        if month == 2 && year % 4 == 0 && (year % 400 == 0 || year % 100 != 0) {
            maxDay = 29
        }
        guard (1...maxDay).contains(day) else { return false }
        return (1900...2030).contains(year)
    }
}
