import Testing
import Foundation
import PDFKit
import UIKit
import os
@testable import ResectaApp
@testable import RedactionEngine

// CAT-227 — Apply-phase memory-stress harness (C-E deep plan §5, amended by
// the ADV-1 streaming-design attack: headless/fable-adv-1-output.md).
//
// This suite proves that the streaming ordered append (CAT-125 / D-32) bounds
// the apply-phase resident footprint independently of page count, superseding
// the PERF-2 collect-then-drain mechanism that held all N full-res CGImages
// resident at the end of the parallel phase (the P0 jetsam cliff).
//
// Proof bar (deep plan §5):
//   * `testResidentRasterCountBounded` is THE deterministic merge gate — no
//     memory measurement, immune to the compressor, host cores, and CI
//     variance. The superseded architecture drives the counter to N+1, so the
//     assertion is structurally red on the unfixed design.
//   * The footprint tests (`...FootprintBoundedStreaming`, `...PeakFootprint`)
//     are measurement artifacts with a documented relax/demote path; they
//     never weaken the bar (test 1 stays the gate).
//
// Serialized + 5-minute per-test limit: the unfixed worst-case allocation
// (~3.4 GB on a 100-page noise fixture) is host-RAM-safe, so a breach fails by
// assertion rather than wedging the simulator. If the iPhone 17 sim DOES wedge:
// `pkill -9 -f xctest` → `xcrun simctl shutdown all` → `xcrun simctl erase`,
// then re-run isolated; never trust a red that follows a wedge.
//
// Privacy: the noise fixture is synthetic; tests read only the process's own
// memory accounting (MemoryFootprint), never document content or coordinates.
@Suite("CAT-227 Apply-Phase Memory Stress", .serialized, .tags(.coordination))
@MainActor
struct ApplyPhaseMemoryStressTests {

    /// Apply-phase footprint ceiling (bytes). Deep plan §5 / ADV-1 A1-6:
    /// the realistic fixed-run upper at override=4 is ≈ 823 MB (≈3·inFlight +
    /// pending + 1 pagefuls of residency + the ~250 MB JPEG floor + ≤135 MB
    /// pool); the unfixed compressed-worst-case floor at 100 pages is ≈
    /// 1.68 GB. 1.1 GB sits below the fixed upper with margin and well under
    /// the unfixed floor. Per the deep plan's relax-once protocol this may be
    /// raised to 1.4 GB if host variance bites — test 1 remains the gate.
    static let footprintCeiling: Int64 = 1_100_000_000

    // MARK: - Test 1 — deterministic residency gate (THE merge gate)

    @Test(
        "maxResidentResults stays within 2*bound+1 under streaming append (override=2)",
        .timeLimit(.minutes(5))
    )
    func testResidentRasterCountBounded() async throws {
        let pageCount = 30
        let url = try makeNoiseBandMultiPagePDF(pages: pageCount)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let doc = PDFDocument(url: url) else {
            Issue.record("Failed to load noise fixture"); return
        }

        let coord = makeLoadedCoordinator(document: doc)
        addRegionToAllPages(coord, pageCount: pageCount)
        // override=2 ⇒ bound = min(natural, 2) ≤ 2 always, so the accounting
        // residency bound 2*bound+1 ≤ 5 cannot false-red on a many-core host.
        coord.parallelismOverride = 2

        let pageData = coord.buildPDFPageData(effectiveMode: .secureRasterization)
        #expect(pageData.count == pageCount)

        // Real reconstructor so the callback exercises the true append path.
        // ADV-1 A1-7: begin(firstPageSize:) MUST run before appendPage or it
        // throws .reconstructionFailed.
        let reconstructor = try await makeStartedReconstructor()
        let rasterizer = PageRasterizer()
        try await coord.rasterizePagesInParallel(
            pages: pageData, rasterizer: rasterizer
        ) { _, result in
            try await reconstructor.recon.appendPage(result.pageOutput)
        }
        await reconstructor.recon.finalize()

        // Limitation (ADV-1 A1-7): without an engine-side per-page delay seam
        // (the engine package is untouched this session) the natural
        // out-of-order depth on a uniform fixture is shallow, so this asserts
        // the bound holds on a well-behaved run rather than adversarially
        // stressing the refill-gate `pending` term. Its load-bearing job is
        // the anti-regression gate: the superseded collect-then-drain drove
        // this counter to N+1 (=\(pageCount + 1) here) — structurally red.
        #expect(
            coord.maxResidentResults <= 2 * 2 + 1,
            "completed-result residency \(coord.maxResidentResults) exceeded 2*bound+1=5 at override=2 (unfixed collect-then-drain would reach \(pageCount + 1))"
        )
        #expect(coord.maxResidentResults >= 1,
                "residency counter never advanced — run produced no completions")
    }

    // MARK: - Test 2 — white-box footprint sampled at the append hook

    @Test(
        "streaming apply-phase footprint stays bounded sampled at the append hook (override=4)",
        .timeLimit(.minutes(5))
    )
    func testApplyPhaseFootprintBoundedStreaming() async throws {
        let pageCount = 100
        let url = try makeNoiseBandMultiPagePDF(pages: pageCount)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let doc = PDFDocument(url: url) else {
            Issue.record("Failed to load noise fixture"); return
        }

        let coord = makeLoadedCoordinator(document: doc)
        addRegionToAllPages(coord, pageCount: pageCount)
        coord.parallelismOverride = 4

        let pageData = coord.buildPDFPageData(effectiveMode: .secureRasterization)
        #expect(pageData.count == pageCount)

        let reconstructor = try await makeStartedReconstructor()
        let rasterizer = PageRasterizer()
        let log = OSLog(subsystem: "com.resecta.tests.cat227", category: .pointsOfInterest)

        let baseline = MemoryFootprint.physFootprint()
        var peakDelta: Int64 = 0

        try await coord.rasterizePagesInParallel(
            pages: pageData, rasterizer: rasterizer
        ) { idx, result in
            try await reconstructor.recon.appendPage(result.pageOutput)
            // Sample every 10th page at the deterministic hook.
            if idx % 10 == 0 {
                let fp = MemoryFootprint.physFootprint()
                let avail = MemoryFootprint.osProcAvailableMemory()  // D-1 probe, logged only
                os_signpost(.event, log: log, name: "CAT227StreamingFootprint",
                            "page=%d footprintBytes=%lld availBytes=%lld",
                            idx, fp, avail)
                if fp > 0 && baseline > 0 {
                    peakDelta = max(peakDelta, fp - baseline)
                }
            }
        }
        await reconstructor.recon.finalize()

        guard baseline > 0, peakDelta > 0 else {
            // phys_footprint unavailable on this host → cannot measure. Surface
            // the skip; test 1 is the deterministic gate. (CAT-230 idiom: never
            // a silent zero-assertion pass.)
            withKnownIssue(
                "phys_footprint unavailable on this host; streaming footprint not asserted (test 1 is the gate)"
            ) {
                Issue.record("baseline=\(baseline) peakDelta=\(peakDelta): footprint read failed")
            }
            return
        }

        // Self-documenting measured value (process-memory bytes only — no
        // document content; ARCH §12.2). Appears in the test log on pass.
        print("[CAT-227] streaming append peak delta = \(peakDelta) B (\(peakDelta / 1_000_000) MB), ceiling \(Self.footprintCeiling) B, override=4, \(pageCount) pages")
        #expect(
            peakDelta <= Self.footprintCeiling,
            "streaming apply-phase footprint delta \(peakDelta) B exceeded ceiling \(Self.footprintCeiling) B (override=4, \(pageCount) pages)"
        )
    }

    // MARK: - Test 3 — end-to-end peak footprint (the red→green artifact)

    @Test(
        "end-to-end apply-phase peak footprint bounded via runFullPipeline (override=4, verify off)",
        .timeLimit(.minutes(5))
    )
    func testEndToEndApplyPhasePeakFootprint() async throws {
        let pageCount = 100  // ADV-1 edit 1: 100, not 60 — the 60-page compressed
                             // floor (~1.01 GB) can fall under the 1.1 GB ceiling.
        let url = try makeNoiseBandMultiPagePDF(pages: pageCount)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let doc = PDFDocument(url: url) else {
            Issue.record("Failed to load noise fixture"); return
        }

        let coord = makeLoadedCoordinator(document: doc)
        addRegionToAllPages(coord, pageCount: pageCount)
        // ADV-1 edit 1: pin parallelism (property exists pre-fix, so the RED
        // run on the collect-then-drain base still compiles) and turn verify
        // OFF so the sampler covers the redact/apply phase only (autoVerify
        // defaults to true; paranoidMode defaults to false).
        coord.parallelismOverride = 4
        let priorAutoVerify = coord.settingsState.autoVerify
        coord.settingsState.autoVerify = false
        defer { coord.settingsState.autoVerify = priorAutoVerify }

        let baseline = MemoryFootprint.physFootprint()

        coord.runFullPipeline(documentOverride: .secureRasterization)
        let pipelineTask = coord.documentState.activePipelineTask

        // Concurrent sampler: poll every 50 ms. The unfixed peak plateau spans
        // the whole drain phase (seconds), so a 50 ms poller cannot miss it.
        // Both this Task and the awaiting test body are MainActor-isolated, so
        // access to the peak box is serialized on the actor.
        let peakBox = PeakFootprintBox()
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                let fp = MemoryFootprint.physFootprint()
                if fp > 0 { peakBox.update(fp) }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { sampler.cancel() }

        await pipelineTask?.value
        sampler.cancel()

        let peak = peakBox.peak
        guard baseline > 0, peak > 0 else {
            withKnownIssue(
                "phys_footprint unavailable on this host; peak not asserted (test 1 is the gate)"
            ) {
                Issue.record("baseline=\(baseline) peak=\(peak): footprint read failed")
            }
            return
        }
        let delta = peak - baseline
        let log = OSLog(subsystem: "com.resecta.tests.cat227", category: .pointsOfInterest)
        os_signpost(.event, log: log, name: "CAT227EndToEndPeak",
                    "deltaBytes=%lld baselineBytes=%lld peakBytes=%lld pages=%d",
                    delta, baseline, peak, pageCount)

        // Self-documenting measured value (process-memory bytes only — no
        // document content; ARCH §12.2). Appears in the test log on pass and
        // in the assertion message on the pre-fix RED run.
        print("[CAT-227] end-to-end peak delta = \(delta) B (\(delta / 1_000_000) MB), ceiling \(Self.footprintCeiling) B, override=4, \(pageCount) pages, verify off")
        // Expected RED (pre-fix collect-then-drain) ≈ ≥ 1.68 GB; expected GREEN
        // (streaming) ≈ ≤ 0.85 GB. See PR body for both measured runs.
        #expect(
            delta <= Self.footprintCeiling,
            "end-to-end apply-phase peak footprint delta \(delta) B exceeded ceiling \(Self.footprintCeiling) B; unfixed collect-then-drain expected ≥1.68 GB, streaming ≤0.85 GB (override=4, \(pageCount) pages, verify off)"
        )
    }

    // MARK: - Test 4 — residency bound survives a mid-run memory warning (L3-9)

    @Test(
        "residency accounting bound holds across a mid-run memory warning",
        .timeLimit(.minutes(5))
    )
    func testResidencyBoundSurvivesMidRunWarning() async throws {
        let pageCount = 40
        let url = try makeNoiseBandMultiPagePDF(pages: pageCount)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let doc = PDFDocument(url: url) else {
            Issue.record("Failed to load noise fixture"); return
        }

        let coord = makeLoadedCoordinator(document: doc)
        addRegionToAllPages(coord, pageCount: pageCount)
        let preWarningBound = 4
        coord.parallelismOverride = preWarningBound

        let pageData = coord.buildPDFPageData(effectiveMode: .secureRasterization)

        // Let the coordinator's async memory-warning observer reach its
        // `for await` so a posted notification is actually delivered.
        for _ in 0..<5 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))

        let reconstructor = try await makeStartedReconstructor()
        let rasterizer = PageRasterizer()
        try await coord.rasterizePagesInParallel(
            pages: pageData, rasterizer: rasterizer
        ) { idx, result in
            try await reconstructor.recon.appendPage(result.pageOutput)
            // Post a memory warning partway through, while `pending` may be
            // non-empty, so the override collapses bound 4 → 1 mid-run.
            if idx == 5 {
                NotificationCenter.default.post(
                    name: UIApplication.didReceiveMemoryWarningNotification,
                    object: nil
                )
            }
        }
        await reconstructor.recon.finalize()

        // The warning lowers the bound (and residentCap) for SUBSEQUENT
        // submissions, but pages already in flight at the pre-warning bound
        // must still drain. The accounting bound must never exceed
        // 2*(pre-warning bound)+1 — and this holds whether or not the warning
        // happened to land mid-run (an override=4 run alone is ≤ 9), so the
        // assertion is timing-tolerant and cannot false-fail.
        #expect(
            coord.maxResidentResults <= 2 * preWarningBound + 1,
            "residency \(coord.maxResidentResults) exceeded 2*(pre-warning bound \(preWarningBound))+1=\(2 * preWarningBound + 1) across a mid-run warning"
        )
    }

    // MARK: - Helpers (private)

    private func makeLoadedCoordinator(document: PDFDocument) -> PipelineCoordinator {
        let coord = PipelineCoordinator(
            documentState: DocumentState(),
            redactionState: RedactionState(),
            settingsState: SettingsState()
        )
        coord.documentState.sourceDocument = document
        coord.documentState.phase = .editing
        return coord
    }

    private func addRegionToAllPages(_ coord: PipelineCoordinator, pageCount: Int) {
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.04),
            source: .manual
        )
        for i in 0..<pageCount {
            coord.redactionState.regions[i] = [region]
        }
    }

    /// A `PDFStreamReconstructor` with a temp URL that is cleaned up when this
    /// wrapper deinits.
    private final class StartedReconstructor {
        let recon: PDFStreamReconstructor
        private let tempURL: URL
        init(tempURL: URL) {
            self.tempURL = tempURL
            self.recon = PDFStreamReconstructor(tempURL: tempURL)
        }
        deinit { try? FileManager.default.removeItem(at: tempURL) }
    }

    /// Build a reconstructor and run `begin(firstPageSize:)` (ADV-1 A1-7:
    /// `appendPage` throws unless `begin` ran first). Standard US-Letter size.
    private func makeStartedReconstructor() async throws -> StartedReconstructor {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cat227-recon-\(UUID().uuidString).pdf"
        )
        let wrapper = StartedReconstructor(tempURL: tempURL)
        try await wrapper.recon.begin(firstPageSize: CGSize(width: 612, height: 792))
        return wrapper
    }
}

/// MainActor-isolated peak accumulator shared between the end-to-end test body
/// and its concurrent sampler Task (both run on MainActor, so no data race).
@MainActor
private final class PeakFootprintBox {
    private(set) var peak: Int64 = 0
    func update(_ value: Int64) { if value > peak { peak = value } }
}
