import Foundation
@testable import RedactionEngine

// Pages for the page mode's invisible-text test: text shown in render mode 3
// or 7 (no fill, no stroke) over a scan, on a typed page and inside a form
// object; and a page that sets the mode and unsets it with no text shown.
// Built raw from invented text. Each page holds enough text to read as a
// page with rich text, so it reaches the test.
extension TestFixtures {

    static let invisibleLine = "Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod"

    private static func invisiblePage(stream: String, resources: String, extra: [PDFObject] = []) -> Data {
        buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << \(resources) >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ] + extra, rootId: 1)
    }

    /// Seventeen lines of text, each set in render `mode` and moved `drift`
    /// points right and up, starting at 72, 740.
    static func layerLines(mode: Int, drift: Int = 0) -> String {
        (0..<17).map { "BT \(mode) Tr /F1 10 Tf \(72 + drift) \(740 + drift - $0 * 14) Td (\(invisibleLine)) Tj ET" }
            .joined(separator: "\n")
    }

    /// A 150-dpi scan over the whole page, under a text layer of seventeen
    /// lines in render `mode` (3 or 7), moved `drift` points from where it
    /// would sit: the shape an OCR tool leaves.
    static func layerOverScanPDF(mode: Int, drift: Int = 0) -> Data {
        invisiblePage(
            stream: "q 612 0 0 792 0 0 cm /Im1 Do Q\n\(layerLines(mode: mode, drift: drift))",
            resources: "/Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >>",
            extra: [imageXObject(id: 6, width: 1275, height: 1650)])
    }

    /// A typed page of seventeen visible lines, one word of which is shown in
    /// render mode 3.
    static func typedPageWithOneInvisibleWordPDF() -> Data {
        let visible = layerLines(mode: 0)
        return invisiblePage(
            stream: "\(visible)\nBT 3 Tr /F1 10 Tf 72 480 Td (Hidden) Tj ET",
            resources: "/Font << /F1 5 0 R >>")
    }

    /// A typed page of seventeen visible lines that draws a form object whose
    /// own content shows one line in render mode 3.
    static func invisibleTextInFormPDF() -> Data {
        let form = "BT 3 Tr /F1 10 Tf 72 460 Td (\(invisibleLine)) Tj ET"
        return invisiblePage(
            stream: "\(layerLines(mode: 0))\n/Fx1 Do",
            resources: "/Font << /F1 5 0 R >> /XObject << /Fx1 6 0 R >>",
            extra: [PDFObject(id: 6, content: """
                << /Type /XObject /Subtype /Form /BBox [0 0 612 792] \
                /Resources << /Font << /F1 5 0 R >> >> /Length \(form.utf8.count) >>
                stream
                \(form)
                endstream
                """)])
    }

    /// A typed page of seventeen visible lines that sets render mode 3 and
    /// unsets it with no text shown between: once inside a saved state it
    /// restores, once inside a text object that sets 0 again.
    static func invisibleModeSetAndUnsetPDF() -> Data {
        invisiblePage(
            stream: "q 3 Tr Q\nBT 7 Tr 0 Tr ET\n\(layerLines(mode: 0))",
            resources: "/Font << /F1 5 0 R >>")
    }
}
