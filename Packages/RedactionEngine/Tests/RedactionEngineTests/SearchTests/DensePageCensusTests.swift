import Foundation
import PDFKit
import Testing
@testable import RedactionEngine

// Dense-page selection-mapping census (a standing measurement emitter).
//
// PDFKit's `PDFPage.selection(for:)` stops resolving ranges past a per-page
// offset on dense pages, and every text-leg consumer of
// `DocumentSearcher.boundingRect(for:page:)` skips a match whose rect is nil.
// This emitter measures that bound per page and counts the matches it would
// silently drop, so the number is on record before any lift is designed. It
// changes nothing in the search path: the page is read through the same
// PDFKit calls the product makes, and the drop count is taken through the
// production `boundingRect` seam.
//
// MEASUREMENT HARNESS: env-gated (RESECTA_CENSUS_OUT / RESECTA_DOCS_ROOT /
// RESECTA_CENSUS_DOCS, with the TEST_RUNNER_-prefixed forms xcodebuild
// forwards), never in the batched gate. RESECTA_CENSUS_DOCS is a comma list
// of PDF paths relative to the docs root. No page text leaves the run: the
// match proxy is `\d{3,}` and only counts are written.
@Suite("Dense-page selection-mapping census (standing emitter)", .serialized)
struct DensePageCensusTests {

    // MARK: - Env gate (SearchGroundTruthRunnerTests pattern)

    static func env(_ name: String) -> String? {
        let e = ProcessInfo.processInfo.environment
        if let p = e[name], !p.isEmpty { return p }
        if let p = e["TEST_RUNNER_" + name], !p.isEmpty { return p }
        return nil
    }
    static func censusOut() -> String? { env("RESECTA_CENSUS_OUT") }
    static func docsRoot() -> String? { env("RESECTA_DOCS_ROOT") }
    static func censusDocs() -> [String]? {
        guard let raw = env("RESECTA_CENSUS_DOCS") else { return nil }
        let docs = raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return docs.isEmpty ? nil : docs
    }

    // MARK: - Probe grid

    /// Fixed UTF-16 offsets probed on every page, plus the page's last
    /// offset. The first offset whose one-character selection is nil or has
    /// empty bounds is the page's measured ceiling.
    static let probeOffsets = [1_000, 1_500, 2_000, 2_500, 3_000, 4_000]

    // MARK: - Output rows (deterministic: counts and offsets only)

    struct ProbeRow: Encodable {
        let offset: Int
        let selection: Bool        // `selection(for:)` returned non-nil
        let bounds_empty: Bool?    // nil when there was no selection
        let resolves: Bool         // selection present AND bounds non-empty
    }
    struct PageRow: Encodable {
        let doc: String
        let page: Int
        let chars: Int             // Character count of `page.string`
        let utf16: Int             // UTF-16 length (the unit the probes use)
        let probes: [ProbeRow]
        let ceiling: Int?          // first non-resolving probe offset, or nil
        let charsPast: Int         // utf16 - ceiling (0 when never)
        let matches: Int           // `\d{3,}` matches on the page
        let matchesPast: Int       // matches whose range starts at or past the ceiling
        let nilRectMatches: Int    // matches whose production boundingRect is nil
    }
    struct Report: Encodable {
        let schema_version: Int
        let generated_by: String
        let docs_root: String
        let docs: [String]
        let probe_offsets: [Int]
        let pages: [PageRow]
    }

    @Test("Census over RESECTA_CENSUS_DOCS (skips when the env is unset)")
    func census() async throws {
        guard let out = Self.censusOut(), let root = Self.docsRoot(), let docs = Self.censusDocs() else {
            print("[census] RESECTA_CENSUS_OUT / RESECTA_DOCS_ROOT / RESECTA_CENSUS_DOCS unset; skipped")
            return
        }
        let outURL = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

        let searcher = DocumentSearcher()
        let digitRun = try NSRegularExpression(pattern: "\\d{3,}")
        var pages: [PageRow] = []

        for docPath in docs {
            let url = URL(fileURLWithPath: root).appendingPathComponent(docPath)
            guard let document = PDFDocument(url: url) else {
                Issue.record("census: could not open \(docPath)")
                continue
            }
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                let text = page.string ?? ""
                let nsText = text as NSString
                let utf16 = nsText.length

                var offsets = Self.probeOffsets.filter { $0 < utf16 }
                if utf16 > 0, !offsets.contains(utf16 - 1) { offsets.append(utf16 - 1) }
                offsets.sort()

                var probes: [ProbeRow] = []
                var ceiling: Int? = nil
                for offset in offsets {
                    let selection = page.selection(for: NSRange(location: offset, length: 1))
                    let boundsEmpty = selection.map { $0.bounds(for: page).isEmpty }
                    let resolves = (boundsEmpty == false)
                    probes.append(ProbeRow(
                        offset: offset, selection: selection != nil,
                        bounds_empty: boundsEmpty, resolves: resolves))
                    if !resolves, ceiling == nil { ceiling = offset }
                }

                let matches = digitRun.matches(in: text, range: NSRange(location: 0, length: utf16))
                let matchesPast = ceiling.map { c in matches.filter { $0.range.location >= c }.count } ?? 0
                let nilRect = matches.filter { searcher.boundingRect(for: $0.range, page: page) == nil }.count

                pages.append(PageRow(
                    doc: docPath, page: pageIndex, chars: text.count, utf16: utf16,
                    probes: probes, ceiling: ceiling,
                    charsPast: ceiling.map { utf16 - $0 } ?? 0,
                    matches: matches.count, matchesPast: matchesPast, nilRectMatches: nilRect))
            }
        }

        let report = Report(
            schema_version: 1,
            generated_by: "DensePageCensusTests",
            docs_root: root, docs: docs, probe_offsets: Self.probeOffsets, pages: pages)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: outURL.appendingPathComponent("census.json"))
        try Self.summary(pages).write(
            to: outURL.appendingPathComponent("SUMMARY.md"), atomically: true, encoding: .utf8)
        print("[census] \(pages.count) pages over \(docs.count) docs → \(out)")
    }

    /// The summary lines: pages by length bucket, pages with a nil-rect
    /// match, and the ceiling distribution.
    static func summary(_ pages: [PageRow]) -> String {
        func bucket(_ n: Int) -> String {
            switch n {
            case ..<1_000: return "< 1,000"
            case 1_000..<2_000: return "1,000–2,000"
            case 2_000..<3_000: return "2,000–3,000"
            default: return "> 3,000"
            }
        }
        var byBucket: [String: Int] = [:]
        for p in pages { byBucket[bucket(p.chars), default: 0] += 1 }
        var byCeiling: [String: Int] = [:]
        for p in pages { byCeiling[p.ceiling.map(String.init) ?? "none", default: 0] += 1 }
        let nilRectPages = pages.filter { $0.nilRectMatches > 0 }
        let pastPages = pages.filter { $0.charsPast > 0 }
        var lines: [String] = ["# Dense-page census", ""]
        lines.append("Pages: \(pages.count)")
        lines.append("")
        lines.append("## Pages by Character count")
        for key in ["< 1,000", "1,000–2,000", "2,000–3,000", "> 3,000"] {
            lines.append("- \(key): \(byBucket[key, default: 0])")
        }
        lines.append("")
        lines.append("## Ceiling distribution (first non-resolving probe offset)")
        for key in byCeiling.keys.sorted() {
            lines.append("- \(key): \(byCeiling[key]!)")
        }
        lines.append("")
        lines.append("## Pages past a ceiling: \(pastPages.count); matches past: \(pastPages.reduce(0) { $0 + $1.matchesPast })")
        lines.append("## Pages with a nil-rect match: \(nilRectPages.count); nil-rect matches: \(nilRectPages.reduce(0) { $0 + $1.nilRectMatches })")
        for p in nilRectPages {
            lines.append("- \(p.doc) page \(p.page): chars \(p.chars) utf16 \(p.utf16) ceiling \(p.ceiling.map(String.init) ?? "none") matches \(p.matches) past \(p.matchesPast) nilRect \(p.nilRectMatches)")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
