import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// A search match that wraps onto a second line, with one line's box
// applied, read by OCR: on a scanned page the coverage re-run reads the
// page through OCR, whose cross-line pass returns the two line pieces as
// one occurrence, so the bare line FAILS; on a Secure output the OCR Check
// reads the surname opening the line below the box as part of the match;
// and the full report over the two-line page reads FAIL in both modes.
// Vision-backed, simulator-only like the other OCR suites.
//
// Privacy rule (audit-lint M-1): locate/match/cover vocabulary.

@Suite("Search Re-check and OCR Check — a wrapped match with one line boxed, read by OCR", .serialized)
struct OccurrenceCoverageOCRTests {

    static let name = OccurrenceCoverageTests.name

    private static func searchBox(over result: SearchResult) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: result.normalizedRect, source: .searchMatch(term: result.term))
    }

    @Test("A scanned page with the first line's box only: the coverage re-run pairs the two lines and the Search Re-check FAILS")
    func scannedPageOneLineBoxed() async throws {
        let (doc, url) = try await OCRCrossLinePhraseTests.scannedPage()
        defer { try? FileManager.default.removeItem(at: url) }
        let options = OCRCrossLinePhraseTests.ocrOptions()
        let hits = await OCRCrossLinePhraseTests.search(doc, .text("Jane Doe", options: options))
        try #require(hits.count == 2 && hits[0].occurrenceID != nil && hits[0].occurrenceID == hits[1].occurrenceID,
                     "the two lines are one occurrence: \(hits.map(\.matchedText))")
        let top = try #require(hits.max { $0.normalizedRect.midY < $1.normalizedRect.midY })
        let box = Self.searchBox(over: top)
        let request = TestFixtures.textRequest("Jane Doe", options: options)
        let coverage = await RegionCoverage.check(source: SendablePDFDocument(doc), requests: [request], regions: [0: [box]])
        #expect(coverage.shortfalls.count == 1 && coverage.shortfalls.first?.pageIndex == 0, "\(coverage.shortfalls)")

        let outURL = try await TestPipeline.processAndExport(try Data(contentsOf: url), mode: .secureRasterization, regions: [0: [box]])
        defer { try? FileManager.default.removeItem(at: outURL) }
        let output = try #require(PDFDocument(url: outURL))
        let outcome = try await SearchRecheck().run(
            outputDocument: SendablePDFDocument(output), requests: [request],
            sourceDocument: SendablePDFDocument(doc), regions: [0: [box]])
        #expect(outcome.status == .fail("1 match is only partly covered by its redaction box on page 1"), "got \(outcome.status)")
    }

    @Test("The two-line name's Secure output with the first line's box only: the OCR Check reads the surname below the box as part of the name")
    func secureOutputSurnameBelowTheBox() async throws {
        let data = OccurrenceCoverageTests.wrappedNamePage
        let doc = try #require(PDFDocument(data: data))
        let pieces = try await OccurrenceCoverageTests.pieces(doc, mode: .text(Self.name, options: SearchOptions()))
        let box = Self.searchBox(over: pieces[0])
        let url = try await TestPipeline.processAndExport(data, mode: .secureRasterization, regions: [0: [box]])
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try #require(PDFDocument(url: url))
        let result = await VerificationEngine().runLayer(
            .ocrCheck, outputDocument: SendablePDFDocument(output), sourcePageCount: 1,
            regions: [0: [box]], sensitiveTerms: [SensitiveTerm(text: Self.name)], pipelineMode: .secureRasterization,
            filterDigests: [nil], perPageModes: [.secureRasterization])
        #expect(result.status.isAttention, "got \(result.status)")
        #expect(result.shortDescription.contains("Part of a redacted term is readable beside a redaction box"), "\(result.shortDescription)")
        #expect(result.pageReferences == [0])
    }

    @Test("The full report over the two-line name with the first line's box only reads FAIL, Secure and Searchable, the Search Re-check naming page 1",
          arguments: [PipelineMode.secureRasterization, .searchableRedaction])
    func fullReportFails(mode: PipelineMode) async throws {
        let data = OccurrenceCoverageTests.wrappedNamePage
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let pieces = try await OccurrenceCoverageTests.pieces(doc, mode: .text(Self.name, options: SearchOptions()))
        let regions = [0: [Self.searchBox(over: pieces[0])]]
        let pages = VerificationCorpusRunnerTests.buildPages(
            doc: doc, effectiveMode: mode, regionsByPage: regions,
            textLayerStatus: [0: TextLayerDetector.detectTextLayer(page)], hasHiddenOCG: false)
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("wrapped_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: outURL) }
        let outcome = try await VerificationCorpusRunnerTests.runRedaction(pages: pages, outputURL: outURL)
        let report = try await VerificationCorpusRunnerTests.runVerificationSweep(
            outputURL: outURL, sourcePageCount: 1, regions: regions,
            sensitiveTerms: [SensitiveTerm(text: Self.name)], effectiveMode: mode,
            filterDigests: outcome.filterDigests, perPageModes: outcome.perPageModes,
            perPageFallbackReasons: outcome.perPageFallbackReasons,
            appliedSearches: [TestFixtures.textRequest(Self.name), VerificationCorpusRunnerTests.sweepRequest()],
            sourceDocument: SendablePDFDocument(doc))
        #expect(report.overallStatus.isFail, "\(mode): got \(report.overallStatus)")
        let recheck = try #require(report.layers.first { $0.layer == .searchRecheck })
        #expect(recheck.status.isFail && recheck.pageReferences == [0], "\(mode): \(recheck.status)")
    }
}
