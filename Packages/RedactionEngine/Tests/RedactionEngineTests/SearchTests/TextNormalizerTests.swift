import Testing
@testable import RedactionEngine

@Suite("TextNormalizer", .tags(.search))
struct TextNormalizerTests {

    // MARK: - Ligature Decomposition

    @Test("fi ligature decomposes to 'fi'")
    func fiLigature() {
        #expect(TextNormalizer.normalize("\u{FB01}nd") == "find")
    }

    @Test("fl ligature decomposes to 'fl'")
    func flLigature() {
        #expect(TextNormalizer.normalize("\u{FB02}ower") == "flower")
    }

    @Test("ff ligature decomposes to 'ff'")
    func ffLigature() {
        #expect(TextNormalizer.normalize("o\u{FB00}ice") == "office")
    }

    @Test("ffi ligature decomposes to 'ffi'")
    func ffiLigature() {
        #expect(TextNormalizer.normalize("o\u{FB03}ce") == "office")
    }

    @Test("ffl ligature decomposes to 'ffl'")
    func fflLigature() {
        #expect(TextNormalizer.normalize("ra\u{FB04}e") == "raffle")
    }

    @Test("Multiple ligatures in one string")
    func multipleLigatures() {
        // "office" with ffi ligature + "find" with fi ligature
        let input = "o\u{FB03}ce \u{FB01}nd"
        #expect(TextNormalizer.normalize(input) == "office find")
    }

    // MARK: - NFKC Normalization

    @Test("NFKC normalizes compatibility characters")
    func nfkcNormalization() {
        // U+2126 OHM SIGN → U+03A9 GREEK CAPITAL LETTER OMEGA
        #expect(TextNormalizer.normalize("\u{2126}") == "\u{03A9}")
    }

    @Test("NFKC normalizes fullwidth digits")
    func fullwidthDigits() {
        // Fullwidth digit 1 (U+FF11) → "1"
        #expect(TextNormalizer.normalize("\u{FF11}\u{FF12}\u{FF13}") == "123")
    }

    // MARK: - Case Folding

    @Test("Case-insensitive normalizeForSearch lowercases")
    func caseInsensitive() {
        #expect(TextNormalizer.normalizeForSearch("HELLO World", caseSensitive: false) == "hello world")
    }

    @Test("Case-sensitive normalizeForSearch preserves case")
    func caseSensitive() {
        #expect(TextNormalizer.normalizeForSearch("HELLO World", caseSensitive: true) == "HELLO World")
    }

    @Test("Case-insensitive with ligature")
    func caseInsensitiveLigature() {
        #expect(TextNormalizer.normalizeForSearch("\u{FB01}ND", caseSensitive: false) == "find")
    }

    // MARK: - Edge Cases

    @Test("Empty string returns empty")
    func emptyString() {
        #expect(TextNormalizer.normalize("") == "")
    }

    @Test("Pure ASCII passes through unchanged")
    func pureASCII() {
        let input = "Hello, world! 123"
        #expect(TextNormalizer.normalize(input) == input)
    }

    @Test("Emoji preserved through normalization")
    func emojiPreservation() {
        let input = "Hello 🌍 World"
        #expect(TextNormalizer.normalize(input) == input)
    }

    @Test("Single character normalization")
    func singleCharacter() {
        #expect(TextNormalizer.normalize("a") == "a")
        #expect(TextNormalizer.normalize("\u{FB01}") == "fi")
    }

    // MARK: - S7 / design 04 §4.4 — Smart Punctuation

    @Test("Smart single quotes fold to apostrophes")
    func smartQuotesNormalized() {
        #expect(TextNormalizer.normalizeSmartPunctuation("Hello \u{2018}world\u{2019}") == "Hello 'world'")
    }

    @Test("Em dash folds to hyphen")
    func emDashNormalized() {
        #expect(TextNormalizer.normalizeSmartPunctuation("foo\u{2014}bar") == "foo-bar")
    }

    @Test("Every smart-punctuation map entry folds and preserves length")
    func smartPunctuationFullMap() {
        let input = "\u{201C}\u{201D}\u{2018}\u{2019}\u{2013}\u{2014}\u{2012}\u{2011}\u{00AD}"
        let folded = TextNormalizer.normalizeSmartPunctuation(input)
        #expect(folded == "\"\"''-----")
        #expect(folded.count == input.count, "1:1 map must preserve Character count")
        #expect(folded.utf16.count == input.utf16.count,
                "1:1 map must preserve UTF-16 length for NSRange validity")
    }

    // MARK: - S7 / design 04 §4.4 — Separator Strip + Offset Map

    @Test("Separator strip on hyphenated SSN with exact offset map")
    func separatorStrip() {
        let (normalized, map) = TextNormalizer.stripSeparators("123-45-6789")
        #expect(normalized == "123456789")
        #expect(map == [0, 1, 2, 4, 5, 7, 8, 9, 10])
    }

    @Test("Separator strip removes space, dot, and slash variants")
    func separatorStripVariants() {
        let (normalized, map) = TextNormalizer.stripSeparators("12 34.56/78")
        #expect(normalized == "12345678")
        #expect(map == [0, 1, 3, 4, 6, 7, 9, 10])
    }

    @Test("Separator-only input strips to empty")
    func separatorStripToEmpty() {
        let (normalized, map) = TextNormalizer.stripSeparators("- . /")
        #expect(normalized.isEmpty)
        #expect(map.isEmpty)
    }

    // MARK: - S7 / design 04 §4.4 — Diacritic Fold + Offset Map

    @Test("Diacritic folding maps Muñoz to Munoz")
    func diacriticFolding() {
        let (normalized, map) = TextNormalizer.foldDiacritics("Muñoz")
        #expect(normalized == "Munoz")
        #expect(map == [0, 1, 2, 3, 4])
    }

    @Test("Offset map is exact for multiple accents (José García)")
    func diacriticFoldOffsetMapCorrectForMultipleAccents() {
        let (normalized, map) = TextNormalizer.foldDiacritics("José García")
        #expect(normalized == "Jose Garcia")
        // 1:1 per-Character fold → identity map; every folded character
        // points at its accented original.
        #expect(map == Array(0..<11))
        #expect(normalized.count == map.count)
    }

    @Test("Decomposed input folds identically to precomposed")
    func diacriticFoldDecomposedInput() {
        // "é" as base + combining acute (two scalars, one Character).
        let (normalized, map) = TextNormalizer.foldDiacritics("Jose\u{0301}")
        #expect(normalized == "Jose")
        #expect(map == [0, 1, 2, 3])
    }

    @Test("Standalone combining mark is removed and skipped in the map")
    func diacriticFoldStandaloneMark() {
        let (normalized, map) = TextNormalizer.foldDiacritics("\u{0301}a")
        #expect(normalized == "a")
        #expect(map == [1])
    }

    @Test("Hangul survives fold via NFC recomposition with identity map")
    func diacriticFoldHangulStable() {
        let (normalized, map) = TextNormalizer.foldDiacritics("한국 123")
        #expect(normalized == "한국 123")
        #expect(map == Array(0..<6))
    }

    @Test("Arabic diacritization marks are removed only when fold is invoked")
    func arabicMarksRemovedOnlyByExplicitFold() {
        let marked = "مُحَمَّد"
        let (folded, _) = TextNormalizer.foldDiacritics(marked)
        #expect(folded == "محمد")
        // The default option set leaves the marks alone.
        let ext = TextNormalizer.applySearchExtensions(
            pageText: marked, query: "محمد", options: SearchOptions()
        )
        #expect(ext.pageText == marked)
        #expect(ext.offsetMap == nil)
    }

    @Test("Emoji survives fold with a stable map")
    func diacriticFoldEmojiStable() {
        let (normalized, map) = TextNormalizer.foldDiacritics("a🌍b")
        #expect(normalized == "a🌍b")
        #expect(map == [0, 1, 2])
    }

    // MARK: - S7 / design 04 §4.4 — Map Composition + Extension Pipeline

    @Test("Composed maps resolve through both length-changing steps")
    func composeOffsetMaps() {
        // "José 12-34" → fold → "Jose 12-34" (identity map) → strip →
        // "Jose1234" with strip map [0,1,2,3,5,6,8,9].
        let ext = TextNormalizer.applySearchExtensions(
            pageText: "José 12-34",
            query: "jose1234",
            options: SearchOptions(stripDigitSeparators: true, foldDiacritics: true)
        )
        #expect(ext.pageText == "Jose1234")
        #expect(ext.query == "jose1234")
        #expect(ext.offsetMap == [0, 1, 2, 3, 5, 6, 8, 9])
        #expect(ext.baseText == "José 12-34")
    }

    @Test("Identity option set reports no offset map")
    func extensionPipelineIdentity() {
        let ext = TextNormalizer.applySearchExtensions(
            pageText: "plain text", query: "plain", options: SearchOptions()
        )
        #expect(ext.pageText == "plain text")
        #expect(ext.offsetMap == nil)
    }

    @Test("Smart punctuation inside the pipeline feeds the separator set")
    func smartPunctuationFeedsSeparatorStrip() {
        // Em-dash folds to "-" first, so the strip step removes it.
        let ext = TextNormalizer.applySearchExtensions(
            pageText: "12\u{2014}34",
            query: "1234",
            options: SearchOptions(stripDigitSeparators: true)
        )
        #expect(ext.pageText == "1234")
        #expect(ext.offsetMap == [0, 1, 3, 4])
    }
}

extension Tag {
    @Tag static var search: Self
}
