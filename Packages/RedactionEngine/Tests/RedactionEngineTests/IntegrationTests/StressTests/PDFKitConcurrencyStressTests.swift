import CoreGraphics
import Foundation
import PDFKit
import Testing
import os
@testable import RedactionEngine

// C-F (CAT-127 / CAT-363) — PDFKit concurrency runtime stress harness.
//
// This suite is the `needs_runtime_check` resolver for CAT-127 and CAT-363.
// The structural guards (G1/G1b/G2/G3 in ParallelVerificationDocumentTests +
// PageRasterizerTests) carry the failing-then-green half of the proof bar;
// this harness is the corroborating runtime evidence — it provokes the
// concurrency hazards by design and is run under ThreadSanitizer per
// the deep-plan §5.3 protocol.
//
// Gating: the suite is SKIPPED unless `RUN_CONCURRENCY_STRESS` is present in
// the environment (forwarded into the test-runner process via
// `TEST_RUNNER_RUN_CONCURRENCY_STRESS=1`). `.enabled(if:)` is the correct
// swift-testing skip trait here — `withKnownIssue` would FAIL a gated-off run
// when the "known issue" does not occur. `.serialized` keeps the stress cases
// from racing each other for the simulator's finite memory so each case's own
// concurrency is the only variable.
//
// TSan note: these tests run on the iOS simulator ONLY (never a physical
// device). TSan does not instrument system frameworks, so a race living wholly
// inside PDFKit/CG internals surfaces only as a crash or value divergence, not
// a TSan report (deep-plan §6). A clean T4/T5 is therefore strong-but-partial
// evidence; the structural fix confines that residual to the surviving
// read-only `extractCharacters` / OCG-walk / `validatePage` paths.
//
// ARCH §12.2: fixtures carry synthetic tokens only; no document content,
// file paths, or coordinates are logged.

@Suite(
    "PDFKit Concurrency Stress",
    .tags(.stress),
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["RUN_CONCURRENCY_STRESS"] != nil)
)
struct PDFKitConcurrencyStressTests {

    // MARK: - Fixtures

    /// 10-page synthetic fixture with a real text layer (seed 42 → byte-stable).
    /// Caller owns cleanup.
    private func makeTextFixture(pageCount: Int = 10) throws -> URL {
        try StressFixtureBuilder.buildStressFixture(pageCount: pageCount, seed: 42)
    }

    /// 5-page fixture carrying a document `/Outlines` (bookmark) tree, so the
    /// T2 `outlineRoot` cold-build path has something to build. Hand-built via
    /// `buildRawPDF` so the outline dictionary is present in the raw bytes.
    private func writeBookmarkedFixture() throws -> URL {
        // Catalog → Pages(5 kids) → /Outlines with two top-level items.
        // Page object ids 10..14; outline dict id 3, items 4 & 5.
        var objects: [PDFObject] = [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R /Outlines 3 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [10 0 R 11 0 R 12 0 R 13 0 R 14 0 R] /Count 5 >>"),
            PDFObject(id: 3, content: "<< /Type /Outlines /First 4 0 R /Last 5 0 R /Count 2 >>"),
            PDFObject(id: 4, content: "<< /Title (Section One) /Parent 3 0 R /Next 5 0 R /Dest [10 0 R /Fit] >>"),
            PDFObject(id: 5, content: "<< /Title (Section Two) /Parent 3 0 R /Prev 4 0 R /Dest [12 0 R /Fit] >>"),
        ]
        // Five pages, each with a tiny real text stream so page.string is
        // non-empty for the page-walk tasks.
        for (offset, pageId) in (10...14).enumerated() {
            let streamId = 20 + offset
            let text = "Section page \(offset + 1) synthetic body token"
            let stream = "BT /F1 12 Tf 72 700 Td (\(text)) Tj ET"
            objects.append(PDFObject(id: pageId, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents \(streamId) 0 R \
                /Resources << /Font << /F1 6 0 R >> >> >>
                """))
            objects.append(PDFObject(
                id: streamId,
                content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"
            ))
        }
        objects.append(PDFObject(
            id: 6,
            content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
        ))
        let data = buildRawPDF(objects: objects, rootId: 1)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmarked_\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }

    /// OCG-hidden-layer fixture (A2-12): exercises the concurrent
    /// `pageReferencesHiddenOCG` pageRef/dictionary walk inside
    /// `extractCharacters(hasHiddenOCG: true)`.
    private func writeOCGFixture() throws -> URL {
        let data = TestFixtures.ocgHiddenLayerPDF()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocg_\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }

    // Layer dispatch parameters shared by T3/T4. Searchable mode keeps all 10
    // layer indices valid; empty regions/terms make the layer outcomes
    // deterministic functions of the (immutable) fixture bytes.
    private func layerParams(pageCount: Int)
        -> (regions: [Int: [RedactionRegion]], terms: [String],
            digests: [PageFilterDigest?], modes: [PipelineMode]) {
        (
            regions: [:],
            terms: [],
            digests: Array(repeating: nil, count: pageCount),
            modes: Array(repeating: .searchableRedaction, count: pageCount)
        )
    }

    // MARK: - T0 — CGPDFPage lifetime probe (deep-plan §1.2 charge b)

    @Test("T0 — CGPDFPage outlives its source PDFDocument", .tags(.stress))
    func cgPageOutlivesSourceDocument() async throws {
        let url = try makeTextFixture(pageCount: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        // Capture the CGPDFPage + geometry inside a pool that owns the
        // PDFDocument, then let the pool drain so the PDFDocument is released.
        var capturedCG: CGPDFPage?
        var capturedBounds = CGRect.zero
        autoreleasepool {
            guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return }
            capturedCG = page.pageRef
            capturedBounds = page.bounds(for: .cropBox)
        }

        let cgPage = try #require(capturedCG, "pageRef capture failed")
        // Render the now-orphaned CGPDFPage through the production CG path.
        let image = try await PageRasterizer().renderPageFromCGPage(
            cgPage, bounds: capturedBounds, rotation: 0, pageIndex: 0, dpi: 72
        )
        #expect(image.width > 0 && image.height > 0)
        // Contingency if this ever fails: document "PDFPageData must not outlive
        // its source document" on the struct + a Debug assertion — NOT a
        // redesign (deep-plan §1.2 charge b).
    }

    // MARK: - T1 — shared-doc concurrent reads (characterization)

    @Test("T1 — shared-doc concurrent page reads (characterization)", .tags(.stress))
    func sharedDocConcurrentPageReadsCharacterization() async throws {
        let url = try makeTextFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let shared = SendablePDFDocument(try #require(PDFDocument(url: url)))
        let pageCount = shared.document.pageCount

        // Serial baseline: page.string per page.
        var baseline: [Int: Int] = [:]   // pageIndex → character count
        for i in 0..<pageCount {
            baseline[i] = shared.document.page(at: i)?.string?.count ?? 0
        }

        // 20 iterations × 10 tasks reading page(at:)+bounds+string on the
        // SAME shared document. This access pattern is exactly the one the
        // CAT-363 fix removes from production; surfacing it under TSan
        // retroactively justifies the fix (informational — not a gate).
        for _ in 0..<20 {
            let barrier = StartBarrier(expected: 10)
            let observed = try await withThrowingTaskGroup(of: (Int, Int).self) { group in
                for t in 0..<10 {
                    group.addTask {
                        await barrier.arrive()
                        let idx = t % pageCount
                        guard let page = shared.document.page(at: idx) else { return (idx, -1) }
                        _ = page.bounds(for: .cropBox)
                        return (idx, page.string?.count ?? 0)
                    }
                }
                await barrier.release()
                var out: [(Int, Int)] = []
                for try await pair in group { out.append(pair) }
                return out
            }
            for (idx, count) in observed where count >= 0 {
                #expect(count == baseline[idx], "value divergence on shared-doc read")
            }
        }
    }

    // MARK: - T2 — cold outlineRoot vs page walks (characterization)

    @Test("T2 — cold outlineRoot build raced with page walks", .tags(.stress))
    func outlineRootColdBuildVsPageWalks() async throws {
        let url = try writeBookmarkedFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        // Each iteration opens a FRESH document so the outlineRoot read is
        // genuinely cold (a cached pointer would be pure flake theater —
        // deep-plan supersedes the dossier's single-instance Test 2).
        for _ in 0..<200 {
            let doc = try #require(PDFDocument(url: url))
            let shared = SendablePDFDocument(doc)
            let barrier = StartBarrier(expected: 4)
            let outlinePresent = try await withThrowingTaskGroup(of: Bool.self) { group in
                // Task A: the one cold outlineRoot read.
                group.addTask {
                    await barrier.arrive()
                    return shared.document.outlineRoot != nil
                }
                // Tasks B/C/D: page walks over 5 pages.
                for _ in 0..<3 {
                    group.addTask {
                        await barrier.arrive()
                        for p in 0..<min(5, shared.document.pageCount) {
                            _ = shared.document.page(at: p)?.string
                        }
                        return true
                    }
                }
                await barrier.release()
                var anyOutline = false
                for try await present in group { anyOutline = anyOutline || present }
                return anyOutline
            }
            #expect(outlinePresent, "bookmarked fixture lost its /Outlines under concurrent cold build")
        }
    }

    // MARK: - T3 — pre-fix shared-doc parallel layers (RUN-ONCE, then DELETED)
    //
    // T3 (`sharedDocParallelLayersCharacterization`) reconstructed the pre-fix
    // CAT-363 configuration in-test (3 verification layers racing ONE shared
    // SendablePDFDocument) to capture the "before" TSan evidence. Per deep-plan
    // §5.3(3) it was run once under TSan on 2026-06-13 (passed, value-stable,
    // ZERO ThreadSanitizer reports — the shared-doc race lives inside PDFKit's
    // uninstrumented internals, §6 blind spot) and then DELETED, because
    // post-fix it exercises a dead configuration and the structural guard G1
    // (ParallelVerificationDocumentTests, red→green) carries the regression.
    // Evidence: sessions/cf-stress-evidence/T3-prefix-tsan-evidence.md.

    // MARK: - T4 — distinct-doc parallel layers (GATE)

    @Test("T4 — distinct-doc parallel layers TSan-clean", .tags(.stress))
    func distinctDocsParallelLayersTSanClean() async throws {
        let url = try makeTextFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let verifier = VerificationEngine()
        let params = layerParams(pageCount: 10)
        // Layers 0/1/2 + the layer-9 operator re-extraction path — the four
        // PERF-6 base layers, each on its OWN PDFDocument(url:) instance.
        let layers = [0, 1, 2, 9]

        let reference = try await serialLayerReference(
            url: url, layers: layers, verifier: verifier, params: params)

        let startMemory = os_proc_available_memory()
        var peakDelta = 0
        for _ in 0..<30 {
            let barrier = StartBarrier(expected: layers.count)
            let observed = try await withThrowingTaskGroup(of: (Int, VerificationStatus?).self) { group in
                for layer in layers {
                    group.addTask {
                        await barrier.arrive()
                        // Concurrent PDFDocument(url:) init is itself part of
                        // what this gate validates — open inside the raced span.
                        guard let doc = PDFDocument(url: url) else { return (layer, nil) }
                        let r = await verifier.runLayer(
                            layer, outputDocument: SendablePDFDocument(doc),
                            sourcePageCount: 10,
                            regions: params.regions, sensitiveTerms: params.terms,
                            pipelineMode: .searchableRedaction,
                            filterDigests: params.digests, perPageModes: params.modes)
                        return (layer, r.status)
                    }
                }
                await barrier.release()
                var out: [Int: VerificationStatus] = [:]
                for try await (l, s) in group { out[l] = s }
                return out
            }
            for layer in layers {
                let status = try #require(observed[layer], "layer \(layer) doc open failed")
                #expect(status == reference[layer], "layer \(layer) parallel≠serial")
            }
            peakDelta = max(peakDelta, max(0, startMemory - os_proc_available_memory()))
        }
        // Informational only (deep-plan §5.2 T4 "Log os_proc_available_memory delta").
        print("[stress T4] peak os_proc_available_memory delta over 30 iters: \(peakDelta) bytes")
    }

    // MARK: - T5 — extractCharacters concurrent on shared source (GATE)

    @Test("T5 — concurrent extractCharacters on shared source is value-stable", .tags(.stress))
    func extractCharactersConcurrentSharedSourceStable() async throws {
        let url = try makeTextFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let shared = SendablePDFDocument(try #require(PDFDocument(url: url)))
        let pageCount = shared.document.pageCount
        let extractor = TextLayerExtractor()

        // Serial baseline: one extractCharacters per page.
        var baseline: [Int: [CharacterInfo]] = [:]
        for i in 0..<pageCount {
            guard let page = shared.document.page(at: i) else { continue }
            baseline[i] = try await extractor.extractCharacters(from: page, hasHiddenOCG: false)
        }

        for _ in 0..<20 {
            let barrier = StartBarrier(expected: pageCount)
            let observed = try await withThrowingTaskGroup(of: (Int, [CharacterInfo]).self) { group in
                for i in 0..<pageCount {
                    group.addTask {
                        await barrier.arrive()
                        guard let page = shared.document.page(at: i) else { return (i, []) }
                        let chars = try await extractor.extractCharacters(from: page, hasHiddenOCG: false)
                        return (i, chars)
                    }
                }
                await barrier.release()
                var out: [Int: [CharacterInfo]] = [:]
                for try await (i, chars) in group { out[i] = chars }
                return out
            }
            for i in 0..<pageCount {
                let base = baseline[i] ?? []
                let got = observed[i] ?? []
                #expect(got.count == base.count, "page \(i): char count diverged under concurrency")
                guard got.count == base.count else { continue }
                for (a, b) in zip(base, got) {
                    #expect(a.character == b.character, "page \(i): char value diverged")
                    #expect(abs(a.bounds.minX - b.bounds.minX) < 1e-4
                        && abs(a.bounds.minY - b.bounds.minY) < 1e-4
                        && abs(a.bounds.width - b.bounds.width) < 1e-4
                        && abs(a.bounds.height - b.bounds.height) < 1e-4,
                        "page \(i): char bounds diverged beyond 1e-4")
                }
            }
        }

        // A2-12 — OCG branch coverage. The hidden-OCG fixture drives the
        // concurrent `pageReferencesHiddenOCG` pageRef/dictionary walk inside
        // extractCharacters(hasHiddenOCG: true), which throws
        // `.reconstructionFailed` per page (AD-2-1). Racing it across iterations
        // exercises that CG-dictionary walk under TSan — the second surviving
        // concurrent PDFKit surface named in the §1.2-C.7 comment.
        let ocgURL = try writeOCGFixture()
        defer { try? FileManager.default.removeItem(at: ocgURL) }
        let ocgDoc = SendablePDFDocument(try #require(PDFDocument(url: ocgURL)))
        for _ in 0..<20 {
            let barrier = StartBarrier(expected: 4)
            let threwCount = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<4 {
                    group.addTask {
                        await barrier.arrive()
                        guard let page = ocgDoc.document.page(at: 0) else { return false }
                        do { // LegalPhrases:safe (Swift keyword)
                            _ = try await extractor.extractCharacters(from: page, hasHiddenOCG: true)
                            return false
                        } catch { // LegalPhrases:safe (Swift keyword)
                            return true
                        }
                    }
                }
                await barrier.release()
                var n = 0
                for await threw in group where threw { n += 1 }
                return n
            }
            #expect(threwCount == 4, "OCG hidden-layer defense did not fire on every concurrent task")
        }
    }

    // MARK: - T5b — validatePage concurrent shared-source (characterization)
    //
    // Post-F05 discovery (CAT-NEW-s06-1, deferred): `rasterize` calls
    // `validatePage(page.page, …)` (PixelOperations.swift) before render — a
    // SECOND read-only concurrent `page.page` access (page.bounds + page.pageRef
    // dictionary) the C-F memo (pinned pre-F05) did not enumerate. It is the same
    // read-only risk class as `extractCharacters`, not a new hazard, but the
    // harness should actually exercise it rather than only name it. This probe is
    // informational — the proper fix (feed validatePage the pre-extracted
    // cropBoxBounds, off the shared object graph) touches C-E's signature and is
    // deferred.

    @Test("T5b — concurrent validatePage on shared source (characterization)", .tags(.stress))
    func validatePageConcurrentSharedSourceCharacterization() async throws {
        let url = try makeTextFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let shared = SendablePDFDocument(try #require(PDFDocument(url: url)))
        let pageCount = shared.document.pageCount

        var baseline: [Int: Bool] = [:]
        for i in 0..<pageCount {
            guard let page = shared.document.page(at: i) else { continue }
            baseline[i] = validatePage(page, effectiveDPI: 150)
        }

        for _ in 0..<20 {
            let barrier = StartBarrier(expected: pageCount)
            let observed = await withTaskGroup(of: (Int, Bool).self) { group in
                for i in 0..<pageCount {
                    group.addTask {
                        await barrier.arrive()
                        guard let page = shared.document.page(at: i) else { return (i, false) }
                        return (i, validatePage(page, effectiveDPI: 150))
                    }
                }
                await barrier.release()
                var out: [Int: Bool] = [:]
                for await (i, ok) in group { out[i] = ok }
                return out
            }
            for i in 0..<pageCount {
                #expect(observed[i] == baseline[i], "page \(i): validatePage verdict diverged under concurrency")
            }
        }
    }

    // MARK: - T6 — extraction wall-clock share probe (no pass/fail)

    @Test("T6 — extraction wall-clock share probe", .tags(.stress))
    func extractionWallClockShareProbe() async throws {
        let url = try makeTextFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        guard let doc = PDFDocument(url: url) else { return }
        let pageCount = doc.pageCount
        let extractor = TextLayerExtractor()
        let rasterizer = PageRasterizer()

        // (a) serial extractCharacters over all pages.
        let extractStart = ContinuousClock.now
        for i in 0..<pageCount {
            guard let page = doc.page(at: i) else { continue }
            _ = try await extractor.extractCharacters(from: page, hasHiddenOCG: false)
        }
        let extractElapsed = ContinuousClock.now - extractStart

        // (b) full serial rasterize per page (searchable mode).
        let rasterStart = ContinuousClock.now
        for i in 0..<pageCount {
            guard let page = doc.page(at: i) else { continue }
            let data = PDFPageData(
                page: page, pageIndex: i,
                regions: [],
                fillColor: .black, targetDPI: 150,
                pipelineMode: .searchableRedaction, rotation: page.rotation,
                cropBoxBounds: page.bounds(for: .cropBox),
                cgPage: page.pageRef, hasText: (page.string?.isEmpty == false))
            _ = try await rasterizer.rasterize(data, dpiCap: 150)
        }
        let rasterElapsed = ContinuousClock.now - rasterStart

        let extractSec = seconds(extractElapsed)
        let rasterSec = seconds(rasterElapsed)
        let share = rasterSec > 0 ? extractSec / rasterSec : 0
        // No assertion — feeds the §1.3 Fallback-1-vs-2 rule (escalate to a
        // per-worker doc pool only if share > ~25%).
        print(String(
            format: "[stress T6] extraction share = %.1f%% (extract=%.3fs raster=%.3fs over %d pages)",
            share * 100, extractSec, rasterSec, pageCount))
    }

    // MARK: - T7 — D10-F1 per-consumer search copy isolates the background scan

    // SEARCH D10-F1 — the background search reads its OWN copy while the
    // on-screen instance is read concurrently (in production the PDFView /
    // MainActor rect resolution). Two DISTINCT PDFDocument instances ⇒ no
    // shared PDFKit object graph, so neither perturbs the other and nothing
    // traps. `DocumentState.makeSearchCopy` is app-side (not engine-visible);
    // its mechanism — `PDFDocument(data: source.dataRepresentation())` — is
    // replicated inline.
    @Test("T7 — search copy isolates the background scan from concurrent source reads", .tags(.stress))
    func searchCopyIsolatesBackgroundScan() async throws {
        let url = try makeTextFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = SendablePDFDocument(try #require(PDFDocument(url: url)))
        let pageCount = source.document.pageCount

        let copyData = try #require(source.document.dataRepresentation())
        let searchCopy = SendablePDFDocument(try #require(PDFDocument(data: copyData)))
        let searcher = DocumentSearcher()

        // Serial baseline of source page char counts for value-stability.
        var baseline: [Int: Int] = [:]
        for i in 0..<pageCount {
            baseline[i] = source.document.page(at: i)?.string?.count ?? 0
        }

        for _ in 0..<20 {
            let barrier = StartBarrier(expected: 5)
            let observed = try await withThrowingTaskGroup(of: (Int, Int).self) { group in
                // One task drains a full search over the COPY (off-actor).
                group.addTask {
                    await barrier.arrive()
                    let stream = searcher.search(
                        searchCopy,
                        mode: .text("token", options: SearchOptions()),
                        progress: { _, _ in })
                    for await _ in stream { }
                    return (-1, -1)   // sentinel — not a page read
                }
                // Four tasks read the SOURCE instance concurrently.
                for t in 0..<4 {
                    group.addTask {
                        await barrier.arrive()
                        let idx = t % pageCount
                        guard let page = source.document.page(at: idx) else { return (idx, -1) }
                        _ = page.bounds(for: .cropBox)
                        return (idx, page.string?.count ?? 0)
                    }
                }
                await barrier.release()
                var out: [(Int, Int)] = []
                for try await pair in group { out.append(pair) }
                return out
            }
            for (idx, count) in observed where idx >= 0 && count >= 0 {
                #expect(count == baseline[idx], "source read diverged while the copy was searched")
            }
        }
    }

    // MARK: - Helpers

    private func serialLayerReference(
        url: URL, layers: [Int], verifier: VerificationEngine,
        params: (regions: [Int: [RedactionRegion]], terms: [String],
                 digests: [PageFilterDigest?], modes: [PipelineMode])
    ) async throws -> [Int: VerificationStatus] {
        let doc = SendablePDFDocument(try #require(PDFDocument(url: url)))
        var out: [Int: VerificationStatus] = [:]
        for layer in layers {
            let r = await verifier.runLayer(
                layer, outputDocument: doc, sourcePageCount: doc.document.pageCount,
                regions: params.regions, sensitiveTerms: params.terms,
                pipelineMode: .searchableRedaction,
                filterDigests: params.digests, perPageModes: params.modes)
            out[layer] = r.status
        }
        return out
    }

    private func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

// MARK: - Start barrier

/// Tiny actor latch so all racing tasks begin their contended work at the
/// same instant — overlap is maximal and repeatable rather than dependent on
/// task-spawn ordering. Single-shot: construct one per iteration.
private actor StartBarrier {
    private let expected: Int
    private var arrived = 0
    private var open = false
    private var gate: [CheckedContinuation<Void, Never>] = []
    private var allArrived: CheckedContinuation<Void, Never>?

    init(expected: Int) { self.expected = expected }

    /// A racing task registers its arrival, then suspends until `release()`
    /// opens the gate.
    func arrive() async {
        arrived += 1
        if arrived == expected {
            allArrived?.resume()
            allArrived = nil
        }
        if open { return }
        await withCheckedContinuation { gate.append($0) }
    }

    /// The coordinator awaits all expected tasks reaching the gate, then opens
    /// it so they proceed together.
    func release() async {
        if arrived < expected {
            await withCheckedContinuation { allArrived = $0 }
        }
        open = true
        for c in gate { c.resume() }
        gate.removeAll()
    }
}
