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

    /// Pages whose Characters before (or inside) the match are wider than
    /// one UTF-16 unit while normalization keeps the Character count: an
    /// emoji, a decomposed accent, a non-BMP letter, a Devanagari consonant
    /// with its vowel sign. Before, the no-map arm took Character offsets as
    /// UTF-16 offsets, so the rect sat one unit to the left per extra unit
    /// before the match and one unit short per extra unit inside it. Whether
    /// `page.string` keeps each code point is font-dependent; the probe
    /// prints the raw-unit and Character offsets it found.
    static let multiUnitPages: [(String, String, String)] = [
        ("emoji before", "\u{1F464} SSN 123-45-6789", "123-45-6789"),
        ("decomposed accent before", "Jose\u{0301} 123-45-6789", "123-45-6789"),
        ("math bold letter before", "\u{1D400} 123-45-6789", "123-45-6789"),
        ("devanagari name", "\u{0930}\u{093E}\u{092E} 123", "\u{0930}\u{093E}\u{092E}"),
    ]

    /// Regex mode never went through the map: the expanding pages (the
    /// ligature drift) and the multi-unit pages, searched by a pattern.
    static let regexPages: [(String, String, String)] =
        expandingPages.map { ($0.0, $0.1, "123-45-6789") } + multiUnitPages

    @Test("Text mode: the match rect on a page with multi-unit Characters is the raw range's rect",
          arguments: multiUnitPages)
    func textRectFollowsRawUnits(name: String, text: String, term: String) async throws {
        try await Self.expectRectIsRawRange(
            name: name, text: text, term: term, mode: .text(term, options: SearchOptions()))
    }

    @Test("Regex mode: the match rect on expanding and multi-unit pages is the raw range's rect",
          arguments: regexPages)
    func regexRectFollowsRawRange(name: String, text: String, term: String) async throws {
        try await Self.expectRectIsRawRange(
            name: name, text: text, term: term,
            mode: .regex(NSRegularExpression.escapedPattern(for: term), options: SearchOptions()))
    }

    /// The oracle is independent of the engine's offsets: the rect of the
    /// term's raw UTF-16 range in `page.string`, through the shared geometry.
    private static func expectRectIsRawRange(name: String, text: String, term: String, mode: SearchMode) async throws {
        let data = TestFixtures.textLayerPDF(text: text)
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let raw = try #require(page.string)
        let rawRange = (raw as NSString).range(of: term)
        try #require(rawRange.location != NSNotFound, "\(name): the term is on the page as drawn")
        let charactersBefore = Range(rawRange, in: raw).map { raw.distance(from: raw.startIndex, to: $0.lowerBound) } ?? -1

        let searcher = DocumentSearcher()
        let expected = try #require(searcher.boundingRect(for: rawRange, page: page))
        let stream = searcher.search(SendablePDFDocument(doc), mode: mode, progress: { _, _ in })
        var results: [SearchResult] = []
        for await result in stream { results.append(result) }
        let rect = try #require(results.first?.normalizedRect, "\(name)")
        print("rect probe \(name): raw units before the term=\(rawRange.location) · Characters before=\(charactersBefore) · drift x=\(rect.minX - expected.minX) · width delta=\(rect.width - expected.width)")
        #expect(results.count == 1, "\(name)")
        #expect(abs(rect.minX - expected.minX) < 1e-6 && abs(rect.minY - expected.minY) < 1e-6
                && abs(rect.width - expected.width) < 1e-6 && abs(rect.height - expected.height) < 1e-6,
                "\(name): the search rect must equal the raw range's rect")
    }
}
