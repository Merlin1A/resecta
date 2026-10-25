import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The hybrid leg's dedup: an OCR line result that repeats a text-layer result
// is dropped, whatever the text-layer box's size. A page read too slowly gets
// the drift envelope (taller than its line, centred where the word should be);
// judged on overlap alone, the envelope missed the line's OCR result, which
// then came back as an extra whole-line hit, so a search reported more under load.

@Suite("Hybrid leg dedup", .tags(.search))
struct HybridDedupTests {

    /// A recognised line and an OCR result on it.
    static let line = CGRect(x: 0.0569, y: 0.9437, width: 0.6062, height: 0.0167)
    static func ocr(_ rect: CGRect = line) -> SearchResult {
        SearchResult(pageIndex: 0, normalizedRect: rect, matchedText: "Delia", contextSnippet: "Delia",
                     source: .ocr(confidence: 1), term: "delia")
    }
    /// The drift envelope of a word on that line: taller than the line, centred on it,
    /// with under half of itself on the line.
    static let envelope = CGRect(x: 0.0, y: 0.9304, width: 0.1636, height: 0.0379)
    /// A word's ink on that line, further along.
    static let word = CGRect(x: 0.40, y: 0.9460, width: 0.04, height: 0.0120)

    @Test("an envelope centred on the line repeats the line's OCR result, though under half of it overlaps")
    func envelopeRepeatsItsLine() {
        let overlap = Self.envelope.intersection(Self.line)
        #expect(overlap.width * overlap.height < 0.5 * Self.envelope.width * Self.envelope.height,
                "the fixture is the case the overlap rule alone missed")
        #expect(DocumentSearcher.mergeHybridResults(textLayerRects: [Self.envelope], ocr: [Self.ocr()]).isEmpty)
    }

    @Test("each text-layer box accounts for one OCR result: a second occurrence the text layer lacks keeps its own")
    func oneToOne() {
        let two = [Self.ocr(), Self.ocr()]
        #expect(DocumentSearcher.mergeHybridResults(textLayerRects: [Self.envelope], ocr: two).count == 1,
                "one occurrence on the line in the text layer, two read: the second keeps its OCR result")
        #expect(DocumentSearcher.mergeHybridResults(textLayerRects: [Self.envelope, Self.word], ocr: two).isEmpty,
                "both occurrences in the text layer: both OCR results repeat them")
    }

    @Test("an OCR result no text-layer box sits on is kept; a page with no text layer keeps every one")
    func unrelatedAndScanned() {
        let elsewhere = CGRect(x: 0.10, y: 0.50, width: 0.05, height: 0.012)
        #expect(DocumentSearcher.mergeHybridResults(textLayerRects: [elsewhere], ocr: [Self.ocr()]).count == 1)
        #expect(DocumentSearcher.mergeHybridResults(textLayerRects: [], ocr: [Self.ocr(), Self.ocr()]).count == 2)
    }

    @Test("a search with recognition on reports the same results when every page read stalls as when none does")
    func sameResultsUnderAStall() async throws {
        // An export of this test's own (two words redacted), so its page keys are no other test's.
        let data = try TestFixtures.sampleStatementPDF()
        let source = try #require(PDFDocument(data: data))
        var regions: [Int: [RedactionRegion]] = [:]
        for hit in await PageImageInkFitTests.hits(source, "Sample", includeOCR: false)
            + (await PageImageInkFitTests.hits(source, "Balance", includeOCR: false)) {
            regions[hit.pageIndex, default: []].append(
                RedactionRegion(id: UUID(), normalizedRect: hit.normalizedRect, source: .manual))
        }
        let url = try await TestPipeline.processAndExport(data, mode: .searchableRedaction, regions: regions, dpi: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        let export = try #require(PDFDocument(data: try Data(contentsOf: url)))
        // Stalled first, before anything on these pages is read or cached.
        var keys: [Int] = []
        for index in 0..<export.pageCount {
            let page = try #require(export.page(at: index))
            let key = InkTokenCache.key(page: page, cgPage: try #require(page.pageRef), visual: page.bounds(for: .cropBox).size)
            keys.append(key)
            DocumentSearcher.inkFitInjectedStalls.set((6.0, 0.2), for: key)
        }
        let stalled = await PageImageInkFitTests.hits(export, "delia", includeOCR: true)
        for key in keys { DocumentSearcher.inkFitInjectedStalls.set(nil, for: key) }
        #expect(stalled.contains { $0.inkFitDegraded }, "the stall degraded the fits")
        #expect(stalled.count == 9 && stalled.allSatisfy { $0.source == .textLayer },
                "stalled: \(stalled.map { "\($0.source) p\($0.pageIndex + 1)" })")
        try await Task.sleep(for: .seconds(8))   // the stalled reads finish
        let normal = await PageImageInkFitTests.hits(export, "delia", includeOCR: true)
        #expect(normal.count == 9 && normal.allSatisfy { $0.source == .textLayer })
    }
}
