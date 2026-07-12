import Darwin
import Foundation
import PDFKit
import Testing
import Vision
@testable import RedactionEngine

// S8 OCR Quality Program — measurement instrument.
// Design reference: design/04-search-ocr-ux-security.md "Tier-5 OCR Quality
// Program" + "Rollout Order and Measurement"; verification.md §6 ("measured,
// not asserted").
//
// Runs the production OCR→detect leg (PageRasterizer.renderPage at the
// detection DPI → DetectionOrchestrator.detectPage with embeddedText: nil,
// which forces real Vision OCR) over:
//   • 3-page synthetic small-text doc    (7/8/9 pt box labels, §5.2)
//   • 20-page synthetic letter doc       (memory + latency revert criteria)
//
// Output: per-category COUNTS to RESECTA_OCR_MEASURE_OUT (default
// /tmp/ocr_quality_measure.json) + [OCRQ] console lines. Counts and
// categories only — never matched text (CLAUDE.md real-document rule).
//
// G6SyntheticRecallTests is the detector-side control: it never touches
// Vision, so it must stay flat across every OCR config step.

@Suite("S8 OCR quality measurement", .serialized)
struct RealDocOCRQualityTests {

    // MARK: - Production config mirror

    /// Forced render DPI for A/B runs (RESECTA_OCR_MEASURE_DPI). When
    /// absent, sweeps run POLICY-CHAINED — per-page DPI from
    /// DetectionRenderPolicy seeded by the page's lag-2 classification,
    /// mirroring production's lookahead schedule exactly: page j renders
    /// while page j-1 detects, so the newest recorded diagnostic at
    /// render-dispatch time is page j-2's (nil for pages 0 and 1).
    static var forcedMeasurementDPI: CGFloat? {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["RESECTA_OCR_MEASURE_DPI"]
            ?? env["TEST_RUNNER_RESECTA_OCR_MEASURE_DPI"],
            let value = Double(raw), value > 0 {
            return CGFloat(value)
        }
        return nil
    }

    static var dpiModeLabel: String {
        forcedMeasurementDPI.map { "forced-\(Int($0))" } ?? "policy-chained"
    }

    /// Per-page render DPI: forced target or the production policy for
    /// the lag-2 doctype seed; cap arithmetic is the policy's own.
    static func pageDPI(
        for page: PDFPage,
        seed: DoctypeClass?
    ) -> CGFloat {
        let rawBounds = page.bounds(for: .cropBox)
        let rotation = page.rotation
        let size = (rotation == 90 || rotation == 270)
            ? CGSize(width: rawBounds.height, height: rawBounds.width)
            : rawBounds.size
        let target = forcedMeasurementDPI
            ?? DetectionRenderPolicy.detectionDPI(for: seed)
        return DetectionRenderPolicy.capped(targetDPI: target, effectiveSize: size)
    }

    // MARK: - Sweep result shapes (Encodable → measurement JSON)

    struct CategoryCounts: Encodable {
        var raw = 0          // all matches detectPage produced (nil vector)
        var surfaced = 0     // confidence ≥ balanced cutoff (or no cutoff)
    }

    struct FixtureSweep: Encodable {
        let fixture: String
        let dpi_mode: String
        let page_count: Int
        let ocr_invocations: Int
        let categories: [String: CategoryCounts]
        let render_ms_total: Int
        let detect_ms_total: Int
        let detect_ms_max_page: Int
        /// Per-page raw detection count, index = page (counts only).
        let per_page_raw_counts: [Int]
        /// Per-page render DPI actually used (policy- or force-selected).
        let per_page_dpi: [Int]
        /// Pages whose detect threw, with the error domain/code and the
        /// rendered pixel dimensions — a page-level Vision failure is a
        /// measurement, not a harness crash (geometry only, never text).
        let page_errors: [String]
    }

    struct MemoryLatencySweep: Encodable {
        let dpi_mode: String
        let per_page_dpi: [Int]
        let page_count: Int
        let phys_footprint_before_bytes: Int64
        let phys_footprint_peak_bytes: Int64
        let phys_footprint_peak_delta_bytes: Int64
        let detect_ms_median_page: Int
        let detect_ms_max_page: Int
        let detect_ms_total: Int
    }

    struct MeasurementReport: Encodable {
        let run_id: String
        let dpi_mode: String
        let fixtures: [FixtureSweep]
        let small_text_per_size: [String: SmallTextResult]
        let memory_latency_20p: MemoryLatencySweep?
    }

    struct SmallTextResult: Encodable {
        let raw_detections: Int
        let ssn_raw: Int
        let ein_raw: Int
        let routing_raw: Int
        let account_raw: Int
    }

    // MARK: - Shared sweep core

    static func sweep(
        pdfData: Data,
        label: String
    ) async throws -> (FixtureSweep, [[DetectionResult]]) {
        guard let document = PDFDocument(data: pdfData) else {
            throw ScanSimulatorFixtureBuilder.FixtureError.unreadableSource
        }
        let rasterizer = PageRasterizer()
        // Production default: .fast (runDetectionPipeline's default level).
        let orchestrator = DetectionOrchestrator(recognitionLevel: .fast)

        var categories: [String: CategoryCounts] = [:]
        var perPageRaw: [Int] = []
        var perPageDPI: [Int] = []
        var classifiedPrimary: [DoctypeClass?] = []
        var pageDetections: [[DetectionResult]] = []
        var pageErrors: [String] = []
        var renderMSTotal = 0
        var detectMSTotal = 0
        var detectMSMax = 0
        // OCR-invocation count is tallied LOCALLY (one per page that completes
        // the forced-OCR detectPage below), NOT via the process-global
        // DetectionOrchestrator.OCRInvocationCounter: that static is shared by
        // every suite in a batched xcodebuild invocation, so a concurrent
        // OCR-driving sibling (e.g. PacketSnapshotTests / PacketOCRQualityRole)
        // inflates a global delta and breaks an exact-equality assert (the S01
        // batch-fragility gotcha). The local tally is deterministic per sweep.
        var ocrInvocations = 0
        let clock = ContinuousClock()

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            // Lag-2 doctype seed (see forcedMeasurementDPI doc comment).
            let seed: DoctypeClass? =
                pageIndex >= 2 ? classifiedPrimary[pageIndex - 2] : nil
            let pageDPI = Self.pageDPI(for: page, seed: seed)
            perPageDPI.append(Int(pageDPI.rounded()))

            let renderStart = clock.now
            let image = try await rasterizer.renderPage(
                page, pageIndex: pageIndex, dpi: pageDPI
            )
            renderMSTotal += Int(
                (clock.now - renderStart).msComponents
            )

            let detectStart = clock.now
            // embeddedText: nil forces the Vision OCR leg — the subject of
            // the program — even on born-digital pages. thresholdVector: nil
            // surfaces every match; balanced cutoffs are applied below so
            // one sweep yields both raw and surfaced counts (D1-gate
            // pattern). A throwing page is recorded (domain/code + pixel
            // dims) and the sweep continues — page-level Vision failures
            // are themselves measurements (the 200-DPI A/B surfaced one).
            let result: PageDetectionResult
            do {
                result = try await orchestrator.detectPage(
                    image: image,
                    pageIndex: pageIndex,
                    priors: PerCategoryPriors(),
                    surfaceForms: SurfaceFormDictionary(),
                    doctypeContext: nil,
                    thresholdVector: nil,
                    embeddedText: nil,
                    ocrSkipReason: nil
                )
            } catch { // LegalPhrases:safe (Swift keyword)
                let ns = error as NSError
                let entry = "page=\(pageIndex + 1) px=\(image.width)x\(image.height) "
                    + "error=\(ns.domain)#\(ns.code)"
                pageErrors.append(entry)
                perPageRaw.append(-1)
                pageDetections.append([])
                classifiedPrimary.append(nil)
                print("[OCRQ] \(label) PAGE ERROR \(entry)")
                continue
            }
            let detectMS = Int((clock.now - detectStart).msComponents)
            detectMSTotal += detectMS
            detectMSMax = max(detectMSMax, detectMS)

            // Reached only on a successful detectPage: embeddedText==nil forces
            // exactly one Vision OCR invocation, so this is the deterministic
            // per-sweep OCR tally. A page that throws before completing (the sim
            // face-pass Vision #9 on a non-financial page) is NOT counted here;
            // it is recorded in page_errors instead.
            ocrInvocations += 1
            perPageRaw.append(result.detections.count)
            classifiedPrimary.append(result.doctype.primary)
            pageDetections.append(result.detections)
            for detection in result.detections {
                let key = categoryKey(for: detection.kind)
                var bucket = categories[key, default: CategoryCounts()]
                bucket.raw += 1
                if let cutoff = Self.cutoff(for: detection.kind) {
                    if detection.confidence >= cutoff { bucket.surfaced += 1 }
                } else {
                    bucket.surfaced += 1  // no wire name → passes W4 unfiltered
                }
                categories[key] = bucket
            }
        }

        let sweepResult = FixtureSweep(
            fixture: label,
            dpi_mode: dpiModeLabel,
            page_count: document.pageCount,
            ocr_invocations: ocrInvocations,
            categories: categories,
            render_ms_total: renderMSTotal,
            detect_ms_total: detectMSTotal,
            detect_ms_max_page: detectMSMax,
            per_page_raw_counts: perPageRaw,
            per_page_dpi: perPageDPI,
            page_errors: pageErrors
        )
        print("[OCRQ] \(label) dpi=\(dpiModeLabel) pages=\(document.pageCount) "
            + "ocr=\(sweepResult.ocr_invocations) "
            + "render_ms=\(renderMSTotal) detect_ms=\(detectMSTotal) "
            + "dpis=\(Set(perPageDPI).sorted()) "
            + "cats=\(categories.mapValues { "\($0.raw)/\($0.surfaced)" }.sorted(by: { $0.key < $1.key }))")
        return (sweepResult, pageDetections)
    }

    static func categoryKey(for kind: DetectionResult.Kind) -> String {
        switch kind {
        case .pii(let piiKind):
            if let category = PIICategory(piiKind: piiKind) {
                return category.rawValue
            }
            return String(describing: piiKind)
        case .face:
            return "face"
        case .searchMatch:
            return "searchMatch"
        }
    }

    /// Balanced-preset cutoff for the kind; non-PII kinds have none.
    static func cutoff(for kind: DetectionResult.Kind) -> Double? {
        if case .pii(let piiKind) = kind {
            return balancedCutoff(for: piiKind)
        }
        return nil
    }

    // MARK: - §5.2 adversarial pin (design test plan)

    /// Hard gate: the detection config must keep recognizing 7/8/9 pt
    /// box-label rows. Baseline through step 3 measured one SSN + one EIN
    /// + one routing detection per size, stable across runs; this pin
    /// fails loudly if a config change (minimumTextHeight, DPI, revision)
    /// starts skipping small box labels.
    @Test("minimumTextHeight does not skip 7/8/9pt box labels")
    func minimumTextHeightDoesNotSkipBoxLabels() async throws {
        let smallText = SmallTextFixtureBuilder.buildDocument()
        let (_, pages) = try await Self.sweep(
            pdfData: smallText, label: "small_text_pin"
        )
        for (pageIndex, detections) in pages.enumerated() {
            let size = SmallTextFixtureBuilder.fontSizes[pageIndex]
            let keys = detections.map { Self.categoryKey(for: $0.kind) }
            #expect(keys.contains("SSN"),
                    "\(Int(size))pt SSN box label lost")
            #expect(keys.contains("EIN"),
                    "\(Int(size))pt EIN box label lost")
            #expect(keys.contains("Routing Number"),
                    "\(Int(size))pt routing box label lost")
        }
    }

    // MARK: - 20-page memory + latency run (design §5.1 revert criterion)

    @Test("20-page letter doc — peak footprint and per-page latency")
    func twentyPageMemoryLatency() async throws {
        let pdfData = TwentyPageFixtureBuilder.buildDocument()
        guard let document = PDFDocument(data: pdfData) else {
            Issue.record("20-page synthetic doc failed to open")
            return
        }
        let rasterizer = PageRasterizer()
        let orchestrator = DetectionOrchestrator(recognitionLevel: .fast)
        let clock = ContinuousClock()

        let before = Self.physFootprint() ?? 0
        var peak = before
        var pageMS: [Int] = []
        var perPageDPI: [Int] = []
        var classifiedPrimary: [DoctypeClass?] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            // Same lag-2 policy chaining as sweep() — the 20-page revert
            // criterion measures the SHIPPING config.
            let seed: DoctypeClass? =
                pageIndex >= 2 ? classifiedPrimary[pageIndex - 2] : nil
            let pageDPI = Self.pageDPI(for: page, seed: seed)
            perPageDPI.append(Int(pageDPI.rounded()))
            let image = try await rasterizer.renderPage(
                page, pageIndex: pageIndex, dpi: pageDPI
            )
            let start = clock.now
            let result = try await orchestrator.detectPage(
                image: image,
                pageIndex: pageIndex,
                priors: PerCategoryPriors(),
                surfaceForms: SurfaceFormDictionary(),
                doctypeContext: nil,
                thresholdVector: nil,
                embeddedText: nil,
                ocrSkipReason: nil
            )
            classifiedPrimary.append(result.doctype.primary)
            pageMS.append(Int((clock.now - start).msComponents))
            if let footprint = Self.physFootprint() {
                peak = max(peak, footprint)
            }
        }

        let sorted = pageMS.sorted()
        let sweep = MemoryLatencySweep(
            dpi_mode: Self.dpiModeLabel,
            per_page_dpi: perPageDPI,
            page_count: document.pageCount,
            phys_footprint_before_bytes: before,
            phys_footprint_peak_bytes: peak,
            phys_footprint_peak_delta_bytes: peak - before,
            detect_ms_median_page: sorted[sorted.count / 2],
            detect_ms_max_page: sorted.last ?? 0,
            detect_ms_total: pageMS.reduce(0, +)
        )
        print("[OCRQ] 20p dpi=\(Self.dpiModeLabel) dpis=\(Set(perPageDPI).sorted()) "
            + "footprint_delta=\(sweep.phys_footprint_peak_delta_bytes / 1_048_576)MB "
            + "median_ms=\(sweep.detect_ms_median_page) max_ms=\(sweep.detect_ms_max_page) total_ms=\(sweep.detect_ms_total)")

        let report = MeasurementReport(
            run_id: Self.runID(),
            dpi_mode: Self.dpiModeLabel,
            fixtures: [],
            small_text_per_size: [:],
            memory_latency_20p: sweep
        )
        try Self.writeReport(report, suffix: "memory")
        #expect(document.pageCount == TwentyPageFixtureBuilder.pageCount)
    }

    // MARK: - Plumbing helpers

    static func runID() -> String {
        let env = ProcessInfo.processInfo.environment
        return env["RESECTA_OCR_RUN_ID"]
            ?? env["TEST_RUNNER_RESECTA_OCR_RUN_ID"]
            ?? "adhoc"
    }

    static func writeReport(_ report: MeasurementReport, suffix: String) throws {
        let env = ProcessInfo.processInfo.environment
        let base = env["RESECTA_OCR_MEASURE_OUT"]
            ?? env["TEST_RUNNER_RESECTA_OCR_MEASURE_OUT"]
            ?? "/tmp/ocr_quality_measure"
        let path = "\(base)_\(report.run_id)_\(suffix).json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        print("[OCRQ] report written: \(path)")
    }

    /// Resident physical footprint (TASK_VM_INFO.phys_footprint) — works on
    /// the simulator, unlike os_proc_available_memory (returns 0 there;
    /// PipelineCoordinator's device-side budget guard uses the latter).
    static func physFootprint() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Int64(info.phys_footprint)
    }
}

private extension Duration {
    /// Whole milliseconds (sufficient resolution for page-level timings).
    var msComponents: Int64 {
        components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
    }
}
