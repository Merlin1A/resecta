import Foundation
@testable import RedactionEngine

// Pages that carry both a text layer and image content: a scanned body under
// a stamp line, a scanned body under an invisible vendor text layer, and —
// the control — a born-digital letter with a small logo. Built raw, so the
// image is a real image XObject whose width and height the page census
// reads (a white 1-bit image, run-length encoded and hex-armoured to keep
// the file ASCII). The scanned body's own words live only in the image, so
// a search locates them only through the recognised text (seeded in tests).
extension TestFixtures {

    /// A white 1-bit image stream body for `width` × `height` pixels,
    /// run-length encoded, then hex-armoured.
    static func whiteImageStreamBody(width: Int, height: Int) -> String {
        let total = (width + 7) / 8 * height
        var hex = String(repeating: "81FF", count: total / 128)
        let rest = total % 128
        if rest >= 2 { hex += String(format: "%02XFF", 257 - rest) } else if rest == 1 { hex += "00FF" }
        return hex + "80>"
    }

    static func imageXObject(id: Int, width: Int, height: Int) -> PDFObject {
        let body = whiteImageStreamBody(width: width, height: height)
        return PDFObject(id: id, content: """
            << /Type /XObject /Subtype /Image /Width \(width) /Height \(height) \
            /ColorSpace /DeviceGray /BitsPerComponent 1 \
            /Filter [/ASCIIHexDecode /RunLengthDecode] /Length \(body.utf8.count) >>
            stream
            \(body)
            endstream
            """)
    }

    private static func onePage(stream: String, resources: String, extra: [PDFObject]) -> Data {
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

    /// A 150-dpi scan (1275 × 1650 px) drawn over the whole letter page, and
    /// one 12-pt text line "EXHIBIT B - 000123" at the top: a stamped scan.
    /// The text layer holds the stamp only.
    /// With a smaller `scanWidth` × `scanHeight` the scan's pixels fall below
    /// half the page at 100 dpi, and only the stamp-thin text layer marks it.
    static func stampedScanPDF(scanWidth: Int = 1275, scanHeight: Int = 1650) -> Data {
        onePage(
            stream: "q 612 0 0 792 0 0 cm /Im1 Do Q\nBT /F1 12 Tf 72 760 Td (EXHIBIT B - 000123) Tj ET",
            resources: "/Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >>",
            extra: [imageXObject(id: 6, width: scanWidth, height: scanHeight)])
    }

    /// A short born-digital page (a title line and a date, no image): not
    /// image content, whatever its density.
    static func shortTitlePagePDF() -> Data {
        onePage(
            stream: "BT /F1 24 Tf 72 700 Td (CONFIDENTIAL SETTLEMENT MEMORANDUM) Tj ET\nBT /F1 12 Tf 72 660 Td (October 2026) Tj ET",
            resources: "/Font << /F1 5 0 R >>",
            extra: [])
    }

    /// The scan's image reached through a chain of `depth` form objects; with
    /// `selfReferencing` the innermost form also names itself.
    static func imageInNestedFormsPDF(depth: Int, selfReferencing: Bool = false) -> Data {
        let firstForm = 7
        var objects: [PDFObject] = [imageXObject(id: 6, width: 1275, height: 1650)]
        for index in 0..<depth {
            let id = firstForm + index
            let last = index == depth - 1
            let child = last ? "/Im1 6 0 R" : "/Fx\(index + 2) \(id + 1) 0 R"
            let selfEntry = last && selfReferencing ? " /Fx\(index + 1) \(id) 0 R" : ""
            let stream = last ? "q 612 0 0 792 0 0 cm /Im1 Do Q" : "/Fx\(index + 2) Do"
            objects.append(PDFObject(id: id, content: """
                << /Type /XObject /Subtype /Form /BBox [0 0 612 792] \
                /Resources << /XObject << \(child)\(selfEntry) >> >> /Length \(stream.utf8.count) >>
                stream
                \(stream)
                endstream
                """))
        }
        return onePage(
            stream: "/Fx1 Do\nBT /F1 12 Tf 72 760 Td (EXHIBIT B - 000123) Tj ET",
            resources: "/Font << /F1 5 0 R >> /XObject << /Fx1 \(firstForm) 0 R >>",
            extra: objects)
    }

    /// The same scan under an invisible text layer of about 1,200 characters
    /// (render mode 3): a vendor text layer whose density alone reads as a
    /// born-digital page; only the page-scale image marks it.
    static func vendorLayerOverScanPDF() -> Data {
        let line = "Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod"
        let lines = (0..<17).map { "BT 3 Tr /F1 10 Tf 72 \(740 - $0 * 14) Td (\(line)) Tj ET" }.joined(separator: "\n")
        return onePage(
            stream: "q 612 0 0 792 0 0 cm /Im1 Do Q\n\(lines)",
            resources: "/Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >>",
            extra: [imageXObject(id: 6, width: 1275, height: 1650)])
    }

    /// A born-digital letter of about 1,200 visible characters with a 120 × 60
    /// px logo in the corner: not image content in the census's sense.
    static func letterWithLogoPDF() -> Data {
        let line = "Dear Counsel, please see enclosed the records you requested on Monday"
        let lines = (0..<17).map { "BT /F1 10 Tf 72 \(700 - $0 * 14) Td (\(line)) Tj ET" }.joined(separator: "\n")
        return onePage(
            stream: "q 60 0 0 30 500 740 cm /Im1 Do Q\n\(lines)",
            resources: "/Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >>",
            extra: [imageXObject(id: 6, width: 120, height: 60)])
    }
}
