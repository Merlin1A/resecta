import Testing
import Foundation
import PDFKit
import CoreText
@testable import RedactionEngine

// The ink fit's waits (`PageImageInkFitTests`): a stalled read or render, a
// cancelled search, and the main thread, each bounded; a stalled Vision lane
// in a suite of its own (`PageImageInkFitStallTests`, below).

extension PageImageInkFitTests {
    /// A mark of a test's own in a blank corner of every page, so each page
    /// of its export (one with none of the redacted words too) has a
    /// content key of its own.
    static func markEveryPage(_ regions: inout [Int: [RedactionRegion]], of source: PDFDocument, at mark: CGRect) {
        for index in 0..<source.pageCount {
            regions[index, default: []].append(RedactionRegion(id: UUID(), normalizedRect: mark, source: .manual))
        }
    }

    /// The export's page content keys share none with the shared re-imported
    /// export's: a stall set on them reaches no other test.
    static func requireOwnKeys(_ export: PDFDocument) async throws {
        let shared = try HybridDedupTests.pageKeys(try await reimportedExport().export)
        try #require(Set(try HybridDedupTests.pageKeys(export)).isDisjoint(with: shared),
                     "a stalled page shares its key with the shared re-imported export")
    }
    @Test("A page read that stalls past the timeout falls back to the safe box in time, uncached")
    func stalledReadFallsBackInTime() async throws {
        // An export of this test's own (one more word redacted, and a corner mark
        // on every page), so its page content keys are no other test's.
        let data = try TestFixtures.sampleStatementPDF()
        let source = try #require(PDFDocument(data: data))
        var regions: [Int: [RedactionRegion]] = [:]
        for hit in await Self.hits(source, "Sample", includeOCR: false) + (await Self.hits(source, "Statement", includeOCR: false)) {
            regions[hit.pageIndex, default: []].append(
                RedactionRegion(id: UUID(), normalizedRect: hit.normalizedRect, source: .manual))
        }
        Self.markEveryPage(&regions, of: source, at: CGRect(x: 0.021, y: 0.011, width: 0.013, height: 0.008))
        let url = try await TestPipeline.processAndExport(data, mode: .searchableRedaction, regions: regions, dpi: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        let export = try #require(PDFDocument(data: try Data(contentsOf: url)))
        try await Self.requireOwnKeys(export)
        let page = try #require(export.page(at: 2))
        let sourcePage = try #require(source.page(at: 2))
        let cgPage = try #require(page.pageRef)
        let size = page.bounds(for: .cropBox).size
        let key = InkTokenCache.key(page: page, cgPage: cgPage, visual: size)
        DocumentSearcher.inkFitInjectedStalls.set((3.0, 0.5), for: key)
        defer { DocumentSearcher.inkFitInjectedStalls.set(nil, for: key) }
        let range = ((page.string ?? "") as NSString).range(of: "Hartwell")
        let selection = try #require(page.selection(for: range))
        let raw = try #require(DocumentSearcher().normalizedRect(for: selection, page: page))
        // The private copy opened once ahead (its cost is the document's, paid
        // on the first ask of a session), then the read awaited (as a search
        // awaits it) stalls; the fit after it does not read again.
        _ = PrivatePDFCopies.shared.copy(of: export)
        let started = Date()
        await DocumentSearcher.prepareInkFit(page)
        let rect = DocumentSearcher.inkFittedRect(raw, page: page, text: "Hartwell", range: range)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 2.5, "the read and fit waited \(elapsed) s for a stalled read; the wait is 0.5 s")
        #expect(rect.contains(raw), "the fallback covers the selection box")
        #expect(InkTokenCache.shared.value(for: key) == nil, "a stalled read leaves nothing cached")
        // The fallback is the drift envelope: the word's ink lies inside it.
        let sourceRange = ((sourcePage.string ?? "") as NSString).range(of: "Hartwell")
        let truth = try #require(sourcePage.selection(for: sourceRange).flatMap { DocumentSearcher().normalizedRect(for: $0, page: sourcePage) })
        let outside = try Self.inkOutside(page, word: Self.points(truth, size), boxes: [Self.points(rect, size)])
        #expect(outside.share == 0, "the stalled word's ink outside the fallback: \(outside.share * 100)%")
    }

    @Test("A render that stalls after the page was read gives the read word's box on its line, degraded")
    func stalledRenderFallsBackToTheEnvelope() async throws {
        // An export of this test's own (two more words redacted, and a corner mark
        // on every page), so its page content keys are no other test's.
        let data = try TestFixtures.sampleStatementPDF()
        let source = try #require(PDFDocument(data: data))
        var regions: [Int: [RedactionRegion]] = [:]
        for hit in await Self.hits(source, "Statement", includeOCR: false) + (await Self.hits(source, "Deposits", includeOCR: false)) {
            regions[hit.pageIndex, default: []].append(
                RedactionRegion(id: UUID(), normalizedRect: hit.normalizedRect, source: .manual))
        }
        Self.markEveryPage(&regions, of: source, at: CGRect(x: 0.022, y: 0.014, width: 0.012, height: 0.007))
        let url = try await TestPipeline.processAndExport(data, mode: .searchableRedaction, regions: regions, dpi: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        let export = try #require(PDFDocument(data: try Data(contentsOf: url)))
        try await Self.requireOwnKeys(export)
        let page = try #require(export.page(at: 2))
        let sourcePage = try #require(source.page(at: 2))
        let cgPage = try #require(page.pageRef)
        let size = page.bounds(for: .cropBox).size
        let key = InkTokenCache.key(page: page, cgPage: cgPage, visual: size)
        // The page is read first, unstalled; then its renders stall.
        await DocumentSearcher.prepareInkFit(page)
        #expect(InkTokenCache.shared.value(for: key)?.isEmpty == false, "the page reads")
        DocumentSearcher.inkFitInjectedRenderStalls.set((3.0, 0.5), for: key)
        defer { DocumentSearcher.inkFitInjectedRenderStalls.set(nil, for: key) }
        let range = ((page.string ?? "") as NSString).range(of: "Hartwell")
        let selection = try #require(page.selection(for: range))
        let raw = try #require(DocumentSearcher().normalizedRect(for: selection, page: page))
        let started = Date()
        let fit = DocumentSearcher.inkFit(raw, page: page, text: "Hartwell", range: range, paintOnly: true)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 2.5, "the fit waited \(elapsed) s for a stalled render; the wait is 0.5 s")
        #expect(fit.degraded, "a fit without its render is degraded")
        let sourceRange = ((sourcePage.string ?? "") as NSString).range(of: "Hartwell")
        let truth = try #require(sourcePage.selection(for: sourceRange).flatMap { DocumentSearcher().normalizedRect(for: $0, page: sourcePage) })
        let outside = try Self.inkOutside(page, word: Self.points(truth, size), boxes: [Self.points(fit.rect, size)])
        #expect(outside.share == 0, "the word's ink outside the fallback: \(outside.share * 100)%")
        // The word was read and placed, only its render is missing: the
        // fallback is the read word's own box on its line's band, degraded,
        // not an envelope across its neighbours.
        let width = fit.rect.width * size.width, rawWidth = Self.points(raw, size).width
        #expect(width <= rawWidth + 20, "the fallback (\(width) pt) is the read word's box, not an envelope (selection \(rawWidth) pt)")
    }

    @Test("A search cancelled while its gated page's read is outstanding returns at once, not after the read's wait")
    func cancelledSearchReturnsPromptly() async throws {
        let data = try TestFixtures.sampleStatementPDF()
        // An export of this test's own (a mark in a blank corner of page 1).
        let mark = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.012, y: 0.013, width: 0.021, height: 0.007), source: .manual)
        let url = try await TestPipeline.processAndExport(data, mode: .searchableRedaction, regions: [0: [mark]], dpi: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        let shared = SendablePDFDocument(try #require(PDFDocument(data: try Data(contentsOf: url))))
        let page = try #require(shared.document.page(at: 0)), cgPage = try #require(page.pageRef)
        let key = InkTokenCache.key(page: page, cgPage: cgPage, visual: page.bounds(for: .cropBox).size)
        DocumentSearcher.inkFitInjectedStalls.set((12.0, 12.0), for: key)
        defer { DocumentSearcher.inkFitInjectedStalls.set(nil, for: key) }
        let search = Task {
            var count = 0
            for await _ in DocumentSearcher().search(shared, mode: .text("delia", options: SearchOptions()), progress: { _, _ in }) { count += 1 }
            return count
        }
        try await Task.sleep(for: .milliseconds(300))
        let cancelled = Date()
        search.cancel()
        _ = await search.value
        let waited = Date().timeIntervalSince(cancelled)
        // Before the stalled read's 12 s wait would have ended (not waited out).
        #expect(waited < 12, "the cancelled search took \(waited) s to return; the stalled read waits 12 s")
    }

    @Test("A main-thread ask never waits on the ink-fit queue, even with a read stalled")
    func mainThreadNeverWaits() async throws {
        let data = try TestFixtures.sampleStatementPDF()
        let source = try #require(PDFDocument(data: data))
        var regions: [Int: [RedactionRegion]] = [:]
        for hit in await Self.hits(source, "Sample", includeOCR: false) + (await Self.hits(source, "Deposits", includeOCR: false)) {
            regions[hit.pageIndex, default: []].append(
                RedactionRegion(id: UUID(), normalizedRect: hit.normalizedRect, source: .manual))
        }
        Self.markEveryPage(&regions, of: source, at: CGRect(x: 0.018, y: 0.015, width: 0.016, height: 0.006))
        let url = try await TestPipeline.processAndExport(data, mode: .searchableRedaction, regions: regions, dpi: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        let shared = SendablePDFDocument(try #require(PDFDocument(data: try Data(contentsOf: url))))
        try await Self.requireOwnKeys(shared.document)
        let page = try #require(shared.document.page(at: 1))
        let cgPage = try #require(page.pageRef)
        let key = InkTokenCache.key(page: page, cgPage: cgPage, visual: page.bounds(for: .cropBox).size)
        DocumentSearcher.inkFitInjectedStalls.set((3.0, 0.5), for: key)
        defer { DocumentSearcher.inkFitInjectedStalls.set(nil, for: key) }
        // The private copy for the background fit, opened once ahead (its cost
        // is the document's, paid on the first ask of a session).
        _ = PrivatePDFCopies.shared.copy(of: shared.document)
        let elapsed: TimeInterval = await MainActor.run {
            let range = ((shared.document.page(at: 1)?.string ?? "") as NSString).range(of: "Hartwell")
            let started = Date()
            _ = shared.document.page(at: 1).flatMap { DocumentSearcher().boundingRect(for: range, page: $0) }
            return Date().timeIntervalSince(started)
        }
        #expect(elapsed < 0.05, "a main-thread ask took \(elapsed * 1000) ms with the queue stalled")
    }

    @Test("With the render stalled, a word cut from a longer token by character share keeps a character's margin: DELIA's ink is held")
    func stalledRenderShareCutHoldsTheWord() async throws {
        // An export of this test's own (a mark in a blank corner of page 1),
        // so the stall reaches no other test's pages.
        let data = try TestFixtures.sampleStatementPDF()
        let source = try #require(PDFDocument(data: data))
        var regions: [Int: [RedactionRegion]] = [:]
        for hit in await Self.hits(source, "Sample", includeOCR: false) {
            regions[hit.pageIndex, default: []].append(RedactionRegion(id: UUID(), normalizedRect: hit.normalizedRect, source: .manual))
        }
        regions[0, default: []].append(RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.014, y: 0.011, width: 0.018, height: 0.009), source: .manual))
        let url = try await TestPipeline.processAndExport(data, mode: .searchableRedaction, regions: regions, dpi: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        let export = try #require(PDFDocument(data: try Data(contentsOf: url)))
        let page = try #require(export.page(at: 0)), sourcePage = try #require(source.page(at: 0))
        let cgPage = try #require(page.pageRef)
        let size = page.bounds(for: .cropBox).size
        // Read first; then the page's renders stall (the fit's render and its glyph runs).
        await DocumentSearcher.prepareInkFit(page)
        let key = InkTokenCache.key(page: page, cgPage: cgPage, visual: size)
        DocumentSearcher.inkFitInjectedRenderStalls.set((2.0, 0.3), for: key)
        defer { DocumentSearcher.inkFitInjectedRenderStalls.set(nil, for: key) }
        let text = (page.string ?? "") as NSString, sourceText = (sourcePage.string ?? "") as NSString
        let token = text.range(of: "INDN:DELIA"), sourceToken = sourceText.range(of: "INDN:DELIA")
        try #require(token.location != NSNotFound && sourceToken.location != NSNotFound)
        let range = NSRange(location: token.location + 5, length: 5)
        let raw = try #require(page.selection(for: range).flatMap { DocumentSearcher().normalizedRect(for: $0, page: page) })
        let truth = try #require(sourcePage.selection(for: NSRange(location: sourceToken.location + 5, length: 5))
            .flatMap { DocumentSearcher().normalizedRect(for: $0, page: sourcePage) })
        let fit = DocumentSearcher.inkFit(raw, page: page, text: "DELIA", range: range, paintOnly: true)
        #expect(fit.degraded, "a fit without its render is degraded")
        let outside = try Self.inkOutside(page, word: Self.points(truth, size), boxes: [Self.points(fit.rect, size)])
        #expect(outside.share == 0, "DELIA's ink outside its box with the render stalled: \(outside.share * 100)%, up to \(outside.reach) pt")
    }

    @Test("On a page whose fit degraded, the main thread's live preview shows the box the search returned, not the selection")
    func previewShowsTheDegradedBox() async throws {
        // An export of this test's own (a mark in a blank corner of page 1).
        let data = try TestFixtures.sampleStatementPDF()
        let mark = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.016, y: 0.012, width: 0.017, height: 0.008), source: .manual)
        let url = try await TestPipeline.processAndExport(data, mode: .searchableRedaction, regions: [0: [mark]], dpi: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        let shared = SendablePDFDocument(try #require(PDFDocument(data: try Data(contentsOf: url))))
        let page = try #require(shared.document.page(at: 0)), cgPage = try #require(page.pageRef)
        let size = page.bounds(for: .cropBox).size
        await DocumentSearcher.prepareInkFit(page)
        let key = InkTokenCache.key(page: page, cgPage: cgPage, visual: size)
        DocumentSearcher.inkFitInjectedRenderStalls.set((2.0, 0.3), for: key)
        defer { DocumentSearcher.inkFitInjectedRenderStalls.set(nil, for: key) }
        let range = ((page.string ?? "") as NSString).range(of: "Hartwell")
        let raw = try #require(page.selection(for: range).flatMap { DocumentSearcher().normalizedRect(for: $0, page: page) })
        // The search's fit (off the main thread) degrades: its render stalls.
        let searched = DocumentSearcher.inkFit(raw, page: page, text: "Hartwell", range: range)
        #expect(searched.degraded, "the stalled render degrades the fit")
        #expect(searched.rect != raw, "the degraded box is not the selection")
        // The live preview on the main thread shows that same box.
        let shown: CGRect = await MainActor.run {
            guard let p = shared.document.page(at: 0) else { return .null }
            return DocumentSearcher.inkFittedRect(raw, page: p, text: "Hartwell", range: range)
        }
        #expect(shown == searched.rect, "the preview shows \(shown), the search returned \(searched.rect)")
    }
}

/// The Vision lane's stall pin, on a suite of its own: the batched runner
/// runs it completely alone after its batches, still gating
/// (`Scripts/test-batched.sh`), so no neighbour's reads, renders or fits
/// share the process while page A's hold is timed. The hold is timed from
/// page A's stalled read at the lane's head, observed after the stall was
/// set, to the read's answer to its caller; page B is sent once A's read is
/// seen at the head, not after a fixed delay.
@Suite("Page-image ink fit: a stalled Vision lane", .tags(.search))
struct PageImageInkFitStallTests {
    /// Narrower than any drift envelope (the selection grown 32 pt each side).
    static let inkFitEnvelopeSlack: CGFloat = 32

    /// Set once a task has returned.
    final class Done: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        var isSet: Bool { lock.withLock { done } }
        func set() { lock.withLock { done = true } }
    }

    struct Fit: Sendable {
        let rect: CGRect, degraded: Bool, raw: CGRect
        /// When the fit began, when its read answered (the awaited read
        /// returned to its caller), and when the fit returned.
        let started: Date, answered: Date, ended: Date
    }

    @Test("A page read that stalls on the Vision lane degrades only its own page: another page reads off the stalled lane and fits, not degraded")
    func stallOnOnePageLeavesOthersFitted() async throws {
        // An export of this test's own: a small mark in a blank corner of
        // both pages makes their content keys no other test's, so the
        // injected stall reaches no other test's jobs.
        let data = try TestFixtures.sampleStatementPDF()
        let source = try #require(PDFDocument(data: data))
        var regions: [Int: [RedactionRegion]] = [:]
        for index in [1, 2] {
            regions[index] = [RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.011, y: 0.012, width: 0.017, height: 0.009),
                                              source: .manual)]
        }
        let url = try await TestPipeline.processAndExport(data, mode: .searchableRedaction, regions: regions, dpi: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        let exported = try Data(contentsOf: url)
        // Each page on a document of its own, so the two fits share no PDF objects.
        let stalled = SendablePDFDocument(try #require(PDFDocument(data: exported)))
        let other = SendablePDFDocument(try #require(PDFDocument(data: exported)))
        let pageA = try #require(stalled.document.page(at: 1)), cgA = try #require(pageA.pageRef)
        let keyA = InkTokenCache.key(page: pageA, cgPage: cgA, visual: pageA.bounds(for: .cropBox).size)
        // A stall far longer than any queue wait in a busy test run: both
        // fits returning well inside it shows that neither waited it out.
        let stall: TimeInterval = 30, limit: TimeInterval = 0.5
        DocumentSearcher.inkFitInjectedLaneStalls.set((stall, limit), for: keyA)
        defer { DocumentSearcher.inkFitInjectedLaneStalls.set(nil, for: keyA) }
        // Every Vision job for page A from here on is the stall: a read of
        // A's at a lane's head after this instant is a stalled one.
        let armed = Date()
        @Sendable func fit(_ shared: SendablePDFDocument, _ index: Int) async -> Fit? {
            guard let page = shared.document.page(at: index) else { return nil }
            let range = ((page.string ?? "") as NSString).range(of: "Hartwell")
            guard let raw = page.selection(for: range).flatMap({ DocumentSearcher().normalizedRect(for: $0, page: page) }) else { return nil }
            let started = Date()
            // Read as a search reads it (awaited), then fitted.
            await DocumentSearcher.prepareInkFit(page)
            let answered = Date()
            let fit = DocumentSearcher.inkFit(raw, page: page, text: "Hartwell", range: range, paintOnly: true)
            return Fit(rect: fit.rect, degraded: fit.degraded, raw: raw, started: started, answered: answered, ended: Date())
        }
        func stalledHead() -> Date? { InkFitLaneTimes.shared.began(keyA).flatMap { $0 > armed ? $0 : nil } }
        // Page A's read takes the Vision lane and stalls there; page B's
        // read is sent once A's is seen at the lane's head, so it is sent
        // while A's stall holds that lane.
        let aDone = Done()
        let a = Task.detached { () -> Fit? in defer { aDone.set() }; return await fit(stalled, 1) }
        var seen: Date?
        while seen == nil, !aDone.isSet, Date().timeIntervalSince(armed) < DocumentSearcher.inkFitReadBackstop {
            if stalledHead() != nil { seen = Date() } else { try await Task.sleep(for: .milliseconds(5)) }
        }
        let b = try #require(await Task.detached { await fit(other, 2) }.value)
        let aResult = try #require(await a.value)
        #expect(aResult.degraded, "the stalled page's fit is degraded")
        #expect(!b.degraded, "the other page's fit is not degraded by page A's stall")
        let page = try #require(other.document.page(at: 2))
        let size = page.bounds(for: .cropBox).size
        let sourcePage = try #require(source.page(at: 2))
        let sourceRange = ((sourcePage.string ?? "") as NSString).range(of: "Hartwell")
        let truth = try #require(sourcePage.selection(for: sourceRange).flatMap { DocumentSearcher().normalizedRect(for: $0, page: sourcePage) })
        let outside = try PageImageInkFitTests.inkOutside(page, word: PageImageInkFitTests.points(truth, size),
                                                          boxes: [PageImageInkFitTests.points(b.rect, size)])
        #expect(outside.share == 0, "the other page's word ink outside its fit: \(outside.share * 100)%")
        #expect(b.rect.width * size.width < PageImageInkFitTests.points(b.raw, size).width + Self.inkFitEnvelopeSlack,
                "the other page's box is a fit, not the drift envelope")
        // The hold is judged only from a stalled read of A's seen at a
        // lane's head; a run whose lanes answered A at once (no head) has
        // no hold to time.
        guard let aBegan = stalledHead() else {
            try Test.cancel("page A's read never reached a Vision lane's head after the stall was set, so no hold was timed")
        }
        // Measured from page A's turn at the lane's head (time queued behind
        // other reads is a busy run's, not the stall's) to the read's answer
        // (the fit after it is the page's own work, not the stall's): A is
        // released within its 0.5 s limit (and a second's slack), while its
        // stall still holds the lane.
        let aHeld = aResult.answered.timeIntervalSince(aBegan)
        let retired = InkFitLaneTimes.shared.retired(keyA)
        print("stall pin: A queued \(aBegan.timeIntervalSince(aResult.started)) s, held \(aHeld) s at the head "
              + "(seen \(seen.map { $0.timeIntervalSince(aBegan) } ?? -1) s after it, lane retired \(retired.map { $0.timeIntervalSince(aBegan) } ?? -1) s after it), "
              + "fit \(aResult.ended.timeIntervalSince(aResult.answered)) s; B took \(b.ended.timeIntervalSince(b.started)) s, "
              + "\(retired.map { b.ended.timeIntervalSince($0) } ?? -1) s after A's retirement")
        #expect(aHeld >= 0, "page A's read reached the head \(-aHeld) s after it answered")
        #expect(aHeld < 1.5, "the stalled page's read was held \(aHeld) s after it reached the head; its limit is \(limit) s, its stall \(stall) s")
        // Its lane was retired under it (by its own wait or by a read
        // queued behind it; the seam keeps the latest).
        #expect(retired.map { $0 >= aBegan } == true, "the stalled read's lane was retired under it (retired \(String(describing: retired)))")
        // B's read is not run behind A's stall: it ran on another lane, or
        // ahead of A on A's. How long B queues behind other reads is a busy
        // run's, so no time is judged.
        let pageB = try #require(other.document.page(at: 2)), cgB = try #require(pageB.pageRef)
        let keyB = InkTokenCache.key(page: pageB, cgPage: cgB, visual: pageB.bounds(for: .cropBox).size)
        let aLane = try #require(InkFitLaneTimes.shared.lane(keyA)), bLane = try #require(InkFitLaneTimes.shared.lane(keyB), "page B's read reached a lane's head")
        let bBegan = try #require(InkFitLaneTimes.shared.began(keyB))
        #expect(bLane != aLane || bBegan < aBegan, "page B's read ran on page A's stalled lane, behind its stall")
    }
}
