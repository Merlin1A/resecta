import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The OCR confusable census: a measurement harness, env-gated
// (RESECTA_OCR_SKELETON_CENSUS=1), never in the batched gate. On the fixture
// library's scanned pages of eight OCR-hostile lines it prints each
// recognised line verbatim and as Scan's confusable normalizer rewrites it,
// then, through the real DocumentSearcher, the result count and the boxes of
// a list of typed numbers, codes and names. Run before and after a change to
// the OCR literal route, the two prints are the census. Vision on the macOS
// host is an estimate of the simulator's.
//
// Reads the fixture library (RESECTA_FIXTURES, default
// ~/Documents/resecta-131-fixtures/made) read-only, by absolute path.

@Suite("OCR confusable census probe (env-gated)",
       .enabled(if: ProcessInfo.processInfo.environment["RESECTA_OCR_SKELETON_CENSUS"] != nil
                || ProcessInfo.processInfo.environment["TEST_RUNNER_RESECTA_OCR_SKELETON_CENSUS"] != nil))
struct OCRSkeletonCensusProbeTests {

    static let fixtures: String =
        ProcessInfo.processInfo.environment["RESECTA_FIXTURES"]
        ?? (NSHomeDirectory() + "/Documents/resecta-131-fixtures/made")

    static let files = ["FX-05-hostile-300dpi-clean.pdf", "FX-05-hostile-300dpi.pdf", "FX-05-hostile-200dpi.pdf"]

    static let texts = [
        "Suite 100", "18-115", "Room 101", "$1,000", "1,000", "Apt 4B", "SO5518", "(414) 555-0193",
        "Iñaki Zubizarreta-Núñez", "Inaki Zubizarreta-Nunez", "1234 5678 9012", "Vance-Oduya",
    ]
    static let patterns = [#"Room \d+"#, #"\d{3}"#]

    static func run(_ data: Data, _ mode: SearchMode, searcher: DocumentSearcher) async -> [SearchResult] {
        guard let doc = PDFDocument(data: data) else { return [] }
        let stream = searcher.search(SendablePDFDocument(doc), mode: mode, progress: { _, _ in })
        var out: [SearchResult] = []
        for await r in stream { out.append(r) }
        return out
    }

    static func box(_ r: CGRect) -> String {
        String(format: "[%.3f %.3f %.3f %.3f]", r.minX, r.minY, r.width, r.height)
    }

    @Test("The hostile scans: recognised lines, their normalized form, and each query's results")
    func hostileScans() async throws {
        let normalizer = OCRTextNormalizer()
        for file in Self.files {
            guard let data = FileManager.default.contents(atPath: Self.fixtures + "/" + file) else {
                print("[OCR-CENSUS] \(file) · unreadable"); continue
            }
            let searcher = DocumentSearcher()
            _ = await Self.run(data, .text("zzzz", options: SearchOptions()), searcher: searcher)
            let lines = await searcher._testOCRCachedLines(forPageIndex: 0) ?? []
            print("[OCR-CENSUS] \(file) · \(lines.count) lines")
            for line in lines {
                print("[OCR-CENSUS]   line \(Self.box(line.normalizedRect)) words=\(line.wordBoxes.count) · \(line.text) · normalized: \(normalizer.normalize(line.text))")
            }
            for query in Self.texts {
                let hits = await Self.run(data, .text(query, options: SearchOptions()), searcher: searcher)
                print("[OCR-CENSUS]   text \(query) · \(hits.count) · \(hits.map { "\($0.matchedText) \(Self.box($0.normalizedRect))" })")
            }
            for pattern in Self.patterns {
                let hits = await Self.run(data, .regex(pattern, options: SearchOptions()), searcher: searcher)
                print("[OCR-CENSUS]   regex \(pattern) · \(hits.count) · \(hits.map(\.matchedText))")
            }
        }
    }
}
