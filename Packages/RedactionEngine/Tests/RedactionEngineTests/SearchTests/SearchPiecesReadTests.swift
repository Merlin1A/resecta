import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// Search, Scan and the not-read signal on a scan stored as many small
// pictures under a full text layer: the picture is read on the second leg.
// Recognition is seeded through `_testSeedOCRLines`, so no Vision read runs.
//
// Privacy rule (audit-lint M-1): locate/read/report vocabulary.

private typealias S = PiecewiseScan

@Suite("Search on scans stored in pieces", .serialized, .tags(.search))
struct SearchPiecesReadTests {

    /// Pages the not-read signal named, collected as they arrive.
    final class Signals: @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [Int] = []
        func append(_ page: Int) { lock.lock(); pages.append(page); lock.unlock() }
        var snapshot: [Int] { lock.lock(); defer { lock.unlock() }; return pages }
    }

    /// A scan in strips of 96 rows whose text layer reads `layerWord` where the
    /// print shows the builder's word, with the filler lines.
    static func stripScan(layerWord: String = S.word) -> Data {
        let d = S.draw(S.print(dpi: 300, shift: 0), dpi: 300, .strips(rows: 96))
        let layer = S.text(mode: 3).replacingOccurrences(of: S.word, with: layerWord) + S.fillerLayer
        return S.document([S.Page(d.ops + layer, resources: "/XObject << \(d.names)>>", objects: d.objects)])
    }

    static func line(_ text: String, _ rect: CGRect) -> OCREngine.TextLine {
        OCREngine.TextLine(text: text, normalizedRect: rect, confidence: 0.9)
    }

    static func run(_ data: Data, _ mode: SearchMode, seed: [OCREngine.TextLine] = []) async throws -> ([SearchResult], [Int]) {
        let (document, _, _) = try #require(S.pdfPage(data))
        let searcher = DocumentSearcher()
        if !seed.isEmpty { await searcher._testSeedOCRLines(seed, forPageIndex: 0) }
        let signals = Signals()
        await searcher.setScannedRegionNotAnalyzedSink { signals.append($0) }
        var results: [SearchResult] = []
        for await result in searcher.search(SendablePDFDocument(document), mode: mode, progress: { _, _ in }) {
            results.append(result)
        }
        return (results, signals.snapshot)
    }

    static let printedLine = CGRect(x: 0.15, y: 0.87, width: 0.6, height: 0.03)

    @Test("A word the picture shows and the text layer lacks is found with OCR pages included")
    func pictureWordFound() async throws {
        let (results, _) = try await Self.run(Self.stripScan(layerWord: "QUENTLN"),
                                              .text(S.word, options: SearchOptions(includeOCR: true)),
                                              seed: [Self.line("Account holder MARISOL \(S.word)", Self.printedLine)])
        #expect(results.count == 1)
        if case .ocr = results.first?.source {} else { Issue.record("read from the picture: \(String(describing: results.first?.source))") }
    }

    @Test("With OCR pages left out, the page is reported as not read")
    func notReadSignal() async throws {
        let (results, signals) = try await Self.run(Self.stripScan(layerWord: "QUENTLN"),
                                                    .text(S.word, options: SearchOptions(includeOCR: false)))
        #expect(results.isEmpty)
        #expect(signals == [0])
    }

    @Test("A word in both the text layer and the picture is one result")
    func oneResultForBothLegs() async throws {
        let (results, _) = try await Self.run(Self.stripScan(),
                                              .text(S.word, options: SearchOptions(includeOCR: true)),
                                              seed: [Self.line(S.word, CGRect(x: 0.02, y: 0.02, width: 0.96, height: 0.96))])
        #expect(results.count == 1)
        #expect(results.first?.source == .textLayer)
    }

    @Test("Typed pages are not reported as not read")
    func typedPagesNotReported() async throws {
        for (name, data) in [("a typed letter", PageImageCensusPiecesTests.typedLetter()),
                             ("a letter with a letterhead logo", TestFixtures.letterWithImagePDF(width: 600, height: 300))] {
            let (_, signals) = try await Self.run(data, .text(S.word, options: SearchOptions(includeOCR: false)))
            #expect(signals.isEmpty, "\(name)")
        }
    }

    @Test("Scan reads the picture of a scan stored in pieces")
    func scanReadsThePicture() async throws {
        let (results, _) = try await Self.run(Self.stripScan(),
                                              .piiScan(categories: [.email], options: SearchOptions(includeOCR: true)),
                                              seed: [Self.line("Write to quentin.halverson@example.com", Self.printedLine)])
        #expect(results.count == 1)
        if case .ocr = results.first?.source {} else { Issue.record("read from the picture: \(String(describing: results.first?.source))") }
    }
}
