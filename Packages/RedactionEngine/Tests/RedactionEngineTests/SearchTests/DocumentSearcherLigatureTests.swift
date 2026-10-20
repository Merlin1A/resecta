import Testing
import PDFKit
@testable import RedactionEngine

// Pre-fix, `matchedText` was sourced from the original page text using
// normalized-space Character offsets. TextNormalizer expands Latin ligatures
// (e.g. U+FB01 ﬁ → "fi"), so the offsets drifted on ligature pages,
// producing corrupted substrings or an out-of-bounds trap on heavy-ligature
// pages. Post-fix, `matchedText` is sourced from the normalized form.
//
// Whether the underlying PDF text layer round-trips the ligature codepoint
// is font/PDFKit dependent. When it does, the search path exercises the
// crash class pre-fix. When PDFKit pre-decomposes to "fi", the test still
// pins the new normalized-form contract.

@Suite("DocumentSearcher Ligature", .tags(.search))
struct DocumentSearcherLigatureTests {

    @Test("Ligature page SSN search returns matchedText and non-empty rect")
    func ligaturePageSSNMatch() async {
        // Fixture: two ligatures precede an SSN.
        let data = TestFixtures.textLayerPDF(text: "ﬁle ﬁle 123-45-6789")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        let mode = SearchMode.text("123-45-6789", options: SearchOptions())
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        #expect(!results.isEmpty, "SSN should match on the ligature page")
        // matchedText is the searchable form; "123-45-6789" is invariant
        // under TextNormalizer (ASCII digits + hyphens).
        #expect(results.first?.matchedText == "123-45-6789")
        let rect = results.first?.normalizedRect ?? .zero
        #expect(rect.width > 0 && rect.height > 0,
                "normalizedRect from PDFKit selection must be non-empty")
    }

    /// Pages whose text layer may keep a code point that normalization
    /// expands: the ffi and fl ligatures and a compatibility character
    /// (ROMAN NUMERAL TWELVE → "XII"). Whether PDFKit keeps the code point
    /// in `page.string` is font-dependent; the rect contract holds either
    /// way, and the probe prints which it was.
    static let expandingPages: [(String, String, Unicode.Scalar)] = [
        ("ffi ligature", "\u{FB03}le \u{FB03}le 123-45-6789", "\u{FB03}"),
        ("fl ligature", "\u{FB02}y \u{FB02}y 123-45-6789", "\u{FB02}"),
        ("roman numeral twelve", "\u{216B} \u{216B} 123-45-6789", "\u{216B}"),
    ]

    @Test("The match rect on a page with expanding code points is the raw range's rect",
          arguments: expandingPages)
    func rectFollowsRawOffsets(name: String, text: String, scalar: Unicode.Scalar) async throws {
        let data = TestFixtures.textLayerPDF(text: text)
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let raw = try #require(page.string)
        let kept = raw.unicodeScalars.contains(scalar)
        let rawRange = (raw as NSString).range(of: "123-45-6789")
        #expect(rawRange.location != NSNotFound, "\(name): the SSN is on the page")

        let searcher = DocumentSearcher()
        let expected = try #require(searcher.boundingRect(for: rawRange, page: page))
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: .text("123-45-6789", options: SearchOptions()),
            progress: { _, _ in }
        )
        var results: [SearchResult] = []
        for await result in stream { results.append(result) }
        let rect = try #require(results.first?.normalizedRect)
        print("expanding-page probe \(name): code point kept in page.string=\(kept) · drift x=\(rect.minX - expected.minX)")
        #expect(results.count == 1, "\(name)")
        #expect(abs(rect.minX - expected.minX) < 1e-6 && abs(rect.minY - expected.minY) < 1e-6
                && abs(rect.width - expected.width) < 1e-6 && abs(rect.height - expected.height) < 1e-6,
                "\(name): the search rect must equal the raw range's rect")
        #expect(results.first?.matchedText == "123-45-6789")
    }

    @Test("Ligature query returns normalized matchedText")
    func ligatureQueryReturnsNormalized() async {
        let data = TestFixtures.textLayerPDF(text: "ﬁle ﬁle 123-45-6789")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        let mode = SearchMode.text("file", options: SearchOptions())
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        #expect(!results.isEmpty, "'file' should match the ligature page")
        // Result rows display the normalized (ligature-decomposed, lowered)
        // form even when the source contains U+FB01 ﬁ.
        #expect(results.first?.matchedText == "file")
    }
}
