import Foundation
import CoreGraphics
import PDFKit
import Testing
import CryptoKit
@testable import RedactionEngine

// H2.2 — the verification corpus runner (1.2 instrumentation plan §4).
//
// For each (document × mode × region set) this suite runs the REDACTION
// pipeline the way `PipelineCoordinator` runs it — `buildPDFPageData` region
// floor + per-page mode selection, `PageRasterizer` with the one half-DPI
// retry, `PDFStreamReconstructor` in append order, the written-page-count
// postcondition — then runs `VerificationEngine.runLayer` over the output in
// the APP's grouping order (page-count gate first; parallel base batch
// [0,1,2(,9)] with one PDFDocument instance per parallel layer; sequential
// [3,4]; sandwich [5..8]; deferred Layer-10 append; `aggregateStatus`), and
// writes output.pdf + report JSON (H2.1 serializer) + regions.json per cell
// for the H2.3 oracle runner (`verify_oracle.py`).
//
// MIRRORING RISK acknowledged (plan §4): this reimplements ~100 lines of
// `PipelineCoordinator` orchestration in the engine test target. The packet
// sim-walkthrough parity check (post-rider) asserts per-layer status parity
// between this runner and the app.
//
// n per cell: the redaction runs once; VERIFICATION runs n=3 sweeps against
// the same output. Layers other than index 1 (OCR Check, Vision-dependent)
// must report identically across sweeps — asserted on the duration-free
// layer tuple. Layer 1's per-sweep statuses are all recorded for downstream
// min/median/max treatment.
//
// Region sets (plan §4): `all-must-fire` (every GT `must_fire` box, rect),
// `seeded-subset` (k boxes, seeded PRNG), `polygon` (the all-must-fire boxes
// as 4-vertex polygon regions). Documents without drawable GT run bespoke
// sets recorded in regions.json (`seeded-grid` for the statement,
// `painted-bars` verify-only for the fill-hallucination artifact, `factory`
// for the RawPDFBuilder adversarial set).
//
// MEASUREMENT HARNESS: env-gated (RESECTA_VERIFY_OUT / RESECTA_DOCS_ROOT,
// plus the TEST_RUNNER_-prefixed forms xcodebuild forwards). Never in the
// batched gate. All fixtures are synthetic with public values manifests —
// matched text is emitted (D31 precedent).

@Suite("H2.2 verification corpus runner (standing emitter)", .serialized)
struct VerificationCorpusRunnerTests {

    // MARK: - Env gate (G8BaselineHarnessTests pattern)

    static func verifyOut() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let p = env["RESECTA_VERIFY_OUT"], !p.isEmpty { return p }
        if let p = env["TEST_RUNNER_RESECTA_VERIFY_OUT"], !p.isEmpty { return p }
        return nil
    }
    static func docsRoot() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let p = env["RESECTA_DOCS_ROOT"], !p.isEmpty { return p }
        if let p = env["TEST_RUNNER_RESECTA_DOCS_ROOT"], !p.isEmpty { return p }
        return nil
    }
    /// Optional comma-separated doc-id filter (smoke runs / partial re-runs).
    static func onlyDocs() -> Set<String>? {
        let env = ProcessInfo.processInfo.environment
        let raw = env["RESECTA_VERIFY_ONLY_DOCS"]
            ?? env["TEST_RUNNER_RESECTA_VERIFY_ONLY_DOCS"]
        guard let raw, !raw.isEmpty else { return nil }
        return Set(raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        })
    }

    // MARK: - Cell execution

    struct CellInput {
        let docId: String
        let data: Data
        let docSHA: String
        let regionSet: RegionSetSpec
        let regionSource: String
        let expectedVisible: [String]
        let notes: String
        /// Verify-only: the input IS the output artifact (fill-hallucination).
        let verifyOnly: Bool
        /// Terms override for non-GT sets (factories). Nil = derive from seeds.
        let termsOverride: [SensitiveTerm]?
    }

    /// Run one (doc × mode × region set) cell end-to-end and write its
    /// evidence files. Returns nil on a skip (with the reason).
    static func runCell(
        _ input: CellInput, mode: PipelineMode, out: String
    ) async throws -> String? {
        let cellDir = "\(out)/\(input.docId)/\(mode.rawValue)/\(input.regionSet.name)"
        try FileManager.default.createDirectory(
            atPath: cellDir, withIntermediateDirectories: true)
        let outputURL = URL(fileURLWithPath: "\(cellDir)/output.pdf")

        guard let doc = PDFDocument(data: input.data) else {
            return "PDFDocument(data:) failed"
        }
        let hasHiddenOCG = documentHasHiddenOCG(input.data)

        // Import mirror: per-page text-layer classification.
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

        // Regions with the floor mirror; record drops.
        var regionsByPage: [Int: [RedactionRegion]] = [:]
        var regionRows: [RegionRow] = []
        var floorDropped: [String] = []
        for seed in input.regionSet.seeds {
            guard seed.page >= 0, seed.page < doc.pageCount else {
                floorDropped.append("\(seed.gtId) (page out of range)")
                continue
            }
            guard let region = region(from: seed, polygon: input.regionSet.polygon) else {
                floorDropped.append(seed.gtId)
                continue
            }
            regionsByPage[seed.page, default: []].append(region)
            regionRows.append(RegionRow(
                page: seed.page,
                rect: [r6(region.normalizedRect.origin.x),
                       r6(region.normalizedRect.origin.y),
                       r6(region.normalizedRect.width),
                       r6(region.normalizedRect.height)],
                polygon: input.regionSet.polygon,
                gt_id: seed.gtId.isEmpty ? nil : seed.gtId,
                value: seed.value.isEmpty ? nil : seed.value,
                category: seed.category.isEmpty ? nil : seed.category))
        }

        // Sub-threshold guard mirror: the app refuses a run with no
        // effective redactions.
        if regionsByPage.values.allSatisfy({ $0.isEmpty }) && !input.verifyOnly {
            return "no effective regions after the floor"
        }

        let terms = input.termsOverride ?? sensitiveTerms(for: input.regionSet.seeds)

        // --- Redaction (or verify-only passthrough) ---
        let clock = ContinuousClock()
        let redactionStart = clock.now
        let outcome: RedactionOutcome
        if input.verifyOnly {
            try input.data.write(to: outputURL, options: .atomic)
            outcome = RedactionOutcome(
                filterDigests: Array(repeating: nil, count: doc.pageCount),
                perPageModes: Array(repeating: .secureRasterization,
                                    count: doc.pageCount),
                perPageFallbackReasons: Array(repeating: nil,
                                              count: doc.pageCount))
        } else {
            let pages = buildPages(
                doc: doc, effectiveMode: mode, regionsByPage: regionsByPage,
                textLayerStatus: status, hasHiddenOCG: hasHiddenOCG)
            outcome = try await runRedaction(pages: pages, outputURL: outputURL)
        }
        let redactionElapsed = clock.now - redactionStart
        let redactionSeconds = Double(redactionElapsed.components.seconds)
            + Double(redactionElapsed.components.attoseconds) / 1e18

        // --- Verification: n = 3 sweeps against the same output ---
        var overallPerSweep: [String] = []
        var layerStatusPerSweep: [[String]] = []
        var identityPerSweep: [[String]] = []
        for sweep in 1...3 {
            let report = try await runVerificationSweep(
                outputURL: outputURL,
                sourcePageCount: doc.pageCount,
                regions: regionsByPage,
                sensitiveTerms: terms,
                effectiveMode: mode,
                filterDigests: outcome.filterDigests,
                perPageModes: outcome.perPageModes,
                perPageFallbackReasons: outcome.perPageFallbackReasons)
            try report.jsonData().write(
                to: URL(fileURLWithPath: "\(cellDir)/report-run-\(sweep).json"),
                options: .atomic)
            if sweep == 1 {
                try report.jsonData().write(
                    to: URL(fileURLWithPath: "\(cellDir)/report.json"),
                    options: .atomic)
            }
            overallPerSweep.append(statusCaseName(report.overallStatus))
            layerStatusPerSweep.append(report.layers.map { statusCaseName($0.status) })
            identityPerSweep.append(report.layers.enumerated().map {
                // Layer index 1 (OCR Check) is Vision-dependent; excluded
                // from the determinism identity. A short single-layer report
                // (page-count gate) participates whole.
                $0.offset == 1 && report.layers.count > 1
                    ? "OCR-EXCLUDED" : layerIdentity($0.element)
            })
        }
        let deterministic = identityPerSweep.dropFirst().allSatisfy {
            $0 == identityPerSweep[0]
        }
        #expect(deterministic,
                "\(input.docId)/\(mode.rawValue)/\(input.regionSet.name): non-OCR layers must report identically across sweeps")

        let outputSHA = sha256Hex((try? Data(contentsOf: outputURL)) ?? Data())
        try writeJSON(
            RegionsJSON(
                schema_version: 1,
                generated_by: "VerificationCorpusRunnerTests.emitVerificationCorpus",
                doc_id: input.docId,
                mode: mode.rawValue,
                region_set: input.regionSet.name,
                region_source: input.regionSource,
                params: input.regionSet.params,
                doc_sha256: input.docSHA,
                page_count: doc.pageCount,
                text_layer_status: statusNames,
                has_hidden_ocg: hasHiddenOCG,
                regions: regionRows,
                floor_dropped: floorDropped,
                sensitive_terms: terms.map {
                    TermRow(text: $0.text,
                            requires_token_boundary: $0.requiresTokenBoundary)
                },
                expected_visible_terms: input.expectedVisible,
                notes: input.notes),
            to: "\(cellDir)/regions.json")
        try writeJSON(
            CellJSON(
                schema_version: 1,
                doc_id: input.docId,
                mode: mode.rawValue,
                region_set: input.regionSet.name,
                verify_only: input.verifyOnly,
                n_verification_sweeps: 3,
                output_sha256: outputSHA,
                redaction_seconds: r6(redactionSeconds),
                per_page_modes: outcome.perPageModes.map(\.rawValue),
                per_page_fallback_reasons: outcome.perPageFallbackReasons.map {
                    $0.map { String(describing: $0) }
                },
                overall_per_sweep: overallPerSweep,
                layer_status_per_sweep: layerStatusPerSweep,
                non_ocr_layers_identical: deterministic),
            to: "\(cellDir)/cell.json")
        return nil
    }

    // MARK: - Manifest (T1.4)

    struct ManifestRow: Decodable {
        let id: String
        let path: String
        let sha256: String
        let gt: String?
        let source: String
    }

    static func loadManifest() throws -> [ManifestRow] {
        let url = try #require(Bundle.module.url(
            forResource: "documents.manifest", withExtension: "json",
            subdirectory: "TestResources"),
            "documents.manifest.json must be bundled in TestResources")
        return try JSONDecoder().decode([ManifestRow].self, from: try Data(contentsOf: url))
    }

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

    /// GT paths are ALWAYS DOCS_ROOT-relative (manifest schema note, L-19),
    /// with the bundled packet GT reachable as a bundle fallback for
    /// root-less host runs.
    static func loadGT(_ row: ManifestRow, root: String?) -> GTFile? {
        guard let gtPath = row.gt else { return nil }
        if let root {
            let url = URL(fileURLWithPath: root).appendingPathComponent(gtPath)
            if let data = try? Data(contentsOf: url),
               let gt = try? JSONDecoder().decode(GTFile.self, from: data) {
                return gt
            }
        }
        let base = ((gtPath as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        if let url = Bundle.module.url(
            forResource: base, withExtension: "json", subdirectory: "TestResources"),
           let data = try? Data(contentsOf: url),
           let gt = try? JSONDecoder().decode(GTFile.self, from: data) {
            return gt
        }
        return nil
    }

    // MARK: - The emit

    @Test("Emit the verification corpus over the T1.4 manifest + fixture set")
    func emitVerificationCorpus() async throws {
        guard let out = Self.verifyOut() else {
            print("[H2.2] RESECTA_VERIFY_OUT not set; verification corpus runner skipped.")
            return
        }
        let root = Self.docsRoot()
        let only = Self.onlyDocs()
        var cellsRun: [String] = []
        var cellsSkipped: [String: String] = [:]
        var shaMismatches: [String] = []

        // Warm Vision once (Layer 2 runs it every cell).
        if let ss = try? TestFixtures.loanPacketScanSimPDF() {
            await DocumentHarnessTests.warmUpVision(scanSimData: ss)
        }

        func execute(_ input: CellInput, modes: [PipelineMode]) async throws {
            if let only, !only.contains(input.docId) { return }
            for mode in modes {
                let cellName = "\(input.docId)/\(mode.rawValue)/\(input.regionSet.name)"
                if let skip = try await Self.runCell(input, mode: mode, out: out) {
                    cellsSkipped[cellName] = skip
                } else {
                    cellsRun.append(cellName)
                    print("[H2.2] done \(cellName)")
                }
            }
        }

        // --- A. Manifest rows with drawable GT: three region sets × both modes ---
        let manifest = try Self.loadManifest()
        for row in manifest where row.path.hasSuffix(".pdf") && row.gt != nil {
            guard let url = Self.resolve(row, root: root),
                  let data = try? Data(contentsOf: url) else {
                cellsSkipped[row.id] = row.source == "external"
                    ? "RESECTA_DOCS_ROOT unset or file missing" : "bundle resource missing"
                continue
            }
            let hex = Self.sha256Hex(data)
            if hex != row.sha256 {
                shaMismatches.append(row.id)
                #expect(hex == row.sha256,
                        "\(row.id): loaded bytes drift from the manifest pin")
            }
            guard let gt = Self.loadGT(row, root: root) else {
                cellsSkipped[row.id] = "ground truth unresolvable (DOCS_ROOT + bundle)"
                continue
            }
            let seeds = Self.regionSeeds(from: gt)
            guard !seeds.isEmpty else {
                cellsSkipped[row.id] = "no drawable must_fire GT boxes"
                continue
            }
            for set in Self.regionSets(for: seeds) {
                let input = CellInput(
                    docId: row.id, data: data, docSHA: hex,
                    regionSet: set, regionSource: "gt",
                    expectedVisible: [],
                    notes: "regions from GT must_fire boxes; ambient-value handling is the oracle's (carried_stmt values recur unburned)",
                    verifyOnly: false, termsOverride: nil)
                try await execute(input, modes: [.secureRasterization, .searchableRedaction])
            }
        }

        // --- B. The statement (no drawable GT): deterministic grid ---
        if let stmtData = try? TestFixtures.sampleStatementPDF(),
           let stmtDoc = PDFDocument(data: stmtData) {
            let input = CellInput(
                docId: "sample-bank-statement", data: stmtData,
                docSHA: Self.sha256Hex(stmtData),
                regionSet: Self.fixedSet(
                    "seeded-grid",
                    seeds: Self.statementGridSeeds(pageCount: stmtDoc.pageCount)),
                regionSource: "seeded-grid",
                expectedVisible: [],
                notes: "no drawable GT (carried_stmt is count-declared); fixed grid probes fill/placement/structure only — no term claims",
                verifyOnly: false, termsOverride: [])
            try await execute(input, modes: [.secureRasterization, .searchableRedaction])
        } else {
            cellsSkipped["sample-bank-statement"] = "bundle resource missing"
        }

        // --- C. The fill-hallucination artifact: verify-only ---
        if let fhData = try? TestFixtures.fillHallucinationRedactedPDF(),
           let fhRegions = try? TestFixtures.fillHallucinationRegionsJSON() {
            struct FHRegions: Decodable {
                struct Box: Decodable {
                    let x: Double; let y: Double
                    let width: Double; let height: Double
                }
                let pages: [[Box]]
            }
            let parsed = try JSONDecoder().decode(FHRegions.self, from: fhRegions)
            let seeds = parsed.pages.enumerated().flatMap { (p, boxes) in
                boxes.enumerated().map { (i, b) in
                    Self.seed("bar_p\(p)_\(i)", page: p,
                              x: b.x, y: b.y, w: b.width, h: b.height)
                }
            }
            let input = CellInput(
                docId: "secureraster-fill-hallucination", data: fhData,
                docSHA: Self.sha256Hex(fhData),
                regionSet: Self.fixedSet("painted-bars", seeds: seeds),
                regionSource: "sidecar",
                expectedVisible: [],
                notes: "verify-only: the fixture IS a Secure Rasterization output (the S1 Layer-2 fill-hallucination reproducer); regions from its sidecar; no term claims",
                verifyOnly: true, termsOverride: [])
            try await execute(input, modes: [.secureRasterization])
        } else {
            cellsSkipped["secureraster-fill-hallucination"] = "bundle resource missing"
        }

        // --- D. The RawPDFBuilder adversarial factory set ---
        for input in Self.factoryInputs() {
            try await execute(
                input, modes: [.secureRasterization, .searchableRedaction])
        }

        // --- E. PB-86 hidden-text probe (searchable path; 1.2 P1.4) ---
        var pb86Rows: [PB86PlantRow] = []
        for (input, rows) in Self.pb86FactoryInputs()
            + Self.pb86SDInputs(root: root, skipped: &cellsSkipped) {
            try await execute(input, modes: [.searchableRedaction])
            pb86Rows.append(contentsOf: rows)
        }
        if !pb86Rows.isEmpty {
            try Self.writePB86Plants(pb86Rows, out: out)
        }

        #if targetEnvironment(simulator)
        let platform = "simulator \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #else
        let platform = "host \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #endif
        try Self.writeJSON(
            RunnerSummary(
                schema_version: 1,
                generated_by: "VerificationCorpusRunnerTests.emitVerificationCorpus",
                platform_note: platform,
                cells_run: cellsRun,
                cells_skipped: cellsSkipped,
                sha_mismatches: shaMismatches),
            to: "\(out)/runner-summary.json")
        print("[H2.2] done: \(cellsRun.count) cells -> \(out); skipped: \(cellsSkipped.count)")
        #expect(shaMismatches.isEmpty)
    }
}
