import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The ink fit's page reads (`InkFitPendingRead.run`): a stalled read at the
// Vision lane's head is retired at its limit and the next one runs; searches
// of one page share its read; pages of other content never do; and a search
// cancelled while its read is queued returns at once.

@Suite("Ink fit: page reads")
struct InkFitReadJoinTests {
    @Test("A read stalled at the head of a Vision lane is retired at its limit, and the read queued behind it runs")
    func stalledHeadRetiresAndTheNextReadRuns() async throws {
        // A lane of this test's own, so no other read waits behind the stall.
        let state = InkFitQueueState(label: "test-retire")
        let stalledKey = Int.random(in: 1...Int.max), nextKey = Int.random(in: 1...Int.max)
        let stalled = OCRLegConcurrencyTests.ResultBox(), next = OCRLegConcurrencyTests.ResultBox()
        let started = Date()
        // Off the task pool, as the reads run (`InkFitReadThreads`).
        Thread {
            let value = DocumentSearcher.onInkFitQueue(key: stalledKey, timeout: 0.3, state: state) { () -> Int in
                Thread.sleep(forTimeInterval: 4); return 1
            }
            stalled.add(value == nil ? Int(Date().timeIntervalSince(started) * 1000) : -1)
        }.start()
        try await Task.sleep(for: .milliseconds(100))
        Thread {
            let value = DocumentSearcher.onInkFitQueue(key: nextKey, state: state) { 2 }
            next.add(value == 2 ? Int(Date().timeIntervalSince(started) * 1000) : -1)
        }.start()
        let deadline = Date().addingTimeInterval(10)
        while (stalled.count == 0 || next.count == 0), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(stalled.count == 1 && stalled.hits >= 0 && stalled.hits < 2000,
                "the stalled read returned nil at its 0.3 s limit, not after its 4 s stall: \(stalled.hits) ms")
        #expect(next.count == 1 && next.hits >= 0 && next.hits < 2000,
                "the read behind it ran on a fresh lane, not after the stall: \(next.hits) ms")
    }

    @Test("A read's time limit counts from when it reaches the head of the lane, not from when it was queued")
    func limitCountsFromTheHead() async throws {
        let state = InkFitQueueState(label: "test-head")
        let ahead = OCRLegConcurrencyTests.ResultBox(), behind = OCRLegConcurrencyTests.ResultBox()
        // A read that moves (1.2 s, within its 3 s limit) at the head; one
        // behind it with a 0.5 s limit, queued longer than that.
        Thread {
            let value = DocumentSearcher.onInkFitQueue(key: Int.random(in: 1...Int.max), timeout: 3, state: state) { () -> Int in
                Thread.sleep(forTimeInterval: 1.2); return 1
            }
            ahead.add(value ?? -1)
        }.start()
        try await Task.sleep(for: .milliseconds(100))
        Thread {
            behind.add(DocumentSearcher.onInkFitQueue(key: Int.random(in: 1...Int.max), timeout: 0.5, state: state) { 2 } ?? -1)
        }.start()
        let deadline = Date().addingTimeInterval(10)
        while (ahead.count == 0 || behind.count == 0), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(ahead.hits == 1, "the read at the head finished")
        #expect(behind.hits == 2, "the read queued past its own limit still ran once at the head")
        // The search's backstop sits above the read's own bounds.
        #expect(DocumentSearcher.inkFitReadBackstop >= DocumentSearcher.inkFitTimeout * 2 + DocumentSearcher.inkFitWaitCeiling)
    }

    @Test("With every read thread held by a draw that has not returned, a new read is refused at once; once one returns, reads run")
    func hungDrawsOnEveryThreadRefuseNewReads() async throws {
        // Threads of this test's own (two, a draw judged hung past 0.3 s), so
        // no other test's reads wait behind the held ones.
        let threads = InkFitReadThreads(count: 2, hungAfter: 0.3)
        let ran = OCRLegConcurrencyTests.ResultBox()
        for _ in 0..<2 {
            #expect(threads.submit { threads.drawing { Thread.sleep(forTimeInterval: 3) } })
        }
        try await Task.sleep(for: .milliseconds(700))
        let asked = Date()
        #expect(!threads.submit { ran.add(1) }, "a read was queued behind two hung draws")
        #expect(Date().timeIntervalSince(asked) < 0.1, "the refusal waited")
        // A thread held by a draw that ends takes reads again.
        let deadline = Date().addingTimeInterval(10)
        var accepted = false
        while !accepted, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
            accepted = threads.submit { ran.add(1) }
        }
        #expect(accepted, "reads were still refused after the draws returned")
        while ran.count == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(ran.count == 1, "the accepted read ran")
    }

    @Test("Searches of one page at once take one read of it, and each fits from it")
    func concurrentSearchesOfOnePageShareOneRead() async throws {
        let data = try await InkFitBusyPoolTests.export(mark: CGRect(x: 0.024, y: 0.012, width: 0.011, height: 0.008))
        let first = try #require(PDFDocument(data: data)?.page(at: 0))
        let key = InkTokenCache.key(page: first, cgPage: try #require(first.pageRef), visual: first.bounds(for: .cropBox).size)
        try #require(InkTokenCache.shared.value(for: key) == nil, "the page is this test's own")
        let count = 6
        let found = OCRLegConcurrencyTests.ResultBox()
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<count {
                group.addTask {
                    // A document of each search's own (one page content).
                    guard let doc = PDFDocument(data: data) else { return -1 }
                    let results = await InkFitBusyPoolTests.search(doc, .text("delia", options: InkFitBusyPoolTests.layerOnly))
                    return results.filter { $0.pageIndex == 0 && !$0.inkFitDegraded }.count
                }
            }
            for await fitted in group { found.add(fitted) }
        }
        #expect(InkFitReadJoin.shared.startedCount(key) == 1, "\(count) searches of the page started \(InkFitReadJoin.shared.startedCount(key)) reads")
        #expect(InkTokenCache.shared.value(for: key)?.isEmpty == false, "the shared read was cached")
        let single = await InkFitBusyPoolTests.search(try #require(PDFDocument(data: data)), .text("delia", options: InkFitBusyPoolTests.layerOnly))
            .filter { $0.pageIndex == 0 && !$0.inkFitDegraded }.count
        #expect(found.hits == single * count, "every search fits the page from the shared read: \(found.hits) of \(single * count)")
    }

    @Test("Pages of other content read at once never share a read: each page's tokens are its own")
    func otherContentIsNeverJoined() async throws {
        // The documents held (a page keeps its document weakly; the read draws a copy of it).
        let shadedDoc = try #require(PDFDocument(data: try PageImageInkFitTests.shadedPagePDF(hidden: true)))
        let interleavedDoc = try #require(PDFDocument(data: try InkFitInterleaveTests.pagePDF(hidden: true)))
        let shaded = try #require(shadedDoc.page(at: 0)), interleaved = try #require(interleavedDoc.page(at: 0))
        func key(_ page: PDFPage) throws -> Int {
            InkTokenCache.key(page: page, cgPage: try #require(page.pageRef), visual: page.bounds(for: .cropBox).size)
        }
        let shadedKey = try key(shaded), interleavedKey = try key(interleaved)
        try #require(shadedKey != interleavedKey)
        let a = SendablePDFPage(shaded), b = SendablePDFPage(interleaved)
        async let one: Void = DocumentSearcher.prepareInkFit(a.page)
        async let two: Void = DocumentSearcher.prepareInkFit(b.page)
        _ = await (one, two)
        withExtendedLifetime((shadedDoc, interleavedDoc)) {}
        let shadedText = InkTokenCache.shared.value(for: shadedKey)?.map(\.raw).joined(separator: " ") ?? ""
        let interleavedText = InkTokenCache.shared.value(for: interleavedKey)?.map(\.raw).joined(separator: " ") ?? ""
        #expect(shadedText.contains("Account") && !shadedText.contains("Wages"), "the shaded page's tokens are its own: \(shadedText)")
        #expect(interleavedText.contains("Wages") && !interleavedText.contains("Account"),
                "the interleaved page's tokens are its own: \(interleavedText)")
    }

    @Test("A search cancelled while its page read is queued behind another returns at once")
    func cancelWhileQueuedReturnsPromptly() async throws {
        // Page A's read holds the Vision lane's head for 2.5 s (within its
        // 3 s limit: a head that moves, never retired, so it leaves no hung
        // lane behind for other tests' reads); page B's search queues its read
        // behind it and is cancelled.
        let dataA = try await InkFitBusyPoolTests.export(mark: CGRect(x: 0.025, y: 0.013, width: 0.010, height: 0.007))
        let dataB = try await InkFitBusyPoolTests.export(mark: CGRect(x: 0.026, y: 0.011, width: 0.009, height: 0.008))
        let docA = try #require(PDFDocument(data: dataA)), pageA = try #require(docA.page(at: 0))
        let keyA = InkTokenCache.key(page: pageA, cgPage: try #require(pageA.pageRef), visual: pageA.bounds(for: .cropBox).size)
        DocumentSearcher.inkFitInjectedLaneStalls.set((2.5, 3.0), for: keyA)
        defer { DocumentSearcher.inkFitInjectedLaneStalls.set(nil, for: keyA) }
        let holder = SendablePDFPage(pageA)
        let hold = Task { await DocumentSearcher.prepareInkFit(holder.page) }
        try await Task.sleep(for: .milliseconds(300))
        let docB = SendablePDFDocument(try #require(PDFDocument(data: dataB)))
        let search = Task {
            var n = 0
            for await _ in DocumentSearcher().search(docB, mode: .text("delia", options: InkFitBusyPoolTests.layerOnly), progress: { _, _ in }) { n += 1 }
            return n
        }
        try await Task.sleep(for: .milliseconds(500))
        let cancelled = ContinuousClock.now
        search.cancel()
        _ = await search.value
        let waited = ContinuousClock.now - cancelled
        #expect(waited < .seconds(2), "the search cancelled while its read was queued took \(waited) to return")
        await hold.value
        #expect(InkFitReadJoin.shared.startedCount(keyA) == 1, "page A's read held the lane (it was started)")
        withExtendedLifetime(docA) {}
    }
}
