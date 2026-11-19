import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// The documents the case table builds, and the helpers that run a check
// and read its row.

extension CouldNotReadRowTests {
    // MARK: - Documents

    /// A document whose listed pages cannot be opened (`page(at:)` is nil)
    /// while `pageCount` still counts them: the per-page loops' unread arm.
    final class UnopenablePagesDocument: PDFDocument {
        nonisolated(unsafe) var unopenable: Set<Int> = []
        override func page(at index: Int) -> PDFPage? {
            unopenable.contains(index) ? nil : super.page(at: index)
        }
    }

    /// A page whose text read returns nothing, or the empty string.
    final class TextReadPage: PDFPage {
        nonisolated(unsafe) var empty = false
        override var string: String? { empty ? "" : nil }
    }

    /// One page of a hand-built file: its content stream, any entries added
    /// to its dictionary, whether it has resources, and an optional picture
    /// (raw JPEG bytes, drawn through `/Im0`).
    struct RawPage {
        var content = ""
        var extras = ""
        var resources = true
        var jpeg: Data? = nil
        /// Helvetica as `/F1` in the page's resources.
        var font = true
    }

    /// A hand-built file: its pages (each in Helvetica as `/F1` unless it
    /// says not), entries
    /// added to the catalogue, an /Info body, and, when `badKid`, one more
    /// kid in the page tree that is not a page dictionary, counted in
    /// `/Count`.
    static func rawPDF(_ pages: [RawPage], catalogExtras: String = "", info: String? = nil,
                       badKid: Bool = false, endMarker: Bool = true) -> Data {
        var objects: [Int: Data] = [:]
        let firstPage = 10
        var kids = pages.indices.map { "\(firstPage + 3 * $0) 0 R" }
        if badKid { kids.append("7 0 R") }
        objects[1] = Data("<< /Type /Catalog /Pages 2 0 R \(catalogExtras) >>".utf8)
        objects[2] = Data("<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count \(kids.count) >>".utf8)
        objects[5] = Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".utf8)
        if let info { objects[6] = Data("<< \(info) >>".utf8) }
        if badKid { objects[7] = Data("(not a page)".utf8) }
        objects[8] = Data("<< >>".utf8)
        for (i, page) in pages.enumerated() {
            let id = firstPage + 3 * i
            var resources = page.font ? "/Font << /F1 5 0 R >>" : ""
            if page.jpeg != nil { resources += " /XObject << /Im0 \(id + 2) 0 R >>" }
            let res = page.resources ? " /Resources << \(resources) >>" : ""
            objects[id] = Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(id + 1) 0 R\(res) \(page.extras) >>".utf8)
            let body = Data(page.content.utf8)
            var stream = Data("<< /Length \(body.count) >>\nstream\n".utf8); stream.append(body); stream.append(Data("\nendstream".utf8))
            objects[id + 1] = stream
            if let jpeg = page.jpeg {
                var image = Data("<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceRGB /Filter /DCTDecode /Length \(jpeg.count) >>\nstream\n".utf8)
                image.append(jpeg); image.append(Data("\nendstream".utf8))
                objects[id + 2] = image
            }
        }
        let size = (objects.keys.max() ?? 0) + 1
        var out = Data("%PDF-1.4\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offsets = [Int](repeating: -1, count: size)
        for number in objects.keys.sorted() {
            offsets[number] = out.count
            out.append(Data("\(number) 0 obj\n".utf8)); out.append(objects[number]!); out.append(Data("\nendobj\n".utf8))
        }
        let xref = out.count
        out.append(Data("xref\n0 \(size)\n0000000000 65535 f \n".utf8))
        for number in 1..<size {
            out.append(Data((offsets[number] < 0 ? "0000000000 65535 f \n" : String(format: "%010d 00000 n \n", offsets[number])).utf8))
        }
        let infoRef = info == nil ? "" : " /Info 6 0 R"
        out.append(Data("trailer\n<< /Size \(size) /Root 1 0 R\(infoRef) >>\nstartxref\n\(xref)\n\(endMarker ? "%%EOF" : "     ")\n".utf8))
        return out
    }

    static func text(_ s: String, size: Int = 24) -> String { "BT /F1 \(size) Tf 72 700 Td (\(s)) Tj ET" }

    /// `data` written to a file and opened from it, with `unopenable` pages.
    static func open(_ data: Data, unopenable: Set<Int> = []) throws -> UnopenablePagesDocument {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cnr_\(UUID().uuidString).pdf")
        try data.write(to: url)
        let doc = try #require(UnopenablePagesDocument(url: url))
        doc.unopenable = unopenable
        return doc
    }

    static func remove(_ doc: PDFDocument) { if let url = doc.documentURL { try? FileManager.default.removeItem(at: url) } }

    /// The first of a few byte strings the string decoder returns nothing
    /// for, written as a hex string; the case's precondition.
    /// The bytes of a string the check is made to read as not decoding.
    /// No hand-built file makes the system's decoder return nothing on the
    /// host (tried: a lone UTF-16 mark, UTF-16 with an odd byte count or an
    /// unpaired surrogate, the UTF-8 mark before bytes that are not UTF-8,
    /// single bytes PDFDocEncoding leaves undefined: each decodes), so the
    /// case binds a decode that returns nothing for these bytes, and the real
    /// one for every other string.
    static let unreadHex = "DEADBEEF"

    static func whereUnreadHexDoesNotDecode<T>(_ body: () async throws -> T) async rethrows -> T {
        let marker = Data([0xDE, 0xAD, 0xBE, 0xEF])
        return try await PDFStringDecode.$decode.withValue({ ref in
            guard let bytes = CGPDFStringGetBytePtr(ref) else { return CGPDFStringCopyTextString(ref) as String? }
            if Data(bytes: bytes, count: CGPDFStringGetLength(ref)) == marker { return nil }
            return CGPDFStringCopyTextString(ref) as String?
        }, operation: body)
    }

    // MARK: - Running a check

    static func run(
        _ layer: VerificationLayer, _ doc: PDFDocument, mode: PipelineMode = .searchableRedaction,
        modes: [PipelineMode]? = nil, digests: [PageFilterDigest?]? = nil, terms: [String] = [],
        regions: [Int: [RedactionRegion]] = [:], searches: [SearchRecheckRequest] = [],
        source: PDFDocument? = nil
    ) async -> LayerResult {
        let n = doc.pageCount
        return await VerificationEngine().runLayer(
            layer, outputDocument: SendablePDFDocument(doc), sourcePageCount: n, regions: regions,
            sensitiveTerms: terms.map { SensitiveTerm(text: $0) }, pipelineMode: mode,
            filterDigests: digests ?? Array(repeating: nil, count: n),
            perPageModes: modes ?? Array(repeating: mode, count: n),
            appliedSearches: searches, sourceDocument: SendablePDFDocument(source ?? doc))
    }

    static func message(_ status: VerificationStatus) -> String {
        switch status {
        case .warn(let m), .info(let m), .attention(let m), .fail(let m), .notApplicable(let m): m
        case .pass, .skipped: ""
        }
    }

    /// A row built from a fold's own values, as `runLayer` builds it.
    static func row(_ status: VerificationStatus, pages: [Int]?, couldNotVerify: Bool,
                    part: String? = nil, partPages: [Int]? = nil, terms: [String]? = nil) -> LayerResult {
        LayerResult(name: "check", symbolName: "s", status: status, shortDescription: message(status),
                    detailDescription: "", pageReferences: pages, durationSeconds: 0, reviewTermTexts: terms,
                    couldNotVerify: couldNotVerify, couldNotVerifyPart: part, couldNotVerifyPartPages: partPages)
    }

    /// A row folded beside rows that all passed must not read Passed.
    static func expectNotPassed(_ r: LayerResult, sourceLocation: SourceLocation = #_sourceLocation) {
        let report = [LayerResult.mock(status: .pass), r, LayerResult.mock(status: .pass)]
        #expect(VerificationEngine().aggregateStatus(report) != .pass, "\(r.status)", sourceLocation: sourceLocation)
    }

    /// The row is a warning with exactly `sentence`, the mark as given, and
    /// exactly `pages`.
    static func expectWarn(_ r: LayerResult, _ sentence: String, mark: Bool, pages: [Int]?,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(r.status.isWarn, "a warning; got \(r.status)", sourceLocation: sourceLocation)
        #expect(message(r.status) == sentence, "got \(message(r.status))", sourceLocation: sourceLocation)
        #expect(r.couldNotVerify == mark, "the mark", sourceLocation: sourceLocation)
        #expect(r.pageReferences == pages, "the pages; got \(String(describing: r.pageReferences))", sourceLocation: sourceLocation)
        #expect(r.couldNotVerifyPart == nil, "no part on a row with no issue", sourceLocation: sourceLocation)
        expectNotPassed(r, sourceLocation: sourceLocation)
    }

    /// The issue is the one `base` reports with nothing unread, and the part
    /// is exactly `part` over exactly `partPages`.
    static func expectFindKept(_ r: LayerResult, as base: LayerResult, part: String, partPages: [Int],
                               sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(r.status.isFail || r.status.isAttention, "an issue; got \(r.status)", sourceLocation: sourceLocation)
        #expect(r.status == base.status && message(r.status) == message(base.status),
                "the issue as with nothing unread; got \(r.status), base \(base.status)", sourceLocation: sourceLocation)
        #expect(r.pageReferences == base.pageReferences, "the issue's pages", sourceLocation: sourceLocation)
        #expect(r.reviewTermTexts == base.reviewTermTexts, "the issue's terms", sourceLocation: sourceLocation)
        #expect(base.couldNotVerifyPart == nil, "the base has no part", sourceLocation: sourceLocation)
        #expect(r.couldNotVerifyPart == part, "the part; got \(String(describing: r.couldNotVerifyPart))", sourceLocation: sourceLocation)
        #expect(r.couldNotVerifyPartPages == partPages, "the part's pages; got \(String(describing: r.couldNotVerifyPartPages))",
                sourceLocation: sourceLocation)
        #expect(!r.couldNotVerify, "the mark stays on warnings only", sourceLocation: sourceLocation)
        expectNotPassed(r, sourceLocation: sourceLocation)
    }

    static let fragment = "Possible sensitive term fragment in output PDF structural data (1 match(es))"
    static func exif(page: Int) -> String { "Sensitive term found in embedded JPEG EXIF metadata on page \(page)" }
    static let short = "1 term too short to check"
    static func unread(_ page: Int) -> String { "Page \(page) could not be read for this check" }
    static let notCrossChecked = "Cross-checked 1 of 2 pages — remaining pages lacked rasterization data"

    /// A box over the left fifth of `page`'s first character: the glyph box
    /// crosses the box's edge while its centre stays outside (an edge graze).
    static func grazeRegion(on page: PDFPage) throws -> RedactionRegion {
        let bounds = try #require(page.selection(for: NSRange(location: 0, length: 1))).bounds(for: page)
        try #require(bounds.width > 0 && bounds.height > 0)
        let p = page.bounds(for: .cropBox)
        let r = CGRect(x: bounds.minX - 10, y: bounds.minY, width: 10 + bounds.width * 0.2, height: bounds.height)
        return RedactionRegion(id: UUID(), normalizedRect: CGRect(x: r.minX / p.width, y: r.minY / p.height,
                                                                  width: r.width / p.width, height: r.height / p.height),
                               source: .manual)
    }

    /// A box well over the first `count` characters of `page`.
    static func coverRegion(on page: PDFPage, count: Int) throws -> RedactionRegion {
        let bounds = try #require(page.selection(for: NSRange(location: 0, length: count))).bounds(for: page).insetBy(dx: -4, dy: -4)
        let p = page.bounds(for: .cropBox)
        return RedactionRegion(id: UUID(), normalizedRect: CGRect(x: bounds.minX / p.width, y: bounds.minY / p.height,
                                                                  width: bounds.width / p.width, height: bounds.height / p.height),
                               source: .manual)
    }
}
