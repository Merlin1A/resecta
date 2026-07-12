import Testing
import PDFKit
@testable import RedactionEngine

// design 04 §1.4 Gap A — tests that OCRTextNormalizer confusable correction
// is applied inside searchPageViaOCR before the TextNormalizer.normalizeForSearch
// step. The seam: _testSeedOCRLines plants confusable-corrupted OCR output;
// a text-mode search with the clean query should still resolve the match.
//
// Privacy rule: test names use locate/match/resolve vocabulary (audit-lint M-1).

@Suite("searchPageViaOCR normalizer parity (design 04 §1.4 Gap A)", .tags(.search))
struct SearchPageViaOCRNormalizerTests {

    @Test("Confusable-corrected OCR text resolves to clean query via text-mode search")
    func normalizerAppliedInManualOCRSearch() async {
        // OCR output has "l23-4S-6789" (l→1 in digit context, S→5 in digit
        // context). After OCRTextNormalizer the text becomes "123-45-6789".
        // A text-mode search for "123-45-6789" with includeOCR=true should
        // return 1 result on the OCR-only page.
        let data = TestFixtures.imageOnlyPDF()
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        await searcher._testSeedOCRLines(
            [OCREngine.TextLine(
                text: "l23-4S-6789",
                normalizedRect: CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.05),
                confidence: 0.85
            )],
            forPageIndex: 0
        )

        let stream = searcher.search(
            SendablePDFDocument(doc),
            mode: .text(
                "123-45-6789",
                options: SearchOptions(includeOCR: true, normalizeUnicode: true)
            ),
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        #expect(results.count == 1,
                "expected 1 result after confusable normalization; got \(results.count)")
        if case .ocr = results.first?.source {
            // expected
        } else {
            Issue.record("Expected .ocr source; got \(String(describing: results.first?.source))")
        }
    }
}
