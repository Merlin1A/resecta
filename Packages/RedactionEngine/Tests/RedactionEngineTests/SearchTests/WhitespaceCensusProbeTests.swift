import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The whitespace census: a measurement harness, env-gated (RESECTA_WS_CENSUS=1),
// never in the batched gate. It prints three facts the whitespace fold is
// shaped on: (i) what PDFKit's `page.string` emits at a line break and inside
// a run of spaces; (ii) for every space-bearing ground-truth query, the
// instance count on the packet under today's matcher and under a
// whitespace-run fold of the page text; (iii) the ground-truth regex queries
// whose matches span a line break in the packet's text. The scanned variant
// needs Vision, which the host does not run; its cells are read from the OCR
// literal path's per-observation shape instead and stated as such.
//
// Reads `~/resecta-sample-doc` (or RESECTA_SAMPLE_DOC) read-only.

@Suite("Whitespace census probe (env-gated)",
       .enabled(if: ProcessInfo.processInfo.environment["RESECTA_WS_CENSUS"] != nil))
struct WhitespaceCensusProbeTests {

    static let sampleDocRoot: String =
        ProcessInfo.processInfo.environment["RESECTA_SAMPLE_DOC"] ?? (NSHomeDirectory() + "/resecta-sample-doc")

    // MARK: - (i) the line separator

    private static func courierPage(_ stream: String) -> Data {
        buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>"),
        ], rootId: 1)
    }

    private static func named(_ text: String) -> String {
        text.unicodeScalars.map { scalar -> String in
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil { return String(scalar) }
            return String(format: "<U+%04X>", scalar.value)
        }.joined()
    }

    @Test("What page.string emits at a line break and inside a run of spaces")
    func lineSeparatorFact() throws {
        let cases: [(String, String)] = [
            ("two text objects, second 14 pt lower", "BT /F1 12 Tf 72 700 Td (Jane) Tj ET\nBT /F1 12 Tf 72 686 Td (Doe) Tj ET"),
            ("two text objects on one line, 40 pt apart", "BT /F1 12 Tf 72 700 Td (Jane) Tj ET\nBT /F1 12 Tf 140 700 Td (Doe) Tj ET"),
            ("one Tj with two spaces", "BT /F1 12 Tf 72 700 Td (Jane  Doe) Tj ET"),
            ("one TJ with a 2000-unit gap", "BT /F1 12 Tf 72 700 Td [(Jane) -2000 (Doe)] TJ ET"),
            ("T* line advance", "BT /F1 12 Tf 14 TL 72 700 Td (Jane) Tj T* (Doe) Tj ET"),
            ("two space glyphs as their own Tj", "BT /F1 12 Tf 72 700 Td (Jane) Tj ( ) Tj ( ) Tj (Doe) Tj ET"),
            ("a tab byte inside one Tj", "BT /F1 12 Tf 72 700 Td (Jane\\011Doe) Tj ET"),
            ("a WinAnsi NBSP (octal 240) inside one Tj", "BT /F1 12 Tf 72 700 Td (Jane\\240Doe) Tj ET"),
            ("a wide word spacing Tw with one space", "BT /F1 12 Tf 40 Tw 72 700 Td (Jane Doe) Tj ET"),
            ("three spaces in one Tj", "BT /F1 12 Tf 72 700 Td (Jane   Doe) Tj ET"),
        ]
        for (name, stream) in cases {
            let doc = try #require(PDFDocument(data: Self.courierPage(stream)))
            let page = try #require(doc.page(at: 0))
            print("[WS-CENSUS] separator · \(name) · page.string=\(Self.named(page.string ?? "<nil>"))")
        }
    }

    // MARK: - (ii) the space-bearing queries on the packet

    struct Bank: Decodable {
        struct Query: Decodable { let qid: String; let mode: String; let query: String?; let terms: [String]?; let pattern: String? }
        let queries: [Query]
    }

    private static func loadBank() throws -> Bank {
        let url = URL(fileURLWithPath: sampleDocRoot + "/search-ground-truth/search-queries.json")
        return try JSONDecoder().decode(Bank.self, from: Data(contentsOf: url))
    }

    private static func loadPacket() throws -> PDFDocument {
        try #require(PDFDocument(url: URL(fileURLWithPath: sampleDocRoot + "/packet.pdf")))
    }

    /// A whitespace-run fold: a run of whitespace or zero-width characters becomes one space.
    static func folded(_ text: String) -> String {
        let zeroWidth: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"]
        var out = ""
        var inRun = false
        for ch in text {
            let isRun = ch.isWhitespace || ch.unicodeScalars.allSatisfy { zeroWidth.contains($0) }
            if isRun { if !inRun { out.append(" "); inRun = true } } else { out.append(ch); inRun = false }
        }
        return out
    }

    private static func occurrences(of needle: String, in hay: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var from = hay.startIndex
        while let r = hay.range(of: needle, range: from..<hay.endIndex) {
            count += 1; from = r.upperBound
        }
        return count
    }

    @Test("Space-bearing queries on the packet: today's instances and the folded instances")
    func spaceBearingQueriesOnThePacket() async throws {
        let bank = try Self.loadBank()
        let doc = try Self.loadPacket()
        let options = SearchOptions()
        var targets: [(String, String)] = []
        for q in bank.queries {
            if q.mode == "text", let s = q.query, s.contains(" ") { targets.append((q.qid, s)) }
            if q.mode == "multiTerm", let terms = q.terms { for t in terms where t.contains(" ") { targets.append((q.qid, t)) } }
        }
        print("[WS-CENSUS] packet · \(doc.pageCount) pages · \(targets.count) space-bearing query strings")
        for (qid, query) in targets {
            let searcher = DocumentSearcher()
            let stream = searcher.search(SendablePDFDocument(doc), mode: .text(query, options: options), progress: { _, _ in })
            var today = 0
            for await _ in stream { today += 1 }
            let foldedQuery = Self.folded(SearchCore.normalizedText(query, options: options))
            var foldedCount = 0
            var contexts: [String] = []
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i), let text = page.string else { continue }
                let normalized = SearchCore.normalizedText(text, options: options)
                let foldedText = Self.folded(normalized)
                let n = Self.occurrences(of: foldedQuery, in: foldedText)
                foldedCount += n
                let plain = Self.occurrences(of: SearchCore.normalizedText(query, options: options), in: normalized)
                if n != plain {
                    // Name the raw context of each folded-only instance.
                    var from = foldedText.startIndex
                    while let r = foldedText.range(of: foldedQuery, range: from..<foldedText.endIndex) {
                        let lo = foldedText.index(r.lowerBound, offsetBy: -20, limitedBy: foldedText.startIndex) ?? foldedText.startIndex
                        let hi = foldedText.index(r.upperBound, offsetBy: 20, limitedBy: foldedText.endIndex) ?? foldedText.endIndex
                        contexts.append("p\(i + 1): …\(Self.named(String(foldedText[lo..<hi])))…")
                        from = r.upperBound
                    }
                }
            }
            print("[WS-CENSUS] \(qid) · packet · today=\(today) · folded=\(foldedCount)\(today == foldedCount ? "" : " · DIFFERS: " + contexts.joined(separator: " | "))")
        }
    }

    // MARK: - (iii) regex matches that span a line break

    @Test("Regex queries whose matches span a line break in the packet's text")
    func regexMatchesSpanningLineBreaks() throws {
        let bank = try Self.loadBank()
        let doc = try Self.loadPacket()
        for q in bank.queries where q.mode == "regex" {
            guard let pattern = q.pattern, let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            var total = 0, spanning = 0
            for i in 0..<doc.pageCount {
                guard let text = doc.page(at: i)?.string else { continue }
                let ns = text as NSString
                for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    total += 1
                    if ns.substring(with: m.range).contains(where: \.isNewline) { spanning += 1 }
                }
            }
            print("[WS-CENSUS] \(q.qid) · packet · regex matches=\(total) · spanning a line break=\(spanning)")
        }
        print("[WS-CENSUS] scan-sim: not run on the host (Vision); the OCR literal path matches per observation and the OCR regex path joins observations with a line feed — see the notes")
    }
}
