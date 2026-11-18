import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// A check that stops at an issue before it has read everything says where it
// stopped: Terms in Text & Bytes, Text & Annotations, Active Content &
// Structure and Document Metadata each give their row the place they stopped
// at, and leave it nil where nothing was left unread. One table of
// seventeen made files, each run through the engine's own check; the
// results screen's table (the app's `CheckStopLineTests`) holds the same
// seventeen rows and the line each shows.

@Suite("A check that stops early says where it stopped")
struct CheckStopTests {

    // MARK: - Made files

    static let term = "Quillfeather"

    /// One page of a made file: its content stream, extra entries for its
    /// page dictionary, and an optional JPEG drawn as `/Im0`.
    struct Page {
        var content = ""
        var entries = ""
        var jpeg: Data? = nil
    }

    /// A file built by hand: Helvetica as `/F1`, the pages, extra catalog
    /// entries, extra objects (numbered 100 and up), an /Info body, extra
    /// trailer entries, and text appended after the end marker.
    static func pdf(_ pages: [Page], catalog: String = "", objects: [Int: String] = [:],
                    info: String? = nil, trailer: String = "", tail: String = "") -> Data {
        var parts: [Int: Data] = [
            1: Data("<< /Type /Catalog /Pages 2 0 R \(catalog) >>".utf8),
            3: Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".utf8),
        ]
        var kids: [String] = []
        for (i, page) in pages.enumerated() {
            let id = 10 + 3 * i
            kids.append("\(id) 0 R")
            let image = page.jpeg == nil ? "" : " /XObject << /Im0 \(id + 2) 0 R >>"
            parts[id] = Data(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(id + 1) 0 R "
                + "/Resources << /Font << /F1 3 0 R >>\(image) >> \(page.entries) >>").utf8)
            parts[id + 1] = Data("<< /Length \(page.content.utf8.count) >>\nstream\n\(page.content)\nendstream".utf8)
            if let jpeg = page.jpeg {
                var stream = Data(("<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 "
                    + "/ColorSpace /DeviceRGB /Filter /DCTDecode /Length \(jpeg.count) >>\nstream\n").utf8)
                stream.append(jpeg)
                stream.append(Data("\nendstream".utf8))
                parts[id + 2] = stream
            }
        }
        parts[2] = Data("<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count \(kids.count) >>".utf8)
        for (id, body) in objects { parts[id] = Data(body.utf8) }
        if let info { parts[4] = Data("<< \(info) >>".utf8) }
        let size = (parts.keys.max() ?? 0) + 1
        var out = Data("%PDF-1.4\n".utf8)
        var offsets = [Int](repeating: -1, count: size)
        for n in parts.keys.sorted() {
            offsets[n] = out.count
            out.append(Data("\(n) 0 obj\n".utf8))
            out.append(parts[n] ?? Data())
            out.append(Data("\nendobj\n".utf8))
        }
        let xref = out.count
        var table = "xref\n0 \(size)\n0000000000 65535 f \n"
        for n in 1..<size { table += offsets[n] < 0 ? "0000000000 65535 f \n" : String(format: "%010d 00000 n \n", offsets[n]) }
        table += "trailer\n<< /Size \(size) /Root 1 0 R\(info == nil ? "" : " /Info 4 0 R") \(trailer) >>\nstartxref\n\(xref)\n%%EOF\n"
        out.append(Data(table.utf8))
        out.append(Data(tail.utf8))
        return out
    }

    /// A JPEG byte stream whose APP1/EXIF segment carries `text` (not a
    /// decodable picture; the EXIF pass reads its bytes only).
    static func exifJPEG(_ text: String) -> Data {
        let payload = [UInt8]("Exif\0\0".utf8) + [UInt8](text.utf8)
        var jpeg = Data([0xFF, 0xD8, 0xFF, 0xE1, UInt8(((payload.count + 2) >> 8) & 0xFF), UInt8((payload.count + 2) & 0xFF)])
        jpeg.append(contentsOf: payload)
        jpeg.append(contentsOf: [0xFF, 0xD9])
        return jpeg
    }

    /// An output that opens without a password but is encrypted.
    static func encrypted() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box,
                            [kCGPDFContextOwnerPassword: "owner"] as CFDictionary)!
        ctx.beginPDFPage(nil)
        ctx.fill(CGRect(x: 72, y: 72, width: 100, height: 20))
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    static func blank(_ n: Int) -> [Page] { Array(repeating: Page(), count: n) }
    static let text = Page(content: "BT /F1 24 Tf 72 700 Td (\(term) Ostrander) Tj ET")
    static var fixedProducer: String { PDFStreamReconstructor.fixedProducerValue }
    static let wrongID = "/ID [<00112233445566778899AABBCCDDEEFF> <00112233445566778899AABBCCDDEEFF>]"

    // MARK: - The table

    struct Case: Sendable, CustomTestStringConvertible {
        let id: String
        let layer: VerificationLayer
        let mode: PipelineMode
        let terms: [String]
        let data: @Sendable () -> Data
        /// The status's case name and the start of its message.
        let status: String
        let message: String
        let pages: [Int]?
        let stopped: CheckStop?
        var testDescription: String { id }
    }

    static let cases: [Case] = [
        Case(id: "S-1", layer: .binaryStringSearch, mode: .secureRasterization, terms: [term],
             data: { pdf(blank(1), info: "/Keywords (\(term))") },
             status: "fail", message: "Sensitive string found in output PDF structural data", pages: nil,
             stopped: .imageEXIFNotSearched),
        Case(id: "S-2", layer: .binaryStringSearch, mode: .secureRasterization, terms: [term],
             data: { pdf([text]) },
             status: "attention", message: "Text matching your redactions is still readable on page 1", pages: [0],
             stopped: .imageEXIFNotSearched),
        Case(id: "S-3", layer: .binaryStringSearch, mode: .secureRasterization, terms: [term],
             data: { pdf(blank(1), info: "/X (\(term)Z)") },
             status: "warn", message: "Possible sensitive term fragment in output PDF structural data", pages: nil,
             stopped: .imageEXIFNotSearched),
        Case(id: "S-4", layer: .binaryStringSearch, mode: .secureRasterization, terms: [term],
             data: { var p = blank(5); p[2].jpeg = exifJPEG("Owner \(term) Ostrander"); return pdf(p) },
             status: "warn", message: "Sensitive term found in embedded JPEG EXIF metadata on page 3", pages: [2],
             stopped: .exifSearchStopped(page: 2)),
        Case(id: "S-5", layer: .binaryStringSearch, mode: .secureRasterization, terms: [term],
             data: { var p = blank(5); p[4].jpeg = exifJPEG("Owner \(term) Ostrander"); return pdf(p) },
             status: "warn", message: "Sensitive term found in embedded JPEG EXIF metadata on page 5", pages: [4],
             stopped: .exifSearchStopped(page: 4)),
        Case(id: "S-6", layer: .textExtraction, mode: .secureRasterization, terms: [],
             data: { pdf([text]) },
             status: "fail", message: "Selectable text found on page 1", pages: [0],
             stopped: .bookmarksAndFormFieldsNotRead),
        Case(id: "S-7", layer: .textExtraction, mode: .secureRasterization, terms: [],
             data: { pdf(blank(1), catalog: "/Outlines 100 0 R /AcroForm << /Fields [] >>",
                         objects: [100: "<< /Type /Outlines /First 101 0 R /Last 101 0 R /Count 1 >>",
                                   101: "<< /Title (One) /Parent 100 0 R /Dest [10 0 R /Fit] >>"]) },
             status: "fail", message: "Bookmarks found in output", pages: nil,
             stopped: .formFieldsNotRead),
        Case(id: "S-8", layer: .textExtraction, mode: .secureRasterization, terms: [],
             data: { pdf(blank(1), catalog: "/AcroForm << /Fields [] >>") },
             status: "fail", message: "Form fields found in output", pages: nil,
             stopped: nil),
        Case(id: "S-9", layer: .structureCheck, mode: .secureRasterization, terms: [],
             data: { encrypted() },
             status: "fail", message: "Encrypt found in document", pages: nil,
             stopped: .stoppedAtThisFind),
        Case(id: "S-10", layer: .structureCheck, mode: .secureRasterization, terms: [],
             data: { pdf(blank(1), catalog: "/OpenAction [10 0 R /Fit] /Names << /EmbeddedFiles << /Names [] >> >>") },
             status: "fail", message: "OpenAction found in document catalog", pages: nil,
             stopped: .stoppedAtThisFind),
        Case(id: "S-11", layer: .structureCheck, mode: .secureRasterization, terms: [],
             data: { var p = blank(2); p[1].entries = "/AA << /O << /S /JavaScript /JS (app.alert(1)) >> >>"
                     return pdf(p, tail: "%%EOF\n") },
             status: "fail", message: "Per-page /AA (automatic action) found on", pages: [1],
             stopped: .stoppedAtThisFind),
        Case(id: "S-12", layer: .structureCheck, mode: .secureRasterization, terms: [],
             data: { pdf(blank(1), tail: "%%EOF\n") },
             status: "fail", message: "Multiple %%EOF markers (2)", pages: nil,
             stopped: nil),
        Case(id: "S-13", layer: .metadataCheck, mode: .secureRasterization, terms: [],
             data: { pdf(blank(1), info: "/Title (Made) /Author (Made)") },
             status: "fail", message: "Metadata key /Title present", pages: nil,
             stopped: .stoppedAtThisFind),
        Case(id: "S-14", layer: .metadataCheck, mode: .secureRasterization, terms: [],
             data: { pdf(blank(1), info: "/Department (Made) /Producer (Another Writer)") },
             status: "fail", message: "Non-standard /Info key(s): Department", pages: nil,
             stopped: .stoppedAtThisFind),
        Case(id: "S-15", layer: .metadataCheck, mode: .secureRasterization, terms: [],
             data: { pdf(blank(1), info: "/Producer (Another Writer)", trailer: wrongID) },
             status: "warn", message: "Producer or timestamp fields were not rewritten to the fixed values", pages: nil,
             stopped: .stoppedAtThisFind),
        Case(id: "S-16", layer: .metadataCheck, mode: .secureRasterization, terms: [],
             data: { pdf(blank(1), info: "/Producer (\(fixedProducer))", trailer: wrongID) },
             status: "warn", message: "File identifier was not derived from the file contents", pages: nil,
             stopped: nil),
        Case(id: "S-17", layer: .operatorReExtraction, mode: .searchableRedaction, terms: [term],
             data: { var p = blank(5); p[2] = text; return pdf(p) },
             status: "attention", message: "", pages: [2],
             stopped: nil),
    ]

    // MARK: - Running a case

    static func statusName(_ s: VerificationStatus) -> (String, String) {
        switch s {
        case .pass: ("pass", "")
        case .skipped: ("skipped", "")
        case .warn(let m): ("warn", m)
        case .info(let m): ("info", m)
        case .attention(let m): ("attention", m)
        case .fail(let m): ("fail", m)
        case .notApplicable(let m): ("not_applicable", m)
        }
    }

    static func run(_ c: Case) async throws -> LayerResult {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("checkstop_\(UUID().uuidString).pdf")
        try c.data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try #require(PDFDocument(url: url), "\(c.id): the made file must open")
        let n = doc.pageCount
        return await VerificationEngine().runLayer(
            c.layer, outputDocument: SendablePDFDocument(doc), sourcePageCount: n, regions: [:],
            sensitiveTerms: c.terms.map { SensitiveTerm(text: $0) }, pipelineMode: c.mode,
            filterDigests: Array(repeating: nil, count: n), perPageModes: Array(repeating: c.mode, count: n))
    }

    @Test("The table holds seventeen cases")
    func tableLength() {
        #expect(Self.cases.count == 17)
        #expect(Set(Self.cases.map(\.id)).count == 17)
    }

    @Test("Each check's own row: its status, its pages, and where it stopped", arguments: Self.cases)
    func row(_ c: Case) async throws {
        let layer = try await Self.run(c)
        let (name, message) = Self.statusName(layer.status)
        #expect(name == c.status, "\(c.id): \(layer.status)")
        #expect(message.hasPrefix(c.message), "\(c.id): \(message)")
        #expect(layer.pageReferences == c.pages, "\(c.id): pages \(String(describing: layer.pageReferences))")
        #expect(layer.stopped == c.stopped, "\(c.id): stopped \(String(describing: layer.stopped))")
        print("CHECKSTOP \(c.id) \(name) stopped=\(String(describing: layer.stopped)) \(message)")
    }
}
