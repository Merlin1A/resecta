import Foundation
import CoreGraphics
import PDFKit
import Testing
import CryptoKit
@testable import RedactionEngine

// H3.1 — the search ground-truth runner (1.2 instrumentation plan §6).
//
// Runs the PRODUCT search path — `DocumentSearcher.search(_:mode:progress:)`,
// the exact pipeline the Search sheet triggers — for every
// (query × option-vector) cell of the T3.1 bank
// (`search-ground-truth/search-queries.json`, sample-doc repo) over the
// packet and scan-sim manifest documents, and emits per-document hits JSON
// for the H3.2 differential-oracle diff and the frozen GT sidecars.
//
// Offsets: the public `SearchResult` carries no character range, so each
// text-layer hit's `{start,end}` (UTF-16 in `page.string` space) is
// RECOVERED losslessly: enumerate the literal occurrences of `matchedText`
// on the page and keep the candidate whose `boundingRect(for:page:)` —
// the same public function the product used — reproduces the hit's rect
// exactly. Unrecoverable hits (none expected on the ASCII corpus) emit
// null offsets plus an `offset_recovery` flag rather than a guess.
// OCR-sourced hits carry null offsets by design (line-space, not
// page.string space); the OCR text itself is emitted via the
// `_testOCRCachedLines` seam so correctness-vs-OCR-text is computable
// downstream from exactly what the product matched against.
//
// n: the all-rich packet battery runs twice with a byte-identity assert on
// the latency-free cell content (text path is deterministic); the scan-sim
// battery runs twice with FRESH searchers (independent Vision passes) so
// OCR-induced hit-set variance is measured, never averaged away.
//
// MEASUREMENT HARNESS: env-gated (RESECTA_SEARCH_OUT / RESECTA_SEARCH_QUERIES,
// with the TEST_RUNNER_-prefixed forms xcodebuild forwards), never in the
// batched gate. MATCHED-TEXT LOGGING (D31): all fixtures are synthetic with
// a public values manifest — matched text is emitted.

@Suite("H3.1 search ground-truth runner (standing emitter)", .serialized)
struct SearchGroundTruthRunnerTests {

    // MARK: - Env gate (G8BaselineHarnessTests pattern)

    static func env(_ name: String) -> String? {
        let e = ProcessInfo.processInfo.environment
        if let p = e[name], !p.isEmpty { return p }
        if let p = e["TEST_RUNNER_" + name], !p.isEmpty { return p }
        return nil
    }
    static func searchOut() -> String? { env("RESECTA_SEARCH_OUT") }
    static func queriesPath() -> String? { env("RESECTA_SEARCH_QUERIES") }
    static func onlyDocs() -> Set<String>? {
        guard let raw = env("RESECTA_SEARCH_ONLY_DOCS") else { return nil }
        return Set(raw.split(separator: ",").map(String.init))
    }

    // MARK: - T3.1 query manifest

    struct VectorRow: Decodable {
        let id: String
        let options: [String: Bool]
    }
    struct QueryRow: Decodable {
        let qid: String
        let mode: String
        let query: String?
        let pattern: String?
        let terms: [String]?
        let family: String
    }
    struct DocPin: Decodable {
        let path: String
        let sha256: String
    }
    struct QueryFile: Decodable {
        let schema_version: Int
        let toggles: [String]
        let vectors: [VectorRow]
        let queries: [QueryRow]
        let docs: [String: DocPin]
    }

    static func loadQueryFile() throws -> (file: QueryFile, sha256: String) {
        let path = try #require(queriesPath(), "RESECTA_SEARCH_QUERIES must point at search-queries.json")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (try JSONDecoder().decode(QueryFile.self, from: data), sha)
    }

    static func makeOptions(_ dict: [String: Bool]) throws -> SearchOptions {
        func flag(_ name: String) throws -> Bool {
            try #require(dict[name] as Bool?, "vector missing toggle \(name)")
        }
        return SearchOptions(
            caseSensitive: try flag("caseSensitive"),
            wholeWord: try flag("wholeWord"),
            includeOCR: try flag("includeOCR"),
            normalizeUnicode: try flag("normalizeUnicode"),
            exactMatch: try flag("exactMatch"),
            stripDigitSeparators: try flag("stripDigitSeparators"),
            normalizeSmartPunctuation: try flag("normalizeSmartPunctuation"),
            foldDiacritics: try flag("foldDiacritics"),
            multiTermConjunction: try flag("multiTermConjunction")
        )
    }

    static func makeMode(_ row: QueryRow, options: SearchOptions) throws -> SearchMode {
        switch row.mode {
        case "text": return .text(try #require(row.query), options: options)
        case "regex": return .regex(try #require(row.pattern), options: options)
        case "multiTerm": return .multiTerm(try #require(row.terms), options: options)
        default:
            Issue.record("unknown query mode \(row.mode)")
            return .text("", options: options)
        }
    }

    // MARK: - Output rows (deterministic: no UUIDs, rounded geometry)

    static func r6(_ v: Double) -> Double { (v * 1e6).rounded() / 1e6 }

    struct HitOut: Encodable {
        let page: Int
        let start: Int?
        let end: Int?
        let text: String
        let rect: [Double]
        let source: String              // "text" | "ocr"
        let ocr_confidence: Double?
        let offset_recovery: String     // "exact" | "ocr-line" | "unmatched" | "ambiguous"
    }
    struct CellOut: Encodable {
        let qid: String
        let vector_id: String
        let mode: String
        let latency_ms: Double
        let yielded: Int
        let cap_reached: Bool
        let not_analyzed_pages: [Int]
        let ocr_skipped_pages: [Int]
        let hits: [HitOut]
    }
    /// Latency-free mirror for the determinism digest.
    struct CellDigest: Encodable {
        let qid: String
        let vector_id: String
        let yielded: Int
        let cap_reached: Bool
        let not_analyzed_pages: [Int]
        let ocr_skipped_pages: [Int]
        let hits: [HitOut]
    }
    struct RunOut: Encodable {
        let schema_version: Int
        let generated_by: String
        let doc_id: String
        let doc_sha256: String
        let queries_sha256: String
        let page_count: Int
        let text_layer_status: [String]
        let run_index: Int
        let duration_s: Double
        let cells: [CellOut]
    }
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
    struct SummaryOut: Encodable {
        let schema_version: Int
        let generated_by: String
        let queries_sha256: String
        let docs_run: [String]
        let docs_skipped: [String: String]
        let packet_deterministic: Bool?
        let packet_differing_cells: [String]?
        let packet_diffs_burst_explained: Bool?
        let cell_count_per_run: Int
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

    static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Per-cell sinks

    final class CellTally: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var notAnalyzed: [Int] = []
        private(set) var ocrSkipped: [Int] = []
        func addNotAnalyzed(_ p: Int) { lock.lock(); notAnalyzed.append(p); lock.unlock() }
        func addOCRSkip(_ p: Int) { lock.lock(); ocrSkipped.append(p); lock.unlock() }
    }

    // MARK: - Offset recovery

    /// All literal case-sensitive occurrences of `text` in `pageString`
    /// (UTF-16 NSRanges, ascending).
    static func occurrences(of text: String, in pageString: String) -> [NSRange] {
        guard !text.isEmpty else { return [] }
        let ns = pageString as NSString
        var found: [NSRange] = []
        var location = 0
        while location < ns.length {
            let r = ns.range(of: text, options: [.literal],
                             range: NSRange(location: location, length: ns.length - location))
            if r.location == NSNotFound { break }
            found.append(r)
            location = r.location + max(r.length, 1)
        }
        return found
    }

    /// Pair each text-layer hit with the candidate occurrence whose product
    /// rect reproduces the hit rect exactly; hits sharing (page, text, rect)
    /// are paired with successive rect-equal candidates in yield order.
    static func recoverOffsets(
        hits: [SearchResult], searcher: DocumentSearcher, doc: PDFDocument
    ) -> [(SearchResult, HitOut)] {
        var pageStrings: [Int: String] = [:]
        var candidateCache: [String: [NSRange]] = [:]   // "page|text" -> ranges
        var rectMatched: [String: [NSRange]] = [:]      // "page|text|rect" -> queue
        var out: [(SearchResult, HitOut)] = []

        for hit in hits {
            let rectArr = [r6(hit.normalizedRect.origin.x), r6(hit.normalizedRect.origin.y),
                           r6(hit.normalizedRect.width), r6(hit.normalizedRect.height)]
            var ocrConf: Double? = nil
            if case .ocr(let c) = hit.source { ocrConf = r6(Double(c)) }
            if ocrConf != nil {
                out.append((hit, HitOut(
                    page: hit.pageIndex, start: nil, end: nil, text: hit.matchedText,
                    rect: rectArr, source: "ocr", ocr_confidence: ocrConf,
                    offset_recovery: "ocr-line")))
                continue
            }
            guard let page = doc.page(at: hit.pageIndex) else { continue }
            let pageString: String
            if let cached = pageStrings[hit.pageIndex] {
                pageString = cached
            } else {
                pageString = page.string ?? ""
                pageStrings[hit.pageIndex] = pageString
            }
            let candKey = "\(hit.pageIndex)|\(hit.matchedText)"
            let cands: [NSRange]
            if let cached = candidateCache[candKey] {
                cands = cached
            } else {
                cands = occurrences(of: hit.matchedText, in: pageString)
                candidateCache[candKey] = cands
            }
            let queueKey = "\(candKey)|\(rectArr)"
            var queue: [NSRange]
            if let q = rectMatched[queueKey] {
                queue = q
            } else {
                queue = cands.filter { cand in
                    searcher.boundingRect(for: cand, page: page) == hit.normalizedRect
                }
                rectMatched[queueKey] = queue
            }
            let recovery: String
            var start: Int? = nil
            var end: Int? = nil
            if queue.isEmpty {
                recovery = "unmatched"
            } else {
                let r = queue.removeFirst()
                rectMatched[queueKey] = queue
                start = r.location
                end = r.location + r.length
                recovery = "exact"
            }
            out.append((hit, HitOut(
                page: hit.pageIndex, start: start, end: end, text: hit.matchedText,
                rect: rectArr, source: "text", ocr_confidence: nil,
                offset_recovery: recovery)))
        }
        return out
    }

    // MARK: - One battery run

    static func batteryRun(
        docID: String, data: Data, status: [Int: TextLayerStatus],
        file: QueryFile, runIndex: Int
    ) async throws -> (cells: [CellOut], digests: [CellDigest], seconds: Double, searcher: DocumentSearcher, doc: PDFDocument) {
        let doc = try #require(PDFDocument(data: data))
        let searcher = DocumentSearcher()
        await searcher.setTextLayerStatus(status)

        var cells: [CellOut] = []
        var digests: [CellDigest] = []
        let clock = ContinuousClock()
        let batteryStart = clock.now

        for query in file.queries {
            for vector in file.vectors {
                let options = try makeOptions(vector.options)
                let mode = try makeMode(query, options: options)
                let tally = CellTally()
                await searcher.setScannedRegionNotAnalyzedSink { tally.addNotAnalyzed($0) }
                await searcher.setOCRSkipSink { tally.addOCRSkip($0) }

                let cellStart = clock.now
                let stream = searcher.search(
                    SendablePDFDocument(doc), mode: mode, progress: { _, _ in })
                var hits: [SearchResult] = []
                for await r in stream { hits.append(r) }
                let elapsed = clock.now - cellStart
                let ms = Double(elapsed.components.seconds) * 1000
                    + Double(elapsed.components.attoseconds) / 1e15

                let recovered = recoverOffsets(hits: hits, searcher: searcher, doc: doc)
                let hitRows = recovered.map(\.1)
                let notAnalyzed = tally.notAnalyzed.sorted()
                let ocrSkipped = tally.ocrSkipped.sorted()
                cells.append(CellOut(
                    qid: query.qid, vector_id: vector.id, mode: query.mode,
                    latency_ms: (ms * 1000).rounded() / 1000,
                    yielded: hits.count,
                    cap_reached: hits.count >= DocumentSearcher.maxResults,
                    not_analyzed_pages: notAnalyzed,
                    ocr_skipped_pages: ocrSkipped,
                    hits: hitRows))
                digests.append(CellDigest(
                    qid: query.qid, vector_id: vector.id,
                    yielded: hits.count,
                    cap_reached: hits.count >= DocumentSearcher.maxResults,
                    not_analyzed_pages: notAnalyzed,
                    ocr_skipped_pages: ocrSkipped,
                    hits: hitRows))
            }
        }
        let total = clock.now - batteryStart
        let seconds = Double(total.components.seconds)
            + Double(total.components.attoseconds) / 1e18
        return (cells, digests, seconds, searcher, doc)
    }

    static func dumpOCRLines(
        searcher: DocumentSearcher, docID: String, runIndex: Int, out: String
    ) async throws {
        let normalizer = OCRTextNormalizer()
        var pages: [OCRPageOut] = []
        for pageIndex in await searcher._testOCRCacheKeys.sorted() {
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
    }

    // MARK: - The emit

    @Test("Emit search-GT product hits over the T3.1 bank")
    func emitSearchGroundTruth() async throws {
        guard let out = Self.searchOut() else {
            print("[H3.1] RESECTA_SEARCH_OUT not set; search GT runner skipped.")
            return
        }
        let (file, queriesSHA) = try Self.loadQueryFile()
        let only = Self.onlyDocs()

        var docsRun: [String] = []
        var docsSkipped: [String: String] = [:]
        var packetDeterministic: Bool? = nil
        var packetDiffering: [String] = []
        var packetBurstExplained: Bool? = nil

        for (docID, pin) in file.docs.sorted(by: { $0.key < $1.key }) {
            if let only, !only.contains(docID) {
                docsSkipped[docID] = "filtered by RESECTA_SEARCH_ONLY_DOCS"
                continue
            }
            let base = (pin.path as NSString).lastPathComponent
            let name = (base as NSString).deletingPathExtension
            let ext = (base as NSString).pathExtension
            guard let url = Bundle.module.url(
                forResource: name, withExtension: ext, subdirectory: "TestResources") else {
                docsSkipped[docID] = "bundle resource missing: \(base)"
                continue
            }
            let data = try Data(contentsOf: url)
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(hex == pin.sha256, "\(docID): bundled bytes drift from the T3.1 pin")

            let probeDoc = try #require(PDFDocument(data: data))
            var status: [Int: TextLayerStatus] = [:]
            for i in 0..<probeDoc.pageCount {
                guard let page = probeDoc.page(at: i) else { continue }
                status[i] = TextLayerDetector.detectTextLayer(page)
            }
            let statusNames: [String] = (0..<probeDoc.pageCount).map {
                switch status[$0] {
                case .rich: "rich"
                case .sparse: "sparse"
                case Optional.none, .some(.none): "none"
                }
            }
            let anyOCR = statusNames.contains { $0 != "rich" }
            if anyOCR {
                await DocumentHarnessTests.warmUpVision(scanSimData: data)
            }

            print("[H3.1] \(docID): pages=\(probeDoc.pageCount) status=\(statusNames) "
                  + "cells=\(file.queries.count * file.vectors.count) runs=2")

            var runDigestLists: [[CellDigest]] = []
            for runIndex in 1...2 {
                let (cells, digests, seconds, searcher, _) = try await Self.batteryRun(
                    docID: docID, data: data, status: status,
                    file: file, runIndex: runIndex)
                try Self.writeJSON(RunOut(
                    schema_version: 1,
                    generated_by: "SearchGroundTruthRunnerTests (H3.1)",
                    doc_id: docID,
                    doc_sha256: hex,
                    queries_sha256: queriesSHA,
                    page_count: probeDoc.pageCount,
                    text_layer_status: statusNames,
                    run_index: runIndex,
                    duration_s: (seconds * 1000).rounded() / 1000,
                    cells: cells), to: "\(out)/\(docID)/run-\(runIndex).json")
                runDigestLists.append(digests)
                if anyOCR {
                    try await Self.dumpOCRLines(
                        searcher: searcher, docID: docID, runIndex: runIndex, out: out)
                }
                print("[H3.1] \(docID) run \(runIndex): \(cells.count) cells in "
                      + String(format: "%.1fs", seconds))
            }
            if !anyOCR {
                // Text-leg determinism, with one measured exception: the
                // search stream's `.bufferingNewest(100)` policy can drop the
                // oldest buffered hits when one page bursts past 100 matches
                // and the consumer lags (observed on the scan-sim OCR leg).
                // A cross-run difference is acceptable ONLY on such burst
                // cells; low-density cells must stay byte-identical.
                var differing: [String] = []
                var allBurst = true
                if runDigestLists.count == 2 {
                    for (a, b) in zip(runDigestLists[0], runDigestLists[1])
                    where (try Self.digest(a)) != (try Self.digest(b)) {
                        differing.append("\(a.qid)|\(a.vector_id)")
                        let burst = [a, b].contains { d in
                            Dictionary(grouping: d.hits, by: \.page)
                                .values.contains { $0.count > 100 }
                        }
                        if !burst { allBurst = false }
                    }
                }
                let identical = differing.isEmpty
                #expect(identical || allBurst,
                        "\(docID): non-burst text-leg cells differ across runs: \(differing)")
                if docID == "packet" {
                    packetDeterministic = identical
                    packetDiffering = differing
                    packetBurstExplained = identical ? nil : allBurst
                }
            }
            docsRun.append(docID)
        }

        try Self.writeJSON(SummaryOut(
            schema_version: 1,
            generated_by: "SearchGroundTruthRunnerTests (H3.1)",
            queries_sha256: queriesSHA,
            docs_run: docsRun,
            docs_skipped: docsSkipped,
            packet_deterministic: packetDeterministic,
            packet_differing_cells: packetDiffering.isEmpty ? nil : packetDiffering,
            packet_diffs_burst_explained: packetBurstExplained,
            cell_count_per_run: file.queries.count * file.vectors.count),
            to: "\(out)/summary.json")
        print("[H3.1] done: \(docsRun) run, \(docsSkipped.count) skipped")
    }
}
