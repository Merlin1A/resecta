import Testing
import Foundation
import PDFKit
import RedactionEngine
@testable import ResectaApp

// A page whose text layer holds text Search cannot read (an unresolved or
// symbol encoding, a CJK encoding failure, glyphs with no geometry) is read
// by OCR in Search, or reported not analysed with OCR off. The import records
// such pages beside the text-layer status, which export and verification keep
// reading unchanged.

@Suite("Search: unreadable text-layer pages", .tags(.importFlow))
@MainActor
struct SearchUnreadablePagesTests {

    /// A two-page PDF: page 1 ordinary text, page 2 a text layer of four
    /// distinct characters (the extraction-failure signature).
    static func twoPagePDF() -> Data {
        let streams = [
            "BT /F1 12 Tf 72 700 Td (Dear Counsel, please see enclosed the records you requested on Monday) Tj ET",
            "BT /F1 12 Tf 72 700 Td (" + String(repeating: "ababa cbcbc ", count: 6) + ") Tj ET",
        ]
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
            "<< /Length \(streams[0].utf8.count) >>\nstream\n\(streams[0])\nendstream",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
            "<< /Length \(streams[1].utf8.count) >>\nstream\n\(streams[1])\nendstream",
        ]
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, object) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    @Test("the import records a garbled text layer for Search alone; Search routes it to OCR")
    func garbledPageReadByOCR() async throws {
        let loaded = try await PDFImportLoader().load(
            .bytes(Self.twoPagePDF(), declaredType: "pdf", door: .files), password: nil, limits: .standard)
        #expect(loaded.facts.textLayerStatus[0] == .rich && loaded.facts.textLayerStatus[1] == .rich,
                "the text-layer status, which export and verification read, is unchanged")
        #expect(loaded.facts.searchUnreadablePages == [1])
        let state = DocumentState()
        state.textLayerStatus = loaded.facts.textLayerStatus
        state.searchUnreadablePages = loaded.facts.searchUnreadablePages
        #expect(state.searchTextLayerStatus == [0: .rich, 1: .sparse])
        #expect(state.textLayerStatus == [0: .rich, 1: .rich])
        // The toolbar's OCR controls and caption show for the unreadable page.
        #expect(state.anyPageAwaitsOCRForSearch)
        state.searchUnreadablePages = []
        #expect(!state.anyPageAwaitsOCRForSearch, "an all-rich document routes no page to OCR")
    }

    @Test("the toolbar reads which pages await OCR from the search map, not the text-layer status")
    func toolbarReadsTheSearchMap() throws {
        let root = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/ResectaApp/Views/Search/SearchToolbarSection+Scan.swift"),
                              encoding: .utf8)
        #expect(text.components(separatedBy: "anyPageAwaitsOCR: documentState.anyPageAwaitsOCRForSearch").count - 1 == 3)
        #expect(!text.contains("textLayerStatus.values"))
    }
}
