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
        let began = OCRLegConcurrencyTests.ResultBox()
        // The stalled read's work is held until the test has seen both
        // reads return, so each check is an order of events, not a time.
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let started = Date()
        // Off the task pool, as the reads run (`InkFitReadThreads`).
        Thread {
            let value = DocumentSearcher.onInkFitQueue(key: stalledKey, timeout: 0.3, state: state) { () -> Int in
                began.add(1); _ = release.wait(timeout: .now() + 120); return 1
            }
            stalled.add(value == nil ? Int(Date().timeIntervalSince(started) * 1000) : -1)
        }.start()
        let deadline = Date().addingTimeInterval(60)
        while began.count == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(began.count == 1, "the stalled read reached the head")
        Thread {
            let value = DocumentSearcher.onInkFitQueue(key: nextKey, state: state) { 2 }
            next.add(value == 2 ? 1 : -1)
        }.start()
        let returned = Date().addingTimeInterval(60)
        while (stalled.count == 0 || next.count == 0), Date() < returned { try await Task.sleep(for: .milliseconds(50)) }
        // Both returned while the stalled read's work was still held.
        #expect(stalled.count == 1 && stalled.hits >= 300,
                "the stalled read returned nil at its 0.3 s limit, its work still held: \(stalled.hits) ms")
        #expect(next.count == 1 && next.hits == 1, "the read behind it ran on a fresh lane while the stall still held the old one")
    }

    @Test("A read moved off a retired lane, whose copy left on the old lane runs there first, is given up at its limit")
    func movedReadRunningOnItsOldLaneIsTimed() async throws {
        // Lane 0 holds a head (its limit 5 s) with a read queued behind it
        // (its limit 0.3 s). Lane 0 is retired and the fresh lane is held by
        // another job, so the read, moved at the head's overrun, queues
        // there; once the old head returns, the read's copy left on lane 0
        // runs first. Each job is held until the test releases it.
        let state = InkFitQueueState(label: "test-moved")
        let headKey = Int.random(in: 1...Int.max), readKey = Int.random(in: 1...Int.max), otherKey = Int.random(in: 1...Int.max)
        let holdHead = DispatchSemaphore(value: 0), holdRead = DispatchSemaphore(value: 0), holdOther = DispatchSemaphore(value: 0)
        defer { holdHead.signal(); holdRead.signal(); holdOther.signal() }
        let headBegan = OCRLegConcurrencyTests.ResultBox(), readBegan = OCRLegConcurrencyTests.ResultBox()
        let otherBegan = OCRLegConcurrencyTests.ResultBox(), read = OCRLegConcurrencyTests.ResultBox()
        let readQueued = OCRLegConcurrencyTests.ResultBox(), staged = OCRLegConcurrencyTests.ResultBox()
        // Staged on a thread of its own: a busy run's task pool can resume a
        // sleeping test seconds late, past the head's limit.
        Thread {
            func until(_ done: () -> Bool) { let end = Date().addingTimeInterval(60); while !done(), Date() < end { Thread.sleep(forTimeInterval: 0.01) } }
            Thread {
                _ = DocumentSearcher.onInkFitQueue(key: headKey, timeout: 5, state: state) { () -> Int in
                    headBegan.add(1); _ = holdHead.wait(timeout: .now() + 120); return 1
                }
            }.start()
            until { headBegan.count == 1 }
            let old = state.current
            Thread {
                readQueued.add(1)
                let value = DocumentSearcher.onInkFitQueue(key: readKey, timeout: 0.3, state: state) { () -> Int in
                    readBegan.add(1); _ = holdRead.wait(timeout: .now() + 120); return 2
                }
                read.add(value == nil ? 1 : -1)
            }.start()
            // The read queued on lane 0 (its call enqueues at once), well inside the head's limit.
            until { readQueued.count == 1 }
            Thread.sleep(forTimeInterval: 1)
            state.retire(old, key: headKey)
            Thread {
                _ = DocumentSearcher.onInkFitQueue(key: otherKey, timeout: 60, state: state) { () -> Int in
                    otherBegan.add(1); _ = holdOther.wait(timeout: .now() + 120); return 3
                }
            }.start()
            until { otherBegan.count == 1 }
            // Past the head's 5 s limit the read moves behind the held job; then the head returns.
            until { InkFitLaneTimes.shared.moves(readKey) >= 1 }
            holdHead.signal()
            staged.add(1)
        }.start()
        let stagedDeadline = Date().addingTimeInterval(200)
        while staged.count == 0, Date() < stagedDeadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(headBegan.count == 1, "the head began")
        try #require(otherBegan.count == 1, "the fresh lane is held")
        try #require(InkFitLaneTimes.shared.moves(readKey) >= 1, "the read moved to the fresh lane before the head returned")
        let readDeadline = Date().addingTimeInterval(60)
        while readBegan.count == 0, Date() < readDeadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(readBegan.count == 1, "the read ran")
        let waited = Date().addingTimeInterval(15)
        while read.count == 0, Date() < waited { try await Task.sleep(for: .milliseconds(50)) }
        #expect(read.count == 1 && read.hits == 1, "the read, run on its old lane, was given up at its 0.3 s limit while its work was still held")
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
        // no other test's reads wait behind the held ones. The draws are held
        // until the test releases them, however late a busy run starts them.
        let threads = InkFitReadThreads(count: 2, hungAfter: 0.3)
        let entered = OCRLegConcurrencyTests.ResultBox(), ran = OCRLegConcurrencyTests.ResultBox()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        for _ in 0..<2 {
            #expect(threads.submit { _ = threads.drawing { entered.add(1); _ = release.wait(timeout: .now() + 120) } })
        }
        let deadline = Date().addingTimeInterval(60)
        while entered.count < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(entered.count == 2, "both draws began")
        try await Task.sleep(for: .milliseconds(500))
        // Refused while both draws are still held: it did not wait behind them.
        #expect(!threads.submit { ran.add(1) }, "a read was queued behind two hung draws")
        release.signal(); release.signal()
        // A thread held by a draw that ends takes reads again.
        var accepted = false
        let acceptDeadline = Date().addingTimeInterval(60)
        while !accepted, Date() < acceptDeadline {
            try await Task.sleep(for: .milliseconds(200))
            accepted = threads.submit { ran.add(1) }
        }
        #expect(accepted, "reads were still refused after the draws returned")
        let ranDeadline = Date().addingTimeInterval(60)
        while ran.count == 0, Date() < ranDeadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(ran.count == 1, "the accepted read ran")
    }

    @Test("With every draw slot held by a draw that has not returned, a new read's draw fails at once, though threads are free")
    func hungDrawSlotsFailNewDraws() async throws {
        // Four threads, one draw slot, a draw judged hung past 1 s (a slot
        // wait lasts that long); the draw held until the test releases it.
        let hungAfter = 1.0
        let threads = InkFitReadThreads(count: 4, draws: 1, hungAfter: hungAfter)
        let entered = OCRLegConcurrencyTests.ResultBox(), outcome = OCRLegConcurrencyTests.ResultBox()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        #expect(threads.submit { _ = threads.drawing { entered.add(1); _ = release.wait(timeout: .now() + 120) } })
        let deadline = Date().addingTimeInterval(60)
        while entered.count == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(entered.count == 1, "the draw began")
        try await Task.sleep(for: .seconds(hungAfter + 0.5))
        // Refused, or taken with its draw failing: timed from its own draw
        // call, so a busy run's late thread start is not counted.
        let submitted = threads.submit {
            let asked = Date()
            outcome.add(threads.drawing { 1 } == nil ? Int(Date().timeIntervalSince(asked) * 1000) : -1)
        }
        if submitted {
            let outcomeDeadline = Date().addingTimeInterval(60)
            while outcome.count == 0, Date() < outcomeDeadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(outcome.count == 1 && outcome.hits >= 0 && outcome.hits < Int(hungAfter * 1000),
                    "the second read's draw failed at once, not after its slot wait: \(outcome.hits) ms")
        }
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
