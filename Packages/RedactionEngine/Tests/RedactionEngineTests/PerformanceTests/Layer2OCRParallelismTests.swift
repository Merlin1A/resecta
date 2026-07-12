import Testing
import Foundation
import CoreGraphics
import CoreText
import PDFKit
@testable import RedactionEngine

// CAT-370 — Layer-2 OCR throughput (cluster C-D).
//
// F1: the per-page OCR loop in `runLayer2OCR` now runs in a width-bounded task
// group (`VerificationEngine.ocrParallelism`), folding per-page results into the
// same priority buckets the sequential loop produced — page lists SORTED so the
// verdict is independent of OCR completion order.
// F2: each page image is downsampled to `ocrMaxPixelDimension` (4096) before
// Vision — the OCR check looks for readable leaked text, not pixel fidelity, and
// Vision's normalized coordinates are scale-invariant so the identity contract
// is unaffected.
//
// Proof bar: behaviour-neutral (verdict identical to the sequential path —
// covered by VerificationEngineTests' Layer-2 suite), order-independence + a
// rotated page in the set, downsample keeps leaked text detectable, and the
// on-demand wall-clock gate that records the serial-vs-parallel p50 pair.
@Suite("Layer-2 OCR parallelism + downsample (CAT-370)", .serialized)
struct Layer2OCRParallelismTests {

    private enum TestError: Error { case failed }

    /// Extract the human-readable string from a warn/info/fail status. The
    /// VerificationStatus `==` compares case identity only (it ignores the
    /// associated String), so message-level parity must bind the string.
    private static func message(of status: VerificationStatus) -> String? {
        switch status {
        case .warn(let m), .info(let m), .attention(let m), .fail(let m): m
        case .pass, .skipped: nil
        }
    }

    // MARK: - F2 downsample (unit)

    @Test("downsampleForOCR caps the largest dimension at 4096 and preserves aspect")
    func downsampleCapsDimension() throws {
        let big = try Self.solidImage(width: 5000, height: 3000)
        let ds = VerificationEngine.downsampleForOCR(big)
        #expect(max(ds.width, ds.height) <= 4096,
                "largest dimension must be capped; got \(ds.width)×\(ds.height)")
        // Aspect preserved within a pixel-rounding tolerance.
        let srcAspect = 5000.0 / 3000.0
        let dsAspect = Double(ds.width) / Double(ds.height)
        #expect(abs(srcAspect - dsAspect) / srcAspect < 0.01,
                "aspect must be preserved by the downsample")
    }

    @Test("downsampleForOCR returns a within-cap image unchanged (identity)")
    func downsampleIdentityForSmall() throws {
        let small = try Self.solidImage(width: 800, height: 600)
        let ds = VerificationEngine.downsampleForOCR(small)
        #expect(ds === small, "an image within the cap is returned untouched")
    }

    // MARK: - F2 downsample keeps leaked text detectable (integration)

    @Test("A >4096px image's in-region text is still detected after downsample → FAIL")
    func oversizeImageTextSurvivesDownsample() async throws {
        // Render large text on an oversized (>4096 px) page so the engine's F2
        // downsample is exercised on the real Layer-2 path. Text under a covering
        // region must still be detected — downsampling for throughput must not drop
        // readable leaked text. Under D08-F2 a readable in-region hit in Secure
        // Rasterization is a leak → FAIL (was WARN before D08-F2); either way the
        // point holds: the downsampled text is surfaced, never silently PASSed.
        let img = try Self.textImage("CONFIDENTIAL", width: 5000, height: 3000, fontSize: 520)
        let (doc, url) = try await Self.makeMultiImagePDF([img], size: CGSize(width: 5000, height: 3000))
        defer { try? FileManager.default.removeItem(at: url) }

        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            source: .manual)
        let result = await VerificationEngine().runLayer(
            1, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isFail,
                "oversize-image in-region text must still be detected post-downsample (D08-F2 FAIL); got \(result.status)")
    }

    // MARK: - F1 order-independence + a rotated page in the set

    @Test("Layer-2 result is deterministic and complete under the bounded group, incl. a rotated page")
    func resultIsOrderIndependentAndComplete() async throws {
        // Four single-image text pages, each under a covering region → each
        // classifies textInRegion, now FAIL in Secure Rasterization (D08-F2; was
        // WARN). With ocrParallelism = 3 the first chunk's three pages OCR
        // concurrently and can complete out of order; the engine sorts the page
        // list, so the message lists every page ascending regardless of completion
        // order. Page index 2 (page 3) is rotated 90° — a JPEG XObject extraction
        // is rotation-independent, so the parallel path must still OCR and list it
        // (rotation tolerance, no drop/crash).
        var pages: [CGImage] = []
        for _ in 0..<4 {
            pages.append(try Self.textImage("CONFIDENTIAL", width: 1200, height: 1500, fontSize: 130))
        }
        let (doc, url) = try await Self.makeMultiImagePDF(pages, size: CGSize(width: 1200, height: 1500))
        defer { try? FileManager.default.removeItem(at: url) }
        doc.page(at: 2)?.rotation = 90   // the rotated page in the set

        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            source: .manual)
        let regions: [Int: [RedactionRegion]] =
            [0: [region], 1: [region], 2: [region], 3: [region]]
        let engine = VerificationEngine()
        let wrapped = SendablePDFDocument(doc)

        func run() async -> VerificationStatus {
            await engine.runLayer(
                1, outputDocument: wrapped, sourcePageCount: 4, regions: regions,
                sensitiveTerms: [], pipelineMode: .secureRasterization,
                filterDigests: [], perPageModes: Array(repeating: .secureRasterization, count: 4)
            ).status
        }

        let first = await run()
        let second = await run()
        #expect(first.isFail, "all four in-region text pages must FAIL (D08-F2); got \(first)")
        let firstMsg = Self.message(of: first)
        #expect(firstMsg == Self.message(of: second),
                "the page list must be identical across runs (sorted, order-independent)")
        // Every page present, ascending — the fold's sort restored page order
        // even though the task group may complete the chunk out of order.
        #expect(firstMsg?.contains("1, 2, 3, 4") == true,
                "WARN must list every page ascending; got: \(firstMsg ?? "nil")")
    }

    // MARK: - Wall-clock acceptance gate (on-demand)

    // Vision throughput on the simulator is directional only, and a wall-clock
    // suite contends with the green-bar run, so this gate is OFF by default and
    // runs on demand — same env-gate convention as PDFKitConcurrencyStressTests:
    //   xcodebuild test -only-testing:'RedactionEngineTests/Layer2OCRParallelismTests/wallClockSerialVsParallel()' \
    //     (with TEST_RUNNER_RUN_CAT370_PERF=1 in the environment)
    // The recorded serial-vs-parallel p50 pair is the perf deliverable (PR body).
    @Test("Layer-2 OCR wall-clock: serial (width 1) vs parallel (width 3)",
          .tags(.performance),
          .enabled(if: ProcessInfo.processInfo.environment["RUN_CAT370_PERF"] != nil),
          .timeLimit(.minutes(5)))
    func wallClockSerialVsParallel() async throws {
        // N text pages incl. one rotated, large enough that each per-page Vision
        // pass is the dominant cost. Measures the SAME production code path at
        // width 1 (serial baseline) and width 3 (parallel) on identical inputs and
        // asserts the verdict message is identical at both widths (behaviour-
        // neutral). The p50 pair is the perf deliverable; the simulator speed-up
        // is directional, not asserted (a hard ratio gate flakes under Vision's
        // internal scheduling on the sim).
        let n = 12
        var imgs: [CGImage] = []
        for _ in 0..<n {
            imgs.append(try Self.textImage("CONFIDENTIAL", width: 1100, height: 1400, fontSize: 120))
        }
        let (doc, url) = try await Self.makeMultiImagePDF(imgs, size: CGSize(width: 1100, height: 1400))
        defer { try? FileManager.default.removeItem(at: url) }
        doc.page(at: n / 2)?.rotation = 90   // one rotated page in the set (F15)

        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            source: .manual)
        var regions: [Int: [RedactionRegion]] = [:]
        for i in 0..<n { regions[i] = [region] }

        let engine = VerificationEngine()
        let wrapped = SendablePDFDocument(doc)
        let modes = Array(repeating: PipelineMode.secureRasterization, count: n)
        func runLayer2() async -> VerificationStatus {
            await engine.runLayer(
                1, outputDocument: wrapped, sourcePageCount: n, regions: regions,
                sensitiveTerms: [], pipelineMode: .secureRasterization,
                filterDigests: [], perPageModes: modes).status
        }

        // Production never mutates ocrParallelism; restore it whatever happens.
        defer { VerificationEngine.ocrParallelism = 3 }

        func measure(_ runs: Int) async -> [Double] {
            var samples: [Double] = []
            for _ in 0..<runs {
                let clock = ContinuousClock()
                let start = clock.now
                _ = await runLayer2()
                let dur = clock.now - start
                samples.append(Double(dur.components.seconds)
                               + Double(dur.components.attoseconds) * 1e-18)
            }
            return samples.sorted()
        }

        // Warm-up: Vision graph init + first-touch image extraction.
        VerificationEngine.ocrParallelism = 1
        _ = await runLayer2()

        VerificationEngine.ocrParallelism = 1
        let serialStatus = await runLayer2()
        let serial = await measure(5)

        VerificationEngine.ocrParallelism = 3
        let parallelStatus = await runLayer2()
        let parallel = await measure(5)

        func p50(_ s: [Double]) -> Double { s[s.count / 2] }
        let sP50 = p50(serial), pP50 = p50(parallel)
        let speedup = sP50 > 0 ? (1 - pP50 / sP50) * 100 : 0
        print(String(
            format: "[CAT-370] Layer-2 OCR wall-clock (%d pages, sim — directional): "
                  + "serial p50=%.3fs, parallel p50=%.3fs, speed-up %.1f%%",
            n, sP50, pP50, speedup))

        // Behaviour-neutral: the verdict must not depend on the task-group width.
        #expect(Self.message(of: serialStatus) == Self.message(of: parallelStatus),
                "Layer-2 verdict must be identical at width 1 and width 3")
    }

    // MARK: - Fixtures

    private static func solidImage(width: Int, height: Int) throws -> CGImage {
        guard let ctx = createBitmapContext(width: width, height: height) else {
            throw TestError.failed
        }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let img = ctx.makeImage() else { throw TestError.failed }
        return img
    }

    /// Render a single large word in black on white using the production
    /// bottom-left bitmap context (mirrors VerificationEngineTests'
    /// renderTextPageImage), so OCR sees the same orientation a rasterized page
    /// would carry.
    private static func textImage(_ s: String, width: Int, height: Int, fontSize: CGFloat) throws -> CGImage {
        guard let ctx = createBitmapContext(width: width, height: height) else {
            throw TestError.failed
        }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.textMatrix = .identity
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attr = NSAttributedString(
            string: s,
            attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: CGFloat(width) * 0.04, y: CGFloat(height) * 0.5)
        CTLineDraw(line, ctx)
        guard let img = ctx.makeImage() else { throw TestError.failed }
        return img
    }

    /// Build an N-page PDF from CGImages via the production reconstructor — the
    /// exact full-page-JPEG shape Layer 2 verifies.
    private static func makeMultiImagePDF(_ images: [CGImage], size: CGSize) async throws -> (PDFDocument, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cat370_\(UUID().uuidString).pdf")
        let recon = PDFStreamReconstructor(tempURL: url)
        try await recon.begin(firstPageSize: size)
        for image in images {
            try await recon.appendPage(PageOutput(image: image, size: size, textLayerEntries: nil))
        }
        await recon.finalize()
        guard let doc = PDFDocument(url: url) else { throw TestError.failed }
        return (doc, url)
    }
}
