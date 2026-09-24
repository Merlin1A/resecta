import Testing
import Foundation
import PDFKit
import CryptoKit
@testable import RedactionEngine

// Preview-versus-full parity census over the T3.1 query bank (a standing,
// env-gated emitter; never part of a batched gate). For every query in the
// bank and every option vector it runs the live preview over the whole
// document and the full search restricted to the text layer (`includeOCR`
// off — the preview never runs OCR) on the same bundled documents the
// search ground-truth runner uses, with the same per-page text-layer
// classification installed, and writes one row per (document, query,
// vector) with both counts. The row set is the identity instrument for the
// preview tier: a refactor of the matching core must leave every row's
// numbers in place except the rows it pre-registered.
//
// Env: RESECTA_PREVIEW_CENSUS_OUT (the output directory) and
// RESECTA_SEARCH_QUERIES (the bank), with the TEST_RUNNER_-prefixed forms
// xcodebuild forwards. Skips when unset.

@Suite("Preview-versus-full parity census (standing emitter)", .serialized)
struct PreviewFullParityCensusTests {

    static func env(_ name: String) -> String? {
        let e = ProcessInfo.processInfo.environment
        if let p = e[name], !p.isEmpty { return p }
        if let p = e["TEST_RUNNER_" + name], !p.isEmpty { return p }
        return nil
    }
    static func censusOut() -> String? { env("RESECTA_PREVIEW_CENSUS_OUT") }

    struct Row: Encodable {
        let doc: String
        let qid: String
        let vector: String
        let mode: String
        let preview_total: Int
        let preview_saturated: Bool
        let preview_current_page_highlights: Int
        let full_count: Int
        let equal: Bool
    }
    struct Report: Encodable {
        let schema_version: Int
        let generated_by: String
        let queries_sha256: String
        let docs: [String: [String]]     // doc id → per-page text-layer status names
        let rows: [Row]
    }

    @Test("Census over the T3.1 bank (skips when the env is unset)")
    func census() async throws {
        guard let out = Self.censusOut(), SearchGroundTruthRunnerTests.queriesPath() != nil else {
            TestGate.skip("RESECTA_PREVIEW_CENSUS_OUT / RESECTA_SEARCH_QUERIES unset — the census was not requested")
            return
        }
        let outURL = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        let (file, queriesSHA) = try SearchGroundTruthRunnerTests.loadQueryFile()

        var rows: [Row] = []
        var docStatuses: [String: [String]] = [:]

        for (docID, pin) in file.docs.sorted(by: { $0.key < $1.key }) {
            let base = (pin.path as NSString).lastPathComponent
            let name = (base as NSString).deletingPathExtension
            let ext = (base as NSString).pathExtension
            guard let url = Bundle.module.url(
                forResource: name, withExtension: ext, subdirectory: "TestResources") else {
                Issue.record("preview-census: bundle resource missing: \(base)")
                continue
            }
            let data = try Data(contentsOf: url)
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(hex == pin.sha256, "\(docID): bundled bytes drift from the T3.1 pin")
            let doc = try #require(PDFDocument(data: data))

            var status: [Int: TextLayerStatus] = [:]
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                status[i] = TextLayerDetector.detectTextLayer(page)
            }
            docStatuses[docID] = (0..<doc.pageCount).map {
                switch status[$0] {
                case .rich: "rich"
                case .sparse: "sparse"
                case Optional.none, .some(.none): "none"
                }
            }
            let texts: [String] = (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
            let provider: @Sendable (Int) async -> String? = { idx in
                (idx >= 0 && idx < texts.count) ? texts[idx] : nil
            }

            let searcher = DocumentSearcher(textLayerStatusByPage: status)
            for query in file.queries {
                for vector in file.vectors {
                    var options = try SearchGroundTruthRunnerTests.makeOptions(vector.options)
                    options.includeOCR = false   // the text layer only: the preview never runs OCR
                    let mode = try SearchGroundTruthRunnerTests.makeMode(query, options: options)

                    let preview = await searcher.previewMatches(
                        mode: mode, scope: .wholeDocument, currentPageIndex: 0,
                        totalPageCount: doc.pageCount, pageTextProvider: provider)

                    var fullCount = 0
                    let stream = searcher.search(SendablePDFDocument(doc), mode: mode, progress: { _, _ in })
                    for await _ in stream { fullCount += 1 }

                    rows.append(Row(
                        doc: docID, qid: query.qid, vector: vector.id, mode: query.mode,
                        preview_total: preview.totalCount,
                        preview_saturated: preview.saturated,
                        preview_current_page_highlights: preview.currentPageMatches.count,
                        full_count: fullCount,
                        equal: preview.totalCount == fullCount))
                }
            }
        }

        let report = Report(
            schema_version: 1,
            generated_by: "PreviewFullParityCensusTests",
            queries_sha256: queriesSHA,
            docs: docStatuses,
            rows: rows)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: outURL.appendingPathComponent("preview-vs-full.json"))

        let unequal = rows.filter { !$0.equal }
        var summary = "# Preview-versus-full parity census\n\n"
        summary += "rows: \(rows.count) · equal: \(rows.count - unequal.count) · unequal: \(unequal.count)\n\n"
        for (doc, names) in docStatuses.sorted(by: { $0.key < $1.key }) {
            summary += "- `\(doc)`: \(names.joined(separator: " "))\n"
        }
        if !unequal.isEmpty {
            summary += "\n| doc | qid | vector | mode | preview | full |\n|---|---|---|---|---|---|\n"
            for r in unequal {
                summary += "| \(r.doc) | \(r.qid) | \(r.vector) | \(r.mode) | \(r.preview_total)\(r.preview_saturated ? " (saturated)" : "") | \(r.full_count) |\n"
            }
        }
        try summary.write(to: outURL.appendingPathComponent("SUMMARY.md"), atomically: true, encoding: .utf8)
        print("[preview-census] \(rows.count) rows; unequal \(unequal.count) → \(out)")
    }
}
