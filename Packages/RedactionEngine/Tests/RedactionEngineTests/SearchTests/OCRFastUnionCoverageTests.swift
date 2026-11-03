import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// On iOS 27 a scanned page's recognized text is read twice, accurate and fast.
// When the fast read splits a line and holds more matches of a term over it than
// the accurate read does, each fast match is an occurrence, and the accurate line
// box is folded into one of them, not dropped: the fast read can miss the very
// occurrence the accurate read matched, and its boxes alone then do not cover it.
// One result per occurrence the fast read holds. One scanned line printed with three
// occurrences, left to right: the accurate read matches the first only; the
// fast read, in three fragments, matches the second and third only.

@Suite("OCR on iOS 27: the occurrence the accurate read matched keeps its box", .tags(.search))
struct OCRFastUnionCoverageTests {

    static let line = CGRect(x: 0.10, y: 0.50, width: 0.84, height: 0.03)
    static let fragments = [
        CGRect(x: 0.10, y: 0.50, width: 0.27, height: 0.03),
        CGRect(x: 0.385, y: 0.50, width: 0.27, height: 0.03),
        CGRect(x: 0.67, y: 0.50, width: 0.27, height: 0.03),
    ]
    /// Where the first occurrence is printed: inside the first fragment only.
    static let firstOccurrence = CGRect(x: 0.11, y: 0.505, width: 0.24, height: 0.02)

    private func search(_ mode: SearchMode, accurate: String, fast: [String]) async throws -> [SearchResult] {
        let doc = try #require(PDFDocument(data: TestFixtures.imageOnlyPDF()))
        let searcher = DocumentSearcher()
        await searcher._testSeedOCRLines(
            [OCREngine.TextLine(text: accurate, normalizedRect: Self.line, confidence: 0.6)], forPageIndex: 0)
        await searcher._testSeedOCRFastLines(
            zip(fast, Self.fragments).map { OCREngine.TextLine(text: $0.0, normalizedRect: $0.1, confidence: 0.5) },
            forPageIndex: 0)
        var results: [SearchResult] = []
        for await r in searcher.search(SendablePDFDocument(doc), mode: mode, progress: { _, _ in }) { results.append(r) }
        return results
    }

    /// The share of the first occurrence's printed span that the results' boxes cover.
    private func firstOccurrenceCovered(_ results: [SearchResult]) -> CGFloat {
        RegionCoverage.coveredFraction(
            of: Self.firstOccurrence,
            by: results.map { RedactionRegion(id: UUID(), normalizedRect: $0.normalizedRect, source: .searchMatch(term: $0.term)) })
    }

    private func expectFirstOccurrenceBoxed(_ results: [SearchResult], fastMatches: Int) {
        #expect(firstOccurrenceCovered(results) == 1, "boxes: \(results.map(\.normalizedRect))")
        if DocumentSearcher.readsFastOCRBeside {
            #expect(results.count == fastMatches, "one result per fast match, the accurate box folded into one: \(results.map(\.normalizedRect))")
        } else {
            #expect(results.count == 1, "iOS 26 reads one recognition")
        }
    }

    @Test("Text search: the first occurrence stays under a box")
    func textSearch() async throws {
        let results = try await search(.text("Delia Hartwell", options: SearchOptions()),
                                       accurate: "Delia Hartwell, Dclia Hartwcll, Dclia Hartwcll",
                                       fast: ["Dclia Hartwcll,", "Delia Hartwell,", "Delia Hartwell"])
        expectFirstOccurrenceBoxed(results, fastMatches: 2)
    }

    @Test("Regex search: the first occurrence stays under a box")
    func regexSearch() async throws {
        let results = try await search(.regex(#"INV-\d{5}"#, options: SearchOptions()),
                                       accurate: "INV-00731 INV-X0842 INV-X0953",
                                       fast: ["INV-X0731", "INV-00842", "INV-00953"])
        expectFirstOccurrenceBoxed(results, fastMatches: 2)
    }

    @Test("PII Scan: the first phone stays under a box")
    func piiScanPhone() async throws {
        let results = try await search(.piiScan(categories: [.phone], options: SearchOptions(includeOCR: true)),
                                       accurate: "(208) 555-0147 (208) 5X5-0199 (208) 5X5-0123",
                                       fast: ["(208) 5X5-0147", "(208) 555-0199", "(208) 555-0123"])
        expectFirstOccurrenceBoxed(results.filter { $0.piiCategory == .phone }, fastMatches: 2)
    }

    @Test("A line the fast read holds more matches on folds the accurate box into the first fast one")
    func unionFoldsTheAccurateBoxIntoAFastOne() {
        func result(_ rect: CGRect) -> SearchResult {
            SearchResult(pageIndex: 0, normalizedRect: rect, matchedText: "x", contextSnippet: "x",
                         source: .ocr(confidence: 0.5), term: "delia hartwell")
        }
        let merged = DocumentSearcher.unionFastOCRResults(
            accurate: [result(Self.line)], fast: [result(Self.fragments[1]), result(Self.fragments[2])])
        #expect(merged.count == 2, "one result per fast match: \(merged.map(\.normalizedRect))")
        // The fold's union is computed in floating point: equal to within 1e-9 on each edge.
        func same(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9
                && abs(a.maxX - b.maxX) < 1e-9 && abs(a.maxY - b.maxY) < 1e-9
        }
        let boxes = merged.map(\.normalizedRect)
        #expect(boxes.contains { same($0, Self.line) }, "the accurate box is kept, on the first: \(boxes)")
        #expect(boxes.contains { same($0, Self.fragments[2]) }, "the other fast match keeps its own box: \(boxes)")
        #expect(Set(merged.map { $0.identityRect ?? $0.normalizedRect }) == [Self.fragments[1], Self.fragments[2]],
                "each keeps its read's own box as its identity")
    }
}
