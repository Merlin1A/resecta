import Testing
import PDFKit
@testable import RedactionEngine

// BUG-006-norm-drift — F-006 sibling at findTextMatches / findOCRMatches.
//
// Pre-fix, `matchedText` was sourced from the original page text using
// normalized-space Character offsets. TextNormalizer expands Latin ligatures
// (e.g. U+FB01 ﬁ → "fi"), so the offsets drifted on ligature pages,
// producing corrupted substrings (Case A) or an out-of-bounds trap on
// heavy-ligature pages (Case B). Post-fix, `matchedText` is sourced from
// the normalized form; REDACTION_ENGINE.md §9.6 pins the display contract.
//
// Whether the underlying PDF text layer round-trips the ligature codepoint
// is font/PDFKit dependent. When it does, the search path exercises the
// crash class pre-fix. When PDFKit pre-decomposes to "fi", the test still
// pins the new normalized-form contract.

@Suite("DocumentSearcher Ligature (BUG-006-norm-drift)", .tags(.search))
struct DocumentSearcherLigatureTests {

    @Test("Ligature page SSN search returns matchedText and non-empty rect")
    func ligaturePageSSNMatch() async {
        // Audit §1.4.a Case A/B fixture: two ligatures preceding an SSN.
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

    @Test("Ligature query returns normalized matchedText per §9.6")
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
        // form even when the source contains U+FB01 ﬁ. §9.6.
        #expect(results.first?.matchedText == "file")
    }
}
