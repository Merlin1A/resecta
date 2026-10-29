import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The hyphen and page-seam census: a measurement harness, env-gated
// (RESECTA_HYPHEN_CENSUS=1), never in the batched gate. It prints the facts
// the hyphen-break fold and the page seam are shaped on: (i) what PDFKit's
// `page.string` emits around a hyphen at a line end and around a soft hyphen
// (U+00AD), on the fixture library's files and on raw Courier pages built
// here; (ii) the first and last non-empty lines of each page of the
// page-break fixture (the running header the seam must skip); (iii) on the
// bundled packet, the count of hard-hyphen line breaks between word
// characters and of U+00AD scalars per page. The per-cell instance counts
// come from the search ground-truth runner, run before and after the change.
//
// Reads the fixture library (RESECTA_FIXTURES, default
// ~/Documents/resecta-131-fixtures) read-only, by absolute path.

@Suite("Hyphen and page-seam census probe (env-gated)",
       .enabled(if: ProcessInfo.processInfo.environment["RESECTA_HYPHEN_CENSUS"] != nil))
struct HyphenSeamCensusProbeTests {

    static let fixtures: String =
        ProcessInfo.processInfo.environment["RESECTA_FIXTURES"]
        ?? (NSHomeDirectory() + "/Documents/resecta-131-fixtures/made")

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

    /// Letters and digits as themselves, every other scalar named.
    private static func named(_ text: String) -> String {
        text.unicodeScalars.map { scalar -> String in
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil { return String(scalar) }
            if scalar == " " { return "·" }
            return String(format: "<U+%04X>", scalar.value)
        }.joined()
    }

    private static let hardHyphens: Set<Unicode.Scalar> = ["-", "\u{2010}", "\u{2011}"]

    /// Every hard hyphen followed by a run holding a line break, and every
    /// U+00AD, with ±12 scalars of context.
    private static func sites(_ text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        var out: [String] = []
        func context(_ i: Int) -> String {
            let lo = max(0, i - 12), hi = min(scalars.count, i + 13)
            return named(String(String.UnicodeScalarView(scalars[lo..<hi])))
        }
        for (i, s) in scalars.enumerated() {
            if s == "\u{00AD}" { out.append("U+00AD at \(i): …\(context(i))…"); continue }
            guard hardHyphens.contains(s) else { continue }
            var j = i + 1
            var sawBreak = false
            while j < scalars.count, scalars[j].properties.isWhitespace {
                if Character(scalars[j]).isNewline { sawBreak = true }
                j += 1
            }
            if sawBreak { out.append("hyphen-break at \(i): …\(context(i))…") }
        }
        return out
    }

    // MARK: - (i) page.string around the breaks

    @Test("What page.string emits around a line-end hyphen and a soft hyphen")
    func hyphenBreakFacts() throws {
        let files = [
            "FX-02-layout-pages.pdf", "FX-02-hardhyphen-quartz.pdf", "FX-02-hardhyphen-text.pdf",
            "FX-02-softhyphen-text.pdf", "FX-02-wordbreak-text.pdf", "FX-06-court-filing.pdf",
        ]
        for file in files {
            guard let doc = PDFDocument(url: URL(fileURLWithPath: Self.fixtures + "/" + file)) else {
                print("[HY-CENSUS] \(file) · unreadable"); continue
            }
            for i in 0..<doc.pageCount {
                let text = doc.page(at: i)?.string ?? ""
                let found = Self.sites(text)
                print("[HY-CENSUS] \(file) p\(i + 1) · sites=\(found.count)")
                for site in found { print("[HY-CENSUS]   \(site)") }
                if file.contains("softhyphen") {
                    for line in text.components(separatedBy: .newlines) where line.lowercased().contains("johan") || line.lowercased().contains("son") {
                        print("[HY-CENSUS]   line: \(Self.named(line))")
                    }
                }
            }
        }
        let built: [(String, String)] = [
            ("the RED page: 'Signed by Marisol Vance-' / 'Oduya on the date below.'",
             "BT /F1 12 Tf 72 700 Td (Signed by Marisol Vance-) Tj ET\nBT /F1 12 Tf 72 686 Td (Oduya on the date below.) Tj ET"),
            ("a WinAnsi soft hyphen (octal 255) at a line end",
             "BT /F1 12 Tf 72 700 Td (Witness Johan\\255) Tj ET\nBT /F1 12 Tf 72 686 Td (son attended.) Tj ET"),
            ("a WinAnsi soft hyphen inside a word",
             "BT /F1 12 Tf 72 700 Td (Witness Jo\\255hanson attended.) Tj ET"),
            ("a space after the line-end hyphen",
             "BT /F1 12 Tf 72 700 Td (Signed by Marisol Vance- ) Tj ET\nBT /F1 12 Tf 72 686 Td (Oduya on the date below.) Tj ET"),
        ]
        for (name, stream) in built {
            let doc = try #require(PDFDocument(data: Self.courierPage(stream)))
            print("[HY-CENSUS] built · \(name) · page.string=\(Self.named(doc.page(at: 0)?.string ?? "<nil>"))")
        }
    }

    // MARK: - (ii) the page-break fixture's edge lines

    @Test("The page-break fixture: the first and last non-empty lines of each page")
    func pageEdgeLines() throws {
        for file in ["FX-03-pagebreak-text.pdf"] {
            guard let doc = PDFDocument(url: URL(fileURLWithPath: Self.fixtures + "/" + file)) else {
                print("[HY-CENSUS] \(file) · unreadable"); continue
            }
            for i in 0..<doc.pageCount {
                let lines = (doc.page(at: i)?.string ?? "").components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                print("[HY-CENSUS] \(file) p\(i + 1) · lines=\(lines.count)")
                print("[HY-CENSUS]   first: \(lines.prefix(3).map(Self.named))")
                print("[HY-CENSUS]   last:  \(lines.suffix(3).map(Self.named))")
            }
        }
    }

    // MARK: - (iii) the packet's sites

    @Test("The bundled packet: hard-hyphen line breaks and soft hyphens per page")
    func packetSites() throws {
        let url = try #require(Bundle.module.url(forResource: "packet", withExtension: "pdf", subdirectory: "TestResources"))
        let doc = try #require(PDFDocument(url: url))
        var total = 0
        for i in 0..<doc.pageCount {
            let found = Self.sites(doc.page(at: i)?.string ?? "")
            total += found.count
            for site in found { print("[HY-CENSUS] packet p\(i + 1) · \(site)") }
        }
        print("[HY-CENSUS] packet · \(doc.pageCount) pages · hyphen-break + U+00AD sites=\(total)")
    }
}
