import Foundation
import CoreGraphics
import PDFKit
import Testing
import CryptoKit
@testable import RedactionEngine

// H1.2 — the Site-B DOCUMENT harness (1.2 instrumentation plan §6).
//
// Runs the PRODUCT search path — `DocumentSearcher.performSearch(.piiScan)`,
// the exact pipeline the Scan interface triggers — over every PDF row of
// `documents.manifest.json` (T1.4) that carries ground truth, and emits one
// hits JSON per (document × leg × run) for the dp `eval-documents` join
// (H1.3). This is the SITE-B counterpart of the Site-A `PacketSnapshotTests`
// snapshot: same fixtures, but hits surface through the composed-posterior
// Site-B gate at the balanced preset instead of the ungated orchestrator.
//
// Legs fall out of the import-time text-layer classification, mirrored here
// exactly as `ImportService` computes it (`TextLayerDetector.detectTextLayer`
// per page → `setTextLayerStatus`):
//   - natural   — the product run as-is: rich pages take the text path,
//                 `.sparse`/`.none` pages take OCR (`includeOCR: true`).
//   - ocr-forced — for all-rich documents (packet, rotate-trigger) every page
//                 is additionally pushed through the private product OCR body
//                 via the `_testScanPagePIIViaOCR` seam, so the OCR leg is
//                 measured on born-digital and rotated pages too.
//
// n per leg: deterministic text-path documents run n=2 with a byte-identity
// expectation; any leg that invokes Vision OCR runs n=3 (min/median/max is
// computed downstream — Vision is not deterministic).
//
// MEASUREMENT HARNESS: env-gated (RESECTA_DOCS_OUT / RESECTA_DOCS_ROOT, with
// the TEST_RUNNER_-prefixed forms xcodebuild forwards), never in the batched
// gate, no engine-behavior assertions beyond fixture identity and text-leg
// determinism. MATCHED-TEXT LOGGING (D31): all fixtures are synthetic with a
// public values manifest — matched text is emitted.
//
// OCR LINE DUMP: every run that took a page through Vision also writes
// `<out>/<doc_id>/ocr-lines-run-<n>.json` — the raw recognized lines and the
// product-normalized form of each, per page, read back from the searcher's
// own OCR cache after the run (the `_testOCRCachedLines` seam the search
// ground-truth runner already uses; same file shape). Nothing in the search
// path changes: the dump is the text the OCR leg matched against, so a
// missed value can be attributed downstream to the recognizer or to the
// normalizer without a second OCR pass.

@Suite("H1.2 Site-B document harness (standing emitter)", .serialized)
struct DocumentHarnessTests {

    // MARK: - Env gate (G8BaselineHarnessTests pattern)

    static func docsOut() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let p = env["RESECTA_DOCS_OUT"], !p.isEmpty { return p }
        if let p = env["TEST_RUNNER_RESECTA_DOCS_OUT"], !p.isEmpty { return p }
        return nil
    }
    static func docsRoot() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let p = env["RESECTA_DOCS_ROOT"], !p.isEmpty { return p }
        if let p = env["TEST_RUNNER_RESECTA_DOCS_ROOT"], !p.isEmpty { return p }
        return nil
    }

    // MARK: - Manifest

    struct ManifestRow: Decodable {
        let id: String
        let path: String
        let sha256: String
        let gt: String?
        let leg_applicability: [String]
        let source: String
    }

    static func loadManifest() throws -> [ManifestRow] {
        let url = try #require(Bundle.module.url(
            forResource: "documents.manifest", withExtension: "json",
            subdirectory: "TestResources"),
            "documents.manifest.json must be bundled in TestResources")
        return try JSONDecoder().decode([ManifestRow].self, from: try Data(contentsOf: url))
    }

    /// Resolve a manifest row to loadable bytes. Bundled rows come from the
    /// test bundle by basename; external rows resolve under RESECTA_DOCS_ROOT.
    static func resolve(_ row: ManifestRow, root: String?) -> URL? {
        if row.source == "bundled" {
            let base = (row.path as NSString).lastPathComponent
            let name = (base as NSString).deletingPathExtension
            let ext = (base as NSString).pathExtension
            return Bundle.module.url(
                forResource: name, withExtension: ext, subdirectory: "TestResources")
        }
        guard let root else { return nil }
        return URL(fileURLWithPath: root).appendingPathComponent(row.path)
    }

    // MARK: - Output rows (deterministic: no UUIDs, rounded geometry)

    struct HitRow: Encodable {
        let page: Int
        let category: String
        let rect: [Double]          // [x, y, w, h] normalized, bottom-left
        let text: String
        let confidence: Double?
        let source: String          // "text" | "ocr"
        let ocr_confidence: Double?
    }

    struct RunReport: Encodable {
        let schema_version: Int
        let generated_by: String
        let site: String
        let doc_id: String
        let doc_sha256: String
        let page_count: Int
        let text_layer_status: [String]
        let threshold_preset: String
        let include_ocr: Bool
        let leg: String             // "natural" | "ocr-forced"
        let run_index: Int
        let duration_s: Double
        let hits: [HitRow]
        let diagnostics: Diagnostics
    }

    struct Diagnostics: Encodable {
        let yielded: Int
        let result_cap: Int
        let cap_reached: Bool
        let ocr_skipped_pages: [Int]
        let scanned_not_analyzed_pages: [Int]
        let overlap_suppressed: [String: Int]
        let below_threshold_dropped: Int
    }

    struct HarnessSummary: Encodable {
        let schema_version: Int
        let generated_by: String
        let site: String
        let platform_note: String
        let docs_run: [String]
        let docs_skipped: [String: String]
        let sha_mismatches: [String]
    }

    static func r6(_ v: Double) -> Double { (v * 1e6).rounded() / 1e6 }

    static func hitRow(_ r: SearchResult) -> HitRow {
        let src: String
        let ocrConf: Double?
        switch r.source {
        case .textLayer: src = "text"; ocrConf = nil
        case .ocr(let c): src = "ocr"; ocrConf = r6(Double(c))
        }
        return HitRow(
            page: r.pageIndex,
            category: r.piiCategory.map { String(describing: $0) } ?? "",
            rect: [r6(r.normalizedRect.origin.x), r6(r.normalizedRect.origin.y),
                   r6(r.normalizedRect.width), r6(r.normalizedRect.height)],
            text: r.matchedText,
            confidence: r.piiConfidence.map(r6),
            source: src,
            ocr_confidence: ocrConf
        )
    }

    static func writeJSON<T: Encodable>(_ value: T, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - OCR line dump (raw + normalized Vision lines per OCR'd page)

    struct OCRLineOut: Encodable {
        let text: String
        let normalized: String
        let rect: [Double]
        let confidence: Double
    }
    struct OCRPageOut: Encodable {
        let page: Int
        let lines: [OCRLineOut]
    }
    struct OCRLinesOut: Encodable {
        let schema_version: Int
        let doc_id: String
        let run_index: Int
        let pages: [OCRPageOut]
    }

    /// Write the searcher's cached Vision lines for every page the run OCR'd.
    /// Returns false (and writes nothing) when the run took no page through
    /// OCR -- a pure text-leg run has no line dump.
    @discardableResult
    static func dumpOCRLines(
        searcher: DocumentSearcher, docID: String, runIndex: Int, out: String
    ) async throws -> Bool {
        let pageIndices = await searcher._testOCRCacheKeys.sorted()
        guard !pageIndices.isEmpty else { return false }
        let normalizer = OCRTextNormalizer()
        var pages: [OCRPageOut] = []
        for pageIndex in pageIndices {
            guard let lines = await searcher._testOCRCachedLines(forPageIndex: pageIndex)
            else { continue }
            pages.append(OCRPageOut(
                page: pageIndex,
                lines: lines.map { line in
                    OCRLineOut(
                        text: line.text,
                        normalized: normalizer.normalize(line.text),
                        rect: [r6(line.normalizedRect.origin.x), r6(line.normalizedRect.origin.y),
                               r6(line.normalizedRect.width), r6(line.normalizedRect.height)],
                        confidence: r6(Double(line.confidence)))
                }))
        }
        try writeJSON(
            OCRLinesOut(schema_version: 1, doc_id: docID, run_index: runIndex, pages: pages),
            to: "\(out)/\(docID)/ocr-lines-run-\(runIndex).json")
        return true
    }

    // MARK: - Per-run sinks

    final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var ocrSkipped: [Int] = []
        private(set) var notAnalyzed: [Int] = []
        private(set) var overlap: [String: Int] = [:]
        private(set) var belowThreshold = 0
        func addOCRSkip(_ p: Int) { lock.lock(); ocrSkipped.append(p); lock.unlock() }
        func addNotAnalyzed(_ p: Int) { lock.lock(); notAnalyzed.append(p); lock.unlock() }
        func addOverlap(_ counts: [PIICategory: Int]) {
            lock.lock()
            for (k, v) in counts { overlap[String(describing: k), default: 0] += v }
            lock.unlock()
        }
        func addBelowThreshold(_ n: Int) { lock.lock(); belowThreshold += n; lock.unlock() }
    }

    /// One product-path run: fresh searcher (fresh OCR caches), balanced
    /// preset, the import-mirrored text-layer statuses, full category set.
    static func naturalRun(
        data: Data, status: [Int: TextLayerStatus],
        balanced: PresetThresholdVector?
    ) async throws -> (hits: [SearchResult], tally: Tally, seconds: Double, searcher: DocumentSearcher) {
        let doc = try #require(PDFDocument(data: data))
        let searcher = DocumentSearcher()
        let tally = Tally()
        await searcher.setThresholdVector(balanced)
        await searcher.setTextLayerStatus(status)
        await searcher.setOCRSkipSink { tally.addOCRSkip($0) }
        await searcher.setScannedRegionNotAnalyzedSink { tally.addNotAnalyzed($0) }
        await searcher.setOverlapSink { tally.addOverlap($0) }
        await searcher.setBelowThresholdSink { tally.addBelowThreshold($0) }
        let clock = ContinuousClock()
        let start = clock.now
        let stream = searcher.search(
            SendablePDFDocument(doc),
            mode: .piiScan(categories: Set(PIICategory.allCases), options: SearchOptions()),
            progress: { _, _ in })
        var hits: [SearchResult] = []
        for await r in stream { hits.append(r) }
        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        return (hits, tally, seconds, searcher)
    }

    /// One forced-OCR run: every page through the private product OCR body
    /// via the `_testScanPagePIIViaOCR` seam (fresh searcher per run so the
    /// OCR cache never collapses repeats into one Vision pass).
    static func forcedOCRRun(
        data: Data, balanced: PresetThresholdVector?
    ) async throws -> (hits: [SearchResult], tally: Tally, seconds: Double, searcher: DocumentSearcher) {
        let doc = try #require(PDFDocument(data: data))
        let searcher = DocumentSearcher()
        let tally = Tally()
        await searcher.setThresholdVector(balanced)
        await searcher.setOCRSkipSink { tally.addOCRSkip($0) }
        let clock = ContinuousClock()
        let start = clock.now
        var hits: [SearchResult] = []
        for pageIndex in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIndex) else { continue }
            let results = await searcher._testScanPagePIIViaOCR(
                page: SendablePDFPage(page), pageIndex: pageIndex,
                categories: Set(PIICategory.allCases))
            hits.append(contentsOf: results)
        }
        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        return (hits, tally, seconds, searcher)
    }

    /// Warm the Vision inference context before the measurement loop (the
    /// PacketSnapshotTests cold-start lesson: the first request in a fresh
    /// process can fail with #9; a run that silently returns [] would poison
    /// run 1 of an OCR leg).
    static func warmUpVision(scanSimData: Data) async {
        guard let doc = PDFDocument(data: scanSimData), let page = doc.page(at: 0)
        else { return }
        let rasterizer = PageRasterizer()
        let engine = OCREngine()
        guard let image = try? await rasterizer.renderPage(page, pageIndex: 0, dpi: 150)
        else { return }
        for attempt in 1...8 {
            do {
                let lines = try await engine.recognizeText(
                    in: image, recognitionLevel: .accurate)
                print("[H1.2] Vision warm-up ok attempt=\(attempt) lines=\(lines.count)")
                if !lines.isEmpty { return }
            } catch {  // LegalPhrases:safe (Swift keyword)
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
        print("[H1.2] Vision warm-up FAILED after 8 attempts")
    }

    // MARK: - The emit

    @Test("Emit Site-B document baselines over the T1.4 manifest")
    func emitDocumentBaselines() async throws {
        guard let out = Self.docsOut() else {
            print("[H1.2] RESECTA_DOCS_OUT not set; document harness skipped.")
            return
        }
        let root = Self.docsRoot()
        let manifest = try Self.loadManifest()
        let balanced = PresetThresholdBundle.loadFromEngineBundle().presets[.balanced]
        #expect(balanced != nil, "balanced preset vector must load from the engine bundle")

        var docsRun: [String] = []
        var docsSkipped: [String: String] = [:]
        var shaMismatches: [String] = []

        // Warm Vision once, off the bundled scan-sim fixture.
        if let ss = try? TestFixtures.loanPacketScanSimPDF() {
            await Self.warmUpVision(scanSimData: ss)
        }

        for row in manifest where row.path.hasSuffix(".pdf") && row.gt != nil {
            guard let url = Self.resolve(row, root: root) else {
                docsSkipped[row.id] = row.source == "external"
                    ? "RESECTA_DOCS_ROOT unset or file missing" : "bundle resource missing"
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                docsSkipped[row.id] = "unreadable: \(url.path)"
                continue
            }
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if hex != row.sha256 {
                shaMismatches.append(row.id)
                #expect(hex == row.sha256, "\(row.id): loaded bytes drift from the manifest pin")
            }
            let doc = try #require(PDFDocument(data: data))

            // Import mirror: per-page text-layer classification, exactly as
            // ImportService computes it at doc-open.
            var status: [Int: TextLayerStatus] = [:]
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                status[i] = TextLayerDetector.detectTextLayer(page)
            }
            let statusNames: [String] = (0..<doc.pageCount).map {
                switch status[$0] {
                case .rich: "rich"
                case .sparse: "sparse"
                case Optional.none, .some(.none): "none"
                }
            }
            let allRich = (0..<doc.pageCount).allSatisfy { status[$0] == .rich }
            let naturalRuns = allRich ? 2 : 3

            print("[H1.2] \(row.id): pages=\(doc.pageCount) allRich=\(allRich) "
                  + "naturalRuns=\(naturalRuns) forced=\(allRich ? 3 : 0)")

            var naturalHitData: [Data] = []
            for run in 1...naturalRuns {
                let (hits, tally, seconds, searcher) = try await Self.naturalRun(
                    data: data, status: status, balanced: balanced)
                let report = RunReport(
                    schema_version: 1,
                    generated_by: "DocumentHarnessTests.emitDocumentBaselines",
                    site: "siteB",
                    doc_id: row.id,
                    doc_sha256: hex,
                    page_count: doc.pageCount,
                    text_layer_status: statusNames,
                    threshold_preset: "balanced",
                    include_ocr: true,
                    leg: "natural",
                    run_index: run,
                    duration_s: Self.r6(seconds),
                    hits: hits.map(Self.hitRow),
                    diagnostics: Diagnostics(
                        yielded: hits.count,
                        result_cap: DocumentSearcher.maxResults,
                        cap_reached: hits.count >= DocumentSearcher.maxResults,
                        ocr_skipped_pages: tally.ocrSkipped.sorted(),
                        scanned_not_analyzed_pages: tally.notAnalyzed.sorted(),
                        overlap_suppressed: tally.overlap,
                        below_threshold_dropped: tally.belowThreshold))
                try Self.writeJSON(report, to: "\(out)/\(row.id)/natural-run-\(run).json")
                // The OCR leg's line dump (pages the run took through Vision;
                // none on a pure text-leg run).
                try await Self.dumpOCRLines(
                    searcher: searcher, docID: row.id, runIndex: run, out: out)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                naturalHitData.append(try encoder.encode(hits.map(Self.hitRow)))
            }
            if allRich, naturalHitData.count == 2 {
                #expect(naturalHitData[0] == naturalHitData[1],
                        "\(row.id): text-path natural runs must be byte-deterministic")
            }

            if allRich {
                for run in 1...3 {
                    let (hits, tally, seconds, searcher) = try await Self.forcedOCRRun(
                        data: data, balanced: balanced)
                    let report = RunReport(
                        schema_version: 1,
                        generated_by: "DocumentHarnessTests.emitDocumentBaselines",
                        site: "siteB",
                        doc_id: row.id,
                        doc_sha256: hex,
                        page_count: doc.pageCount,
                        text_layer_status: statusNames,
                        threshold_preset: "balanced",
                        include_ocr: true,
                        leg: "ocr-forced",
                        run_index: run,
                        duration_s: Self.r6(seconds),
                        hits: hits.map(Self.hitRow),
                        diagnostics: Diagnostics(
                            yielded: hits.count,
                            result_cap: DocumentSearcher.maxResults,
                            cap_reached: false,
                            ocr_skipped_pages: tally.ocrSkipped.sorted(),
                            scanned_not_analyzed_pages: [],
                            overlap_suppressed: [:],
                            below_threshold_dropped: 0))
                    try Self.writeJSON(report, to: "\(out)/\(row.id)/ocr-forced-run-\(run).json")
                    try await Self.dumpOCRLines(
                        searcher: searcher, docID: row.id, runIndex: run, out: out)
                }
            }
            docsRun.append(row.id)
        }

        #if targetEnvironment(simulator)
        let platform = "simulator \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #else
        let platform = "host \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #endif
        try Self.writeJSON(
            HarnessSummary(
                schema_version: 1,
                generated_by: "DocumentHarnessTests.emitDocumentBaselines",
                site: "siteB",
                platform_note: platform,
                docs_run: docsRun,
                docs_skipped: docsSkipped,
                sha_mismatches: shaMismatches),
            to: "\(out)/harness-summary.json")
        print("[H1.2] done: \(docsRun.count) documents -> \(out)")
        #expect(shaMismatches.isEmpty)
    }
}
