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

    /// The text layer only: no recognition leg (its Vision reads would be
    /// the time measured, not the fits).
    static var layerOnly: SearchOptions { var options = SearchOptions(); options.includeOCR = false; return options }

    static func search(_ doc: PDFDocument, _ mode: SearchMode, searcher: DocumentSearcher = DocumentSearcher()) async -> [SearchResult] {
        var out: [SearchResult] = []
        for await result in searcher.search(SendablePDFDocument(doc), mode: mode, progress: { _, _ in }) { out.append(result) }
        return out
    }

    @Test("More hidden-layer searches than the task pool has threads fit side by side, not one render at a time, and a regex scan beside them cancels promptly")
    func busyPoolLeavesOtherWorkMoving() async throws {
        let data = try await Self.export(mark: CGRect(x: 0.013, y: 0.011, width: 0.019, height: 0.008))
        // The pages read first (as each search's first page read would), so
        // the searches below spend their time fitting.
        let reader = try #require(PDFDocument(data: data))
        for index in 0..<reader.pageCount { if let page = reader.page(at: index) { await DocumentSearcher.prepareInkFit(page) } }
        // No stall seam: the real renders and draw locks. One search alone first.
        let aloneStarted = Date()
        // A letter on most words: hundreds of fits a search.
        let mode = SearchMode.text("e", options: Self.layerOnly)
        let alone = await Self.search(try #require(PDFDocument(data: data)), mode)
        let aloneSeconds = Date().timeIntervalSince(aloneStarted)
        let count = ProcessInfo.processInfo.activeProcessorCount + 4
        let finished = OCRLegConcurrencyTests.ResultBox(), degraded = OCRLegConcurrencyTests.ResultBox()
        let started = Date()
        let searches = Task {
            await withTaskGroup(of: Int.self) { group in
                for _ in 0..<count {
                    group.addTask {
                        // A document of each search's own (no shared PDF objects).
                        guard let doc = PDFDocument(data: data) else { return 0 }
                        let results = await Self.search(doc, mode)
                        degraded.add(results.filter(\.inkFitDegraded).count)
                        return results.count
                    }
                }
                for await hits in group { finished.add(hits) }
            }
        }
        // An unrelated regex scan, started while the searches fit and
        // cancelled at once: it returns only once a pool thread runs it. A
        // pool held by waits frees a thread for it only after
        // count - cores + 1 searches end; a pool that moves runs it within
        // the first search's time.
        try await Task.sleep(for: .milliseconds(300))
        let plain = SendablePDFDocument(try #require(PDFDocument(data: try TestFixtures.sampleStatementPDF())))
        let cancelled = ContinuousClock.now
        let scan = Task {
            var n = 0
            for await _ in DocumentSearcher().search(plain, mode: .regex("[0-9]{2}", options: Self.layerOnly), progress: { _, _ in }) { n += 1 }
            return n
        }
        scan.cancel()
        _ = await scan.value
        let waited = ContinuousClock.now - cancelled
        let finishedBeforeScan = finished.count
        #expect(finishedBeforeScan == 0,
                "the cancelled regex scan returned (after \(waited)) only once \(finishedBeforeScan) of \(count) fitting searches had finished")
        // Bounded: a pool held by waits on a lane would finish late or never.
        let deadline = Date().addingTimeInterval(120)
        while finished.count < count, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        let together = Date().timeIntervalSince(started)
        #expect(finished.count == count, "\(finished.count) of \(count) searches finished in 120 s")
        // Each search's renders run on its own thread: together they take
        // about as long as their share of the cores, not one render at a time
        // across all of them (measured on 10 cores, 14 searches: 1.2 times
        // one alone inline, 2.7 times with the renders on one lane).
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let bound = aloneSeconds * 1.5 * max(1, Double(count) / cores)
        #expect(together < bound, "\(count) searches took \(together) s; one alone \(aloneSeconds) s (bound \(bound) s)")
        #expect(finished.hits == alone.count * count, "every search returns the hits one alone does: \(finished.hits) of \(alone.count * count)")
        // Reported, not judged (a degraded box holds its word; how many
        // degrade under load is measured here).
        print("busy-pool: alone \(aloneSeconds) s, \(alone.filter(\.inkFitDegraded).count) of \(alone.count) degraded; "
              + "\(count) together \(together) s, \(degraded.hits) of \(finished.hits) degraded; regex cancel \(waited)")
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
            for await _ in DocumentSearcher().search(shared, mode: .text("e", options: Self.layerOnly), progress: { _, _ in }) { n += 1 }
            return n
        }
        try await Task.sleep(for: .milliseconds(400))
        let cancelled = ContinuousClock.now
        search.cancel()
        _ = await search.value
        let waited = ContinuousClock.now - cancelled
        #expect(waited < .milliseconds(500), "the cancelled search took \(waited) to return; one render is a few ms")
    }

    @Test("A page with a draw that has not returned is not drawn again from another copy; another page still draws")
    func hungDrawIsNotRepeated() async throws {
        let data = try await Self.export(mark: CGRect(x: 0.017, y: 0.012, width: 0.015, height: 0.008))
        // Two documents of the same content (two private copies, one page
        // content key), and another page of it.
        let one = try #require(PDFDocument(data: data)), two = try #require(PDFDocument(data: data))
        let first = try #require(PrivatePDFCopies.shared.copy(of: one)?.page(at: 1))
        let second = try #require(PrivatePDFCopies.shared.copy(of: two)?.page(at: 1))
        let elsewhere = try #require(PrivatePDFCopies.shared.copy(of: two)?.page(at: 2))
        let key = Int.random(in: 1...Int.max), otherKey = Int.random(in: 1...Int.max)
        let a = InkFitPage(first), b = InkFitPage(second), c = InkFitPage(elsewhere)
        try #require(a.drawLock !== b.drawLock, "each copy has its own draw lock")
        // A draw of the page that does not return in time (held until the
        // test releases it, judged hung past 0.3 s), on a thread of its own.
        let began = DispatchSemaphore(value: 0), stalled = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = DocumentSearcher.drawn(a, key: key, hungAfter: 0.3) { began.signal(); _ = release.wait(timeout: .now() + 120) }
            stalled.signal()
        }
        // Past the hung bound after the draw began (a busy run can start it late).
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { began.wait(); done.resume() }
        }
        try await Task.sleep(for: .milliseconds(600))
        // The same page from the other copy: not drawn, while the draw is
        // still held (so the skip did not wait for it).
        let again: Bool? = DocumentSearcher.drawn(b, key: key, hungAfter: 0.3) { true }
        #expect(again == nil, "the page with a hung draw was drawn again from another copy")
        // Another page of that copy still draws.
        let other: Bool? = DocumentSearcher.drawn(c, key: otherKey, hungAfter: 0.3) { true }
        #expect(other == true, "another page did not draw beside the hung one")
        release.signal()
        // Once the slow draw returns (as a failed render would), the page draws again.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { stalled.wait(); done.resume() }
        }
        let after: Bool? = DocumentSearcher.drawn(b, key: key, hungAfter: 0.3) { true }
        #expect(after == true, "the page did not draw after its slow draw returned")
    }

    @Test("A page whose read timed out in one search is read again by later ones, which fit it, not degraded")
    func timedOutReadIsReadAgainNextSearch() async throws {
        let data = try await Self.export(mark: CGRect(x: 0.012, y: 0.014, width: 0.018, height: 0.007))
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0)), cgPage = try #require(page.pageRef)
        let key = InkTokenCache.key(page: page, cgPage: cgPage, visual: page.bounds(for: .cropBox).size)
        let mode = SearchMode.text("Hartwell", options: Self.layerOnly)
        // Search 1: the page's read stalls past its wait.
        DocumentSearcher.inkFitInjectedStalls.set((3.0, 0.5), for: key)
        let first = await Self.search(doc, mode).filter { $0.pageIndex == 0 }
        DocumentSearcher.inkFitInjectedStalls.set(nil, for: key)
        try #require(!first.isEmpty)
        #expect(first.allSatisfy { $0.inkFitDegraded }, "with its read stalled, the page's boxes are degraded")
        #expect(InkTokenCache.shared.value(for: key) == nil, "the stalled read leaves nothing cached")
        // Later searches, with the read working, await the read again and
        // fit (a busy run's Vision lane can make one of them wait past its
        // read's limit too; the page is never left enveloped for good).
        var later: [SearchResult] = []
        for _ in 0..<3 {
            later = await Self.search(doc, mode).filter { $0.pageIndex == 0 }
            if !later.isEmpty, later.allSatisfy({ !$0.inkFitDegraded }) { break }
        }
        #expect(later.count == first.count, "a later search returns the same words")
        #expect(later.allSatisfy { !$0.inkFitDegraded }, "a later search fits the page: \(later.map(\.inkFitDegraded))")
        #expect(InkTokenCache.shared.value(for: key)?.isEmpty == false, "a later search read the page")
    }
}
