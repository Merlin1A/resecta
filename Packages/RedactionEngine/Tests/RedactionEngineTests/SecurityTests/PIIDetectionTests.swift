import Testing
import Foundation
import CoreGraphics
@testable import RedactionEngine

// TEST §7 — PII detection test cases.

@Suite("PII Detection")
struct PIIDetectionTests {

    // MARK: - SSN Regex (TEST §7.1)

    @Test("SSN regex matches valid formats", arguments: [
        "123-45-6789",    // Standard dashed
        "123 45 6789",    // Space-separated
        "123456789",      // No separator
        "123\u{2013}45\u{2013}6789",  // En-dash (U+2013) — common in typeset PDFs
        "123\u{2014}45\u{2014}6789",  // Em-dash (U+2014)
        "123\u{2011}45\u{2011}6789",  // Non-breaking hyphen (U+2011)
        "123\u{2012}45\u{2012}6789",  // Figure dash (U+2012)
    ])
    func validSSN(_ input: String) {
        let nsInput = input as NSString
        let range = NSRange(location: 0, length: nsInput.length)
        let matches = PIIDetector.ssnPattern.matches(in: input, range: range)
        #expect(!matches.isEmpty, "Expected SSN match for '\(input)'")
    }

    @Test("SSN regex rejects invalid patterns", arguments: [
        "000-45-6789",    // Invalid area: 000
        "666-45-6789",    // Invalid area: 666
        "900-45-6789",    // Invalid area: 900-999
        "123-00-6789",    // Invalid group: 00
        "123-45-0000",    // Invalid serial: 0000
        "1234567890",     // 10 digits (phone number)
        "12345678",       // 8 digits (too short)
        "123\u{2013}45-6789",  // Mixed separators: en-dash then hyphen (backreference \1 rejects)
    ])
    func invalidSSN(_ input: String) {
        let nsInput = input as NSString
        let range = NSRange(location: 0, length: nsInput.length)
        let matches = PIIDetector.ssnPattern.matches(in: input, range: range)
        #expect(matches.isEmpty, "Expected no SSN match for '\(input)'")
    }

    @Test("SSN with context words boosts confidence")
    func ssnContextBoost() async {
        let detector = PIIDetector()
        let text = "SSN: 123-45-6789 is the social security number"
        let results = await detector.detect(in: text)
        let ssnResults = results.filter { $0.kind == .ssn }
        #expect(!ssnResults.isEmpty)
        #expect(ssnResults.first!.confidence >= 0.90)
    }

    // MARK: - Luhn Checksum (TEST §7.2)

    @Test("Luhn check validates known card numbers", arguments: [
        ("4111111111111111", true),   // Visa test
        ("5500000000000004", true),   // MC test
        ("340000000000009", true),    // Amex test
        ("4111111111111112", false),  // Invalid checksum
        ("0000000000000000", true),   // Edge case: all zeros pass Luhn
    ] as [(String, Bool)])
    func luhnValidation(_ number: String, _ expected: Bool) {
        #expect(PIIDetector.luhnCheck(number) == expected)
    }

    @Test("Luhn rejects too-short and too-long inputs")
    func luhnLengthReject() {
        #expect(PIIDetector.luhnCheck("12345") == false)       // 5 digits
        #expect(PIIDetector.luhnCheck("12345678901234567890") == false) // 20 digits
    }

    // MARK: - Credit Card Detection

    @Test("Credit card detector finds valid Visa number with Luhn")
    func creditCardVisa() async {
        let detector = PIIDetector()
        let text = "Card: 4111-1111-1111-1111"
        let results = await detector.detect(in: text)
        let ccResults = results.filter { $0.kind == .creditCard }
        #expect(!ccResults.isEmpty, "Should detect valid Visa number")
    }

    @Test("Credit card detector rejects number failing Luhn")
    func creditCardInvalidLuhn() async {
        let detector = PIIDetector()
        let text = "Card: 4111-1111-1111-1112"  // Invalid check digit
        let results = await detector.detect(in: text)
        let ccResults = results.filter { $0.kind == .creditCard }
        #expect(ccResults.isEmpty, "Should reject number failing Luhn check")
    }

    // MARK: - Email Detection

    @Test("Email detector finds standard email address")
    func emailDetection() async {
        let detector = PIIDetector()
        let text = "Contact: john.doe@example.com for details"
        let results = await detector.detect(in: text)
        let emailResults = results.filter { $0.kind == .email }
        #expect(!emailResults.isEmpty)
        #expect(emailResults.first?.text == "john.doe@example.com")
    }

    // L-01: Email regex tightening

    @Test("Email regex still accepts valid addresses", arguments: [
        "john.doe@example.com",
        "a.b@example.co.uk",
        "user+tag@sub.domain.com",
        "first_last@site.io",
        "x@y.zz",
    ])
    func emailStillAcceptsValidAddresses(_ input: String) {
        let range = NSRange(location: 0, length: (input as NSString).length)
        let matches = PIIDetector.emailPattern.matches(in: input, range: range)
        #expect(!matches.isEmpty, "Expected email match for '\(input)'")
        // Exact-span match: the entire input is the match.
        let matched = (input as NSString).substring(with: matches.first!.range)
        #expect(matched == input, "Expected full-string match for '\(input)'")
    }

    @Test("Email regex rejects leading dot in local part")
    func emailRejectsLeadingDotLocal() {
        let input = ".a@b.co"
        let range = NSRange(location: 0, length: (input as NSString).length)
        let matches = PIIDetector.emailPattern.matches(in: input, range: range)
        for match in matches {
            let matched = (input as NSString).substring(with: match.range)
            #expect(!matched.hasPrefix("."),
                    "local part must not start with a dot — matched '\(matched)'")
        }
    }

    @Test("Email regex rejects leading dot in domain")
    func emailRejectsLeadingDotDomain() {
        let input = "a@.b.co"
        let range = NSRange(location: 0, length: (input as NSString).length)
        let matches = PIIDetector.emailPattern.matches(in: input, range: range)
        #expect(matches.isEmpty,
                "domain must not start with a dot — got \(matches.count) match(es)")
    }

    @Test("Email regex rejects consecutive dots in local part")
    func emailRejectsConsecutiveDotsLocal() {
        let input = "a..b@c.co"
        let range = NSRange(location: 0, length: (input as NSString).length)
        let matches = PIIDetector.emailPattern.matches(in: input, range: range)
        for match in matches {
            let matched = (input as NSString).substring(with: match.range)
            #expect(!matched.contains(".."),
                    "consecutive dots in local part should not match — got '\(matched)'")
        }
    }

    @Test("Email regex rejects consecutive dots in domain")
    func emailRejectsConsecutiveDotsDomain() {
        let input = "a@b..co"
        let range = NSRange(location: 0, length: (input as NSString).length)
        let matches = PIIDetector.emailPattern.matches(in: input, range: range)
        for match in matches {
            let matched = (input as NSString).substring(with: match.range)
            #expect(!matched.contains(".."),
                    "consecutive dots in domain should not match — got '\(matched)'")
        }
    }

    // MARK: - Phone Detection

    @Test("Phone detector finds US phone number formats")
    func phoneDetection() async {
        let detector = PIIDetector()
        let text = "Call (555) 123-4567 or 555.987.6543"
        let results = await detector.detect(in: text)
        let phoneResults = results.filter { $0.kind == .phone }
        #expect(phoneResults.count >= 1)
    }

    @Test("Phone detection boosts confidence with context keyword")
    func phoneContextBoost() async {
        let detector = PIIDetector()
        let text = "Phone: (555) 123-4567"
        let results = await detector.detect(in: text)
        let phoneResults = results.filter { $0.kind == .phone }
        #expect(!phoneResults.isEmpty)
        #expect(phoneResults.first!.confidence >= 0.75,
                "Context keyword should boost confidence")
    }

    @Test("Phone detection has lower base confidence without context")
    func phoneNoContext() async {
        let detector = PIIDetector()
        let text = "Reference 5551234567 in the filing"
        let results = await detector.detect(in: text)
        let phoneResults = results.filter { $0.kind == .phone }
        #expect(!phoneResults.isEmpty)
        #expect(phoneResults.first!.confidence < 0.70,
                "Without context keywords, confidence should be lower")
    }

    // L-04: Phone regex tightening

    @Test("Phone regex accepts balanced parens `(###) ###-####`", arguments: [
        "(555) 123-4567",
        "(555)123-4567",
        "(555).123.4567",
    ])
    func phoneAcceptsBalancedParens(_ input: String) {
        let range = NSRange(location: 0, length: (input as NSString).length)
        let matches = PIIDetector.phonePattern.matches(in: input, range: range)
        #expect(!matches.isEmpty, "Expected phone match for '\(input)'")
    }

    @Test("Phone regex accepts unparenthesized forms", arguments: [
        "555-123-4567",
        "555.123.4567",
        "555 123 4567",
        "5551234567",
    ])
    func phoneAcceptsNoParens(_ input: String) {
        let range = NSRange(location: 0, length: (input as NSString).length)
        let matches = PIIDetector.phonePattern.matches(in: input, range: range)
        #expect(!matches.isEmpty, "Expected phone match for '\(input)'")
    }

    @Test("Phone regex accepts `+1` country prefix", arguments: [
        "+1 555-123-4567",
        "+1-555-123-4567",
        "+1(555) 123-4567",
    ])
    func phoneAcceptsPlus1Prefix(_ input: String) {
        let range = NSRange(location: 0, length: (input as NSString).length)
        let matches = PIIDetector.phonePattern.matches(in: input, range: range)
        #expect(!matches.isEmpty, "Expected phone match for '\(input)'")
        // +1 should be inside the match.
        let matched = (input as NSString).substring(with: matches.first!.range)
        #expect(matched.hasPrefix("+1"), "Expected '+1' prefix in match, got '\(matched)'")
    }

    @Test("Phone regex rejects bare `+` (only `+1` leads)")
    func phoneRejectsBarePlus() {
        let input = "+555-123-4567"
        let range = NSRange(location: 0, length: (input as NSString).length)
        let matches = PIIDetector.phonePattern.matches(in: input, range: range)
        for match in matches {
            let matched = (input as NSString).substring(with: match.range)
            #expect(!matched.hasPrefix("+"),
                    "bare `+` should not prefix a phone match — got '\(matched)'")
        }
    }

    @Test("Phone regex does not absorb an unmatched leading `(`")
    func phoneRejectsUnbalancedLeftParen() {
        let input = "(555 123-4567"
        let range = NSRange(location: 0, length: (input as NSString).length)
        let matches = PIIDetector.phonePattern.matches(in: input, range: range)
        for match in matches {
            let matched = (input as NSString).substring(with: match.range)
            #expect(!matched.hasPrefix("("),
                    "unbalanced '(' should not be in the match — got '\(matched)'")
        }
    }

    @Test("Phone regex does not absorb an unmatched trailing `)`")
    func phoneRejectsUnbalancedRightParen() {
        let input = "555)123-4567"
        let range = NSRange(location: 0, length: (input as NSString).length)
        let matches = PIIDetector.phonePattern.matches(in: input, range: range)
        for match in matches {
            let matched = (input as NSString).substring(with: match.range)
            #expect(!matched.contains(")") || matched.hasPrefix("("),
                    "unmatched ')' should not appear in the match — got '\(matched)'")
        }
    }

    // MARK: - EIN Detection

    @Test("EIN detector finds employer ID with context boost")
    func einDetection() async {
        let detector = PIIDetector()
        let text = "EIN: 12-3456789 for the company"
        let results = await detector.detect(in: text)
        let einResults = results.filter { $0.kind == .ein }
        #expect(!einResults.isEmpty)
        #expect(einResults.first!.confidence >= 0.80)
    }

    // MARK: - ALL-CAPS Title-Casing (ENGINE §4.5)

    @Test("titleCaseAllCapsWords converts ALL-CAPS to title case")
    func titleCaseConversion() {
        let result = PIIDetector.titleCaseAllCapsWords("JOHN SMITH FILED A CLAIM")
        #expect(result == "John Smith Filed A Claim")
    }

    @Test("titleCaseAllCapsWords preserves known acronyms")
    func titleCasePreservesAcronyms() {
        let result = PIIDetector.titleCaseAllCapsWords("FBI AGENT SSN: 123")
        #expect(result.contains("FBI"))
        #expect(result.contains("SSN:"))
    }

    @Test("titleCaseAllCapsWords leaves mixed-case words unchanged")
    func titleCaseMixedCase() {
        let result = PIIDetector.titleCaseAllCapsWords("Hello World test")
        #expect(result == "Hello World test")
    }

    // MARK: - Name Deduplication

    @Test("Name detection deduplicates overlapping matches from multiple passes")
    func nameDeduplication() async {
        let detector = PIIDetector()
        // "Mr. JOHN SMITH" triggers legal prefix (Pass 3) and title-cased NLTagger (Pass 2)
        let text = "Mr. JOHN SMITH filed the motion"
        let results = await detector.detect(in: text)
        let nameResults = results.filter { $0.kind == .name }
        // Verify no two name results overlap in range
        for i in 0..<nameResults.count {
            for j in (i+1)..<nameResults.count {
                let overlap = NSIntersectionRange(nameResults[i].range, nameResults[j].range)
                #expect(overlap.length == 0,
                        "Name results should not overlap: '\(nameResults[i].text)' and '\(nameResults[j].text)'")
            }
        }
    }

    // MARK: - Face Detection Padding

    @Test("Face detection bounding box has 20% padding and is clamped to [0,1]")
    func facePaddingAndClamping() {
        // Simulate a face at center: 0.3-0.7 on both axes (0.4 × 0.4)
        let original = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let padded = original.insetBy(dx: -original.width * 0.2, dy: -original.height * 0.2)
        let clamped = padded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

        // 20% padding: 0.4 * 0.2 = 0.08 on each side
        #expect(abs(clamped.minX - 0.22) < 0.01)
        #expect(abs(clamped.minY - 0.22) < 0.01)
        #expect(abs(clamped.width - 0.56) < 0.01)
        #expect(abs(clamped.height - 0.56) < 0.01)
    }

    @Test("Face detection padding clamps at page edge")
    func facePaddingAtEdge() {
        // Face near top-right corner
        let original = CGRect(x: 0.85, y: 0.85, width: 0.15, height: 0.15)
        let padded = original.insetBy(dx: -original.width * 0.2, dy: -original.height * 0.2)
        let clamped = padded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

        #expect(clamped.maxX <= 1.0)
        #expect(clamped.maxY <= 1.0)
        #expect(clamped.minX >= 0.0)
        #expect(clamped.minY >= 0.0)
    }

    // MARK: - Card Prefix Validation

    @Test("Card prefix validation accepts major card types")
    func cardPrefixes() {
        #expect(PIIDetector.hasValidCardPrefix("4111111111111111"))  // Visa
        #expect(PIIDetector.hasValidCardPrefix("5500000000000004"))  // MC
        #expect(PIIDetector.hasValidCardPrefix("340000000000009"))   // Amex
        #expect(PIIDetector.hasValidCardPrefix("6011000000000004"))  // Discover
    }

    @Test("Card prefix validation rejects unknown prefixes")
    func cardPrefixReject() {
        #expect(!PIIDetector.hasValidCardPrefix("9999999999999999")) // Unknown
        #expect(!PIIDetector.hasValidCardPrefix("123"))             // Too short
    }

    @Test("Card prefix validation accepts JCB and UnionPay")
    func cardPrefixJCBUnionPay() {
        #expect(PIIDetector.hasValidCardPrefix("3528000000000000"))  // JCB low
        #expect(PIIDetector.hasValidCardPrefix("3589000000000000"))  // JCB high
        #expect(PIIDetector.hasValidCardPrefix("6200000000000000"))  // UnionPay
        #expect(!PIIDetector.hasValidCardPrefix("3527000000000000")) // Below JCB
        #expect(!PIIDetector.hasValidCardPrefix("3590000000000000")) // Above JCB
    }

    // MARK: - Address Detection

    @Test("Address detector finds US street address with ZIP")
    func addressDetection() async {
        let detector = PIIDetector()
        let text = "Plaintiff resides at 123 Main Street, Springfield, IL 62701"
        let results = await detector.detect(in: text)
        let addressResults = results.filter { $0.kind == .address }
        #expect(!addressResults.isEmpty, "Should detect US street address")
    }

    @Test("Address detector finds additional street suffixes", arguments: [
        "456 Mountain Highway, Denver, CO 80203",
        "789 Oak Terrace, Portland, OR 97201",
        "321 Town Square, Austin, TX 78701",
        "100 Forest Loop, Bend, OR 97701",
        "555 Scenic Trail, Boise, ID 83701",
    ])
    func addressAdditionalSuffixes(_ input: String) async {
        let detector = PIIDetector()
        let results = await detector.detect(in: input)
        let addressResults = results.filter { $0.kind == .address }
        #expect(!addressResults.isEmpty, "Should detect address in '\(input)'")
    }

    @Test("Address detector finds address with ZIP+4")
    func addressZipPlus4() async {
        let detector = PIIDetector()
        let text = "Ship to 456 Elm Ave, Suite 7, New York, NY 10001-2345"
        let results = await detector.detect(in: text)
        let addressResults = results.filter { $0.kind == .address }
        #expect(!addressResults.isEmpty, "Should detect address with ZIP+4")
    }

    // MARK: - Date of Birth Detection

    @Test("DOB detector finds date of birth with label")
    func dobDetection() async {
        let detector = PIIDetector()
        let text = "Patient DOB: 03/15/1985 was admitted"
        let results = await detector.detect(in: text)
        let dobResults = results.filter { $0.kind == .dateOfBirth }
        #expect(!dobResults.isEmpty, "Should detect DOB pattern")
    }

    @Test("DOB detector finds 'Date of Birth' label")
    func dobFullLabel() async {
        let detector = PIIDetector()
        let text = "Date of Birth: January 15, 1990"
        let results = await detector.detect(in: text)
        let dobResults = results.filter { $0.kind == .dateOfBirth }
        #expect(!dobResults.isEmpty, "Should detect 'Date of Birth' pattern")
    }

    // MARK: - ITIN Detection

    @Test("ITIN regex matches valid formats", arguments: [
        "912-34-5678",        // Standard dashed
        "900 12 3456",        // Space-separated
        "900123456",          // No separator (9 digits)
        "912\u{2013}34\u{2013}5678",  // En-dash
    ])
    func validITIN(_ input: String) {
        let nsInput = input as NSString
        let range = NSRange(location: 0, length: nsInput.length)
        let matches = PIIDetector.itinPattern.matches(in: input, range: range)
        #expect(!matches.isEmpty, "Expected ITIN match for '\(input)'")
    }

    @Test("ITIN regex rejects non-9xx prefixes", arguments: [
        "812-34-5678",        // Not a 9xx prefix
        "123-45-6789",        // Standard SSN range
        "012-34-5678",        // 0xx prefix
    ])
    func invalidITIN(_ input: String) {
        let nsInput = input as NSString
        let range = NSRange(location: 0, length: nsInput.length)
        let matches = PIIDetector.itinPattern.matches(in: input, range: range)
        #expect(matches.isEmpty, "Expected no ITIN match for '\(input)'")
    }

    @Test("ITIN with context boosts confidence")
    func itinContextBoost() async {
        let detector = PIIDetector()
        // YY=80 is in the IRS range [70-88]; the M6 YY-bucket gate accepts it.
        let text = "ITIN: 912-80-5678 individual taxpayer identification"
        let results = await detector.detect(in: text)
        let itinResults = results.filter { $0.kind == .itin }
        #expect(!itinResults.isEmpty, "Should detect ITIN")
        #expect(itinResults.first!.confidence >= 0.80, "Context should boost confidence")
    }

    // MARK: - Driver's License Detection
    // Dedicated coverage lives in DetectionTests/DriversLicenseDetectorTests.swift
    // (L-15): labeled-format recall, L-02 numeric-floor regression, doctype
    // agnostic behavior, confidence calibration, synthetic recall/precision.

    // MARK: - Address Regex Improvements

    @Test("Address regex rejects digit-only street names")
    func addressRejectsDigitStreet() async {
        let detector = PIIDetector()
        let text = "The codes are 123 456 789 012 345, CA 90210"
        let results = await detector.detect(in: text)
        let addressResults = results.filter { $0.kind == .address }
        #expect(addressResults.isEmpty, "Digit-only street names should not match as addresses")
    }

    @Test("Address regex still matches real addresses after fix")
    func addressStillMatchesReal() async {
        let detector = PIIDetector()
        let text = "Located at 123 North Main Street, Springfield, IL 62701"
        let results = await detector.detect(in: text)
        let addressResults = results.filter { $0.kind == .address }
        #expect(!addressResults.isEmpty, "Real address should still match")
    }

    @Test("Address regex handles long input without excessive backtracking",
          .timeLimit(.minutes(1)))
    func addressRegexNoBacktracking() async {
        let detector = PIIDetector()
        // 10,000-char string with no addresses — should complete fast
        let longText = String(repeating: "Lorem ipsum dolor sit amet. ", count: 400)
        let results = await detector.detect(in: longText)
        let addressResults = results.filter { $0.kind == .address }
        #expect(addressResults.isEmpty, "No addresses in lorem ipsum")
    }

    // MARK: - Email Length Cap

    @Test("Email detector rejects overlength emails")
    func emailRejectsOverlength() async {
        let detector = PIIDetector()
        let longLocal = String(repeating: "a", count: 300)
        let text = "\(longLocal)@example.com is not valid"
        let results = await detector.detect(in: text)
        let emailResults = results.filter { $0.kind == .email }
        #expect(emailResults.isEmpty, "Emails over 254 chars should be rejected")
    }

    // MARK: - Context Window Expansion

    @Test("SSN context boost with distant label")
    func ssnDistantContextBoost() async {
        let detector = PIIDetector()
        // Label 80 chars before the SSN
        let padding = String(repeating: " ", count: 70)
        let text = "Social Security\(padding)123-45-6789"
        let results = await detector.detect(in: text)
        let ssnResults = results.filter { $0.kind == .ssn }
        #expect(!ssnResults.isEmpty)
        #expect(ssnResults.first!.confidence >= 0.90,
                "Distant context label should still boost confidence")
    }

    @Test("EIN context boost with distant label")
    func einDistantContextBoost() async {
        let detector = PIIDetector()
        // "Employer" (8 chars) + 50 chars padding = 58 chars before EIN.
        // ContextWindowScorer windows are ±windowRadius TOKENS (einProfile: 6)
        // within a 200-char cap — whitespace collapses, so "employer" is the
        // nearest token and lands in the window despite the padding.
        let padding = String(repeating: " ", count: 50)
        let text = "Employer\(padding)12-3456789"
        let results = await detector.detect(in: text)
        let einResults = results.filter { $0.kind == .ein }
        #expect(!einResults.isEmpty)
        #expect(einResults.first!.confidence >= 0.80,
                "Distant EIN context label should still boost confidence")
    }

    // MARK: - Regex Pattern Compilation Safety

    // MARK: - Passport Detection
    // Dedicated coverage lives in DetectionTests/PassportDetectorTests.swift
    // (L-15): labeled-format recall, doctype-agnostic behavior, confidence
    // calibration, synthetic recall/precision.

    // MARK: - Medical Record Number Detection

    @Test("MRN detector finds labeled medical record numbers (W10)", arguments: [
        ("MRN: 12345678", PIIDetector.mrnPatternLabeled),
        ("Patient ID: AB12345", PIIDetector.mrnPatternPatientID),
        ("Community Hospital ABC-1234567 discharge",
         PIIDetector.mrnPatternInstitution),
    ])
    func validMRN(_ input: String, _ pattern: NSRegularExpression) {
        let nsInput = input as NSString
        let range = NSRange(location: 0, length: nsInput.length)
        let matches = pattern.matches(in: input, range: range)
        #expect(!matches.isEmpty, "Expected MRN match for '\(input)'")
    }

    @Test("MRN detector rejects unlabeled digits")
    func mrnRejectsUnlabeled() {
        let input = "The value 12345678 is a count"
        let nsInput = input as NSString
        let range = NSRange(location: 0, length: nsInput.length)
        let matches = PIIDetector.mrnPatternLabeled.matches(in: input, range: range)
        #expect(matches.isEmpty, "Should not match bare digits without MRN label")
    }

    @Test("MRN detector via full pipeline")
    func mrnFullPipeline() async {
        let detector = PIIDetector()
        let text = "Patient MRN: 87654321 scheduled for follow-up"
        let results = await detector.detect(in: text, doctype: .medical)
        let mrnResults = results.filter { $0.kind == .medicalRecord }
        #expect(!mrnResults.isEmpty, "Should detect medical record number")
        // W10: context-scored confidence; the `patient` keyword pushes it
        // into the boosted band (no more flat 0.75).
        let conf = try! #require(mrnResults.first?.confidence)
        #expect(conf >= 0.85)
    }

    // MARK: - Email Edge Cases

    @Test("Email detector finds complex email formats", arguments: [
        "user@example.com",
        "first.last+tag@sub.domain.org",
        "test_user@company.co",
    ])
    func emailFormats(_ input: String) async {
        let detector = PIIDetector()
        let text = "Contact \(input) for info"
        let results = await detector.detect(in: text)
        let emailResults = results.filter { $0.kind == .email }
        #expect(!emailResults.isEmpty, "Expected email match for '\(input)'")
        #expect(emailResults.first?.text == input)
    }

    // MARK: - DOB Invalid Date Rejection

    @Test("DOB detector rejects invalid month")
    func dobRejectsInvalidMonth() async {
        let detector = PIIDetector()
        let text = "DOB: 13/15/1990"
        let results = await detector.detect(in: text)
        let dobResults = results.filter { $0.kind == .dateOfBirth }
        #expect(dobResults.isEmpty, "Month 13 should be rejected")
    }

    @Test("DOB detector rejects invalid day")
    func dobRejectsInvalidDay() async {
        let detector = PIIDetector()
        let text = "DOB: 01/45/1990"
        let results = await detector.detect(in: text)
        let dobResults = results.filter { $0.kind == .dateOfBirth }
        #expect(dobResults.isEmpty, "Day 45 should be rejected")
    }

    @Test("DOB detector rejects zero month and day")
    func dobRejectsZero() async {
        let detector = PIIDetector()
        let text = "DOB: 00/00/0000"
        let results = await detector.detect(in: text)
        let dobResults = results.filter { $0.kind == .dateOfBirth }
        #expect(dobResults.isEmpty, "Month/day 0 should be rejected")
    }

    @Test("DOB detector still accepts valid dates")
    func dobAcceptsValid() async {
        let detector = PIIDetector()
        let text = "DOB: 12/31/1999"
        let results = await detector.detect(in: text)
        let dobResults = results.filter { $0.kind == .dateOfBirth }
        #expect(!dobResults.isEmpty, "Valid date should still be accepted")
    }

    // MARK: - Regex Pattern Compilation Safety

    @Test("All regex patterns compile successfully")
    func regexPatternsCompile() {
        // Validates the try! safety documented in PIIDetector.swift.
        // These are hardcoded constant patterns that cannot fail at runtime,
        // but this test makes that guarantee explicit and CI-enforced.
        _ = PIIDetector.ssnPattern
        _ = PIIDetector.ccPattern
        _ = PIIDetector.emailPattern
        _ = PIIDetector.phonePattern
        _ = PIIDetector.einPattern
        _ = PIIDetector.addressPattern
        _ = PIIDetector.dobPattern
        _ = PIIDetector.itinPattern
        _ = PIIDetector.driversLicensePattern
        _ = PIIDetector.passportPattern
        _ = PIIDetector.mrnPatternLabeled
        _ = PIIDetector.mrnPatternPatientID
        _ = PIIDetector.mrnPatternInstitution
        _ = PIIDetector.licensePlateLabeled
    }
}
