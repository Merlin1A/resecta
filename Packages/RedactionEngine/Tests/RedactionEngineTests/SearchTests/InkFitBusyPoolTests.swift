import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The ink fit on a busy task pool (`PageImageInkFitTests`): its renders run on
// the search's own thread and no fit waits on a page read, so searches with
// more fits than the pool has threads leave other work moving, a cancelled
// search stops fitting, and a read that timed out is read again next time.

@Suite("Ink fit: a busy task pool")
struct InkFitBusyPoolTests {
    /// A re-imported Searchable export of the statement with a mark of this
    /// test's own in a blank corner of each page, so its page content keys
    /// (and any stall set on them) are no other test's.
    static func export(mark: CGRect) async throws -> Data {
        let data = try TestFixtures.sampleStatementPDF()
        let pages = try #require(PDFDocument(data: data)).pageCount
        var regions: [Int: [RedactionRegion]] = [:]
        for index in 0..<pages { regions[index] = [RedactionRegion(id: UUID(), normalizedRect: mark, source: .manual)] }
        let url = try await TestPipeline.processAndExport(data, mode: .searchableRedaction, regions: regions, dpi: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }

    static func search(_ doc: PDFDocument, _ mode: SearchMode, searcher: DocumentSearcher = DocumentSearcher()) async -> [SearchResult] {
        var out: [SearchResult] = []
        for await result in searcher.search(SendablePDFDocument(doc), mode: mode, progress: { _, _ in }) { out.append(result) }
        return out
    }

    @Test("More hidden-layer searches than the task pool has threads, with a regex scan beside them: all finish, and the scan's cancellation returns promptly")
    func busyPoolLeavesOtherWorkMoving() async throws {
        let data = try await Self.export(mark: CGRect(x: 0.013, y: 0.011, width: 0.019, height: 0.008))
        // The pages read first (as each search's first page read would), so
        // the searches below spend their time fitting.
        let reader = try #require(PDFDocument(data: data))
        for index in 0..<reader.pageCount { if let page = reader.page(at: index) { await DocumentSearcher.prepareInkFit(page) } }
        let count = ProcessInfo.processInfo.activeProcessorCount + 4
        let finished = OCRLegConcurrencyTests.ResultBox()
        let searches = Task {
            await withTaskGroup(of: Int.self) { group in
                for _ in 0..<count {
                    group.addTask {
                        // A document of each search's own (no shared PDF objects).
                        guard let doc = PDFDocument(data: data) else { return 0 }
                        return await Self.search(doc, .text("delia", options: SearchOptions())).count
                    }
                }
                for await hits in group { finished.add(hits) }
            }
        }
        // An unrelated regex scan, started while the searches fit, then cancelled.
        try await Task.sleep(for: .milliseconds(300))
        let plain = SendablePDFDocument(try #require(PDFDocument(data: try TestFixtures.sampleStatementPDF())))
        let scan = Task {
            var n = 0
            for await _ in DocumentSearcher().search(plain, mode: .regex("[0-9]{2}", options: SearchOptions()), progress: { _, _ in }) { n += 1 }
            return n
        }
        try await Task.sleep(for: .milliseconds(100))
        let cancelled = ContinuousClock.now
        scan.cancel()
        _ = await scan.value
        let waited = ContinuousClock.now - cancelled
        #expect(waited < .seconds(2), "the cancelled regex scan took \(waited) to return beside \(count) fitting searches")
        // Bounded: a pool held by waits on a lane would finish late or never.
        let deadline = Date().addingTimeInterval(120)
        while finished.count < count, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        #expect(finished.count == count, "\(finished.count) of \(count) searches finished in 120 s")
        #expect(finished.hits == 9 * count, "every search returns the statement's nine Delias: \(finished.hits) of \(9 * count)")
        searches.cancel()
    }

    @Test("A hidden-layer search cancelled while it fits returns promptly: its remaining words are not rendered")
    func cancelledSearchStopsFitting() async throws {
        let data = try await Self.export(mark: CGRect(x: 0.015, y: 0.013, width: 0.016, height: 0.009))
        let doc = try #require(PDFDocument(data: data))
        for index in 0..<doc.pageCount { if let page = doc.page(at: index) { await DocumentSearcher.prepareInkFit(page) } }
        let shared = SendablePDFDocument(doc)
        // A letter on nearly every word: far more fits than the wait below allows.
        let search = Task {
            var n = 0
            for await _ in DocumentSearcher().search(shared, mode: .text("e", options: SearchOptions()), progress: { _, _ in }) { n += 1 }
            return n
        }
        try await Task.sleep(for: .milliseconds(400))
        let cancelled = ContinuousClock.now
        search.cancel()
        _ = await search.value
        let waited = ContinuousClock.now - cancelled
        #expect(waited < .milliseconds(500), "the cancelled search took \(waited) to return; one render is a few ms")
    }

    @Test("A page whose read timed out in one search is read again by the next, which fits it, not degraded")
    func timedOutReadIsReadAgainNextSearch() async throws {
        let data = try await Self.export(mark: CGRect(x: 0.012, y: 0.014, width: 0.018, height: 0.007))
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0)), cgPage = try #require(page.pageRef)
        let key = InkTokenCache.key(page: page, cgPage: cgPage, visual: page.bounds(for: .cropBox).size)
        let mode = SearchMode.text("Hartwell", options: SearchOptions())
        // Search 1: the page's read stalls past its wait.
        DocumentSearcher.inkFitInjectedStalls.set((3.0, 0.5), for: key)
        let first = await Self.search(doc, mode).filter { $0.pageIndex == 0 }
        DocumentSearcher.inkFitInjectedStalls.set(nil, for: key)
        try #require(!first.isEmpty)
        #expect(first.allSatisfy { $0.inkFitDegraded }, "with its read stalled, the page's boxes are degraded")
        #expect(InkTokenCache.shared.value(for: key) == nil, "the stalled read leaves nothing cached")
        // Search 2, with the read working: it awaits the read again and fits.
        let second = await Self.search(doc, mode).filter { $0.pageIndex == 0 }
        #expect(second.count == first.count, "the second search returns the same words")
        #expect(second.allSatisfy { !$0.inkFitDegraded }, "the next search fits the page: \(second.map(\.inkFitDegraded))")
        #expect(InkTokenCache.shared.value(for: key)?.isEmpty == false, "the second search read the page")
    }
}
