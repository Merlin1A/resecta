import Testing
import Foundation
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// A row whose check reported an issue and also could not read part of its
// input, and a row that could not verify: the caption under the title, and
// the Share sheet's lines. The two Share-line cases of a could-not-verify
// row run the engine on a hand-built file and read its own row; the others
// hold a row built as the engine's case table pins it.

@Suite("A row's could-not-read part on the results screen and the Share sheet")
struct VerificationRowPartTests {

    static let nbsp = "\u{00A0}"
    static let unread2 = "Page 2 could not be read for this check"

    static func row(_ status: VerificationStatus, _ identity: VerificationLayer, pages: [Int]?,
                    terms: [String]? = nil, lines: [SearchRecheckQueryLine]? = nil, couldNotVerify: Bool = false,
                    part: String? = nil, partPages: [Int]? = nil) -> LayerResult {
        let sentence: String = switch status {
        case .warn(let m), .info(let m), .attention(let m), .fail(let m), .notApplicable(let m): m
        case .pass, .skipped: ""
        }
        return LayerResult(name: identity.rawValue, symbolName: "doc", status: status, shortDescription: sentence,
                           detailDescription: sentence, pageReferences: pages, durationSeconds: 0,
                           reviewTermTexts: terms, layer: identity, queryLines: lines, couldNotVerify: couldNotVerify,
                           couldNotVerifyPart: part, couldNotVerifyPartPages: part == nil ? nil : (partPages ?? []))
    }

    static func report(_ layers: [LayerResult]) -> VerificationReport {
        VerificationReport(layers: layers, overallStatus: .fail("x"), durationSeconds: 0)
    }

    static func caption(_ layer: LayerResult) -> String? {
        VerificationRowModel.caption(for: layer, outcome: VerificationRowModel.outcome(for: layer, perPageModes: []))
    }

    // MARK: - The two cases beside the engine table: real engine rows

    /// A document whose listed pages cannot be opened (`page(at:)` is nil).
    nonisolated final class UnopenablePagesDocument: PDFDocument {
        nonisolated(unsafe) var unopenable: Set<Int> = []
        override func page(at index: Int) -> PDFPage? {
            unopenable.contains(index) ? nil : super.page(at: index)
        }
    }

    /// A hand-built file: one page per content stream, in Helvetica as
    /// `/F1`, and an /Info body.
    static func rawPDF(_ contents: [String], info: String? = nil) -> Data {
        var objects: [Int: String] = [1: "<< /Type /Catalog /Pages 2 0 R >>",
                                      3: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"]
        var kids: [String] = []
        for (i, content) in contents.enumerated() {
            let id = 10 + 2 * i
            kids.append("\(id) 0 R")
            objects[id] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(id + 1) 0 R /Resources << /Font << /F1 3 0 R >> >> >>"
            objects[id + 1] = "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        }
        objects[2] = "<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count \(kids.count) >>"
        if let info { objects[4] = "<< \(info) >>" }
        let size = (objects.keys.max() ?? 0) + 1
        var out = "%PDF-1.4\n"
        var offsets = [Int](repeating: -1, count: size)
        for n in objects.keys.sorted() {
            offsets[n] = out.utf8.count
            out += "\(n) 0 obj\n\(objects[n] ?? "")\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(size)\n0000000000 65535 f \n"
        for n in 1..<size { out += offsets[n] < 0 ? "0000000000 65535 f \n" : String(format: "%010d 00000 n \n", offsets[n]) }
        out += "trailer\n<< /Size \(size) /Root 1 0 R\(info == nil ? "" : " /Info 4 0 R") >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    /// The file written to a temporary URL and opened from it, as the app
    /// opens the verified document.
    static func open(_ data: Data, unopenable: Set<Int> = []) throws -> UnopenablePagesDocument {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vrp_\(UUID().uuidString).pdf")
        try data.write(to: url)
        let doc = try #require(UnopenablePagesDocument(url: url))
        doc.unopenable = unopenable
        return doc
    }

    static func remove(_ doc: PDFDocument) {
        if let url = doc.documentURL { try? FileManager.default.removeItem(at: url) }
    }

    /// The engine's own row for `layer` on `doc`, every page in `mode`.
    static func engineRow(_ layer: VerificationLayer, _ doc: PDFDocument, mode: PipelineMode,
                          terms: [String] = [], regions: [Int: [RedactionRegion]] = [:]) async -> LayerResult {
        let n = doc.pageCount
        return await VerificationEngine().runLayer(
            layer, outputDocument: SendablePDFDocument(doc), sourcePageCount: n, regions: regions,
            sensitiveTerms: terms.map { SensitiveTerm(text: $0) }, pipelineMode: mode,
            filterDigests: Array(repeating: nil, count: n), perPageModes: Array(repeating: mode, count: n),
            appliedSearches: [], sourceDocument: SendablePDFDocument(doc))
    }

    /// A box over the left edge of the page's first character: an edge graze.
    static func grazeRegion(on page: PDFPage) throws -> RedactionRegion {
        let bounds = try #require(page.selection(for: NSRange(location: 0, length: 1))).bounds(for: page)
        try #require(bounds.width > 0 && bounds.height > 0)
        let p = page.bounds(for: .cropBox)
        let r = CGRect(x: bounds.minX - 10, y: bounds.minY, width: 10 + bounds.width * 0.2, height: bounds.height)
        return RedactionRegion(id: UUID(), normalizedRect: CGRect(x: r.minX / p.width, y: r.minY / p.height,
                                                                  width: r.width / p.width, height: r.height / p.height),
                               source: .manual)
    }

    @Test("Character Positions' own row for a page that did not open beside an edge graze: the Share line names the unopened page and no other")
    func shareLineNamesTheUnopenedPage() async throws {
        let data = Self.rawPDF(["BT /F1 24 Tf 72 700 Td (SECRET CONTENT) Tj ET", ""])
        let doc = try Self.open(data, unopenable: [1]), whole = try Self.open(data)
        defer { Self.remove(doc); Self.remove(whole) }
        let region = try Self.grazeRegion(on: try #require(whole.page(at: 0)))
        // The fixture really grazes: with every page open, the row is the
        // graze note and the sheet lists nothing.
        let grazed = await Self.engineRow(.spatialVerification, whole, mode: .searchableRedaction, regions: [0: [region]])
        try #require(grazed.status.isWarn && !grazed.couldNotVerify, "the fixture grazes; got \(grazed.status)")
        #expect(DocumentEditorView.couldNotVerifyItemLines(report: Self.report([grazed])).isEmpty)
        let layer = await Self.engineRow(.spatialVerification, doc, mode: .searchableRedaction, regions: [0: [region]])
        #expect(layer.status == .warn("") && layer.shortDescription == Self.unread2, "got \(layer.status)")
        #expect(DocumentEditorView.couldNotVerifyItemLines(report: Self.report([layer]))
                == ["Character Positions: could not verify on\(Self.nbsp)page\(Self.nbsp)2"])
    }

    @Test("Terms in Text & Bytes' own joined row with no page list: the Share line reads could not verify, with no page")
    func shareLineJoinedRowNoPage() async throws {
        let doc = try Self.open(Self.rawPDF([""], info: "/X (CLASSIFIEDZ)"))
        defer { Self.remove(doc) }
        let layer = await Self.engineRow(.binaryStringSearch, doc, mode: .secureRasterization, terms: ["CLASSIFIED", "ab"])
        #expect(layer.shortDescription
                == "1 term too short to check; Possible sensitive term fragment in output PDF structural data (1 match(es))",
                "got \(layer.status)")
        #expect(layer.pageReferences == nil)
        #expect(DocumentEditorView.couldNotVerifyItemLines(report: Self.report([layer]))
                == ["Terms in Text & Bytes: could not verify"])
    }

    // MARK: - The caption

    @Test("a failed row with the part: the engine's sentence, \"; \", the part")
    func failedCaptionCarriesThePart() {
        let layer = Self.row(.fail("Annotations found on page 1"), .textExtraction, pages: [0],
                             part: Self.unread2, partPages: [1])
        let caption = Self.caption(layer)
        #expect(caption == "Annotations found on page 1; Page 2 could not be read for this check")
        #expect(caption?.count == 68)
    }

    @Test("a needs-review term row with the part: the composed sentence, its final stop dropped at the join, then the part")
    func termCaptionCarriesThePart() {
        let layer = Self.row(.attention("Sensitive term found in decoded text on page 1"), .binaryStringSearch, pages: [0],
                             terms: ["Acme"], part: Self.unread2, partPages: [1])
        let caption = Self.caption(layer)
        #expect(caption == "\u{201C}Acme\u{201D} is still readable on\(Self.nbsp)page\(Self.nbsp)1; Page 2 could not be read for this check")
        #expect(caption?.count == 75)
    }

    @Test("a Search Re-check needs-review row with the part: the composed sentence, then the part")
    func recheckCaptionCarriesThePart() {
        let line = SearchRecheckQueryLine(label: "\u{201C}Delia\u{201D}", foundCount: 2, foundHitCap: false,
                                          appliedCount: 1, remainingCount: 1, route: .textLayer)
        let layer = Self.row(.attention("Re-ran 1 search — 1 match remains on page 1, 1 page could not be checked: 2"),
                             .searchRecheck, pages: [0], terms: ["Delia"], lines: [line],
                             part: "1 page could not be checked: 2", partPages: [1])
        #expect(Self.caption(layer)
                == "Your search \u{201C}Delia\u{201D} still has 1 match on\(Self.nbsp)page\(Self.nbsp)1; 1 page could not be checked: 2")
    }

    @Test("a Search Re-check needs-review row whose only matching search is unchecked: the engine's sentence, its clause once")
    func recheckUncheckedRowShowsTheClauseOnce() {
        let line = SearchRecheckQueryLine(label: "\u{201C}Delia\u{201D}", foundCount: 2, foundHitCap: false,
                                          appliedCount: 1, remainingCount: 1, route: .textLayer, unchecked: true)
        let sentence = "Re-ran 1 search \u{2014} 1 match remains on page 1, 1 page could not be checked: 2"
        let layer = Self.row(.attention(sentence), .searchRecheck, pages: [0], terms: ["Delia"], lines: [line],
                             part: "1 page could not be checked: 2", partPages: [1])
        #expect(VerificationRowModel.composesRecheckCaption(layer) == false)
        let caption = Self.caption(layer)
        #expect(caption == sentence)
        #expect(caption?.components(separatedBy: "could not be checked").count == 2)
        let spoken = VerificationRowModel(layer: layer, perPageModes: []).spokenLabel
        #expect(spoken.components(separatedBy: "could not be checked").count == 2)
    }

    @Test("a failed Search Re-check row, a match only partly covered: the engine's sentence, \"; \", the part")
    func recheckFailedRowKeepsThePart() {
        let line = SearchRecheckQueryLine(label: "\u{201C}Delia\u{201D}", foundCount: 2, foundHitCap: false,
                                          appliedCount: 2, remainingCount: 0, route: .textLayer)
        let layer = Self.row(.fail("1 match is only partly covered by its redaction box on page 1"), .searchRecheck,
                             pages: [0], terms: ["Delia"], lines: [line],
                             part: "1 page could not be checked: 2", partPages: [1])
        #expect(Self.caption(layer)
                == "1 match is only partly covered by its redaction box on page 1; 1 page could not be checked: 2")
    }

    @Test("a part that ends in a full stop: the stop stays at the end, and there is none before \"; \"")
    func partKeepsItsFinalStop() {
        // The engine's own sentence, which ends in a full stop: the stop is
        // dropped at the join, and the part keeps its own.
        let issue = VerificationEngine.hiddenWordInkFailed(page: 1)
        #expect(issue.hasSuffix("."))
        let layer = Self.row(.fail(issue), .hiddenWordInk,
                             pages: [0], part: "Page 2: the hidden text could not be matched to the printed words, so its boxes were not checked.",
                             partPages: [1])
        let caption = Self.caption(layer)
        #expect(caption == "Page 1: a box covers a word whose hidden copy is still in the text layer; Page 2: the hidden text could not be matched to the printed words, so its boxes were not checked.")
        #expect(caption?.count == 171)
        #expect(caption?.contains(".;") == false)
    }

    // MARK: - The Share sheet

    @Test("the Share sheet for a failed row with the part: the issue's line, then a could-not-verify line from the part's pages")
    func shareLinesForAFailedRowWithThePart() {
        let layer = Self.row(.fail("Annotations found on page 1"), .textExtraction, pages: [0],
                             part: Self.unread2, partPages: [1])
        #expect(DocumentEditorView.atRiskItemLines(report: Self.report([layer]))
                == ["Text & Annotations in the Redacted PDF: failed on\(Self.nbsp)page\(Self.nbsp)1",
                    "Text & Annotations in the Redacted PDF: could not verify on\(Self.nbsp)page\(Self.nbsp)2"])
    }

    @Test("the Share sheet for a needs-review row whose part names no page: could not verify, with no page")
    func shareLinesForAPartWithNoPage() {
        let layer = Self.row(.attention("Sensitive term found in decoded text on page 1"), .binaryStringSearch, pages: [0],
                             terms: ["Acme"], part: "1 term too short to check", partPages: [])
        #expect(DocumentEditorView.atRiskItemLines(report: Self.report([layer]))
                == ["Terms in Text & Bytes: needs review on\(Self.nbsp)page\(Self.nbsp)1",
                    "Terms in Text & Bytes: could not verify"])
    }

    // MARK: - The pin

    @Test("an issue with no part: the caption and the Share sheet's lines exactly as today")
    func findWithNoPartIsUnchanged() {
        let failed = Self.row(.fail("Annotations found on page 1"), .textExtraction, pages: [0])
        #expect(Self.caption(failed) == "Annotations found on page 1")
        let review = Self.row(.attention("Sensitive term found in decoded text on page 1"), .binaryStringSearch, pages: [0],
                              terms: ["Acme"])
        #expect(Self.caption(review) == "\u{201C}Acme\u{201D} is still readable on\(Self.nbsp)page\(Self.nbsp)1.")
        #expect(DocumentEditorView.atRiskItemLines(report: Self.report([failed, review]))
                == ["Text & Annotations in the Redacted PDF: failed on\(Self.nbsp)page\(Self.nbsp)1",
                    "Terms in Text & Bytes: needs review on\(Self.nbsp)page\(Self.nbsp)1"])
        #expect(DocumentEditorView.couldNotVerifyItemLines(report: Self.report([failed, review])).isEmpty)
    }
}
