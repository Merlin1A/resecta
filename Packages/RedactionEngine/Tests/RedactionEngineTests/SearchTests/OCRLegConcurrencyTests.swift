import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The search's text recognition never blocks a task-pool thread: more searches
// with recognition on than the pool has threads, all at once, still finish.

@Suite("OCR leg concurrency")
struct OCRLegConcurrencyTests {
    /// A one-page scan: a picture of the statement's first page, no text layer.
    static func scannedPagePDF() throws -> Data {
        let page = try #require(PDFDocument(data: try TestFixtures.sampleStatementPDF())?.page(at: 0)?.pageRef)
        var media = page.getBoxRect(.mediaBox)
        let scale: CGFloat = 200 / 72
        let width = Int(media.width * scale), height = Int(media.height * scale)
        let bitmap = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        bitmap.setFillColor(gray: 1, alpha: 1); bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.scaleBy(x: scale, y: scale); bitmap.drawPDFPage(page)
        let picture = try #require(bitmap.makeImage())
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let ctx = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        ctx.beginPDFPage(nil); ctx.draw(picture, in: media); ctx.endPDFPage(); ctx.closePDF()
        return data as Data
    }

    @Test("More searches with recognition on than the task pool has threads, at once, all finish")
    func manyRecognizingSearchesFinish() async throws {
        let data = try Self.scannedPagePDF()
        let count = ProcessInfo.processInfo.activeProcessorCount + 4
        let finished = ResultBox()
        let all = Task {
            await withTaskGroup(of: Int.self) { group in
                for _ in 0..<count {
                    group.addTask {
                        // A document of each search's own (no shared PDF objects).
                        guard let doc = PDFDocument(data: data) else { return 0 }
                        var options = SearchOptions()
                        options.includeOCR = true
                        var hits = 0
                        for await _ in DocumentSearcher().search(SendablePDFDocument(doc), mode: .text("Delia", options: options),
                                                                 progress: { _, _ in }) { hits += 1 }
                        return hits
                    }
                }
                for await hits in group { finished.add(hits) }
            }
        }
        // Bounded: a pool starved by blocked recognitions would never finish.
        let deadline = Date().addingTimeInterval(180)
        while finished.count < count, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        #expect(finished.count == count, "\(finished.count) of \(count) searches finished in 180 s")
        #expect(finished.hits > 0, "the scans were read")
        all.cancel()
    }

    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = 0, total = 0
        func add(_ hits: Int) { lock.withLock { done += 1; total += hits } }
        var count: Int { lock.withLock { done } }
        var hits: Int { lock.withLock { total } }
    }
}
