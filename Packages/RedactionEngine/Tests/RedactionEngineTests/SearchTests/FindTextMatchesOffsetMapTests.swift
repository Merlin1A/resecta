import Testing
import PDFKit
@testable import RedactionEngine

// S7 / design 04 §4.4 + Risk 1 — the offset-map regression gates.
//
// The length-changing normalization extensions (separator strip,
// diacritic fold) run matching on a transformed string while PDFKit
// rects are computed from base-coordinate NSRanges. A wrong mapping is
// a misplaced redaction (leak-class), so these tests pin rect EQUALITY
// against the literal query's rect rather than asserting raw geometry:
// the literal path is the long-verified baseline, and both paths must
// select the same glyph run.
//
// Privacy rule: test names use locate/match/resolve vocabulary (audit-lint M-1).

@Suite("Offset-map rect correctness (design 04 §4.4 / Risk 1)", .tags(.search))
struct FindTextMatchesOffsetMapTests {

    // MARK: - Helpers

    private func runSearch(doc: PDFDocument, mode: SearchMode) async -> [SearchResult] {
        let searcher = DocumentSearcher()
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode, progress: { _, _ in }
        )
        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }
        return results
    }

    private func rectsApproximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.0005) -> Bool {
        abs(a.minX - b.minX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }

    private func makeDoc(text: String) -> PDFDocument? {
        PDFDocument(data: TestFixtures.textLayerPDF(text: text))
    }

    // MARK: - Separator strip (named gate)

    @Test("Separator-stripped query selects the hyphenated string's exact rect")
    func separatorStripCorrectRect() async {
        guard let doc = makeDoc(text: "Account 123-45-6789 end") else {
            Issue.record("PDFDocument creation failed")
            return
        }

        let literal = await runSearch(
            doc: doc, mode: .text("123-45-6789", options: SearchOptions())
        )
        let stripped = await runSearch(
            doc: doc, mode: .text("123456789", options: SearchOptions(stripDigitSeparators: true))
        )

        #expect(literal.count == 1, "baseline literal query must resolve once")
        #expect(stripped.count == 1, "stripped query must resolve once; got \(stripped.count)")
        guard let lhs = literal.first, let rhs = stripped.first else { return }
        #expect(rectsApproximatelyEqual(lhs.normalizedRect, rhs.normalizedRect),
                "rect drifted: literal \(lhs.normalizedRect) vs stripped \(rhs.normalizedRect)")
        // UXF-15: matchedText displays the base span (original separators
        // included), re-sliced at the mapped offsets. Matching still ran
        // on the stripped form.
        #expect(rhs.matchedText == "123-45-6789")
    }

    @Test("Space-separated digits resolve with the same rect as the literal span")
    func separatorStripSpaceVariantRect() async {
        guard let doc = makeDoc(text: "Ref 123 45 6789 trailer") else {
            Issue.record("PDFDocument creation failed")
            return
        }

        let literal = await runSearch(
            doc: doc, mode: .text("123 45 6789", options: SearchOptions())
        )
        let stripped = await runSearch(
            doc: doc, mode: .text("123456789", options: SearchOptions(stripDigitSeparators: true))
        )

        #expect(literal.count == 1)
        #expect(stripped.count == 1)
        guard let lhs = literal.first, let rhs = stripped.first else { return }
        #expect(rectsApproximatelyEqual(lhs.normalizedRect, rhs.normalizedRect))
    }

    // MARK: - Diacritic fold (named gate)

    @Test("Folded query selects the accented string's exact rect (multiple accents)")
    func diacriticFoldOffsetMapCorrectForMultipleAccents() async {
        guard let doc = makeDoc(text: "Name José García end") else {
            Issue.record("PDFDocument creation failed")
            return
        }

        let literal = await runSearch(
            doc: doc, mode: .text("José García", options: SearchOptions())
        )
        let folded = await runSearch(
            doc: doc, mode: .text("Jose Garcia", options: SearchOptions(foldDiacritics: true))
        )

        #expect(literal.count == 1, "baseline accented literal must resolve once")
        #expect(folded.count == 1, "folded query must resolve once; got \(folded.count)")
        guard let lhs = literal.first, let rhs = folded.first else { return }
        #expect(rectsApproximatelyEqual(lhs.normalizedRect, rhs.normalizedRect),
                "rect drifted: literal \(lhs.normalizedRect) vs folded \(rhs.normalizedRect)")
        // UXF-15: display keeps the document's accents and casing.
        #expect(rhs.matchedText == "José García")
    }

    // MARK: - Composition

    @Test("Fold + strip composed maps select the same span as the literal query")
    func composedFoldAndStripRect() async {
        guard let doc = makeDoc(text: "Name José 12-34 end") else {
            Issue.record("PDFDocument creation failed")
            return
        }

        let literal = await runSearch(
            doc: doc, mode: .text("José 12-34", options: SearchOptions())
        )
        let composed = await runSearch(
            doc: doc, mode: .text(
                "jose1234",
                options: SearchOptions(stripDigitSeparators: true, foldDiacritics: true)
            )
        )

        #expect(literal.count == 1)
        #expect(composed.count == 1, "composed query must resolve once; got \(composed.count)")
        guard let lhs = literal.first, let rhs = composed.first else { return }
        #expect(rectsApproximatelyEqual(lhs.normalizedRect, rhs.normalizedRect),
                "rect drifted under composed maps: \(lhs.normalizedRect) vs \(rhs.normalizedRect)")
    }

    // MARK: - Adversarial: RTL / combining marks

    @Test("Arabic diacritization marks are not stripped by default")
    func arabicCombiningMarkNotStrippedByDefault() async {
        // Page carries the fully diacritized form; the query omits the
        // marks. With the default option set the marks must survive, so
        // the unmarked query must NOT resolve; with fold opted in it must.
        // Runs through previewMatches (same extension pipeline as
        // findTextMatches) because UIGraphics-drawn Arabic does not
        // round-trip its combining marks through the PDFKit text layer —
        // the provider hands the engine the marked text directly.
        let pageText = "بسم مُحَمَّد للتغطية"
        let searcher = DocumentSearcher()

        let unmarkedDefault = await searcher.previewMatches(
            mode: .text("محمد", options: SearchOptions()),
            scope: .currentPage(pageIndex: 0),
            currentPageIndex: 0,
            totalPageCount: 1,
            pageTextProvider: { _ in pageText }
        )
        #expect(unmarkedDefault.totalCount == 0,
                "marks were stripped without foldDiacritics opt-in")

        let unmarkedFolded = await searcher.previewMatches(
            mode: .text("محمد", options: SearchOptions(foldDiacritics: true)),
            scope: .currentPage(pageIndex: 0),
            currentPageIndex: 0,
            totalPageCount: 1,
            pageTextProvider: { _ in pageText }
        )
        #expect(unmarkedFolded.totalCount == 1,
                "fold opt-in should resolve the unmarked query")
    }

    // MARK: - Whole-word semantics in base coordinates

    @Test("Whole-word with strip respects boundaries of the original text")
    func wholeWordWithStripUsesBaseBoundaries() async {
        guard let doc = makeDoc(text: "ID A123-45-6789 and 123-45-6789 end") else {
            Issue.record("PDFDocument creation failed")
            return
        }

        let options = SearchOptions(wholeWord: true, stripDigitSeparators: true)
        let results = await runSearch(doc: doc, mode: .text("123456789", options: options))
        #expect(results.count == 1,
                "letter-prefixed run must be rejected by base-coordinate boundaries; got \(results.count)")

        let literal = await runSearch(
            doc: doc, mode: .text("123-45-6789", options: SearchOptions(wholeWord: true))
        )
        #expect(literal.count == 1)
        guard let lhs = literal.first, let rhs = results.first else { return }
        #expect(rectsApproximatelyEqual(lhs.normalizedRect, rhs.normalizedRect))
    }

    // MARK: - Degenerate queries

    @Test("Separator-only query resolves to zero results without trapping")
    func separatorOnlyQueryIsRejected() async {
        guard let doc = makeDoc(text: "Account 123-45-6789 end") else {
            Issue.record("PDFDocument creation failed")
            return
        }
        let results = await runSearch(
            doc: doc, mode: .text("- . /", options: SearchOptions(stripDigitSeparators: true))
        )
        #expect(results.isEmpty)
    }

    // MARK: - Smart punctuation (default-on, 1:1)

    @Test("Plain-hyphen query resolves an em-dash span under the default options")
    func smartPunctuationDefaultMatchesEmDash() async {
        guard let doc = makeDoc(text: "John\u{2014}Smith record") else {
            Issue.record("PDFDocument creation failed")
            return
        }
        let results = await runSearch(
            doc: doc, mode: .text("John-Smith", options: SearchOptions())
        )
        #expect(results.count == 1, "em-dash should fold to hyphen by default; got \(results.count)")
        // UXF-15: original casing; the em dash reads as "-" because smart
        // punctuation is part of the base text (1:1 fold), not the case fold.
        #expect(results.first?.matchedText == "John-Smith")

        let optedOut = await runSearch(
            doc: doc, mode: .text(
                "John-Smith", options: SearchOptions(normalizeSmartPunctuation: false)
            )
        )
        #expect(optedOut.isEmpty, "fold should not apply once toggled off")
    }

    // MARK: - OCR literal path (whole-line rects, seeded lines)

    @Test("OCR literal path resolves a stripped query against the seeded line box")
    func ocrLiteralPathStripResolvesLineRect() async {
        guard let doc = PDFDocument(data: TestFixtures.imageOnlyPDF()) else {
            Issue.record("PDFDocument creation failed")
            return
        }

        let searcher = DocumentSearcher()
        let lineRect = CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.05)
        await searcher._testSeedOCRLines(
            [OCREngine.TextLine(text: "123-45-6789", normalizedRect: lineRect, confidence: 0.9)],
            forPageIndex: 0
        )

        let stream = searcher.search(
            SendablePDFDocument(doc),
            mode: .text(
                "123456789",
                options: SearchOptions(includeOCR: true, stripDigitSeparators: true)
            ),
            progress: { _, _ in }
        )
        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        #expect(results.count == 1, "seeded OCR line should resolve; got \(results.count)")
        guard let result = results.first else { return }
        // The OCR path emits the padded LINE box — verify it contains the
        // seeded rect (padding only ever expands).
        #expect(result.normalizedRect.contains(lineRect) ||
                rectsApproximatelyEqual(result.normalizedRect, lineRect, tolerance: 0.02))
        // UXF-15: the OCR literal path also displays the base span with
        // its original separators.
        #expect(result.matchedText == "123-45-6789")
    }

    // MARK: - Live preview parity (emitted ranges are base-coordinate)

    @Test("Preview emits base-coordinate ranges for stripped matches")
    func previewLiteralEmitsBaseCoordinateRanges() async {
        let pageText = "ab 123-45-6789 cd"
        let searcher = DocumentSearcher()
        let result = await searcher.previewMatches(
            mode: .text("123456789", options: SearchOptions(stripDigitSeparators: true)),
            scope: .currentPage(pageIndex: 0),
            currentPageIndex: 0,
            totalPageCount: 1,
            pageTextProvider: { _ in pageText }
        )
        #expect(result.totalCount == 1)
        // "123-45-6789" spans Character offsets 3..<14 of the page text.
        #expect(result.currentPageMatches == [NSRange(location: 3, length: 11)],
                "preview range must be mapped back to base coordinates; got \(result.currentPageMatches)")
    }
}
