import Testing
import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
import os
@testable import RedactionEngine

// PERF-6 — Parallel verification base layers.
//
// These tests mirror the dispatch contract implemented in
// `Sources/ResectaApp/State/PipelineCoordinator.swift` (private
// `runVerification` block). The engine package owns the per-layer logic
// (`VerificationEngine.runLayer`), but the parallel/sequential dispatch
// is the coordinator's responsibility. The tests therefore re-run the
// same dispatch pattern locally (parallel 0/1/2 → sequential 3, 4 →
// sequential 5..<sandwichEnd) and assert the wall-clock + ordering
// shape, without coupling to the coordinator type (which lives in the
// app target and is unreachable from this package's test bundle).
//
// Per plan §0.2 (base layers) and plan §4.4 / §4.5 (Layer 9 / Layer 10
// additions), the post-M3 layer numbering is:
//   - Base layers 0/1/2 = Text Extraction, OCR, Binary Search → parallel
//   - Layer 9 (M3 SVT-5) = Operator Re-Extraction (CGPDFScanner)
//                                                              → parallel
//   - Base layers 3, 4  = Structure, Metadata                → sequential
//   - Sandwich 5/6/7/8  = Spatial, CharCount, FontVerify,
//                         Character Lineage                  → sequential
//
// Mechanism-description language only — no outcome promises.

// `.serialized` keeps the five tests from racing each other inside the
// suite. They measure wall-clock and concurrency shape, so concurrent
// execution would distort the readings; serializing also reduces the
// CPU pressure that the suite contributes to neighbouring wall-clock-
// sensitive tests (e.g., `RegexSearchHardeningTests.cancellationPropagatesQuickly`).
@Suite("PERF-6 Parallel Layer Execution", .tags(.performance), .serialized)
struct ParallelLayerExecutionTests {

    // MARK: - Per-layer wall-clock harness

    /// A single timed run of `runLayer`. The Date stamps come from the
    /// SAME `Date()` source on both ends so subtraction is meaningful
    /// across concurrent Tasks (ContinuousClock is also monotonic;
    /// either works — Date is used here so timestamps are directly
    /// comparable across the parallel/sequential branches).
    struct TimedLayer: Sendable {
        let layerIndex: Int
        let result: LayerResult
        let start: Date
        let end: Date
    }

    /// Re-implements the coordinator's parallel-dispatch contract for
    /// the test bundle. The production code path is in
    /// `PipelineCoordinator.runVerification` (see PERF-6 plan §5).
    /// Returns timestamped results in layer-index ascending order.
    ///
    /// M3 (plan §4.5 / ENGINE §6.9 PERF-6): accepts an arbitrary `[Int]`
    /// so callers can dispatch the post-M3 Searchable batch `[0, 1, 2, 9]`
    /// in addition to the pre-M3 contiguous `[0, 1, 2]` range.
    static func runParallelBase(
        layers: [Int],
        verifier: VerificationEngine,
        doc: SendablePDFDocument,
        sourcePageCount: Int,
        regions: [Int: [RedactionRegion]],
        sensitiveTerms: [String],
        pipelineMode: PipelineMode,
        filterDigests: [PageFilterDigest?],
        perPageModes: [PipelineMode]
    ) async -> [TimedLayer] {
        let collected: [TimedLayer] = await withTaskGroup(
            of: TimedLayer.self
        ) { group in
            for layerIndex in layers {
                group.addTask {
                    let start = Date()
                    let result = await verifier.runLayer(
                        layerIndex,
                        outputDocument: doc,
                        sourcePageCount: sourcePageCount,
                        regions: regions,
                        sensitiveTerms: sensitiveTerms,
                        pipelineMode: pipelineMode,
                        filterDigests: filterDigests,
                        perPageModes: perPageModes
                    )
                    let end = Date()
                    return TimedLayer(
                        layerIndex: layerIndex, result: result,
                        start: start, end: end
                    )
                }
            }
            var collected: [TimedLayer] = []
            for await timed in group {
                collected.append(timed)
            }
            return collected
        }
        return collected.sorted { $0.layerIndex < $1.layerIndex }
    }

    /// Sequential per-layer runner; mirrors the post-parallel branches
    /// (layers 3, 4) and the sandwich-layer branch (5–7) in the
    /// coordinator. Captures the same start/end stamps so callers can
    /// assert non-overlap.
    static func runSequential(
        layers: [Int],
        verifier: VerificationEngine,
        doc: SendablePDFDocument,
        sourcePageCount: Int,
        regions: [Int: [RedactionRegion]],
        sensitiveTerms: [String],
        pipelineMode: PipelineMode,
        filterDigests: [PageFilterDigest?],
        perPageModes: [PipelineMode]
    ) async -> [TimedLayer] {
        var collected: [TimedLayer] = []
        for layerIndex in layers {
            let start = Date()
            let result = await verifier.runLayer(
                layerIndex,
                outputDocument: doc,
                sourcePageCount: sourcePageCount,
                regions: regions,
                sensitiveTerms: sensitiveTerms,
                pipelineMode: pipelineMode,
                filterDigests: filterDigests,
                perPageModes: perPageModes
            )
            let end = Date()
            collected.append(TimedLayer(
                layerIndex: layerIndex, result: result,
                start: start, end: end
            ))
        }
        return collected
    }

    // MARK: - Test 1 — Parallel base layers overlap

    @Test("Base layers 0/1/2 overlap when dispatched via withTaskGroup")
    func testBaseLayersRunInParallel() async throws {
        // 4-page fixture: enough to give the OCR layer real per-page
        // work so the parallel timeline is observable, while small
        // enough to coexist with wall-clock-budgeted tests elsewhere
        // in the suite.
        let (doc, url) = try await makeMultiPagePDF(pageCount: 4)
        defer { try? FileManager.default.removeItem(at: url) }

        let verifier = VerificationEngine()
        let signposter = OSSignposter(
            subsystem: "com.resecta.tests", category: "perf6"
        )
        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval(
            "ParallelBaseLayers", id: signpostID
        )
        defer { signposter.endInterval("ParallelBaseLayers", interval) }

        let parallel = await Self.runParallelBase(
            layers: [0, 1, 2],
            verifier: verifier,
            doc: SendablePDFDocument(doc),
            sourcePageCount: doc.pageCount,
            regions: [:],
            sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [],
            perPageModes: Array(repeating: .secureRasterization, count: doc.pageCount)
        )

        #expect(parallel.count == 3, "Expected three timed results (layers 0, 1, 2)")

        // Two layers "overlap" when one's [start, end] interval and the
        // other's intersect — i.e., neither finished before the other
        // started. Three layers produce 3 pairs; requiring >= 2 means at
        // least two-thirds of the pairs must overlap, ruling out the
        // near-serial schedule (exactly one incidental overlap) that the
        // old >= 1 floor accepted (CAT-250). If this turns flaky under
        // full-suite load, that is evidence of a real scheduling
        // regression — do not re-widen without maintainer review.
        var overlappingPairs = 0
        for i in 0..<parallel.count {
            for j in (i + 1)..<parallel.count {
                let a = parallel[i]
                let b = parallel[j]
                let overlap = a.start < b.end && b.start < a.end
                if overlap { overlappingPairs += 1 }
            }
        }
        #expect(
            overlappingPairs >= 2,
            "Expected at least two overlapping pairs among layers 0/1/2 under withTaskGroup dispatch (saw \(overlappingPairs); >= 2 of 3 pairs per CAT-250)"
        )

        // Layer-index ordering is preserved by the sort step in
        // runParallelBase so downstream consumers of `completedLayers`
        // see ascending indices.
        #expect(parallel[0].layerIndex == 0)
        #expect(parallel[1].layerIndex == 1)
        #expect(parallel[2].layerIndex == 2)
    }

    // MARK: - Test 2 — Layer 4 starts after Layer 3 ends

    @Test("Layer 4 starts after Layer 3 ends (sequential base)")
    func testLayer3And4Sequential() async throws {
        let (doc, url) = try await makeMultiPagePDF(pageCount: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let verifier = VerificationEngine()
        let timed = await Self.runSequential(
            layers: [3, 4],
            verifier: verifier,
            doc: SendablePDFDocument(doc),
            sourcePageCount: doc.pageCount,
            regions: [:],
            sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [],
            perPageModes: Array(repeating: .secureRasterization, count: doc.pageCount)
        )

        #expect(timed.count == 2, "Expected sequential timing entries for layers 3 and 4")
        let layer3 = timed[0]
        let layer4 = timed[1]
        #expect(layer3.layerIndex == 3)
        #expect(layer4.layerIndex == 4)
        #expect(
            layer4.start >= layer3.end,
            "Layer 4 should begin no earlier than Layer 3 ends — concurrent PDFDocument catalog parsing would contend (plan §0.2)"
        )
    }

    // MARK: - Test 3 — Sandwich layers run sequentially

    @Test("Sandwich layers 5/6/7/8 run one after the other (no overlap)")
    func testSandwichLayersSequential() async throws {
        // Sandwich layers expect a Searchable-Redaction page with a
        // filter digest. Use the textLayerPDF fixture so the page has
        // a real text layer; pair with a stub digest sized for the
        // page's extracted text. M1 (plan §4.4) added Layer 9
        // (Character Lineage) to the sandwich-sequential set; M3 leaves
        // it there and adds Layer 10 to the parallel base batch instead
        // (plan §4.5, ENGINE §6.9 PERF-6).
        let (doc, url) = try await makeMultiPageSandwichPDF(pageCount: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        let verifier = VerificationEngine()
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
        let perPageModes = Array(repeating: PipelineMode.searchableRedaction, count: pageCount)

        let timed = await Self.runSequential(
            layers: [5, 6, 7, 8],
            verifier: verifier,
            doc: SendablePDFDocument(doc),
            sourcePageCount: pageCount,
            regions: [:],
            sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: digests,
            perPageModes: perPageModes
        )

        #expect(timed.count == 4, "Expected timing entries for layers 5/6/7/8")
        for i in 0..<(timed.count - 1) {
            let a = timed[i]
            let b = timed[i + 1]
            #expect(
                b.start >= a.end,
                "Sandwich layer \(b.layerIndex) should start after layer \(a.layerIndex) finishes — inter-layer character-count baselines require sequential ordering"
            )
        }
        #expect(timed.map { $0.layerIndex } == [5, 6, 7, 8])
    }

    // MARK: - Test 3b — Layer 10 joins the parallel base batch (Searchable, M3)

    @Test("Layer 10 overlaps base parallel batch in Searchable mode (M3)")
    func testLayer10ParallelBaseOverlap() async throws {
        // Plan §4.5 / ENGINE §6.9 PERF-6: Layer 10 (operator-semantic
        // re-extraction, index 9 in the zero-indexed dispatcher) joins
        // the base-parallel batch in Searchable mode. The layer walks
        // each output page's content stream via CGPDFScanner — no
        // catalog-handle contention with Layers 0/1/2 and no sequencing
        // dependency on the sandwich-sequential layers (5–8).
        //
        // The test dispatches `[0, 1, 2, 9]` via the same withTaskGroup
        // shape the coordinator uses (`PipelineCoordinator.runVerification`)
        // and asserts at least one pair of intervals overlaps. Non-empty
        // `sensitiveTerms` so Layer 10 does real per-page work via the
        // Aho-Corasick automaton; the token does not appear in the
        // fixture, so all four layers report PASS and the timing shape
        // is what's under test, not the result.
        let (doc, url) = try await makeMultiPageSandwichPDF(pageCount: 4)
        defer { try? FileManager.default.removeItem(at: url) }

        let verifier = VerificationEngine()
        let pageCount = doc.pageCount
        let digests: [PageFilterDigest?] = (0..<pageCount).map { _ in nil }
        let perPageModes = Array(repeating: PipelineMode.searchableRedaction, count: pageCount)

        let parallel = await Self.runParallelBase(
            layers: [0, 1, 2, 9],
            verifier: verifier,
            doc: SendablePDFDocument(doc),
            sourcePageCount: pageCount,
            regions: [:],
            sensitiveTerms: ["NONEXISTENT_SAMPLE_PII_TOKEN_XYZ123"],
            pipelineMode: .searchableRedaction,
            filterDigests: digests,
            perPageModes: perPageModes
        )

        #expect(parallel.count == 4,
                "Expected four timed results (layers 0, 1, 2, 9)")

        // Same overlap predicate the layers-0/1/2 test uses. Four layers
        // produce 6 pairs; requiring >= 2 rules out the near-serial
        // schedule (exactly one incidental overlap) that the old >= 1
        // floor accepted (CAT-250). If this turns flaky under full-suite
        // load, that is evidence of a real scheduling regression — do not
        // re-widen without maintainer review.
        var overlappingPairs = 0
        for i in 0..<parallel.count {
            for j in (i + 1)..<parallel.count {
                let a = parallel[i]
                let b = parallel[j]
                if a.start < b.end && b.start < a.end {
                    overlappingPairs += 1
                }
            }
        }
        #expect(
            overlappingPairs >= 2,
            "Expected at least two overlapping pairs among layers 0/1/2/9 under withTaskGroup dispatch (saw \(overlappingPairs); >= 2 of 6 pairs per CAT-250)"
        )

        // Sorted output preserves layer-index-ascending order so
        // downstream slot-based consumers (UI list rows) read correctly.
        #expect(parallel.map { $0.layerIndex } == [0, 1, 2, 9])
    }

    // MARK: - Test 4 — Wall-clock under 50% of sequential baseline

    // Wall-clock acceptance test per plan §5. Asserts that the parallel
    // dispatch reduces verification wall-clock vs. the sequential
    // baseline; reports the 0.5× strict target as a non-asserting log
    // line. Same convention as the existing `SearchPerformanceTests`
    // and `RegexSentinelCheckTests` env-skip entries
    // (inherited-red triage 2026-05-08) — `.disabled` under default
    // green-bar runs because Swift Testing schedules tests across CPU
    // cores by default and parallel-scheduling contention with other
    // wall-clock-budgeted suites distorts the ratio. Explicit
    // invocation gate (same pattern as PERF-7 `make stress-baseline`):
    //   xcodebuild test -only-testing:'RedactionEngineTests/ParallelLayerExecutionTests/testVerifyWallClockUnderHalfBaseline()'
    @Test("Parallel verify wall-clock beats sequential baseline (acceptance gate)",
          .tags(.performance),
          .disabled("Parallel-scheduling contention with neighbouring wall-clock-budgeted suites distorts the ratio under default `xcodebuild test`. Run on demand via explicit `-only-testing` invocation."),
          .timeLimit(.minutes(4)))
    func testVerifyWallClockUnderHalfBaseline() async throws {
        // 50-page document per the plan acceptance criterion (§5).
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
        let sensitiveTerms = ["NONEXISTENT_SAMPLE_PII_TOKEN_XYZ123"]

        let verifier = VerificationEngine()
        let wrappedDoc = SendablePDFDocument(doc)
        let pageCount = doc.pageCount
        let perPageModes = Array(repeating: PipelineMode.secureRasterization, count: pageCount)

        // Warm-up pass — caches CGPDFDocument open, Vision request
        // graph initialisation, and any first-touch image-extraction
        // costs so the measured samples below reflect steady-state
        // dispatch rather than one-off startup overhead.
        for i in 0..<5 {
            _ = await verifier.runLayer(
                i,
                outputDocument: wrappedDoc,
                sourcePageCount: pageCount,
                regions: [:],
                sensitiveTerms: sensitiveTerms,
                pipelineMode: .secureRasterization,
                filterDigests: [],
                perPageModes: perPageModes
            )
        }

        // Three iterations averaged to dampen scheduler noise. The
        // 0.5× ratio target follows plan §5; sample averaging makes
        // the assertion robust to brief CPU contention from
        // neighbouring suites in the engine green-bar run.
        let iterations = 3
        var sequentialSamples: [TimeInterval] = []
        var parallelSamples: [TimeInterval] = []

        for _ in 0..<iterations {
            // --- Sequential baseline: all 5 base layers serially ---
            let sequentialStart = Date()
            for i in 0..<5 {
                _ = await verifier.runLayer(
                    i,
                    outputDocument: wrappedDoc,
                    sourcePageCount: pageCount,
                    regions: [:],
                    sensitiveTerms: sensitiveTerms,
                    pipelineMode: .secureRasterization,
                    filterDigests: [],
                    perPageModes: perPageModes
                )
            }
            sequentialSamples.append(Date().timeIntervalSince(sequentialStart))

            // --- Parallel arrangement: 0/1/2 in task group, then 3, 4 ---
            let parallelStart = Date()
            _ = await Self.runParallelBase(
                layers: [0, 1, 2],
                verifier: verifier,
                doc: wrappedDoc,
                sourcePageCount: pageCount,
                regions: [:],
                sensitiveTerms: sensitiveTerms,
                pipelineMode: .secureRasterization,
                filterDigests: [],
                perPageModes: perPageModes
            )
            _ = await Self.runSequential(
                layers: [3, 4],
                verifier: verifier,
                doc: wrappedDoc,
                sourcePageCount: pageCount,
                regions: [:],
                sensitiveTerms: sensitiveTerms,
                pipelineMode: .secureRasterization,
                filterDigests: [],
                perPageModes: perPageModes
            )
            parallelSamples.append(Date().timeIntervalSince(parallelStart))
        }

        // Trim the worst outlier (iter 1 often shows first-touch
        // Vision warmup overhead even after the warm-up pass — task-
        // group creation is the first parallel dispatch the
        // VerificationEngine instance sees).
        let trimmedSequential = sequentialSamples.sorted().dropLast()
        let trimmedParallel = parallelSamples.sorted().dropLast()
        let sequentialAvg = trimmedSequential.reduce(0, +) / Double(trimmedSequential.count)
        let parallelAvg = trimmedParallel.reduce(0, +) / Double(trimmedParallel.count)

        // Acceptance: plan §5 acceptance is "Total verification
        // wall-clock reduced; correctness invariants preserved." The
        // test asserts the "reduced" side (parallel beats sequential)
        // and reports the 0.5× strict aspirational bar to the test
        // log without asserting on it — the strict ratio depends on
        // the per-layer work balance, which the synthetic fixture
        // does not provide. Real-world documents with comparable
        // text-extraction / OCR / byte-scan work tend to hit ≈ 0.5×
        // per the plan body.
        let strictTarget = sequentialAvg * 0.5
        #expect(
            parallelAvg < sequentialAvg,
            """
            Parallel verify wall-clock did not beat sequential baseline.
            avg parallel (trimmed): \(parallelAvg)s
            avg sequential (trimmed): \(sequentialAvg)s
            strict §5 target (0.5×): \(strictTarget)s
            samples: seq=\(sequentialSamples), par=\(parallelSamples)
            """
        )
        // Non-asserting visibility into the strict-target achievement.
        let hitStrictTarget = parallelAvg < strictTarget
        let speedupPct = (1 - parallelAvg / sequentialAvg) * 100
        print("[PERF-6] Parallel verify wall-clock speedup: " +
              "\(String(format: "%.1f", speedupPct))% " +
              "(strict §5 0.5× target \(hitStrictTarget ? "hit" : "not hit") " +
              "on synthetic fixture). " +
              "Sequential avg=\(sequentialAvg)s, parallel avg=\(parallelAvg)s.")
    }

    // MARK: - Test 5 — Correctness invariants preserved

    @Test("Layer-result correctness matches sequential dispatch")
    func testCorrectnessInvariantsPreserved() async throws {
        // Sanity gate: the parallel dispatch must not alter the
        // per-layer status compared to a strictly sequential run. Per
        // the plan, the existing engine correctness suite is the
        // ultimate guard — this test confirms the dispatch wrapper
        // itself is transparent (same inputs → same per-layer outputs).
        // Two pages keeps the OCR cost low enough to coexist with the
        // engine suite's wall-clock-budgeted neighbours.
        let (doc, url) = try await makeMultiPagePDF(pageCount: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let verifier = VerificationEngine()
        let wrappedDoc = SendablePDFDocument(doc)
        let pageCount = doc.pageCount
        let perPageModes = Array(repeating: PipelineMode.secureRasterization, count: pageCount)

        // Sequential run (baseline)
        var sequentialResults: [LayerResult] = []
        for i in 0..<5 {
            let result = await verifier.runLayer(
                i,
                outputDocument: wrappedDoc,
                sourcePageCount: pageCount,
                regions: [:],
                sensitiveTerms: [],
                pipelineMode: .secureRasterization,
                filterDigests: [],
                perPageModes: perPageModes
            )
            sequentialResults.append(result)
        }

        // Parallel-then-sequential run (production shape)
        let parallel = await Self.runParallelBase(
            layers: [0, 1, 2],
            verifier: verifier,
            doc: wrappedDoc,
            sourcePageCount: pageCount,
            regions: [:],
            sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [],
            perPageModes: perPageModes
        )
        let post = await Self.runSequential(
            layers: [3, 4],
            verifier: verifier,
            doc: wrappedDoc,
            sourcePageCount: pageCount,
            regions: [:],
            sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [],
            perPageModes: perPageModes
        )
        let parallelResults: [LayerResult] = (parallel + post).map { $0.result }

        #expect(parallelResults.count == 5)
        for i in 0..<5 {
            #expect(
                parallelResults[i].name == sequentialResults[i].name,
                "Layer \(i) name should be stable across dispatch shape"
            )
            // .skipped never appears for these layers in
            // .secureRasterization — confirm the status kind matches.
            #expect(
                parallelResults[i].status.isFail == sequentialResults[i].status.isFail,
                "Layer \(i) FAIL status should be stable across dispatch shape"
            )
            #expect(
                parallelResults[i].status.isWarn == sequentialResults[i].status.isWarn,
                "Layer \(i) WARN status should be stable across dispatch shape"
            )
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
