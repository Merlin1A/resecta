import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import RedactionEngine

// Tie census over the Site-B gate's stable sort (a standing measurement
// emitter).
//
// Both PII-scan legs re-sort the recombined survivors by `range.location`
// with Swift's stable sort, so two survivors at one location keep their
// input order. This emitter counts such ties over the H1.2 corpus. The
// text leg re-reads each rich page through the same PDFKit calls and runs
// the same detector, assembler, resolver and gate the searcher runs; the
// OCR leg re-reads the normalized lines the H1.2 run dumped per page
// (`ocr-lines-run-1.json` — the text the OCR leg matched against) and runs
// the same steps over their concatenation. Counts only are written.
//
// MEASUREMENT HARNESS: env-gated (RESECTA_TIE_OUT / RESECTA_DOCS_ROOT /
// RESECTA_TIE_DUMPS, with the TEST_RUNNER_-prefixed forms xcodebuild
// forwards), never in the batched gate.
@Suite("Site-B sort-input tie census (standing emitter)", .serialized)
struct SortTieCensusTests {

    // MARK: - Env gate

    static func env(_ name: String) -> String? {
        let e = ProcessInfo.processInfo.environment
        if let p = e[name], !p.isEmpty { return p }
        if let p = e["TEST_RUNNER_" + name], !p.isEmpty { return p }
        return nil
    }
    static func tieOut() -> String? { env("RESECTA_TIE_OUT") }
    static func docsRoot() -> String? { env("RESECTA_DOCS_ROOT") }
    static func dumpsRoot() -> String? { env("RESECTA_TIE_DUMPS") }

    // MARK: - The OCR dump (the H1.2 emitter's shape)

    struct DumpFile: Decodable {
        struct Page: Decodable {
            struct Line: Decodable {
                let text: String
                let normalized: String
                let rect: [Double]
                let confidence: Double
            }
            let page: Int
            let lines: [Line]
        }
        let doc_id: String
        let pages: [Page]
    }

    // MARK: - Output rows (counts only)

    struct PageRow: Encodable {
        let doc: String
        let page: Int
        let leg: String            // "text" | "ocr"
        let surviving: Int         // after overlap resolution
        let sortInput: Int         // the gate's recombined list (the sort's input)
        let ties: Int              // Σ (n − 1) over locations shared by n ≥ 2 inputs
        let tieLocations: Int
        let sentinelAddresses: Int // assembled addresses at the sentinel location
    }
    struct Report: Encodable {
        let schema_version: Int
        let generated_by: String
        let threshold_preset: String
        let text_pages: Int
        let ocr_pages: Int
        let ties_text: Int
        let ties_ocr: Int
        let pages: [PageRow]
    }

    /// Ties in a list keyed by `range.location`.
    static func ties(_ matches: [PIIDetector.PIIMatch]) -> (ties: Int, locations: Int) {
        var byLocation: [Int: Int] = [:]
        for m in matches { byLocation[m.range.location, default: 0] += 1 }
        let groups = byLocation.values.filter { $0 >= 2 }
        return (groups.reduce(0) { $0 + $1 - 1 }, groups.count)
    }

    /// One page's sort input, built the way the searcher builds it:
    /// detector matches, the assembled addresses (located in the haystack
    /// or at the sentinel), overlap resolution, then the partition-gate-
    /// compose split at the balanced preset.
    static func sortInput(
        text: String, lines: [OCREngine.TextLine],
        detector: PIIDetector, assembler: AddressSpatialAssembler,
        vector: PresetThresholdVector?, calibrated: CalibratedScorer, scorer: ContextScorerWeights
    ) async -> (surviving: [PIIDetector.PIIMatch], input: [PIIDetector.PIIMatch], sentinels: Int) {
        var raw = await detector.detect(in: text, categories: Set(PIICategory.allCases))
        let haystack = text as NSString
        let sentinel = haystack.length
        var sentinels = 0
        for address in assembler.assemble(lines: lines) {
            let located = haystack.range(
                of: address.text, options: [], range: NSRange(location: 0, length: sentinel))
            if located.location == NSNotFound { sentinels += 1 }
            let range = located.location != NSNotFound ? located : NSRange(location: sentinel, length: 0)
            raw.append(PIIDetector.PIIMatch(
                text: address.text, range: range, kind: .address, confidence: address.confidence))
        }
        let surviving = DetectionOrchestrator.resolveOverlaps(raw).surviving
        let (scored, rest) = surviving.partitionedByScoredFamily()
        let gated = rest.applyingCountingDrops(thresholdVector: vector)
        let composed = DocumentSearcher.composedSurvivors(
            scored, pageText: text, thresholdVector: vector,
            calibratedScorer: calibrated, contextScorer: scorer, priors: PerCategoryPriors())
        return (surviving, gated.survivors + composed, sentinels)
    }

    @Test("Tie census over the H1.2 corpus (skips when the env is unset)")
    func census() async throws {
        guard let out = Self.tieOut() else {
            print("[tie-census] RESECTA_TIE_OUT unset; skipped")
            return
        }
        let outURL = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

        let detector = PIIDetector()
        let assembler = AddressSpatialAssembler()
        let vector = PresetThresholdBundle.loadFromEngineBundle().presets[.balanced]
        let calibrated = CalibratedScorer()
        let scorer = ContextScorerWeights.loadFromEngineBundle()
        var rows: [PageRow] = []

        // The text leg: every rich page of every corpus document.
        let root = Self.docsRoot()
        for row in try DocumentHarnessTests.loadManifest() where row.path.hasSuffix(".pdf") && row.gt != nil {
            guard let url = DocumentHarnessTests.resolve(row, root: root),
                  let data = try? Data(contentsOf: url),
                  let document = PDFDocument(data: data) else { continue }
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex),
                      TextLayerDetector.detectTextLayer(page) == .rich,
                      let text = page.string, !text.isEmpty else { continue }
                let lines = EmbeddedTextSource.make(from: page)?.lines ?? []
                let built = await Self.sortInput(
                    text: text, lines: lines, detector: detector, assembler: assembler,
                    vector: vector, calibrated: calibrated, scorer: scorer)
                let tie = Self.ties(built.input)
                rows.append(PageRow(
                    doc: row.id, page: pageIndex, leg: "text",
                    surviving: built.surviving.count, sortInput: built.input.count,
                    ties: tie.ties, tieLocations: tie.locations, sentinelAddresses: built.sentinels))
            }
        }

        // The OCR leg: the normalized lines the H1.2 run dumped, per page.
        if let dumps = Self.dumpsRoot() {
            let docDirs = (try? FileManager.default.contentsOfDirectory(atPath: dumps)) ?? []
            for docDir in docDirs.sorted() {
                let dumpURL = URL(fileURLWithPath: dumps)
                    .appendingPathComponent(docDir).appendingPathComponent("ocr-lines-run-1.json")
                guard let data = try? Data(contentsOf: dumpURL),
                      let dump = try? JSONDecoder().decode(DumpFile.self, from: data) else { continue }
                for page in dump.pages {
                    let lines = page.lines.map { line in
                        OCREngine.TextLine(
                            text: line.normalized,
                            normalizedRect: CGRect(
                                x: line.rect[0], y: line.rect[1], width: line.rect[2], height: line.rect[3]),
                            confidence: Float(line.confidence))
                    }
                    var concatenated = ""
                    for line in page.lines { concatenated += line.normalized + "\n" }
                    let built = await Self.sortInput(
                        text: concatenated, lines: lines, detector: detector, assembler: assembler,
                        vector: vector, calibrated: calibrated, scorer: scorer)
                    let tie = Self.ties(built.input)
                    rows.append(PageRow(
                        doc: dump.doc_id, page: page.page, leg: "ocr",
                        surviving: built.surviving.count, sortInput: built.input.count,
                        ties: tie.ties, tieLocations: tie.locations, sentinelAddresses: built.sentinels))
                }
            }
        }

        let textRows = rows.filter { $0.leg == "text" }
        let ocrRows = rows.filter { $0.leg == "ocr" }
        let report = Report(
            schema_version: 1, generated_by: "SortTieCensusTests", threshold_preset: "balanced",
            text_pages: textRows.count, ocr_pages: ocrRows.count,
            ties_text: textRows.reduce(0) { $0 + $1.ties },
            ties_ocr: ocrRows.reduce(0) { $0 + $1.ties },
            pages: rows)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: outURL.appendingPathComponent("ties.json"))
        print("[tie-census] text leg: \(report.text_pages) pages, \(report.ties_text) ties on \(textRows.filter { $0.ties > 0 }.count) pages; OCR leg: \(report.ocr_pages) pages, \(report.ties_ocr) ties on \(ocrRows.filter { $0.ties > 0 }.count) pages → \(out)")
    }
}
