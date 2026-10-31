import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// On iOS 27 a scanned page's recognized text is read twice, accurate and
// fast, and the literal, regex and PII Scan routes add what only the fast
// read matched (`DocumentSearcher+OCRFastUnion`). A fast match on the same
// term over at least half of an accurate match's box is that match, boxed
// by the union of the two. iOS 26 reads one recognition.

@Suite("OCR on iOS 27: the fast read beside the accurate one", .tags(.search))
struct OCRFastUnionTests {

    private func result(_ term: String, _ rect: CGRect, text: String = "x") -> SearchResult {
        SearchResult(pageIndex: 0, normalizedRect: rect, matchedText: text, contextSnippet: text,
                     source: .ocr(confidence: 0.5), term: term)
    }

    @Test("A fast match over half an accurate match's box is that match, boxed by both")
    func overlappingMatchIsOneWithTheUnionBox() {
        let a = result("INV-00731", CGRect(x: 0.10, y: 0.50, width: 0.40, height: 0.02), text: "accurate")
        let f = result("INV-00731", CGRect(x: 0.12, y: 0.495, width: 0.40, height: 0.02), text: "fast")
        let merged = DocumentSearcher.unionFastOCRResults(accurate: [a], fast: [f])
        #expect(merged.count == 1)
        #expect(merged.first?.id == a.id && merged.first?.matchedText == "accurate", "the accurate match is kept")
        #expect(merged.first?.normalizedRect == a.normalizedRect.union(f.normalizedRect))
    }

    @Test("A fast match on another box, on another term, or over less than half is added")
    func otherFastMatchesAreAdded() {
        let a = result("INV-00731", CGRect(x: 0.10, y: 0.50, width: 0.40, height: 0.02))
        let elsewhere = result("INV-00731", CGRect(x: 0.10, y: 0.30, width: 0.40, height: 0.02))
        let otherTerm = result("2026-CV-0042", a.normalizedRect)
        let sliver = result("INV-00731", CGRect(x: 0.45, y: 0.50, width: 0.40, height: 0.02))
        let merged = DocumentSearcher.unionFastOCRResults(accurate: [a], fast: [elsewhere, otherTerm, sliver])
        #expect(merged.count == 4)
        #expect(merged.first?.normalizedRect == a.normalizedRect, "the accurate box is untouched")
    }

    private func searched(_ mode: SearchMode, accurate: String, fast: String) async throws -> [SearchResult] {
        let doc = try #require(PDFDocument(data: TestFixtures.imageOnlyPDF()))
        let rect = CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.03)
        let searcher = DocumentSearcher()
        await searcher._testSeedOCRLines([OCREngine.TextLine(text: accurate, normalizedRect: rect, confidence: 0.6)], forPageIndex: 0)
        await searcher._testSeedOCRFastLines([OCREngine.TextLine(text: fast, normalizedRect: rect, confidence: 0.5)], forPageIndex: 0)
        var results: [SearchResult] = []
        for await r in searcher.search(SendablePDFDocument(doc), mode: mode, progress: { _, _ in }) { results.append(r) }
        return results
    }

    @Test("Text search: a value only the fast read has is matched on iOS 27, not on iOS 26")
    func literalRouteAddsTheFastOnlyValue() async throws {
        let results = try await searched(.text("INV-00731", options: SearchOptions()),
                                         accurate: "Reference PR4471-A / frøn R (00 00",
                                         fast: "Reference PR4471-A / Case 2026-CV-0042 / Invoice INV-00731")
        if DocumentSearcher.readsFastOCRBeside {
            #expect(results.count == 1)
            if case .ocr = results.first?.source {} else { Issue.record("expected an OCR result") }
        } else {
            #expect(results.isEmpty)
        }
    }

    @Test("Text search: a value both reads have is one result")
    func literalRouteKeepsOneWhenBothRead() async throws {
        let results = try await searched(.text("PR4471-A", options: SearchOptions()),
                                         accurate: "Reference PR4471-A / frøn R (00 00",
                                         fast: "Reference PR4471-A / Case 2026-CV-0042 / Invoice INV-00731")
        #expect(results.count == 1)
    }

    @Test("Regex search: a value only the fast read has is matched on iOS 27, not on iOS 26")
    func regexRouteAddsTheFastOnlyValue() async throws {
        let results = try await searched(.regex(#"INV-\d{5}"#, options: SearchOptions()),
                                         accurate: "Reference PR4471-A / frøn R (00 00",
                                         fast: "Reference PR4471-A / Case 2026-CV-0042 / Invoice INV-00731")
        #expect(results.count == (DocumentSearcher.readsFastOCRBeside ? 1 : 0))
    }

    @Test("PII Scan: a phone only the fast read has is matched on iOS 27, not on iOS 26")
    func piiScanAddsTheFastOnlyPhone() async throws {
        let results = try await searched(.piiScan(categories: [.phone], options: SearchOptions(includeOCR: true)),
                                         accurate: "Home Phone: frøn R эçæ",
                                         fast: "Home Phone: (208) 555-0147")
        let phones = results.filter { $0.piiCategory == .phone }
        #expect(phones.count == (DocumentSearcher.readsFastOCRBeside ? 1 : 0), "\(results.map(\.matchedText))")
    }
}
