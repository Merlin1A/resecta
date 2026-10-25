import Testing
import Foundation
import PDFKit
import CoreText
@testable import RedactionEngine

// The ink fit's waits (`PageImageInkFitTests`): a stalled read, render or
// lane, a cancelled search, and the main thread, each bounded.

extension PageImageInkFitTests {
    @Test("A page read that stalls past the timeout falls back to the safe box in time, uncached")
    func stalledReadFallsBackInTime() async throws {
        // An export of this test's own (one more word redacted), so its page
        // content key is no other test's.
        let data = try TestFixtures.sampleStatementPDF()
        let source = try #require(PDFDocument(data: data))
        var regions: [Int: [RedactionRegion]] = [:]
        for hit in await Self.hits(source, "Sample", includeOCR: false) + (await Self.hits(source, "Statement", includeOCR: false)) {
            regions[hit.pageIndex, default: []].append(
                RedactionRegion(id: UUID(), normalizedRect: hit.normalizedRect, source: .manual))
        }
        let url = try await TestPipeline.processAndExport(data, mode: .searchableRedaction, regions: regions, dpi: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        let export = try #require(PDFDocument(data: try Data(contentsOf: url)))
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
        let started = Date()
        let rect = DocumentSearcher.inkFittedRect(raw, page: page, text: "Hartwell", range: range)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 2.5, "the fit waited \(elapsed) s for a stalled read; the wait is 0.5 s")
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
        // An export of this test's own (two more words redacted), so its page
        // content key is no other test's.
        let data = try TestFixtures.sampleStatementPDF()
        let source = try #require(PDFDocument(data: data))
        var regions: [Int: [RedactionRegion]] = [:]
        for hit in await Self.hits(source, "Statement", includeOCR: false) + (await Self.hits(source, "Deposits", includeOCR: false)) {
            regions[hit.pageIndex, default: []].append(
                RedactionRegion(id: UUID(), normalizedRect: hit.normalizedRect, source: .manual))
        }
        let url = try await TestPipeline.processAndExport(data, mode: .searchableRedaction, regions: regions, dpi: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        let export = try #require(PDFDocument(data: try Data(contentsOf: url)))
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

    @Test("A job that stalls on the shared lane degrades only its own page: another page fits on time, not degraded")
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
        DocumentSearcher.inkFitInjectedLaneStalls.set((30.0, 0.5), for: keyA)
        defer { DocumentSearcher.inkFitInjectedLaneStalls.set(nil, for: keyA) }
        @Sendable func fit(_ shared: SendablePDFDocument, _ index: Int) -> (rect: CGRect, degraded: Bool, raw: CGRect, seconds: TimeInterval)? {
            guard let page = shared.document.page(at: index) else { return nil }
            let range = ((page.string ?? "") as NSString).range(of: "Hartwell")
            guard let raw = page.selection(for: range).flatMap({ DocumentSearcher().normalizedRect(for: $0, page: page) }) else { return nil }
            let started = Date()
            let fit = DocumentSearcher.inkFit(raw, page: page, text: "Hartwell", range: range, paintOnly: true)
            return (fit.rect, fit.degraded, raw, Date().timeIntervalSince(started))
        }
        // Page A's read takes the lane and stalls there; page B queues behind it.
        let a = Task.detached { fit(stalled, 1) }
        try await Task.sleep(for: .milliseconds(150))
        let b = try #require(await Task.detached { Self.settled({ fit(other, 2) }, degraded: \.degraded) }.value)
        let aResult = try #require(await a.value)
        #expect(aResult.degraded, "the stalled page's fit is degraded")
        #expect(aResult.seconds < 20, "the stalled page's fit waited \(aResult.seconds) s; its limit is 0.5 s, its stall 30 s")
        #expect(!b.degraded, "the other page's fit is not degraded by page A's stall")
        // The hung job's copy is dropped: the stalled document's next fit
        // draws from a copy of its own, not the one still being drawn.
        let before = PrivatePDFCopies.shared.madeCount(of: stalled.document)
        _ = PrivatePDFCopies.shared.copy(of: stalled.document)
        #expect(PrivatePDFCopies.shared.madeCount(of: stalled.document) == before + 1,
                "the stalled document's copy was dropped when its lane was retired")
        #expect(b.seconds < 20, "the other page's fit took \(b.seconds) s, as if it waited out page A's 30 s stall")
        let page = try #require(other.document.page(at: 2))
        let size = page.bounds(for: .cropBox).size
        let sourcePage = try #require(source.page(at: 2))
        let sourceRange = ((sourcePage.string ?? "") as NSString).range(of: "Hartwell")
        let truth = try #require(sourcePage.selection(for: sourceRange).flatMap { DocumentSearcher().normalizedRect(for: $0, page: sourcePage) })
        let outside = try Self.inkOutside(page, word: Self.points(truth, size), boxes: [Self.points(b.rect, size)])
        #expect(outside.share == 0, "the other page's word ink outside its fit: \(outside.share * 100)%")
        #expect(b.rect.width * size.width < Self.points(b.raw, size).width + Self.inkFitEnvelopeSlack,
                "the other page's box is a fit, not the drift envelope")
    }

    /// Narrower than any drift envelope (the selection grown 32 pt each side).
    static let inkFitEnvelopeSlack: CGFloat = 32

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
        #expect(waited < 2, "the cancelled search took \(waited) s to return; the stalled read waits 12 s")
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
        let url = try await TestPipeline.processAndExport(data, mode: .searchableRedaction, regions: regions, dpi: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        let shared = SendablePDFDocument(try #require(PDFDocument(data: try Data(contentsOf: url))))
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
}
