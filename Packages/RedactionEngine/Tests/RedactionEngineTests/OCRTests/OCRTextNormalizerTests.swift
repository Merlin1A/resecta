import Testing
@testable import RedactionEngine

// Plan Phase 2 / §G6 — unit tests for context-sensitive OCR normalization.

@Suite("OCRTextNormalizer (G6)")
struct OCRTextNormalizerTests {

    private let normalizer = OCRTextNormalizer()

    @Test("Empty input passes through")
    func empty() {
        #expect(normalizer.normalize("") == "")
    }

    @Test("Pure-letter token is untouched (letter context, no digits present)")
    func pureLetterToken() {
        #expect(normalizer.normalize("Street") == "Street")
        #expect(normalizer.normalize("Plaintiff") == "Plaintiff")
    }

    @Test("Pure-digit token is untouched (digit context, no letters present)")
    func pureDigitToken() {
        #expect(normalizer.normalize("90210") == "90210")
        #expect(normalizer.normalize("2026") == "2026")
    }

    @Test("Ambig-only token inherits digit context from digit-majority line")
    func digitContextFromLine() {
        // "1OO-23-4567": line has clear digits 2,3,4,6,7 (5) and 0 clear
        // letters → line tendency = digit. Token "1OO" is all-ambiguous →
        // inherits digit context → 'O'→'0' → "100".
        #expect(normalizer.normalize("1OO-23-4567") == "100-23-4567")
    }

    @Test("Token with clear-digit signal applies digit context directly")
    func digitContextAtTokenLevel() {
        // "S23": '2' and '3' are clear digits; 'S' is ambig → digit context
        // at the token level → 'S'→'5' → "523".
        #expect(normalizer.normalize("S23") == "523")
    }

    @Test("Token with clear-letter signal applies letter context directly")
    func letterContextAtTokenLevel() {
        // "0Street": 't','r','e','e','t' are clear letters; '0' ambig, 'S' ambig
        // → clear-letter count 5, clear-digit count 0 → letter context →
        // '0'→'O' → "OStreet".
        #expect(normalizer.normalize("0Street") == "OStreet")

        // "1nvoice": 'n','v','i','c','e' clear letters → letter context →
        // '1'→'I' → "Invoice".
        #expect(normalizer.normalize("1nvoice") == "Invoice")
    }

    @Test("Alphanumeric identifier tokenizes on non-alphanumeric boundary")
    func alphanumericIdentifier() {
        // "SW-2026": token "SW" has clear letter 'W' → letter context, 'S'
        // not in letter map → unchanged. Token "2026" has clear digits
        // '2','2','6' → digit context, no letters to sub → unchanged.
        #expect(normalizer.normalize("SW-2026") == "SW-2026")

        // "MRN-001O23": "MRN" = 3 clear letters → letter context → unchanged.
        // "001O23" = 2 clear digits ('2','3') → digit context → 'O'→'0' →
        // "001023".
        #expect(normalizer.normalize("MRN-001O23") == "MRN-001023")
    }

    @Test("Ambig-only token with no line signal passes through unchanged")
    func ambiguousTokenNoSignalPassthrough() {
        // "1OO0S": '1','O','O','0','S' all ambiguous. Line has 0 clear
        // digits and 0 clear letters → line tendency = passthrough → token
        // passes through unchanged.
        #expect(normalizer.normalize("1OO0S") == "1OO0S")

        // "1O" alone: pure ambig, no line signal → passthrough → "1O".
        #expect(normalizer.normalize("1O") == "1O")
    }

    @Test("Whitespace and punctuation pass through unchanged")
    func punctuationPassthrough() {
        #expect(normalizer.normalize("Hello, World!") == "Hello, World!")
        #expect(normalizer.normalize("   leading and trailing   ") == "   leading and trailing   ")
        #expect(normalizer.normalize("a\tb\nc") == "a\tb\nc")
    }

    @Test("Normalization is idempotent on clean input")
    func idempotent() {
        let clean = "John Smith lives at 123 Main Street, Apt 4B."
        let once = normalizer.normalize(clean)
        let twice = normalizer.normalize(once)
        #expect(once == twice)
    }

    @Test("Multiple confusables in a token apply context uniformly")
    func multipleConfusablesSameContext() {
        // "John OStreet 12345" — line has clear letters dominating → letter
        // context line-wide; "OStreet" has clear letters at token level
        // → letter context → '0' NOT present, so no change. "12345" has
        // clear digits '2','3','4' → digit context → no letters to sub.
        #expect(normalizer.normalize("John OStreet 12345") == "John OStreet 12345")

        // "123 O0I1S5 7": line has clear digits '2','3','7' (3) and 0 clear
        // letters → line digit. Token "O0I1S5" all ambig → inherit digit →
        // O→0, I→1, S→5 → "001155".
        #expect(normalizer.normalize("123 O0I1S5 7") == "123 001155 7")
    }

    // MARK: - design 04 §1.3/§1.4 additions

    @Test("Confusable OCR SSN pattern normalizes to clean digits")
    func confusableSSNNormalizesToCleanDigits() {
        // "l23-4S-678O": vision OCR might produce 'l' for '1', 'S' for '5',
        // 'O' for '0'. The line has clear digits '2','3','4','6','7','8' →
        // digit context. Expected output: "123-45-6789" → wait: the last
        // character is 'O', not '9'. The raw input is "l23-4S-678O":
        //   token "l23": clear digits '2','3' → digit → l→1 → "123"
        //   token "4S": clear digit '4' → digit → S→5 → "45"
        //   token "678O": clear digits '6','7','8' → digit → O→0 → "6780"
        // Result: "123-45-6780".
        #expect(normalizer.normalize("l23-4S-678O") == "123-45-6780")
    }

    @Test("Normalizer does not corrupt a clear-letter name token")
    func normalizerDoesNotCorruptName() {
        // "JOHNSON" — all clear letters (J,H,N are unambiguous; O and S are
        // ambiguous but the token has 5 clear letters and 0 clear digits
        // → letter context → O→O (no sub in letterContextMap for O),
        // S→S (no sub). Result: "JOHNSON" unchanged.
        #expect(normalizer.normalize("JOHNSON") == "JOHNSON")
    }

    @Test("Ambiguous token in digit-majority line resolves correctly")
    func ambiguousTokenInDigitLineResolvedCorrectly() {
        // "1OO-23-4567": ambiguous token "1OO" inherits digit context from
        // clear digits '2','3','4','5','6','7' on the line → O→0 → "100".
        // (Mirrors the existing digitContextFromLine test to pin the contract
        // in this suite for design 04.)
        #expect(normalizer.normalize("1OO-23-4567") == "100-23-4567")
    }

    // MARK: - Same-length invariant (leak-class guard, design 04 §1.3/§1.4)
    //
    // OCRTextNormalizer must be same-length by construction — 1:1 character
    // substitution, no deletions or insertions — because the search/detection
    // paths rely on character offsets from normalized text mapping back to
    // OCR line bounding rects. A normalization that changes String.count
    // would break offset→rect mapping (leak-class risk).

    @Test("Same-length invariant holds for ASCII confusables")
    func sameLengthASCIIConfusables() {
        let inputs = [
            "l23-4S-6789",
            "1OO-23-4567",
            "0Street",
            "SW-2026",
            "MRN-001O23",
            "JOHNSON",
            "123 O0I1S5 7",
            "",
        ]
        for s in inputs {
            let normalized = normalizer.normalize(s)
            #expect(
                normalized.count == s.count,
                "same-length violated for '\(s)': got \(normalized.count), expected \(s.count)"
            )
        }
    }

    @Test("Same-length invariant holds for emoji, CJK, combining marks, and confusables")
    func sameLengthInvariantBattery() {
        // Battery of inputs that stress test the Character-count invariant.
        // These must NOT be passed through any substitution — non-alphanumeric
        // characters are emitted byte-for-byte by the normalizer.
        let inputs: [String] = [
            // Emoji (each is a single Swift Character but >1 UTF-16 code unit)
            "👋",
            "Hello 👋 World",
            // CJK characters (single Characters, >1 byte in UTF-8)
            "中文",
            "日本語テスト",
            // Combining marks — precomposed vs decomposed
            "caf\u{E9}",          // é as single codepoint (U+00E9)
            "cafe\u{301}",        // é as base + combining acute (2 codepoints)
            // Mix of confusables with non-ASCII
            "l23中文S",
            "1OO\u{E9}AB",
            // Pure digits and letters (no substitution expected)
            "abcABC012",
        ]
        for s in inputs {
            let normalized = normalizer.normalize(s)
            #expect(
                normalized.count == s.count,
                "same-length violated for '\(s)' (count \(s.count)): normalized '\(normalized)' has count \(normalized.count)"
            )
        }
    }
}
