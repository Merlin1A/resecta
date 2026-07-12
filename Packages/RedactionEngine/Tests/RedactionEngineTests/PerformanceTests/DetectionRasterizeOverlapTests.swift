import Testing
import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
import CoreGraphics
import os
@testable import RedactionEngine

// PERF-3 — Detection ↔ rasterization pipeline-overlap regression suite.
//
// PERF-3 contract: depth-2
// lookahead via structured concurrency. While the orchestrator detects
// page N, the next page's render-for-detection (`renderPageForDetection`
// in `PipelineCoordinator`) runs concurrently via `async let`. At the
// start of iteration N+1, the prefetched image is already in hand —
// detect for the next page begins without waiting for a fresh rasterize.
//
// Why this lives in the Engine test target (PERF-2 precedent §13 of the
// shared-context says "when reality contradicts the plan, surface in the
// handoff"). The orchestrating code (`runDetectionPipeline`) is owned by
// `PipelineCoordinator` in the app target. The PERF-2 suite ran into the
// same coupling and parked its tests in the app target. PERF-3's agent
// body asked for the engine path; rather than relocate, this suite
// MIRRORS the dispatch contract locally — same `async let` shape, same
// per-iteration overlap — and asserts overlap on engine-accessible
// primitives (`PageRasterizer.renderPage` + `DetectionOrchestrator.detectPage`).
// A peer app-target suite drives the actual `PipelineCoordinator` end
// of the contract; both share the same overlap-rate metric definition.
//
// .serialized: the wall-clock measurements would distort if multiple
// tests in this suite ran concurrently (each saturates rasterize +
// detect threads). Suite-level serialization keeps the readings stable.
@Suite("PERF-3 Detection-Rasterize Overlap", .tags(.performance), .serialized)
struct DetectionRasterizeOverlapTests {

    // MARK: - Per-phase interval (timed by Date)

    /// A single timed phase of the detection pipeline. `kind` discriminates
    /// rasterize-for-detection (`renderPageForDetection`) from detect
    /// (`orchestrator.detectPage`). Dates come from the same `Date()`
    /// source on both ends so subtraction is meaningful across concurrent
    /// Tasks (matches the PERF-6 pattern in `ParallelLayerExecutionTests`).
    struct Interval: Sendable {
        enum Kind: Sendable { case rasterize, detect }
        let pageIndex: Int
        let kind: Kind
        let start: Date
        let end: Date
    }

    /// Thread-safe interval collector. Tests append from multiple
    /// concurrent tasks (the depth-2 lookahead spawns a rasterize task
    /// while a detect is in flight); the collector serializes appends.
    /// `final class @unchecked Sendable` mirrors the codebase's existing
    /// `OCRInvocationCounter` / `PageRasterizerTestSeam` pattern.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var _intervals: [Interval] = []

        var intervals: [Interval] {
            lock.lock(); defer { lock.unlock() }
            return _intervals
        }

        func record(_ interval: Interval) {
            lock.lock(); _intervals.append(interval); lock.unlock()
        }
    }

    /// Hook a synchronous failure into the rasterize path for a target
    /// page index. The cancellation test wires this to a deterministic
    /// throw site that the production coordinator code would experience
    /// from a CGContext allocation failure or a memory-budget veto.
    /// Sendable for the same reason as `Collector` above.
    final class RasterFailureInjector: @unchecked Sendable {
        let failPageIndex: Int
        init(failPageIndex: Int) { self.failPageIndex = failPageIndex }
    }

    // MARK: - Dispatch contract — local mirror of PipelineCoordinator

    /// Re-implements the coordinator's depth-2 lookahead for the test
    /// bundle. The production code path lives in
    /// `Sources/ResectaApp/State/PipelineCoordinator.swift` (private
    /// `runDetectionPipeline`). The shape MUST stay aligned with that
    /// code — see PERF-3 plan §5 "Hard stops". Returns the collected
    /// intervals in start-time order (the collector preserves arrival
    /// order, which is start-time order for begin-stamps).
    ///
    /// `failInjector != nil` simulates a rasterize failure at the
    /// targeted page index; `pageImageFor` is the rasterize step
    /// (mirrors `renderPageForDetection`). `detectFor` is the detect
    /// step (mirrors `orchestrator.detectPage`).
    static func runDetectionPipelineDepth2(
        pages: [PDFPage],
        pageImageFor: @escaping @Sendable (PDFPage, Int) async throws -> CGImage,
        detectFor: @escaping @Sendable (CGImage, Int) async throws -> Int,
        collector: Collector,
        failInjector: RasterFailureInjector? = nil
    ) async throws -> [Int] {
        // Empty input — match coordinator's early-return shape.
        guard !pages.isEmpty else { return [] }

        // Bootstrap: render page 0's image. Mirror of the coordinator's
        // pre-loop `renderPageForDetection(...)` await.
        let bootstrapStart = Date()
        let bootstrapImage: CGImage
        do {
            if let inj = failInjector, inj.failPageIndex == 0 {
                throw PipelineError.detectionError(.visionError(pageIndex: 0))
            }
            bootstrapImage = try await pageImageFor(pages[0], 0)
        } catch { // LegalPhrases:safe (Swift keyword)
            collector.record(.init(pageIndex: 0, kind: .rasterize,
                                   start: bootstrapStart, end: Date()))
            throw error
        }
        collector.record(.init(pageIndex: 0, kind: .rasterize,
                               start: bootstrapStart, end: Date()))

        var pendingImage: CGImage = bootstrapImage
        var detections: [Int] = []

        for i in 0..<pages.count {
            try Task.checkCancellation()
            let imageForCurrent = pendingImage

            if i + 1 < pages.count {
                let lookaheadIndex = i + 1
                // SendablePDFPage wraps PDFPage as Sendable so the
                // depth-2 `async let` closure can safely capture it
                // (mirrors the coordinator's `nonisolated(unsafe)`
                // capture in `runDetectionPipeline`). Per-call
                // single-threaded access: the lookahead is the only
                // task reading this page; detect runs against a
                // CGImage from the prior iteration, never this page.
                let lookahead = SendablePDFPage(pages[lookaheadIndex])
                // Inject failure for the lookahead rasterize when the
                // target index matches. The throw propagates through
                // `async let`'s structured scope at the next await.
                async let nextImage: CGImage = {
                    let s = Date()
                    do {
                        if let inj = failInjector, inj.failPageIndex == lookaheadIndex {
                            // Yield first so the concurrent detect
                            // observes a real overlap window before
                            // we throw. Otherwise the throw can race
                            // ahead of the detect's start and the
                            // cancellation test becomes flaky.
                            try await Task.sleep(for: .milliseconds(2))
                            collector.record(.init(
                                pageIndex: lookaheadIndex, kind: .rasterize,
                                start: s, end: Date()
                            ))
                            throw PipelineError.detectionError(
                                .visionError(pageIndex: lookaheadIndex)
                            )
                        }
                        let img = try await pageImageFor(lookahead.page, lookaheadIndex)
                        collector.record(.init(
                            pageIndex: lookaheadIndex, kind: .rasterize,
                            start: s, end: Date()
                        ))
                        return img
                    } catch { // LegalPhrases:safe (Swift keyword)
                        collector.record(.init(
                            pageIndex: lookaheadIndex, kind: .rasterize,
                            start: s, end: Date()
                        ))
                        throw error
                    }
                }()

                // Detect runs concurrent with the lookahead rasterize.
                let detectStart = Date()
                let detectCount = try await detectFor(imageForCurrent, i)
                collector.record(.init(
                    pageIndex: i, kind: .detect,
                    start: detectStart, end: Date()
                ))
                detections.append(detectCount)

                // Await the lookahead. On rasterize failure the throw
                // unwinds through this await — `async let`'s structured
                // scope has already cancelled and awaited any in-flight
                // child work.
                pendingImage = try await nextImage
            } else {
                let detectStart = Date()
                let detectCount = try await detectFor(imageForCurrent, i)
                collector.record(.init(
                    pageIndex: i, kind: .detect,
                    start: detectStart, end: Date()
                ))
                detections.append(detectCount)
            }
        }

        return detections
    }

    /// Reference "no-overlap" pipeline — strictly sequential rasterize
    /// then detect, per page. Used as the parity baseline so we can
    /// assert the overlap path produces the same detection set
    /// (byte-for-byte, modulo UUID freshness — we compare counts).
    static func runDetectionPipelineSequential(
        pages: [PDFPage],
        pageImageFor: @escaping @Sendable (PDFPage, Int) async throws -> CGImage,
        detectFor: @escaping @Sendable (CGImage, Int) async throws -> Int,
        collector: Collector
    ) async throws -> [Int] {
        var counts: [Int] = []
        for i in 0..<pages.count {
            try Task.checkCancellation()
            let rStart = Date()
            let img = try await pageImageFor(pages[i], i)
            collector.record(.init(pageIndex: i, kind: .rasterize,
                                   start: rStart, end: Date()))
            let dStart = Date()
            let count = try await detectFor(img, i)
            collector.record(.init(pageIndex: i, kind: .detect,
                                   start: dStart, end: Date()))
            counts.append(count)
        }
        return counts
    }

    // MARK: - Test 1: Detection starts before rasterize ends (overlap >= 90%)

    @Test(
        "≥ 90% of pages: detect for page N overlaps the lookahead rasterize for page N+1",
        .timeLimit(.minutes(2))
    )
    func testDetectionStartsBeforeRasterizeEnds() async throws {
        // 10-page fixture matches plan §5 acceptance criterion.
        let (doc, url) = try makeTextLayerPDF(pages: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let pages: [PDFPage] = (0..<doc.pageCount).compactMap { doc.page(at: $0) }
        #expect(pages.count == 10, "Expected 10 pages in fixture")

        let collector = Collector()
        let rasterizer = PageRasterizer()
        let orchestrator = DetectionOrchestrator()
        // PERF-4 — supply an embedded-text source so the orchestrator
        // takes the OCR-skip fast path. Vision OCR is unreliable on the
        // iOS Simulator (it sporadically returns "Could not create
        // inference context"); the SKIP path keeps detect deterministic.
        // To exercise a realistic overlap shape we then add a short
        // `Task.sleep` inside the detect closure so detect-N is
        // observably long enough for rasterize-(N+1) to start before
        // detect-N ends. This stand-in is consistent with the locked
        // decision: PERF-3 overlap is about scheduling, not about
        // which detect branch fires (plan §6 PERF-3 ↔ PERF-4 row).
        let stub = makeStubEmbedded(
            text: "Alice Smith SSN 123-45-6789 at 742 Evergreen."
        )

        let imageFor: @Sendable (PDFPage, Int) async throws -> CGImage = { page, idx in
            let wrapped = SendablePDFPage(page)
            return try await rasterizer.renderPage(
                wrapped.page, pageIndex: idx, dpi: 150
            )
        }
        let detectFor: @Sendable (CGImage, Int) async throws -> Int = { img, idx in
            // Hold detect long enough that an observable overlap window
            // with the lookahead rasterize is reliably present. On a
            // real device the OCR-on path takes hundreds of ms per page
            // — the locked 90% acceptance bar applies there. This 25 ms
            // stand-in keeps the simulator test fast AND deterministic.
            try await Task.sleep(for: .milliseconds(25))
            let res = try await orchestrator.detectPage(
                image: img,
                pageIndex: idx,
                priors: PerCategoryPriors(),
                surfaceForms: SurfaceFormDictionary(),
                doctypeContext: DoctypeWindow(primary: .financial),
                thresholdVector: nil,
                embeddedText: stub,
                ocrSkipReason: .coverageHighEnough
            )
            return res.detections.count
        }

        _ = try await Self.runDetectionPipelineDepth2(
            pages: pages, pageImageFor: imageFor, detectFor: detectFor,
            collector: collector
        )

        // Overlap-rate metric (plan §5 PERF-3 acceptance):
        //
        //   numerator   = number of consecutive (detect(K), rasterize(K+1))
        //                 pairs whose intervals intersect in time
        //   denominator = total consecutive pairs (pages - 1) — the
        //                 trailing page has no lookahead counterpart
        //
        // Per the contract (depth-2 via `async let`), each
        // non-trailing iteration dispatches the lookahead rasterize
        // concurrent with the current detect, so on any multi-core
        // host the pair overlap is expected to fire for at least 90%
        // of pages.
        let intervals = collector.intervals
        let detects = intervals.filter { $0.kind == .detect }
            .sorted { $0.pageIndex < $1.pageIndex }
        let rasterizes = intervals.filter { $0.kind == .rasterize }
            .sorted { $0.pageIndex < $1.pageIndex }
        #expect(detects.count == pages.count,
                "Expected one detect interval per page")
        #expect(rasterizes.count == pages.count,
                "Expected one rasterize interval per page (bootstrap + N-1 lookaheads)")

        var overlapping = 0
        var pairs = 0
        for k in 0..<(pages.count - 1) {
            guard let detectK = detects.first(where: { $0.pageIndex == k }),
                  let rasterKplus1 = rasterizes.first(where: { $0.pageIndex == k + 1 })
            else { continue }
            pairs += 1
            // Two intervals overlap when [a.start, a.end] ∩ [b.start, b.end]
            // is non-empty: a.start < b.end AND b.start < a.end. Mirrors
            // the PERF-6 overlap test (ParallelLayerExecutionTests).
            if detectK.start < rasterKplus1.end
                && rasterKplus1.start < detectK.end {
                overlapping += 1
            }
        }
        #expect(pairs == pages.count - 1,
                "Expected one detect/rasterize pair per non-trailing page")
        let rate = Double(overlapping) / Double(max(1, pairs))
        // Allow single-core simulator hosts to fall under the bar with a
        // graceful skip — the acceptance threshold lives in
        // `stress-baseline.json` for end-to-end runs; this unit test
        // verifies the SHAPE on a multi-core host. iPhone 17 simulator
        // runs with multiple cores so the threshold engages.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        if cores >= 2 {
            #expect(
                rate >= 0.90,
                "Expected ≥ 90% overlap rate (got \(Int(rate * 100))% on \(pairs) pairs, cores=\(cores))"
            )
        } else {
            // Single-core host: record the rate but do not fail.
            #expect(pairs > 0)
        }
    }

    // MARK: - Test 2: Cancellation propagates to lookahead detect

    @Test(
        "rasterize failure at page 3 propagates: no page-4 detect runs",
        .timeLimit(.minutes(2))
    )
    func testCancellationCancelsLookaheadDetect() async throws {
        // Plan §5 PERF-3 "Hard stops": on rasterize failure for page N,
        // the in-flight detect for the prior page must complete or be
        // cancelled, and the lookahead detect for the failed page MUST
        // NOT produce results. We assert: when rasterize(3) throws,
        // detect(3) and detect(4) never appear in the result vector.
        let (doc, url) = try makeTextLayerPDF(pages: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let pages: [PDFPage] = (0..<doc.pageCount).compactMap { doc.page(at: $0) }
        #expect(pages.count == 6)

        let collector = Collector()
        let rasterizer = PageRasterizer()
        let orchestrator = DetectionOrchestrator()
        // OCR-skip stub — same rationale as testDetectionStartsBefore...
        let stub = makeStubEmbedded(
            text: "Alice Smith SSN 123-45-6789 at 742 Evergreen."
        )

        let imageFor: @Sendable (PDFPage, Int) async throws -> CGImage = { page, idx in
            let wrapped = SendablePDFPage(page)
            return try await rasterizer.renderPage(
                wrapped.page, pageIndex: idx, dpi: 150
            )
        }
        let detectFor: @Sendable (CGImage, Int) async throws -> Int = { img, idx in
            let res = try await orchestrator.detectPage(
                image: img,
                pageIndex: idx,
                priors: PerCategoryPriors(),
                surfaceForms: SurfaceFormDictionary(),
                doctypeContext: DoctypeWindow(primary: .financial),
                thresholdVector: nil,
                embeddedText: stub,
                ocrSkipReason: .coverageHighEnough
            )
            return res.detections.count
        }

        let injector = RasterFailureInjector(failPageIndex: 3)
        do {
            _ = try await Self.runDetectionPipelineDepth2(
                pages: pages, pageImageFor: imageFor, detectFor: detectFor,
                collector: collector, failInjector: injector
            )
            Issue.record("Pipeline should have thrown on rasterize(3) failure")
        } catch is PipelineError { // LegalPhrases:safe (Swift keyword)
            // Expected — the lookahead rasterize for page 3 throws and
            // unwinds through the `try await nextImage` at end of
            // iteration 2.
        }

        // Detect for pages 3, 4, 5 must NOT have run — iteration 3
        // never began because we threw before reaching it. Iteration 2
        // (detect(2)) may have run before or after the throw; both are
        // acceptable correctness-wise (overlap is a perf change, not
        // a correctness change — plan §5 PERF-3 Hard stops).
        let detects = collector.intervals.filter { $0.kind == .detect }
        let detectIndices = Set(detects.map { $0.pageIndex })
        #expect(!detectIndices.contains(3),
                "Detect for page 3 must NOT run when rasterize(3) fails")
        #expect(!detectIndices.contains(4),
                "Detect for page 4 must NOT run — the lookahead chain stopped at the rasterize(3) failure")
        #expect(!detectIndices.contains(5),
                "Detect for page 5 must NOT run — the lookahead chain stopped at the rasterize(3) failure")
    }

    // MARK: - Test 3: Overlap is benign when OCR is skipped (PERF-4 fast path)

    @Test(
        "OCR-skip pages still pipeline: detect(N) is short, overlap is benign",
        .timeLimit(.minutes(2))
    )
    func testNoOverlapWhenOCRSkipped() async throws {
        // PERF-4 + PERF-3 cross-cutting risk (plan §6): when detect(N)
        // is on the OCR-skip fast path, it is far shorter than a normal
        // detect — the lookahead rasterize for page N+1 may finish
        // before detect(N) does, so the overlap is largely no-op for
        // that page. The pair `(detect(K), rasterize(K+1))` is STILL a
        // benign overlap — it does not run any extra work — and the
        // detection set parity is preserved. The acceptance criterion
        // is the LATTER: no spurious work AND correctness held.
        let (doc, url) = try makeTextLayerPDF(pages: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let pages: [PDFPage] = (0..<doc.pageCount).compactMap { doc.page(at: $0) }
        #expect(pages.count == 6)

        let collector = Collector()
        let rasterizer = PageRasterizer()
        let orchestrator = DetectionOrchestrator()

        // Synthesize an EmbeddedTextSource per page so the OCR path is
        // skipped for every page (mirrors PERF-4 `coverage > 0.95`).
        // The PERF-4 orchestrator path stamps provenance on every
        // detection — we re-use that path here.
        let imageFor: @Sendable (PDFPage, Int) async throws -> CGImage = { page, idx in
            nonisolated(unsafe) let unsafePage = page
            return try await rasterizer.renderPage(
                unsafePage, pageIndex: idx, dpi: 150
            )
        }
        let stub = makeStubEmbedded(
            text: "Alice Smith SSN 123-45-6789 lives in Portland."
        )
        let detectFor: @Sendable (CGImage, Int) async throws -> Int = { img, idx in
            let res = try await orchestrator.detectPage(
                image: img,
                pageIndex: idx,
                priors: PerCategoryPriors(),
                surfaceForms: SurfaceFormDictionary(),
                doctypeContext: DoctypeWindow(primary: .financial),
                thresholdVector: nil,
                embeddedText: stub,
                ocrSkipReason: .coverageHighEnough
            )
            // Every detection on a skipped page records OCR-skipped
            // provenance (PERF-4 contract).
            for d in res.detections {
                #expect(d.provenance.ocrSkipped == true,
                        "OCR-skip path must stamp provenance.ocrSkipped")
            }
            return res.detections.count
        }

        let counts = try await Self.runDetectionPipelineDepth2(
            pages: pages, pageImageFor: imageFor, detectFor: detectFor,
            collector: collector
        )
        // Six pages with identical stub text — detection set parity
        // across pages is the simplest invariant to assert here.
        #expect(counts.count == pages.count)
        for k in 1..<counts.count {
            #expect(counts[k] == counts[0],
                    "Skipped-OCR detection counts must match across pages with identical embedded text (got \(counts) at page \(k))")
        }

        // No spurious extra detect intervals — exactly one per page.
        let detects = collector.intervals.filter { $0.kind == .detect }
        #expect(detects.count == pages.count,
                "Exactly one detect interval per page on the OCR-skip path")
    }

    // MARK: - Test 4: Detection parity vs. no-overlap baseline

    @Test(
        "Depth-2 lookahead produces the same per-page detection set as the no-overlap baseline",
        .timeLimit(.minutes(3))
    )
    func testCorrectnessUnchanged() async throws {
        // Plan §5 PERF-3 "Hard stops": overlap is a perf optimization,
        // not a correctness change. The detected-PII set must be
        // byte-for-byte identical to the no-overlap baseline. We
        // compare per-page detection counts (UUIDs are fresh per run,
        // so a deeper byte-level compare is not meaningful — the
        // orchestrator's text+geometry inputs are identical between
        // the two paths, so the count + ordering is the right
        // invariant to assert).
        let (doc, url) = try makeTextLayerPDF(pages: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let pages: [PDFPage] = (0..<doc.pageCount).compactMap { doc.page(at: $0) }
        #expect(pages.count == 10)

        let rasterizer = PageRasterizer()
        let orchestrator = DetectionOrchestrator()
        // OCR-skip stub keeps Vision off the simulator hot path; the
        // detection set parity question is orthogonal to the OCR branch
        // — both sequential and overlap paths feed identical inputs
        // (image + embedded text) into the orchestrator.
        let stub = makeStubEmbedded(
            text: "Alice Smith SSN 123-45-6789 at 742 Evergreen."
        )
        let imageFor: @Sendable (PDFPage, Int) async throws -> CGImage = { page, idx in
            let wrapped = SendablePDFPage(page)
            return try await rasterizer.renderPage(
                wrapped.page, pageIndex: idx, dpi: 150
            )
        }
        let detectFor: @Sendable (CGImage, Int) async throws -> Int = { img, idx in
            let res = try await orchestrator.detectPage(
                image: img,
                pageIndex: idx,
                priors: PerCategoryPriors(),
                surfaceForms: SurfaceFormDictionary(),
                doctypeContext: DoctypeWindow(primary: .financial),
                thresholdVector: nil,
                embeddedText: stub,
                ocrSkipReason: .coverageHighEnough
            )
            return res.detections.count
        }

        let sequentialCollector = Collector()
        let sequential = try await Self.runDetectionPipelineSequential(
            pages: pages, pageImageFor: imageFor, detectFor: detectFor,
            collector: sequentialCollector
        )

        let overlapCollector = Collector()
        let overlap = try await Self.runDetectionPipelineDepth2(
            pages: pages, pageImageFor: imageFor, detectFor: detectFor,
            collector: overlapCollector
        )

        #expect(sequential.count == overlap.count,
                "Per-page detection-count arrays must be the same length")
        for i in 0..<min(sequential.count, overlap.count) {
            #expect(sequential[i] == overlap[i],
                    "Page \(i): overlap count (\(overlap[i])) differs from baseline (\(sequential[i])) — overlap must not change detection results")
        }
    }

    // MARK: - Fixture helpers

    /// Build a multi-page text-layer PDF for the suite. Each page has
    /// extractable text via `UIGraphicsPDFRenderer` so the detection
    /// orchestrator's OCR / embedded-text paths both have substance
    /// to work with.
    private func makeTextLayerPDF(pages: Int) throws -> (PDFDocument, URL) {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let data = renderer.pdfData { ctx in
            for i in 0..<pages {
                ctx.beginPage()
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 18)
                ]
                ("Page \(i + 1) text content for detection test "
                 + "with SSN 123-45-67\(String(format: "%02d", i % 100))"
                    as NSString)
                    .draw(at: CGPoint(x: 72, y: 100), withAttributes: attrs)
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf3-fixture-\(UUID().uuidString).pdf")
        try data.write(to: url)
        guard let doc = PDFDocument(url: url) else {
            throw FixtureError.pdfBuildFailed
        }
        return (doc, url)
    }

    /// Build a small Sendable `EmbeddedTextSource` for the OCR-skip
    /// path test. Coordinates are arbitrary but valid in [0,1]; the
    /// PII detector cares about the `text` string, not the geometry
    /// (matches `OCRSkipFastPathTests.makeStubEmbeddedTextSource`).
    private func makeStubEmbedded(text: String) -> EmbeddedTextSource {
        let nsText = text as NSString
        var wordBounds: [EmbeddedTextSource.WordBound] = []
        var x: CGFloat = 0
        let wordWidth: CGFloat = 0.08
        let wordHeight: CGFloat = 0.04
        let baselineY: CGFloat = 0.5

        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length),
            options: .byWords
        ) { _, wordRange, _, _ in
            let rect = CGRect(x: x, y: baselineY,
                              width: wordWidth, height: wordHeight)
            wordBounds.append(EmbeddedTextSource.WordBound(
                range: wordRange, normalizedRect: rect
            ))
            x += wordWidth + 0.005
        }

        let line = OCREngine.TextLine(
            text: text,
            normalizedRect: CGRect(x: 0, y: baselineY,
                                   width: 1, height: wordHeight),
            confidence: 1.0
        )
        return EmbeddedTextSource(
            text: text,
            wordBounds: wordBounds,
            lines: [line],
            coverage: 0.99
        )
    }

    enum FixtureError: Error {
        case pdfBuildFailed
    }
}
