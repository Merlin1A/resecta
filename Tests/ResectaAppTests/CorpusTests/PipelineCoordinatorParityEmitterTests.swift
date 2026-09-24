import Testing
import Foundation
import CoreGraphics
import CryptoKit
import PDFKit
import UIKit
@testable import ResectaApp
@testable import RedactionEngine

// C12-123 — the coordinator-parity emitter (the first evidence the
// walkthrough parity leg owes; S4-X5a).
//
// For every H2.2 cell of the run of record whose document is a packet-family
// or factory document, this suite drives the PRODUCT path — a real
// `PipelineCoordinator` through `runFullPipeline()` — over the SAME document
// bytes and the SAME regions the engine-side mirror
// (`VerificationCorpusMirror.runVerificationSweep`) redacted and verified,
// and writes the resulting `VerificationReport` per cell in the H2.1 wire
// shape. `compare_parity.py` (planning estate) then compares the duration-
// free layer tuples against the mirror's: the mirror reimplements ~100
// lines of coordinator orchestration in the engine test target, and this
// emitter is the instrument that says whether the two still agree.
//
// Inputs (all env-gated; unset ⇒ skipped, the H2.2 runner's shape):
//   RESECTA_PARITY_OUT    — the output directory (<doc>/<mode>/<set>/…)
//   RESECTA_PARITY_CELLS  — the H2.2 run of record's `cells/` directory
//                           (each cell's regions.json is the seed)
//   RESECTA_PARITY_DOCS   — the corpus input dump (`<doc_id>.pdf`; written
//                           by the engine test target's CorpusInputDumpTests)
//   RESECTA_PARITY_ONLY_DOCS — optional comma-separated doc-id filter
// plus the TEST_RUNNER_-prefixed forms xcodebuild forwards.
//
// Seeding contract (stated in the session notes before the first run):
// regions come from regions.json (page · rect · polygon → the rect's four
// corners, the mirror's `region(from:polygon:)` order); the document's
// per-page text-layer status and hidden-OCG flag are computed with the same
// two engine calls the mirror makes and cross-checked against the cell's
// record; sensitive terms are seeded through `RegionMetadata` (matched
// text + kind) so the coordinator's own derivation yields the mirror's
// term set — asserted before the run; a cell that cannot be seeded to
// equality is recorded as skipped, never approximated.

@Suite("PipelineCoordinator parity emitter (standing, C12-123)", .serialized)
@MainActor
struct PipelineCoordinatorParityEmitterTests {

    // MARK: - Env gate

    static func env(_ key: String) -> String? {
        let e = ProcessInfo.processInfo.environment
        if let p = e[key], !p.isEmpty { return p }
        if let p = e["TEST_RUNNER_" + key], !p.isEmpty { return p }
        return nil
    }

    /// The 61-cell oracle keep-list's packet-family + factory documents.
    static let keepListDocs: Set<String> = [
        "packet", "packet-degrade-blur", "packet-degrade-lowdpi",
        "packet-degrade-skew", "packet-rotate-trigger", "packet-scan-sim-150dpi",
        "factory-annotations", "factory-embedded-file", "factory-fake-redaction",
        "factory-gps-jpeg", "factory-incremental-update", "factory-javascript",
        "factory-kerning-injection", "factory-metadata", "factory-ocg-hidden",
        "factory-rotated-text-90", "factory-two-image",
    ]

    // MARK: - The mirror's regions.json (the decoded subset this emitter reads)

    struct RegionRow: Decodable {
        let page: Int
        let rect: [Double]
        let polygon: Bool
        let gt_id: String?
        let value: String?
        let category: String?
    }
    struct TermRow: Decodable, Hashable {
        let text: String
        let requires_token_boundary: Bool
    }
    struct RegionsJSON: Decodable {
        let doc_id: String
        let mode: String
        let region_set: String
        let region_source: String
        let doc_sha256: String
        let page_count: Int
        let text_layer_status: [String]
        let has_hidden_ocg: Bool
        let regions: [RegionRow]
        let sensitive_terms: [TermRow]
    }

    // MARK: - Seeding

    struct Seed {
        var regions: [Int: [RedactionRegion]] = [:]
        var metadata: [UUID: RegionMetadata] = [:]
    }

    /// Build the coordinator's region + metadata state for one cell so that
    /// `PipelineCoordinator.sensitiveTerms(fromAppliedRegions:metadata:)`
    /// derives exactly the mirror's term set. Returns nil (with the reason)
    /// when the cell cannot be seeded to equality.
    static func seed(_ cell: RegionsJSON) -> (Seed?, String?) {
        var seed = Seed()
        let overrideTerms = cell.region_source == "gt" ? nil : cell.sensitive_terms
        if let overrideTerms, overrideTerms.count > 2 * max(1, cell.regions.count) {
            return (nil, "\(overrideTerms.count) override terms over \(cell.regions.count) regions")
        }
        if let overrideTerms, overrideTerms.contains(where: { $0.requires_token_boundary }) {
            return (nil, "an override term requires a token boundary (no region-metadata shape yields it)")
        }
        var pendingTerms = overrideTerms.map { Array($0) } ?? []
        for row in cell.regions {
            guard row.rect.count == 4 else { return (nil, "malformed rect on page \(row.page)") }
            let rect = CGRect(x: row.rect[0], y: row.rect[1],
                              width: row.rect[2], height: row.rect[3])
            let vertices: [CGPoint]? = row.polygon ? [
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY),
            ] : nil
            let id = UUID()
            var source: RedactionRegion.Source = .manual
            var meta: RegionMetadata? = nil
            if overrideTerms == nil {
                // GT-sourced: the region's own value/category is the term.
                if let value = row.value, !value.isEmpty {
                    let kind: DetectionResult.Kind =
                        row.category == "name" ? .pii(.name) : .pii(.other)
                    meta = RegionMetadata(
                        piiKind: kind, confidence: 1.0, matchedText: value,
                        recognitionLevel: .fast)
                }
            } else if !pendingTerms.isEmpty {
                // Factory-sourced: distribute the override terms — one as the
                // matched text, a second (when present) as a typed search
                // term on the same region (the coordinator contributes both).
                let first = pendingTerms.removeFirst()
                if !pendingTerms.isEmpty {
                    let second = pendingTerms.removeFirst()
                    source = .searchMatch(term: second.text, rationale: nil)
                    meta = RegionMetadata(
                        piiKind: .searchMatch(term: second.text), confidence: 1.0,
                        matchedText: first.text, recognitionLevel: .fast)
                } else {
                    meta = RegionMetadata(
                        piiKind: .pii(.other), confidence: 1.0,
                        matchedText: first.text, recognitionLevel: .fast)
                }
            }
            let region = RedactionRegion(
                id: id, normalizedRect: rect, source: source, vertices: vertices)
            seed.regions[row.page, default: []].append(region)
            if let meta { seed.metadata[id] = meta }
        }
        if !pendingTerms.isEmpty {
            return (nil, "\(pendingTerms.count) override terms left unseeded")
        }
        // The coordinator's own derivation must equal the mirror's set.
        let derived = Set(PipelineCoordinator.sensitiveTerms(
            fromAppliedRegions: seed.regions, metadata: seed.metadata
        ).map { TermRow(text: $0.text, requires_token_boundary: $0.requiresTokenBoundary) })
        let expected = Set(cell.sensitive_terms)
        guard derived == expected else {
            return (nil, "derived terms \(derived.map(\.text).sorted()) != mirror \(expected.map(\.text).sorted())")
        }
        return (seed, nil)
    }

    /// A coordinator with a loaded source document, parked in `.editing`
    /// (the S4-H3 `makeLoadedCoordinator(document:)` shape) plus the two
    /// document facts the app's import path records and the mirror computes
    /// the same way: the per-page text-layer status and the hidden-OCG flag.
    static func makeLoadedCoordinator(document: PDFDocument, data: Data) -> PipelineCoordinator {
        let coord = PipelineCoordinator(
            documentState: DocumentState(),
            redactionState: RedactionState(),
            settingsState: SettingsState()
        )
        coord.documentState.sourceDocument = document
        coord.documentState.phase = .editing
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            coord.documentState.textLayerStatus[i] = TextLayerDetector.detectTextLayer(page)
        }
        if let provider = CGDataProvider(data: data as CFData),
           let cgDoc = CGPDFDocument(provider) {
            coord.documentState.sourceHasHiddenOCG = TextLayerExtractor.documentHasHiddenOCG(cgDoc)
        }
        return coord
    }

    static func statusName(_ s: TextLayerStatus?) -> String {
        switch s {
        case .rich: "rich"
        case .sparse: "sparse"
        case Optional.none, .some(.none): "none"
        }
    }

    // MARK: - Output records (the H2.1 wire shape + the identity tuples)

    struct StatusJSON: Encodable {
        let `case`: String
        let message: String?
        init(_ status: VerificationStatus) {
            switch status {
            case .pass:               self.case = "pass";      self.message = nil
            case .warn(let m):        self.case = "warn";      self.message = m
            case .info(let m):        self.case = "info";      self.message = m
            case .attention(let m):   self.case = "attention"; self.message = m
            case .fail(let m):        self.case = "fail";      self.message = m
            case .skipped:            self.case = "skipped";   self.message = nil
            }
        }
    }
    struct LayerJSON: Encodable {
        let index: Int
        let name: String
        let symbol: String
        let status: StatusJSON
        let short: String
        let detail: String
        let pages: [Int]?
        let duration_s: Double
        let review_terms: [String]?
        let could_not_verify: Bool
        init(_ l: LayerResult, index: Int) {
            self.index = index; self.name = l.name; self.symbol = l.symbolName
            self.status = StatusJSON(l.status); self.short = l.shortDescription
            self.detail = l.detailDescription; self.pages = l.pageReferences
            self.duration_s = l.durationSeconds; self.review_terms = l.reviewTermTexts
            self.could_not_verify = l.couldNotVerify
        }
    }
    struct ReportJSON: Encodable {
        let schema_version: Int
        let generated_by: String
        let overall: StatusJSON
        let duration_s: Double
        let layers: [LayerJSON]
        let per_page_modes: [String]
        let per_page_fallback_reasons: [String?]
        init(_ r: VerificationReport) {
            schema_version = 1
            generated_by = "PipelineCoordinatorParityEmitterTests.emitCoordinatorParity"
            overall = StatusJSON(r.overallStatus)
            duration_s = r.durationSeconds
            layers = r.layers.enumerated().map { LayerJSON($0.element, index: $0.offset) }
            per_page_modes = r.perPageModes.map(\.rawValue)
            per_page_fallback_reasons = r.perPageFallbackReasons.map { $0.map { String(describing: $0) } }
        }
    }
    struct CellJSON: Encodable {
        let schema_version: Int
        let doc_id: String
        let mode: String
        let region_set: String
        let doc_sha256: String
        let output_sha256: String
        let region_count: Int
        let sensitive_terms: [String]
        let layer_identity: [String]
        let overall: String
    }
    struct Summary: Encodable {
        let schema_version: Int
        let generated_by: String
        let platform_note: String
        let cells_run: [String]
        let cells_skipped: [String: String]
        let cells_failed: [String: String]
    }

    /// The 8-element duration-free identity tuple — the shape
    /// `VerificationCorpusRecords.layerIdentity` pins.
    static func layerIdentity(_ layer: LayerResult) -> String {
        let s = StatusJSON(layer.status)
        let pages = layer.pageReferences.map { $0.map(String.init).joined(separator: ",") } ?? "-"
        let terms = layer.reviewTermTexts?.joined(separator: "|") ?? "-"
        let flag = layer.couldNotVerify ? "could_not_verify" : "-"
        return [layer.name, s.case, s.message ?? "", layer.shortDescription,
                layer.detailDescription, pages, terms, flag].joined(separator: "\u{1F}")
    }

    static func writeJSON<T: Encodable>(_ value: T, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Vision warm-up (the H2.2 runner's): one OCR pass on the scan-sim
    /// packet's first page so the first cell's Layer 2 is not the cold call.
    static func warmUpVision(docs: String) async {
        let url = URL(fileURLWithPath: "\(docs)/packet-scan-sim-150dpi.pdf")
        guard let data = try? Data(contentsOf: url),
              let doc = PDFDocument(data: data), let page = doc.page(at: 0),
              let image = try? await PageRasterizer().renderPage(page, pageIndex: 0, dpi: 150)
        else { return }
        let engine = OCREngine()
        for attempt in 1...8 {
            if let lines = try? await engine.recognizeText(in: image, recognitionLevel: .accurate) {
                print("[PARITY] Vision warm-up ok attempt=\(attempt) lines=\(lines.count)")
                if !lines.isEmpty { return }
            }
            try? await Task.sleep(for: .milliseconds(600))
        }
        print("[PARITY] Vision warm-up FAILED after 8 attempts")
    }

    // MARK: - One cell through the product path

    /// Returns nil on success (files written), else the failure reason.
    static func runCell(
        _ cell: RegionsJSON, cellName: String, data: Data, seed: Seed, out: String
    ) async throws -> String? {
        guard let document = PDFDocument(data: data) else { return "PDFDocument(data:) failed" }
        guard let mode = PipelineMode(rawValue: cell.mode) else { return "unknown mode \(cell.mode)" }
        let coord = makeLoadedCoordinator(document: document, data: data)
        defer { coord.tearDownTempDirectory() }

        // Cross-check the two document facts against the mirror's record.
        let statuses = (0..<document.pageCount).map { statusName(coord.documentState.textLayerStatus[$0]) }
        guard statuses == cell.text_layer_status else {
            return "text_layer_status \(statuses) != mirror \(cell.text_layer_status)"
        }
        guard coord.documentState.sourceHasHiddenOCG == cell.has_hidden_ocg else {
            return "has_hidden_ocg \(coord.documentState.sourceHasHiddenOCG) != mirror \(cell.has_hidden_ocg)"
        }
        guard document.pageCount == cell.page_count else {
            return "page_count \(document.pageCount) != mirror \(cell.page_count)"
        }

        // The cell's RunSettings: its mode · fill black · DPI 300 · autoVerify on.
        coord.settingsState.pipelineMode = mode
        coord.settingsState.fillColor = .black
        coord.settingsState.exportDPI = 300
        coord.settingsState.autoVerify = true
        coord.settingsState.paranoidMode = false
        coord.redactionState.regions = seed.regions
        coord.redactionState.regionMetadata = seed.metadata

        coord.runFullPipeline(documentOverride: nil)
        guard let task = coord.documentState.activePipelineTask else {
            return "runFullPipeline did not start (guard refused)"
        }
        await task.value

        let report: VerificationReport
        switch coord.documentState.phase {
        case .verified(let r): report = r
        case .failed(let error, _): return "pipeline failed: \(error)"
        default: return "pipeline ended in \(coord.documentState.phaseKind)"
        }
        let outputData = coord.redactionState.outputURL.flatMap { try? Data(contentsOf: $0) } ?? Data()

        let cellDir = "\(out)/\(cell.doc_id)/\(cell.mode)/\(cell.region_set)"
        try writeJSON(ReportJSON(report), to: "\(cellDir)/report.json")
        try writeJSON(
            CellJSON(
                schema_version: 1,
                doc_id: cell.doc_id, mode: cell.mode, region_set: cell.region_set,
                doc_sha256: cell.doc_sha256,
                output_sha256: sha256Hex(outputData),
                region_count: seed.regions.values.reduce(0) { $0 + $1.count },
                sensitive_terms: coord.collectSensitiveTerms().map(\.text),
                layer_identity: report.layers.map(layerIdentity),
                overall: StatusJSON(report.overallStatus).case),
            to: "\(cellDir)/cell.json")
        return nil
    }

    // MARK: - The emit

    @Test("Emit the coordinator's verification reports over the mirror's cells")
    func emitCoordinatorParity() async throws {
        guard let out = Self.env("RESECTA_PARITY_OUT"),
              let cellsRoot = Self.env("RESECTA_PARITY_CELLS"),
              let docs = Self.env("RESECTA_PARITY_DOCS") else {
            TestGate.skip("[PARITY] RESECTA_PARITY_OUT / _CELLS / _DOCS not all set — the coordinator parity emitter was not requested")
            return
        }
        let only: Set<String>? = Self.env("RESECTA_PARITY_ONLY_DOCS").map {
            Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }

        // Every cell of the run of record: <cells>/<doc>/<mode>/<set>/regions.json
        let fm = FileManager.default
        var cellPaths: [String] = []
        if let e = fm.enumerator(atPath: cellsRoot) {
            while let rel = e.nextObject() as? String {
                if rel.hasSuffix("/regions.json") && rel.split(separator: "/").count == 4 {
                    cellPaths.append(rel)
                }
            }
        }
        cellPaths.sort()

        await Self.warmUpVision(docs: docs)

        var cellsRun: [String] = []
        var cellsSkipped: [String: String] = [:]
        var cellsFailed: [String: String] = [:]
        var docCache: [String: Data] = [:]

        for rel in cellPaths {
            let cellName = rel.replacingOccurrences(of: "/regions.json", with: "")
            let cell = try JSONDecoder().decode(
                RegionsJSON.self, from: Data(contentsOf: URL(fileURLWithPath: "\(cellsRoot)/\(rel)")))
            guard Self.keepListDocs.contains(cell.doc_id) else {
                cellsSkipped[cellName] = "outside the packet-family + factory set"
                continue
            }
            if let only, !only.contains(cell.doc_id) { continue }
            let data: Data
            if let cached = docCache[cell.doc_id] {
                data = cached
            } else {
                guard let loaded = try? Data(contentsOf: URL(fileURLWithPath: "\(docs)/\(cell.doc_id).pdf")) else {
                    cellsSkipped[cellName] = "document missing from the dump"
                    continue
                }
                docCache[cell.doc_id] = loaded
                data = loaded
            }
            guard Self.sha256Hex(data) == cell.doc_sha256 else {
                cellsSkipped[cellName] = "dump bytes differ from the cell's doc_sha256"
                continue
            }
            let (seed, reason) = Self.seed(cell)
            guard let seed else {
                cellsSkipped[cellName] = "unseedable: \(reason ?? "?")"
                continue
            }
            do {
                if let failure = try await Self.runCell(
                    cell, cellName: cellName, data: data, seed: seed, out: out) {
                    cellsFailed[cellName] = failure
                    print("[PARITY] FAILED \(cellName): \(failure)")
                } else {
                    cellsRun.append(cellName)
                    print("[PARITY] done \(cellName)")
                }
            } catch { // LegalPhrases:safe (Swift keyword)
                cellsFailed[cellName] = "threw: \(error)"
                print("[PARITY] THREW \(cellName): \(error)")
            }
        }

        #if targetEnvironment(simulator)
        let platform = "simulator \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #else
        let platform = "host \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #endif
        try Self.writeJSON(
            Summary(
                schema_version: 1,
                generated_by: "PipelineCoordinatorParityEmitterTests.emitCoordinatorParity",
                platform_note: platform,
                cells_run: cellsRun,
                cells_skipped: cellsSkipped,
                cells_failed: cellsFailed),
            to: "\(out)/parity-summary.json")
        print("[PARITY] done: \(cellsRun.count) cells -> \(out); skipped: \(cellsSkipped.count); failed: \(cellsFailed.count)")
        #expect(cellsFailed.isEmpty, "every seeded cell must reach .verified: \(cellsFailed)")
    }
}
