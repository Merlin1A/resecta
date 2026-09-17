import Testing
import PDFKit
@testable import RedactionEngine

// Tests that OCRTextNormalizer confusable correction
// is applied inside searchPageViaOCR before the TextNormalizer.normalizeForSearch
// step. The seam: _testSeedOCRLines plants confusable-corrupted OCR output;
// a text-mode search with the clean query should still resolve the match.
//
// Privacy rule: test names use locate/match/resolve vocabulary (audit-lint M-1).

@Suite("searchPageViaOCR normalizer parity", .tags(.search))
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

    @Test("Labelled phone line on an image-only page resolves through the PII scan")
    func labelledPhoneLineResolvesViaPIIScan() async {
        // The line is letter-majority (its label) and "555" carries no clear
        // digit of its own. Before the digit-run rule the normalizer turned
        // the value into "SSS-0147" and the phone detector saw no number;
        // the run "(208) 555-0147" now keeps digit context end to end, so
        // the PII scan over the OCR page yields the phone.
        let data = TestFixtures.imageOnlyPDF()
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        await searcher._testSeedOCRLines(
            [OCREngine.TextLine(
                text: "Home Phone: (208) 555-0147",
                normalizedRect: CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.05),
                confidence: 0.9
            )],
            forPageIndex: 0
        )

        let stream = searcher.search(
            SendablePDFDocument(doc),
            mode: .piiScan(categories: [.phone], options: SearchOptions(includeOCR: true)),
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        #expect(results.count == 1,
                "expected the phone once from the OCR page; got \(results.count): \(results.map(\.matchedText))")
        #expect(results.first?.matchedText.contains("555-0147") == true,
                "expected the digit run intact in the matched text; got \(String(describing: results.first?.matchedText))")
        if case .ocr = results.first?.source {
            // expected
        } else {
            Issue.record("Expected .ocr source; got \(String(describing: results.first?.source))")
        }
    }
}
