import Foundation
import CoreGraphics
import PDFKit
import Testing
import CryptoKit
@testable import RedactionEngine

// H4.1 — Family-4 stage-timing emitter (1.2 instrumentation plan §6 row H4.1).
//
// ContinuousClock around each pipeline stage over the ratified doc set —
// packet / scan-sim / perf-filler-120 / huge-4999 — n = 5 sweeps, pooled
// per-page samples where the stage is per-page, per-doc samples otherwise;
// p50/p95 computed in-suite; peak footprint via TASK_VM_INFO.phys_footprint
// (the RealDocOCRQualityTests pattern — os_proc_available_memory is unusable
// on the simulator).
//
// Stages: validate_page · text_layer_detect · scan_text (H1.2 naturalRun) ·
// scan_ocr_natural (scan-sim product path) · scan_ocr_forced (packet, the
// L-20 seam) · rasterize_render_fill (per page, H2.2 processDocument mirror
// shape) · reconstruct_append / reconstruct_finalize · verify_layer:<name>
// (per-layer LayerResult.durationSeconds through the H2.2 runVerification
// mirror) · cancel_fill / cancel_verify (the PERF-8 cancel→surrender window).
//
// REPORT-ONLY (no gating asserts on latency values) and env-gated
// (RESECTA_PERF_OUT / RESECTA_DOCS_ROOT + the TEST_RUNNER_ forms). ISOLATED
// run only — its own xcodebuild invocation, never batched (memory
// `project_resecta_parallel_load_flaky_tests`); perf/timing numbers under
// parallel load are meaningless.
//
// v0 doc×stage boundaries (recorded, not silent): filler-120 skips the
// verification stage (10 layers × 120 pp × 5 sweeps of output OCR is a
// device-runsheet cost, not a sim-emitter one) and the huge/filler docs skip
// the OCR scan stages (no OCR leg applicability).

@Suite("H4.1 stage-timing emitter (standing, ISOLATED run only)", .serialized)
struct StageTimingEmitterTests {

    // MARK: - Env gate

    static func perfOut() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let p = env["RESECTA_PERF_OUT"], !p.isEmpty { return p }
        if let p = env["TEST_RUNNER_RESECTA_PERF_OUT"], !p.isEmpty { return p }
        return nil
    }
    static func docsRoot() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let p = env["RESECTA_DOCS_ROOT"], !p.isEmpty { return p }
        if let p = env["TEST_RUNNER_RESECTA_DOCS_ROOT"], !p.isEmpty { return p }
        return nil
    }

    // MARK: - Docs

    struct Doc {
        let id: String
        let docClass: String       // page-class label for the M12-16 row
        let data: Data
        let pages: Int
        let textLeg: Bool          // scan_text applicability
        let ocrLeg: Bool           // scan_ocr applicability
        let verifyLeg: Bool        // verification-stage applicability (v0 bounds)
    }

    static func loadDocs() throws -> (docs: [Doc], skipped: [String]) {
        var docs: [Doc] = []
        var skipped: [String] = []
        let packet = try TestFixtures.loanPacketPDF()
        docs.append(Doc(id: "packet", docClass: "born-digital-12pp", data: packet,
                        pages: 12, textLeg: true, ocrLeg: true, verifyLeg: true))
        let scanSim = try TestFixtures.loanPacketScanSimPDF()
        docs.append(Doc(id: "packet-scan-sim-150dpi", docClass: "scan-150dpi-12pp",
                        data: scanSim, pages: 12, textLeg: false, ocrLeg: true,
                        verifyLeg: true))
        if let root = docsRoot() {
            let rootURL = URL(fileURLWithPath: root)
            let external: [(String, String, String, Bool)] = [
                ("perf-filler-120pp", "dense-filler-120pp",
                 "variants/perf-filler-120pp.pdf", false),
                ("packet-huge-4999", "huge-page-4999pt",
                 "robustness/packet-huge-4999.pdf", true),
            ]
            for (id, cls, rel, verify) in external {
                let url = rootURL.appendingPathComponent(rel)
                if let data = try? Data(contentsOf: url),
                   let doc = PDFDocument(data: data) {
                    docs.append(Doc(id: id, docClass: cls, data: data,
                                    pages: doc.pageCount, textLeg: true,
                                    ocrLeg: false, verifyLeg: verify))
                } else {
                    skipped.append("\(id) (unreadable at \(rel))")
                }
            }
        } else {
            skipped.append("perf-filler-120pp + packet-huge-4999 (RESECTA_DOCS_ROOT unset)")
        }
        return (docs, skipped)
    }

    // MARK: - Measurement plumbing

    static let clock = ContinuousClock()
    static let nRuns = 5

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000
            + Double(d.components.attoseconds) / 1e15
    }

    /// TASK_VM_INFO.phys_footprint (simulator-safe residency reading).
    static func physFootprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }

    struct StageRow: Encodable {
        let doc: String
        let doc_class: String
        let stage: String
        let unit: String               // "per_page" | "per_doc" | "per_call"
        let n: Int
        let p50_ms: Double
        let p95_ms: Double
        let min_ms: Double
        let max_ms: Double
        let mean_ms: Double
        let footprint_before_mb: Double?
        let footprint_after_mb: Double?
        let peak_footprint_mb: Double?
        let notes: String?
    }

    final class FootprintTracker {
        let before: Double?
        private(set) var peak: Double?
        init() {
            before = StageTimingEmitterTests.physFootprintMB()
            peak = before
        }
        func sample() {
            guard let f = StageTimingEmitterTests.physFootprintMB() else { return }
            peak = max(peak ?? f, f)
        }
    }

    static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((q * Double(sorted.count)).rounded(.up)) - 1
        return sorted[max(0, min(sorted.count - 1, rank))]
    }

    static func row(doc: Doc, stage: String, unit: String, samples: [Double],
                    tracker: FootprintTracker, notes: String? = nil) -> StageRow {
        let sorted = samples.sorted()
        let r3: (Double) -> Double = { ($0 * 1000).rounded() / 1000 }
        return StageRow(
            doc: doc.id, doc_class: doc.docClass, stage: stage, unit: unit,
            n: samples.count,
            p50_ms: r3(percentile(sorted, 0.50)),
            p95_ms: r3(percentile(sorted, 0.95)),
            min_ms: r3(sorted.first ?? 0), max_ms: r3(sorted.last ?? 0),
            mean_ms: r3(samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count)),
            footprint_before_mb: tracker.before.map { ($0).rounded() },
            footprint_after_mb: physFootprintMB().map { ($0).rounded() },
            peak_footprint_mb: tracker.peak.map { ($0).rounded() },
            notes: notes)
    }

    // MARK: - Stage bodies

    static func sweepValidatePage(_ doc: Doc, tracker: FootprintTracker) -> [Double] {
        var samples: [Double] = []
        for _ in 0..<nRuns {
            guard let pdf = PDFDocument(data: doc.data) else { continue }
            for i in 0..<pdf.pageCount {
                guard let page = pdf.page(at: i) else { continue }
                let t0 = clock.now
                _ = validatePage(page)
                samples.append(ms(clock.now - t0))
            }
            tracker.sample()
        }
        return samples
    }

    static func sweepTextLayerDetect(_ doc: Doc, tracker: FootprintTracker) -> [Double] {
        var samples: [Double] = []
        for _ in 0..<nRuns {
            guard let pdf = PDFDocument(data: doc.data) else { continue }
            for i in 0..<pdf.pageCount {
                guard let page = pdf.page(at: i) else { continue }
                let t0 = clock.now
                _ = TextLayerDetector.detectTextLayer(page)
                samples.append(ms(clock.now - t0))
            }
            tracker.sample()
        }
        return samples
    }

    static func mirroredStatus(_ data: Data) -> [Int: TextLayerStatus] {
        guard let pdf = PDFDocument(data: data) else { return [:] }
        var status: [Int: TextLayerStatus] = [:]
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            status[i] = TextLayerDetector.detectTextLayer(page)
        }
        return status
    }

    static func sweepScan(_ doc: Doc, forcedOCR: Bool,
                          balanced: PresetThresholdVector?,
                          tracker: FootprintTracker) async throws -> [Double] {
        var samples: [Double] = []
        let status = mirroredStatus(doc.data)
        for _ in 0..<nRuns {
            let seconds: Double
            if forcedOCR {
                seconds = try await DocumentHarnessTests.forcedOCRRun(
                    data: doc.data, balanced: balanced).seconds
            } else {
                seconds = try await DocumentHarnessTests.naturalRun(
                    data: doc.data, status: status, balanced: balanced).seconds
            }
            samples.append(seconds * 1000)
            tracker.sample()
        }
        return samples
    }

    static let regionSpec = "one manual band per page, normalized (0.10, 0.45, 0.80, 0.10)"

    static func bandRegions(pages: Int) -> [Int: [RedactionRegion]] {
        var regions: [Int: [RedactionRegion]] = [:]
        for i in 0..<pages {
            regions[i] = [RedactionRegion(
                id: UUID(),
                normalizedRect: CGRect(x: 0.1, y: 0.45, width: 0.8, height: 0.1),
                source: .manual)]
        }
        return regions
    }

    struct RasterizeSweepResult {
        var rasterMs: [Double] = []
        var appendMs: [Double] = []
        var finalizeMs: [Double] = []
        var lastOutputURL: URL?
        var lastOutcome: VerificationCorpusRunnerTests.RedactionOutcome?
    }

    /// One pass per sweep: per-page rasterize (render+fill+verify) and
    /// reconstructor append timed separately inside the processDocument
    /// mirror's serial order; the final sweep's output is kept for the
    /// verification stage.
    static func sweepRasterizeReconstruct(
        _ doc: Doc, scratch: URL, tracker: FootprintTracker
    ) async throws -> RasterizeSweepResult {
        var result = RasterizeSweepResult()
        let status = mirroredStatus(doc.data)
        let anyRich = status.values.contains(.rich)
        let mode: PipelineMode = anyRich ? .searchableRedaction : .secureRasterization
        let hasOCG = VerificationCorpusRunnerTests.documentHasHiddenOCG(doc.data)

        for sweep in 0..<nRuns {
            guard let pdf = PDFDocument(data: doc.data) else { continue }
            let regions = bandRegions(pages: pdf.pageCount)
            let pages = VerificationCorpusRunnerTests.buildPages(
                doc: pdf, effectiveMode: mode, regionsByPage: regions,
                textLayerStatus: status, hasHiddenOCG: hasOCG)
            let outputURL = scratch.appendingPathComponent("\(doc.id)-s\(sweep).pdf")
            let tempURL = scratch.appendingPathComponent("\(doc.id)-s\(sweep)-tmp.pdf")
            let rasterizer = PageRasterizer()
            let reconstructor = PDFStreamReconstructor(tempURL: tempURL)

            let firstSize = pages.first.map { p in
                let raw = p.cropBoxBounds
                switch p.rotation {
                case 90, 270: return CGSize(width: raw.height, height: raw.width)
                default: return raw.size
                }
            } ?? CGSize(width: 612, height: 792)
            try await reconstructor.begin(firstPageSize: firstSize)

            var digests: [PageFilterDigest?] = []
            var modes: [PipelineMode] = []
            var reasons: [TextLayerDetector.FallbackReason?] = []
            for page in pages {
                let t0 = clock.now
                let r: RasterizeResult
                do {
                    r = try await rasterizer.rasterize(page, dpiCap: 300)
                } catch let error as PipelineError { // LegalPhrases:safe (Swift keyword)
                    guard case .redactionError(.fillVerificationFailed(let idx)) = error,
                          idx == page.pageIndex else { throw error }
                    r = try await rasterizer.rasterize(page, dpiCap: max(96, 300 / 2))
                }
                result.rasterMs.append(ms(clock.now - t0))
                digests.append(r.filterDigest)
                modes.append(r.filterDigest != nil ? .searchableRedaction : .secureRasterization)
                reasons.append(r.fallbackReason)
                let t1 = clock.now
                try await reconstructor.appendPage(r.pageOutput)
                result.appendMs.append(ms(clock.now - t1))
                tracker.sample()
            }
            let t2 = clock.now
            await reconstructor.finalize()
            result.finalizeMs.append(ms(clock.now - t2))
            let written = await reconstructor.writtenPageCount
            guard written == pages.count else {
                throw PipelineError.redactionError(.reconstructionFailed)
            }
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tempURL)
            if sweep == nRuns - 1 {
                result.lastOutputURL = outputURL
                result.lastOutcome = VerificationCorpusRunnerTests.RedactionOutcome(
                    filterDigests: digests, perPageModes: modes,
                    perPageFallbackReasons: reasons)
            } else {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
        return result
    }

    /// n sweeps of the full runVerification mirror over the kept output;
    /// per-layer wall clock from the product's own LayerResult.durationSeconds.
    static func sweepVerification(
        _ doc: Doc, outputURL: URL, outcome: VerificationCorpusRunnerTests.RedactionOutcome,
        tracker: FootprintTracker
    ) async throws -> (perLayer: [String: [Double]], total: [Double]) {
        var perLayer: [String: [Double]] = [:]
        var total: [Double] = []
        let status = mirroredStatus(doc.data)
        let anyRich = status.values.contains(.rich)
        let mode: PipelineMode = anyRich ? .searchableRedaction : .secureRasterization
        guard let pdf = PDFDocument(data: doc.data) else { return (perLayer, total) }
        let regions = bandRegions(pages: pdf.pageCount)
        for _ in 0..<nRuns {
            let t0 = clock.now
            let report = try await VerificationCorpusRunnerTests.runVerificationSweep(
                outputURL: outputURL, sourcePageCount: pdf.pageCount,
                regions: regions, sensitiveTerms: [], effectiveMode: mode,
                filterDigests: outcome.filterDigests,
                perPageModes: outcome.perPageModes,
                perPageFallbackReasons: outcome.perPageFallbackReasons)
            total.append(ms(clock.now - t0))
            for layer in report.layers {
                perLayer[layer.name, default: []].append(layer.durationSeconds * 1000)
            }
            tracker.sample()
        }
        return (perLayer, total)
    }

    /// PERF-8 cancel→surrender window, n reps (the CancellationLatencyTests
    /// measurement shape, pooled instead of asserted).
    static func cancellationSamples(verifyLeg: Bool) async throws -> [Double] {
        let size = 5000
        let region = RedactionRegion(
            id: UUID(), normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            source: .manual)
        struct UncheckedCtx: @unchecked Sendable { let ctx: CGContext }
        final class InstantBox: @unchecked Sendable {
            var instant: ContinuousClock.Instant?
        }
        var samples: [Double] = []
        for _ in 0..<nRuns {
            guard let ctx = createBitmapContext(width: size, height: size) else { continue }
            ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            if verifyLeg {
                try applyRedactionFills(context: ctx, regions: [region], fillColor: .black)
            }
            let boxed = UncheckedCtx(ctx: ctx)
            let pixelRect = normalizedToFillPixels(
                region.normalizedRect, bitmapWidth: size, bitmapHeight: size)
            let surrendered = InstantBox()
            let task: Task<Void, Never> = Task.detached(priority: .userInitiated) {
                while !Task.isCancelled {
                    do {
                        if verifyLeg {
                            _ = try verifyFill(context: boxed.ctx, rect: pixelRect,
                                               expectedColor: FillColor.black.expectedPixel)
                        } else {
                            try applyRedactionFills(context: boxed.ctx,
                                                    regions: [region], fillColor: .black)
                        }
                    } catch { // LegalPhrases:safe (Swift keyword)
                        surrendered.instant = ContinuousClock.now
                        return
                    }
                }
                surrendered.instant = ContinuousClock.now
            }
            try await Task.sleep(for: .milliseconds(25))
            let cancelInstant = clock.now
            task.cancel()
            await task.value
            samples.append(ms((surrendered.instant ?? clock.now) - cancelInstant))
        }
        return samples
    }

    // MARK: - The emit

    @Test("Emit stage-timing p50/p95 + footprint over the Family-4 doc set")
    func emitStageTimings() async throws {
        guard let out = Self.perfOut() else {
            print("[H4.1] RESECTA_PERF_OUT not set; stage-timing emitter skipped.")
            return
        }
        let (docs, skipped) = try Self.loadDocs()
        let balanced = PresetThresholdBundle.loadFromEngineBundle().presets[.balanced]
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("f4-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Vision warm-up before any OCR-leg measurement (H1.2 cold-start lesson).
        if let ss = try? TestFixtures.loanPacketScanSimPDF() {
            await DocumentHarnessTests.warmUpVision(scanSimData: ss)
        }

        var rows: [StageRow] = []
        for doc in docs {
            print("[H4.1] doc=\(doc.id) pages=\(doc.pages)")

            let tValidate = FootprintTracker()
            rows.append(Self.row(doc: doc, stage: "validate_page", unit: "per_page",
                                 samples: Self.sweepValidatePage(doc, tracker: tValidate),
                                 tracker: tValidate))

            let tDetect = FootprintTracker()
            rows.append(Self.row(doc: doc, stage: "text_layer_detect", unit: "per_page",
                                 samples: Self.sweepTextLayerDetect(doc, tracker: tDetect),
                                 tracker: tDetect))

            if doc.textLeg {
                let t = FootprintTracker()
                rows.append(Self.row(doc: doc, stage: "scan_text", unit: "per_doc",
                                     samples: try await Self.sweepScan(
                                        doc, forcedOCR: false, balanced: balanced, tracker: t),
                                     tracker: t))
            }
            if doc.ocrLeg {
                let t = FootprintTracker()
                let forced = doc.id == "packet"
                rows.append(Self.row(
                    doc: doc, stage: forced ? "scan_ocr_forced" : "scan_ocr_natural",
                    unit: "per_doc",
                    samples: try await Self.sweepScan(
                        doc, forcedOCR: forced, balanced: balanced, tracker: t),
                    tracker: t,
                    notes: forced ? "every page via the _testScanPagePIIViaOCR seam"
                                  : "product natural path (all pages image-only)"))
            }

            let tRaster = FootprintTracker()
            let raster = try await Self.sweepRasterizeReconstruct(
                doc, scratch: scratch, tracker: tRaster)
            rows.append(Self.row(doc: doc, stage: "rasterize_render_fill", unit: "per_page",
                                 samples: raster.rasterMs, tracker: tRaster))
            rows.append(Self.row(doc: doc, stage: "reconstruct_append", unit: "per_page",
                                 samples: raster.appendMs, tracker: tRaster))
            rows.append(Self.row(doc: doc, stage: "reconstruct_finalize", unit: "per_doc",
                                 samples: raster.finalizeMs, tracker: tRaster))

            if doc.verifyLeg, let outputURL = raster.lastOutputURL,
               let outcome = raster.lastOutcome {
                let tVerify = FootprintTracker()
                let verify = try await Self.sweepVerification(
                    doc, outputURL: outputURL, outcome: outcome, tracker: tVerify)
                rows.append(Self.row(doc: doc, stage: "verify_total", unit: "per_doc",
                                     samples: verify.total, tracker: tVerify))
                for (layer, samples) in verify.perLayer.sorted(by: { $0.key < $1.key }) {
                    rows.append(Self.row(doc: doc, stage: "verify_layer:\(layer)",
                                         unit: "per_doc", samples: samples, tracker: tVerify,
                                         notes: "product LayerResult.durationSeconds"))
                }
            } else if !doc.verifyLeg {
                print("[H4.1] \(doc.id): verification stage skipped (v0 bound, see header)")
            }
        }

        let synthetic = Doc(id: "synthetic-5000px", docClass: "synthetic-bitmap",
                            data: Data(), pages: 1, textLeg: false, ocrLeg: false,
                            verifyLeg: false)
        let tCancelFill = FootprintTracker()
        rows.append(Self.row(doc: synthetic, stage: "cancel_fill", unit: "per_call",
                             samples: try await Self.cancellationSamples(verifyLeg: false),
                             tracker: tCancelFill,
                             notes: "cancel→surrender, applyRedactionFills loop (PERF-8 shape)"))
        let tCancelVerify = FootprintTracker()
        rows.append(Self.row(doc: synthetic, stage: "cancel_verify", unit: "per_call",
                             samples: try await Self.cancellationSamples(verifyLeg: true),
                             tracker: tCancelVerify,
                             notes: "cancel→surrender, verifyFill loop (PERF-8 shape)"))

        struct DocMeta: Encodable {
            let id: String
            let doc_class: String
            let pages: Int
            let sha256: String
        }
        struct Envelope: Encodable {
            let schema_version: Int
            let generated_by: String
            let platform: String
            let os_build: String
            let n_sweeps: Int
            let region_spec: String
            let docs: [DocMeta]
            let docs_skipped: [String]
            let rows: [StageRow]
        }
        let envelope = Envelope(
            schema_version: 1,
            generated_by: "StageTimingEmitterTests (H4.1)",
            platform: platformLabel(),
            os_build: osBuildLabel(),
            n_sweeps: Self.nRuns,
            region_spec: Self.regionSpec,
            docs: docs.map {
                DocMeta(id: $0.id, doc_class: $0.docClass, pages: $0.pages,
                        sha256: SHA256.hash(data: $0.data)
                            .map { String(format: "%02x", $0) }.joined())
            },
            docs_skipped: skipped,
            rows: rows)
        try RobustnessRunnerTests.writeJSON(envelope, to: out + "/stage-timing.json")
        print("[H4.1] \(rows.count) stage rows over \(docs.count) docs; wrote stage-timing.json")
    }
}
