import Testing
import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
import os
@testable import RedactionEngine

// Parallel verification base layers, measured on the engine's own
// schedule: every test runs `VerificationOrchestrator.run`, the schedule the
// product and the corpus harness run (parallel base batch on one document
// instance per layer → the catalog readers in order → the sandwich checks in
// order → the post-sequential checks). Each layer's interval is read from the
// engine's dispatch seam (`VerificationEngine.onRunLayerDispatch`, stamped as
// the layer starts) plus the layer's reported duration; the order assertions
// read the orchestrator's `VerificationRunEvent` stream.
//
// The layer numbering (zero-based ordinals in `layers(for:)`) is:
//   - Base layers 0/1/2 = Text Extraction, OCR, Binary Search → parallel
//   - Layer 9 = Operator Re-Extraction (CGPDFScanner)         → parallel
//   - Base layers 3, 4  = Structure, Metadata                → sequential
//   - Sandwich 5/6/7/8  = Spatial, CharCount, FontVerify,
//                         Character Lineage                  → sequential
//
// Mechanism-description language only — no outcome promises.
//
// REPORT-ONLY: this suite is listed in PERF_ALONE_RedactionEngine in
// Scripts/test-batched.sh, so it runs by itself after the batches and its
// results do not gate the batched exit status. The overlap-floor assertion
// measures wall-clock concurrency shape and has read red under full
// batch load while passing alone on the same build; a red here is a
// maintainer review signal (re-run the suite alone on a quiet machine),
// not a batch verdict.

// `.serialized` keeps the five tests from racing each other inside the
// suite. They measure wall-clock and concurrency shape, so concurrent
// execution would distort the readings; serializing also reduces the
// CPU pressure that the suite contributes to neighbouring wall-clock-
// sensitive tests (e.g., `RegexSearchHardeningTests.cancellationPropagatesQuickly`).
@Suite("Parallel Layer Execution", .tags(.performance), .serialized)
struct ParallelLayerExecutionTests {

    // MARK: - The orchestrated run and its timeline

    /// One layer's interval in an orchestrated run: `start` from the
    /// dispatch seam, `end` = `start` + the layer's reported duration.
    struct TimedLayer: Sendable {
        let layerIndex: Int
        let result: LayerResult
        let start: Double
        let end: Double
    }

    /// An event as the sink received it, with the time it arrived.
    struct StampedEvent {
        let event: VerificationRunEvent
        let at: Double
    }

    struct OrchestratedRun {
        let report: VerificationReport
        let events: [StampedEvent]
        /// Keyed by zero-based ordinal in `layers(for:)`.
        let timeline: [Int: TimedLayer]
        /// Zero-based ordinals in the order the engine dispatched them.
        let dispatchOrder: [Int]
    }

    /// Records the dispatch seam's (ordinal, time) pairs across the
    /// orchestrator's concurrent layer tasks.
    final class DispatchLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(ordinal: Int, at: Double)] = []
        func record(_ ordinal: Int) {
            let now = CFAbsoluteTimeGetCurrent()
            lock.lock(); entries.append((ordinal, now)); lock.unlock()
        }
        var snapshot: [(ordinal: Int, at: Double)] {
            lock.lock(); defer { lock.unlock() }; return entries
        }
    }

    /// Run the engine's verification schedule over the document at `url`,
    /// one freshly opened document instance per parallel-batch layer (the
    /// product's provisioning), and return the report, the stamped events
    /// and each layer's interval.
    static func runOrchestrated(
        url: URL,
        doc: PDFDocument,
        pipelineMode: PipelineMode,
        sensitiveTerms: [SensitiveTerm],
        filterDigests: [PageFilterDigest?]
    ) async throws -> OrchestratedRun {
        let log = DispatchLog()
        var verifier = VerificationEngine()
        verifier.onRunLayerDispatch = { ordinal, _ in log.record(ordinal) }
        let pageCount = doc.pageCount
        var events: [StampedEvent] = []
        let report = try await VerificationOrchestrator(verifier: verifier).run(
            outputDocument: SendablePDFDocument(doc),
            sourcePageCount: pageCount,
            regions: [:],
            sensitiveTerms: sensitiveTerms,
            pipelineMode: pipelineMode,
            filterDigests: filterDigests,
            perPageModes: Array(repeating: pipelineMode, count: pageCount),
            perPageFallbackReasons: Array(repeating: nil, count: pageCount),
            appliedSearches: [],
            provisionLayerDocuments: { layers in
                var docs: [VerificationLayer: SendablePDFDocument] = [:]
                for layer in layers {
                    guard let d = PDFDocument(url: url) else { return nil }
                    docs[layer] = SendablePDFDocument(d)
                }
                return docs
            },
            events: { events.append(StampedEvent(event: $0, at: CFAbsoluteTimeGetCurrent())) }
        )
        let dispatches = log.snapshot
        var timeline: [Int: TimedLayer] = [:]
        for (ordinal, start) in dispatches where ordinal < report.layers.count {
            let result = report.layers[ordinal]
            timeline[ordinal] = TimedLayer(
                layerIndex: ordinal, result: result,
                start: start, end: start + result.durationSeconds)
        }
        return OrchestratedRun(
            report: report, events: events, timeline: timeline,
            dispatchOrder: dispatches.map(\.ordinal))
    }

    /// Pairs among `ordinals` whose intervals intersect (neither finished
    /// before the other started).
    static func overlappingPairs(_ ordinals: [Int], in timeline: [Int: TimedLayer]) -> Int {
        let timed = ordinals.compactMap { timeline[$0] }
        var pairs = 0
        for i in 0..<timed.count {
            for j in (i + 1)..<timed.count {
                let a = timed[i], b = timed[j]
                if a.start < b.end && b.start < a.end { pairs += 1 }
            }
        }
        return pairs
    }

    /// The time the sink received `layerFinished` for `ordinal` (zero-based).
    static func finishedAt(_ ordinal: Int, in events: [StampedEvent]) -> Double? {
        for stamped in events {
            if case .layerFinished(_, let o, _) = stamped.event, o == ordinal + 1 {
                return stamped.at
            }
        }
        return nil
    }

    /// The ordinals (zero-based) of `mode`'s layers in `phase`.
    static func ordinals(
        of phase: VerificationLayer.ExecutionPhase, mode: PipelineMode
    ) -> [Int] {
        VerificationEngine().layers(for: mode).enumerated()
            .filter { $0.element.phase == phase }.map(\.offset)
    }

    // MARK: - Test 1 — Parallel base layers overlap

    @Test("Base layers 0/1/2 overlap under the verification orchestrator")
    func testBaseLayersRunInParallel() async throws {
        // 4-page fixture: enough to give the OCR layer real per-page
        // work so the parallel timeline is observable, while small
        // enough to coexist with wall-clock-budgeted tests elsewhere
        // in the suite.
        let (doc, url) = try await makeMultiPagePDF(pageCount: 4)
        defer { try? FileManager.default.removeItem(at: url) }

        let signposter = OSSignposter(
            subsystem: "com.resecta.tests", category: "perf6"
        )
        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval(
            "ParallelBaseLayers", id: signpostID
        )
        defer { signposter.endInterval("ParallelBaseLayers", interval) }

        let parallelOrdinals = Self.ordinals(of: .parallelBase, mode: .secureRasterization)
        #expect(parallelOrdinals == [0, 1, 2])

        let run = try await Self.runOrchestrated(
            url: url, doc: doc, pipelineMode: .secureRasterization,
            sensitiveTerms: [], filterDigests: Array(repeating: nil, count: doc.pageCount))

        #expect(parallelOrdinals.allSatisfy { run.timeline[$0] != nil },
                "Expected one timed interval per parallel-base layer (layers 0, 1, 2)")

        // Two layers "overlap" when one's [start, end] interval and the
        // other's intersect — i.e., neither finished before the other
        // started. Three layers produce 3 pairs; requiring >= 2 means at
        // least two-thirds of the pairs must overlap, which excludes the
        // near-serial schedule (exactly one incidental overlap). If this
        // turns flaky under full-suite load, that is evidence of a real
        // scheduling regression rather than justification to widen the
        // floor.
        let overlapping = Self.overlappingPairs(parallelOrdinals, in: run.timeline)
        #expect(
            overlapping >= 2,
            "Expected at least two overlapping pairs among layers 0/1/2 in the orchestrator's parallel batch (saw \(overlapping); >= 2 of 3 pairs required)"
        )

        // The batch publishes its results in canonical order so the
        // progress UI's `completedLayers` reads ascending.
        let finishedOrdinals = run.events.compactMap { stamped -> Int? in
            if case .layerFinished(_, let ordinal, _) = stamped.event { return ordinal - 1 }
            return nil
        }
        #expect(Array(finishedOrdinals.prefix(3)) == parallelOrdinals)
    }

    // MARK: - Test 2 — Layer 4 starts after Layer 3 ends

    @Test("Layer 4 starts after Layer 3 ends (sequential base)")
    func testLayer3And4Sequential() async throws {
        let (doc, url) = try await makeMultiPagePDF(pageCount: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(Self.ordinals(of: .catalogSequential, mode: .secureRasterization) == [3, 4])
        let run = try await Self.runOrchestrated(
            url: url, doc: doc, pipelineMode: .secureRasterization,
            sensitiveTerms: [], filterDigests: Array(repeating: nil, count: doc.pageCount))

        let layer3Finished = try #require(Self.finishedAt(3, in: run.events))
        let layer4 = try #require(run.timeline[4])
        #expect(
            layer4.start >= layer3Finished,
            "Layer 4 should begin no earlier than Layer 3 ends — concurrent PDFDocument catalog parsing would contend"
        )
        let order = run.dispatchOrder.filter { [3, 4].contains($0) }
        #expect(order == [3, 4])
    }

    // MARK: - Test 3 — Sandwich layers run sequentially

    @Test("Sandwich layers 5/6/7/8 run one after the other (no overlap)")
    func testSandwichLayersSequential() async throws {
        // Sandwich layers expect a Searchable-Redaction page with a
        // filter digest. Use the textLayerPDF fixture so the page has
        // a real text layer; pair with a stub digest sized for the
        // page's extracted text. Layer 9 (Character Lineage) belongs to
        // the sandwich-sequential set; Layer 10 belongs to the parallel
        // base batch instead.
        let (doc, url) = try await makeMultiPageSandwichPDF(pageCount: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        let pageCount = doc.pageCount
        let digests: [PageFilterDigest?] = (0..<pageCount).map { i in
            PageFilterDigest(
                pageIndex: i,
                extractedCount: 0,
                excludedCount: 0,
                survivingCount: 0,
                boundaryCharacters: []
            )
        }
        let sandwich = Self.ordinals(of: .sandwichSequential, mode: .searchableRedaction)
        #expect(sandwich == [5, 6, 7, 8])

        let run = try await Self.runOrchestrated(
            url: url, doc: doc, pipelineMode: .searchableRedaction,
            sensitiveTerms: [], filterDigests: digests)

        for (previous, next) in zip(sandwich, sandwich.dropFirst()) {
            let previousFinished = try #require(Self.finishedAt(previous, in: run.events))
            let nextStart = try #require(run.timeline[next]).start
            #expect(
                nextStart >= previousFinished,
                "Sandwich layer \(next) should start after layer \(previous) finishes — inter-layer character-count baselines require sequential ordering"
            )
        }
        #expect(run.dispatchOrder.filter { sandwich.contains($0) } == sandwich)
    }

    // MARK: - Test 3b — Layer 10 joins the parallel base batch (Searchable, M3)

    @Test("Layer 10 overlaps base parallel batch in Searchable mode")
    func testLayer10ParallelBaseOverlap() async throws {
        // Layer 10 (operator-semantic re-extraction, index 9 in the
        // zero-indexed order) joins the base-parallel batch in
        // Searchable mode. The layer walks each output page's content
        // stream via CGPDFScanner — no catalog-handle contention with
        // Layers 0/1/2 and no sequencing dependency on the
        // sandwich-sequential layers (5–8).
        //
        // The orchestrator dispatches the batch; the test asserts at
        // least two pairs of intervals overlap. Non-empty
        // `sensitiveTerms` so Layer 10 does real per-page work via the
        // Aho-Corasick automaton; the token does not appear in the
        // fixture, so the timing shape is what's under test, not the
        // result.
        let (doc, url) = try await makeMultiPageSandwichPDF(pageCount: 4)
        defer { try? FileManager.default.removeItem(at: url) }

        let parallelOrdinals = Self.ordinals(of: .parallelBase, mode: .searchableRedaction)
        #expect(parallelOrdinals == [0, 1, 2, 9])

        let run = try await Self.runOrchestrated(
            url: url, doc: doc, pipelineMode: .searchableRedaction,
            sensitiveTerms: ["NONEXISTENT_SAMPLE_PII_TOKEN_XYZ123"].map { SensitiveTerm(text: $0) },
            filterDigests: Array(repeating: nil, count: doc.pageCount))

        #expect(parallelOrdinals.allSatisfy { run.timeline[$0] != nil },
                "Expected one timed interval per parallel-base layer (\(parallelOrdinals))")

        // Same overlap predicate the layers-0/1/2 test uses. Four layers
        // produce 6 pairs; requiring >= 2 excludes the near-serial
        // schedule (exactly one incidental overlap). If this turns flaky
        // under full-suite load, that is evidence of a real scheduling
        // regression rather than justification to widen the floor.
        let overlapping = Self.overlappingPairs(parallelOrdinals, in: run.timeline)
        #expect(
            overlapping >= 2,
            "Expected at least two overlapping pairs among layers 0/1/2/9 in the orchestrator's parallel batch (saw \(overlapping); >= 2 of 6 pairs required)"
        )
    }

    // MARK: - Test 4 — Wall-clock under 50% of sequential baseline

    // Wall-clock acceptance test. Asserts that the orchestrator's schedule
    // reduces verification wall-clock vs. running every layer serially;
    // reports the 0.5× strict target as a non-asserting log line.
    // `.disabled` under default green-bar runs because Swift Testing
    // schedules tests across CPU cores by default and parallel-scheduling
    // contention with other wall-clock-budgeted suites distorts the ratio.
    // Explicit invocation gate:
    //   xcodebuild test -only-testing:'RedactionEngineTests/ParallelLayerExecutionTests/testVerifyWallClockUnderHalfBaseline()'
    @Test("Parallel verify wall-clock beats sequential baseline (acceptance gate)",
          .tags(.performance),
          .disabled("Parallel-scheduling contention with neighbouring wall-clock-budgeted suites distorts the ratio under default `xcodebuild test`. Run on demand via explicit `-only-testing` invocation."),
          .timeLimit(.minutes(4)))
    func testVerifyWallClockUnderHalfBaseline() async throws {
        // 50-page document exercises the acceptance criterion.
        // Uses bitmap pages (engine reconstructor produces JPEG XObjects)
        // so Layer 1 OCR runs Vision on every page, AND the resulting
        // PDF byte stream is large enough that Layer 2's Aho-Corasick
        // scan does meaningful work. Without real work in every base
        // layer the parallel/sequential ratio collapses to ≈1 because
        // one heavy layer dominates either dispatch shape.
        let (doc, url) = try await makeMultiPagePDF(pageCount: 50)
        defer { try? FileManager.default.removeItem(at: url) }

        // Provide non-empty sensitive terms so Layer 2 builds and
        // runs an Aho-Corasick automaton against the PDF byte stream.
        let sensitiveTerms = ["NONEXISTENT_SAMPLE_PII_TOKEN_XYZ123"].map { SensitiveTerm(text: $0) }

        let verifier = VerificationEngine()
        let wrappedDoc = SendablePDFDocument(doc)
        let pageCount = doc.pageCount
        let perPageModes = Array(repeating: PipelineMode.secureRasterization, count: pageCount)
        let digests: [PageFilterDigest?] = Array(repeating: nil, count: pageCount)
        let layers = verifier.layers(for: .secureRasterization)

        // Warm-up pass — caches CGPDFDocument open, Vision request
        // graph initialisation, and any first-touch image-extraction
        // costs so the measured samples below reflect steady-state
        // dispatch rather than one-off startup overhead.
        for layer in layers {
            _ = await verifier.runLayer(
                layer,
                outputDocument: wrappedDoc,
                sourcePageCount: pageCount,
                regions: [:],
                sensitiveTerms: sensitiveTerms,
                pipelineMode: .secureRasterization,
                filterDigests: digests,
                perPageModes: perPageModes
            )
        }

        // Three iterations averaged to dampen scheduler noise. The
        // 0.5× ratio target is aspirational; sample averaging makes
        // the assertion robust to brief CPU contention from
        // neighbouring suites in the engine green-bar run.
        let iterations = 3
        var sequentialSamples: [TimeInterval] = []
        var parallelSamples: [TimeInterval] = []

        for _ in 0..<iterations {
            // --- Sequential baseline: every layer serially ---
            let sequentialStart = Date()
            for layer in layers {
                _ = await verifier.runLayer(
                    layer,
                    outputDocument: wrappedDoc,
                    sourcePageCount: pageCount,
                    regions: [:],
                    sensitiveTerms: sensitiveTerms,
                    pipelineMode: .secureRasterization,
                    filterDigests: digests,
                    perPageModes: perPageModes
                )
            }
            sequentialSamples.append(Date().timeIntervalSince(sequentialStart))

            // --- The orchestrator's schedule ---
            let parallelStart = Date()
            _ = try await Self.runOrchestrated(
                url: url, doc: doc, pipelineMode: .secureRasterization,
                sensitiveTerms: sensitiveTerms, filterDigests: digests)
            parallelSamples.append(Date().timeIntervalSince(parallelStart))
        }

        // Trim the worst outlier (iter 1 often shows first-touch
        // Vision warmup overhead even after the warm-up pass).
        let trimmedSequential = sequentialSamples.sorted().dropLast()
        let trimmedParallel = parallelSamples.sorted().dropLast()
        let sequentialAvg = trimmedSequential.reduce(0, +) / Double(trimmedSequential.count)
        let parallelAvg = trimmedParallel.reduce(0, +) / Double(trimmedParallel.count)

        // Acceptance criterion: "Total verification wall-clock
        // reduced; correctness invariants preserved." The test
        // asserts the "reduced" side (parallel beats sequential) and
        // reports the 0.5× strict aspirational bar to the test log
        // without asserting on it — the strict ratio depends on the
        // per-layer work balance, which the synthetic fixture does not
        // provide.
        let strictTarget = sequentialAvg * 0.5
        #expect(
            parallelAvg < sequentialAvg,
            """
            Parallel verify wall-clock did not beat sequential baseline.
            avg parallel (trimmed): \(parallelAvg)s
            avg sequential (trimmed): \(sequentialAvg)s
            strict target (0.5×): \(strictTarget)s
            samples: seq=\(sequentialSamples), par=\(parallelSamples)
            """
        )
        // Non-asserting visibility into the strict-target achievement.
        let hitStrictTarget = parallelAvg < strictTarget
        let speedupPct = (1 - parallelAvg / sequentialAvg) * 100
        print("Parallel verify wall-clock speedup: " +
              "\(String(format: "%.1f", speedupPct))% " +
              "(strict 0.5× target \(hitStrictTarget ? "hit" : "not hit") " +
              "on synthetic fixture). " +
              "Sequential avg=\(sequentialAvg)s, parallel avg=\(parallelAvg)s.")
    }

    // MARK: - Test 5 — Correctness invariants preserved

    @Test("Layer-result correctness matches sequential dispatch")
    func testCorrectnessInvariantsPreserved() async throws {
        // The orchestrator's schedule must not alter the per-layer
        // status compared to a strictly sequential run of each layer
        // (same inputs → same per-layer outputs). Two pages keeps the
        // OCR cost low enough to coexist with the engine suite's
        // wall-clock-budgeted neighbours.
        let (doc, url) = try await makeMultiPagePDF(pageCount: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let verifier = VerificationEngine()
        let wrappedDoc = SendablePDFDocument(doc)
        let pageCount = doc.pageCount
        let perPageModes = Array(repeating: PipelineMode.secureRasterization, count: pageCount)
        let digests: [PageFilterDigest?] = Array(repeating: nil, count: pageCount)
        let layers = verifier.layers(for: .secureRasterization)

        // Sequential run (baseline)
        var sequentialResults: [LayerResult] = []
        for layer in layers {
            let result = await verifier.runLayer(
                layer,
                outputDocument: wrappedDoc,
                sourcePageCount: pageCount,
                regions: [:],
                sensitiveTerms: [],
                pipelineMode: .secureRasterization,
                filterDigests: digests,
                perPageModes: perPageModes
            )
            sequentialResults.append(result)
        }

        // The orchestrator's schedule (production shape)
        let run = try await Self.runOrchestrated(
            url: url, doc: doc, pipelineMode: .secureRasterization,
            sensitiveTerms: [], filterDigests: digests)
        let orchestrated = run.report.layers

        #expect(orchestrated.count == layers.count)
        for (i, (a, b)) in zip(orchestrated, sequentialResults).enumerated() {
            #expect(a.name == b.name, "Layer \(i) name should be stable across dispatch shape")
            #expect(a.status.isFail == b.status.isFail,
                    "Layer \(i) FAIL status should be stable across dispatch shape")
            #expect(a.status.isWarn == b.status.isWarn,
                    "Layer \(i) WARN status should be stable across dispatch shape")
        }
    }

    // MARK: - Helpers

    /// Build a multi-page PDF using the engine's reconstructor. The
    /// resulting document has a valid `documentURL`, which Layers 1
    /// and 4 require for `CGPDFDocument(url:)` catalog access.
    private func makeMultiPagePDF(pageCount: Int) async throws -> (PDFDocument, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf6_multipage_\(UUID().uuidString).pdf")
        let recon = PDFStreamReconstructor(tempURL: url)
        let size = CGSize(width: 200, height: 300)
        try await recon.begin(firstPageSize: size)

        for _ in 0..<pageCount {
            // Each page is a solid mid-gray rectangle. No selectable text,
            // no annotations — Layer 1 should pass on every page.
            guard let ctx = createBitmapContext(width: 200, height: 300) else {
                throw PerfTestError.bitmapContextFailed
            }
            ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            guard let image = ctx.makeImage() else {
                throw PerfTestError.imageMakeFailed
            }
            try await recon.appendPage(
                PageOutput(image: image, size: size, textLayerEntries: nil)
            )
        }
        await recon.finalize()

        guard let doc = PDFDocument(url: url) else {
            throw PerfTestError.docOpenFailed
        }
        return (doc, url)
    }

    /// Build a multi-page sandwich-mode fixture: real text-layer pages
    /// suitable for sandwich layers 5/6/7 to traverse.
    private func makeMultiPageSandwichPDF(pageCount: Int) async throws -> (PDFDocument, URL) {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf6_sandwich_\(UUID().uuidString).pdf")
        try renderer.writePDF(to: url) { context in
            for i in 0..<pageCount {
                context.beginPage()
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont(name: "Courier", size: 18)!,
                    .foregroundColor: UIColor.black
                ]
                let text = "Sandwich page \(i + 1) body text for verification."
                (text as NSString).draw(
                    at: CGPoint(x: 72, y: 72), withAttributes: attrs
                )
            }
        }
        guard let doc = PDFDocument(url: url) else {
            throw PerfTestError.docOpenFailed
        }
        return (doc, url)
    }

    private enum PerfTestError: Error {
        case bitmapContextFailed
        case imageMakeFailed
        case docOpenFailed
    }
}

// MARK: - Tag

extension Tag {
    /// Performance-focused tests — wall-clock and concurrency shape.
    @Tag static var performance: Self
}
