import Foundation
import Testing
@testable import RedactionEngine

@Suite("PDFByteScanner")
struct PDFByteScannerTests {
    let scanner = PDFByteScanner()

    @Test("countEOFMarkers returns 1 for normal PDF")
    func singleEOF() async {
        let data = TestFixtures.blankPage()
        let count = await scanner.countEOFMarkers(in: data)
        #expect(count == 1)
    }

    @Test("countEOFMarkers returns >1 for incremental update")
    func multipleEOF() async {
        let data = TestFixtures.incrementalUpdate()
        let count = await scanner.countEOFMarkers(in: data)
        #expect(count > 1)
    }

    @Test("detectXMP returns false for clean PDF")
    func noXMP() async {
        let data = TestFixtures.blankPage()
        let hasXMP = await scanner.detectXMP(in: data)
        #expect(!hasXMP)
    }

    @Test("detectXMP returns true for data containing xpacket")
    func hasXMP() async {
        var data = TestFixtures.blankPage()
        // Inject <?xpacket marker into the data
        data.append(Data("<?xpacket begin>test</xpacket>".utf8))
        let hasXMP = await scanner.detectXMP(in: data)
        #expect(hasXMP)
    }

    @Test("countEOFMarkers returns 0 for empty data")
    func emptyData() async {
        let count = await scanner.countEOFMarkers(in: Data())
        #expect(count == 0)
    }

    @Test("searchKnownTerms filters short terms")
    func filtersShortTerms() async {
        let data = TestFixtures.textLayerPDF(text: "ABC DEF GHI")
        let result = await scanner.searchKnownTerms(in: data, terms: ["AB", "DE"])
        #expect(result.termsSearched == 0)
        #expect(result.termsFound == 0)
    }

    @Test("searchKnownTerms finds planted term")
    func findsPlantedTerm() async {
        let secretTerm = "SensitiveTermHere"
        var data = TestFixtures.blankPage()
        data.append(Data(secretTerm.utf8))

        let result = await scanner.searchKnownTerms(in: data, terms: [secretTerm])
        #expect(result.termsSearched == 1)
        #expect(result.termsFound == 1)
    }

    @Test("searchKnownTerms returns zero for absent term")
    func absentTerm() async {
        let data = TestFixtures.blankPage()
        let result = await scanner.searchKnownTerms(in: data, terms: ["XYZNONEXISTENT"])
        #expect(result.termsSearched == 1)
        #expect(result.termsFound == 0)
    }

    // MARK: - Supplementary-plane (emoji / CJK) pattern emission tests
    //
    // 🔴 = U+1F534; surrogate pair: high 0xD83D, low 0xDD34.
    // These tests confirm the utf16-based encoding path emits correct
    // surrogate-pair bytes instead of the old unicodeScalars-based path that
    // would trap in debug (UInt16(0x1F534) precondition) or silently truncate
    // to 0xF534 in release.

    /// UTF-16BE pattern for a term containing 🔴 must open with the four-byte
    /// surrogate-pair sequence [0xD8, 0x3D, 0xDD, 0x34].
    @Test("UTF-16BE pattern for emoji term starts with correct surrogate-pair bytes")
    func emojiTermUTF16BEPatternCorrect() async {
        // Build a minimal synthetic PDF carrying the UTF-16BE encoding of
        // "🔴 Confidential". searchKnownTerms is the public entry point;
        // a match confirms the emitted BE pattern is correct.
        let term = "🔴 Confidential"
        // Encode term as UTF-16BE into a raw byte buffer.
        var beBytes: [UInt8] = []
        for cu in term.utf16 {
            beBytes.append(UInt8(cu >> 8))
            beBytes.append(UInt8(cu & 0xFF))
        }
        // The first four bytes must be the surrogate-pair sequence for 🔴.
        #expect(beBytes.prefix(4).elementsEqual([0xD8, 0x3D, 0xDD, 0x34]))

        // Also verify via a live scan: plant the BE bytes in a buffer and
        // confirm the scanner reports the term as present.
        var data = TestFixtures.blankPage()
        data.append(Data(beBytes))
        let result = await scanner.searchKnownTerms(in: data, terms: [term])
        #expect(result.termsFound == 1)
    }

    /// UTF-16LE pattern for a term containing 🔴 must open with the four-byte
    /// surrogate-pair sequence [0x3D, 0xD8, 0x34, 0xDD].
    @Test("UTF-16LE pattern for emoji term starts with correct surrogate-pair bytes")
    func emojiTermUTF16LEPatternCorrect() async {
        let term = "🔴 Confidential"
        var leBytes: [UInt8] = []
        for cu in term.utf16 {
            leBytes.append(UInt8(cu & 0xFF))
            leBytes.append(UInt8(cu >> 8))
        }
        // The first four bytes must be the LE surrogate-pair sequence for 🔴.
        #expect(leBytes.prefix(4).elementsEqual([0x3D, 0xD8, 0x34, 0xDD]))

        // Verify via live scan.
        var data = TestFixtures.blankPage()
        data.append(Data(leBytes))
        let result = await scanner.searchKnownTerms(in: data, terms: [term])
        #expect(result.termsFound == 1)
    }

    /// searchKnownTerms must not crash when a term contains emoji.
    /// "🔴 Confidential" has grapheme-cluster count 14, above the 4-char minimum.
    @Test("searchKnownTerms with emoji term does not crash")
    func emojiTermDoesNotCrash() async {
        let data = TestFixtures.blankPage()
        let result = await scanner.searchKnownTerms(in: data, terms: ["🔴 Confidential"])
        // The term passes the ≥4-character filter; zero matches in a blank PDF is expected.
        #expect(result.termsSearched == 1)
        #expect(result.termsFound == 0)
    }

    /// A BMP-only term produces UTF-16BE bytes identical to the pre-fix encoding
    /// (for BMP scalars, utf16 and unicodeScalars produce the same code unit).
    /// Hand-computed for "Conf": C=0x43, o=0x6F, n=0x6E, f=0x66.
    @Test("BMP-only term emits unchanged UTF-16 pattern")
    func bmpCharacterUnchanged() async {
        let term = "Conf"   // 4 chars, all BMP; passes the ≥4 filter
        // Expected UTF-16BE bytes: [0x00,0x43, 0x00,0x6F, 0x00,0x6E, 0x00,0x66]
        let expectedBE: [UInt8] = [0x00, 0x43, 0x00, 0x6F, 0x00, 0x6E, 0x00, 0x66]
        // Expected UTF-16LE bytes: [0x43,0x00, 0x6F,0x00, 0x6E,0x00, 0x66,0x00]
        let expectedLE: [UInt8] = [0x43, 0x00, 0x6F, 0x00, 0x6E, 0x00, 0x66, 0x00]

        // Plant each encoding in a buffer and assert the scanner locates it.
        var dataWithBE = TestFixtures.blankPage()
        dataWithBE.append(Data(expectedBE))
        let beResult = await scanner.searchKnownTerms(in: dataWithBE, terms: [term])
        #expect(beResult.termsFound == 1)

        var dataWithLE = TestFixtures.blankPage()
        dataWithLE.append(Data(expectedLE))
        let leResult = await scanner.searchKnownTerms(in: dataWithLE, terms: [term])
        #expect(leResult.termsFound == 1)
    }

    /// Scanner locates "🔴 Confidential" when the raw byte buffer contains its
    /// UTF-16BE encoding (as a PDF viewer would write it for a text string).
    @Test("Scanner locates emoji term in UTF-16BE-encoded PDF byte buffer")
    func emojiTermLocatedInPDFBytesEncodedUTF16() async {
        let term = "🔴 Confidential"
        // Construct UTF-16BE encoding of the term.
        var beBytes: [UInt8] = []
        for cu in term.utf16 {
            beBytes.append(UInt8(cu >> 8))
            beBytes.append(UInt8(cu & 0xFF))
        }
        // Embed the encoded bytes in a PDF-ish wrapper to simulate a real
        // text-stream payload: blank PDF header + raw UTF-16BE term bytes.
        var data = TestFixtures.blankPage()
        data.append(Data(beBytes))
        let result = await scanner.searchKnownTerms(in: data, terms: [term])
        #expect(result.termsSearched == 1)
        #expect(result.termsFound == 1)
    }

    /// The truncated two-byte form [0xF5, 0x34] — what UInt16(0x1F534) would
    /// produce under the old scalar-cast code path — must NOT appear as a
    /// standalone pattern that causes a false positive in an unrelated buffer.
    @Test("Truncated scalar form 0xF534 does not produce spurious match")
    func scalarValueAbove0xFFFFNoLongerTruncates() async {
        // Plant only the two-byte truncated sequence [0xF5, 0x34] (the old
        // broken emission). The corrected path never emits this as a standalone
        // 🔴 surrogate pattern, so a scan for "🔴 Confidential" must NOT match.
        var data = TestFixtures.blankPage()
        data.append(Data([0xF5, 0x34]))   // truncated artifact from old code
        let result = await scanner.searchKnownTerms(in: data, terms: ["🔴 Confidential"])
        // The term is not present — only the truncated artifact is, which is
        // no longer emitted as a pattern by the corrected implementation.
        #expect(result.termsFound == 0)
    }

    /// Supplementary-plane CJK term "𠀀𠀁𠀂𠀃文档" produces correct UTF-16
    /// surrogate-pair bytes for each ext-B character (e.g. 𠀀 = U+20000:
    /// high surrogate 0xD840, low surrogate 0xDC00 → BE [0xD8,0x40,0xDC,0x00]).
    @Test("Supplementary-plane CJK term emits correct surrogate-pair bytes in BE and LE")
    func supplementaryPlaneCJKTermSurrogatePairBytes() async {
        let term = "𠀀𠀁𠀂𠀃文档"   // 6 grapheme clusters; all above the 4-char minimum

        // Build expected BE and LE from the same String.utf16 view used by
        // the scanner, then plant each in a buffer and confirm a match.
        var expectedBE: [UInt8] = []
        var expectedLE: [UInt8] = []
        for cu in term.utf16 {
            expectedBE.append(UInt8(cu >> 8))
            expectedBE.append(UInt8(cu & 0xFF))
            expectedLE.append(UInt8(cu & 0xFF))
            expectedLE.append(UInt8(cu >> 8))
        }

        // First surrogate pair of 𠀀 (U+20000): high=0xD840, low=0xDC00.
        // BE opens with [0xD8, 0x40, 0xDC, 0x00].
        #expect(expectedBE.prefix(4).elementsEqual([0xD8, 0x40, 0xDC, 0x00]))
        // LE opens with [0x40, 0xD8, 0x00, 0xDC].
        #expect(expectedLE.prefix(4).elementsEqual([0x40, 0xD8, 0x00, 0xDC]))

        var dataWithBE = TestFixtures.blankPage()
        dataWithBE.append(Data(expectedBE))
        let beResult = await scanner.searchKnownTerms(in: dataWithBE, terms: [term])
        #expect(beResult.termsFound == 1)

        var dataWithLE = TestFixtures.blankPage()
        dataWithLE.append(Data(expectedLE))
        let leResult = await scanner.searchKnownTerms(in: dataWithLE, terms: [term])
        #expect(leResult.termsFound == 1)
    }
}
