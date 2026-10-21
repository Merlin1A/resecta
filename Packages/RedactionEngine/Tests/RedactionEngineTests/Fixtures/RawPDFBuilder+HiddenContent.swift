import Foundation
import CoreGraphics
@testable import RedactionEngine

// Hidden-content fixtures for the hidden-layer walk and the ink test.
//
// Optional content can be named in three places the walk reads beside a
// page's own `/Properties` entry: a default configuration whose base state
// turns every layer off, a resource dictionary the page inherits from the
// page tree, and a form XObject that carries the group (or names it through
// its own resources). One page puts its text outside the crop box. Every
// page draws the shared anchor line at
// `hiddenPlantAnchorTd` and the hidden line at `hiddenPlantHiddenTd` (the
// crop-box page moves them inside and outside the box), so the hidden-text
// probe cells can burn a region over exactly one of them.
extension TestFixtures {

    // MARK: - Optional content

    /// The default configuration's base state turns every group off and its
    /// `/ON` list names none of them; there is no `/OFF` array. The page's own
    /// resources name the group; the hidden line sits in its marked content.
    /// With `everyGroupOn` the `/ON` list names the group, so nothing is hidden.
    static func ocgBaseStateOffPDF(
        visible: String = "BSO VISIBLE ANCHOR LINE",
        hidden: String = "PLANT-ENGBSO-01",
        everyGroupOn: Bool = false
    ) -> Data {
        let stream = """
            BT /F1 18 Tf 72 700 Td (\(visible)) Tj ET
            /OC /OC1 BDC
            BT /F1 18 Tf 72 400 Td (\(hidden)) Tj ET
            EMC
            """
        let on = everyGroupOn ? "/ON [5 0 R]" : "/ON []"
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: """
                << /Type /Catalog /Pages 2 0 R \
                /OCProperties << /OCGs [5 0 R] \
                /D << /BaseState /OFF \(on) >> >> >>
                """),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R \
                /Resources << /Font << /F1 6 0 R >> \
                /Properties << /OC1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /OCG /Name (Hidden Layer) >>"),
            PDFObject(id: 6, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ], rootId: 1)
    }

    /// The group is turned off by the ordinary `/OFF` array, but the page has
    /// no resource dictionary of its own: it inherits the `/Pages` node's,
    /// which names the group under `/Properties`.
    static func ocgInheritedResourcesPDF(
        visible: String = "INH VISIBLE ANCHOR LINE",
        hidden: String = "PLANT-ENGINH-01"
    ) -> Data {
        let stream = """
            BT /F1 18 Tf 72 700 Td (\(visible)) Tj ET
            /OC /OC1 BDC
            BT /F1 18 Tf 72 400 Td (\(hidden)) Tj ET
            EMC
            """
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: """
                << /Type /Catalog /Pages 2 0 R \
                /OCProperties << /OCGs [5 0 R] \
                /D << /OFF [5 0 R] >> >> >>
                """),
            PDFObject(id: 2, content: """
                << /Type /Pages /Kids [3 0 R] /Count 1 \
                /Resources << /Font << /F1 6 0 R >> \
                /Properties << /OC1 5 0 R >> >> >>
                """),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R >>
                """),
            PDFObject(id: 4, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /OCG /Name (Hidden Layer) >>"),
            PDFObject(id: 6, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ], rootId: 1)
    }

    /// The group is turned off by the `/OFF` array; the page's resources name
    /// no optional content. The hidden line is drawn by a form XObject that
    /// carries `/OC` — or, with `nested`, by a second form XObject inside the
    /// first whose own resources name the group under `/Properties`.
    static func ocgFormXObjectPDF(
        visible: String = "XOB VISIBLE ANCHOR LINE",
        hidden: String = "PLANT-ENGXOB-01",
        nested: Bool = false
    ) -> Data {
        let pageStream = "BT /F1 18 Tf 72 700 Td (\(visible)) Tj ET\n/Fx1 Do"
        let hiddenLine = "BT /F1 18 Tf 72 400 Td (\(hidden)) Tj ET"
        var objects: [PDFObject] = [
            PDFObject(id: 1, content: """
                << /Type /Catalog /Pages 2 0 R \
                /OCProperties << /OCGs [5 0 R] \
                /D << /OFF [5 0 R] >> >> >>
                """),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R \
                /Resources << /Font << /F1 6 0 R >> \
                /XObject << /Fx1 7 0 R >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(pageStream.utf8.count) >>\nstream\n\(pageStream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /OCG /Name (Hidden Layer) >>"),
            PDFObject(id: 6, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ]
        if nested {
            let outer = "/Fx2 Do"
            let inner = "/OC /OC1 BDC\n\(hiddenLine)\nEMC"
            objects.append(PDFObject(id: 7, content: """
                << /Type /XObject /Subtype /Form /BBox [0 0 612 792] \
                /Resources << /XObject << /Fx2 8 0 R >> >> \
                /Length \(outer.utf8.count) >>
                stream
                \(outer)
                endstream
                """))
            objects.append(PDFObject(id: 8, content: """
                << /Type /XObject /Subtype /Form /BBox [0 0 612 792] \
                /Resources << /Font << /F1 6 0 R >> /Properties << /OC1 5 0 R >> >> \
                /Length \(inner.utf8.count) >>
                stream
                \(inner)
                endstream
                """))
        } else {
            objects.append(PDFObject(id: 7, content: """
                << /Type /XObject /Subtype /Form /BBox [0 0 612 792] /OC 5 0 R \
                /Resources << /Font << /F1 6 0 R >> >> \
                /Length \(hiddenLine.utf8.count) >>
                stream
                \(hiddenLine)
                endstream
                """))
        }
        return buildRawPDF(objects: objects, rootId: 1)
    }

    // MARK: - The crop box

    /// A page whose crop box (`[0 0 612 600]`) is shorter than its media box:
    /// the visible anchor sits inside the box, the hidden line outside it.
    static func offCropBoxTextPDF(
        visible: String = "CROP VISIBLE ANCHOR LINE",
        hidden: String = "PLANT-ENGCROP-01"
    ) -> Data {
        let stream = """
            BT /F1 18 Tf 72 400 Td (\(visible)) Tj ET
            BT /F1 18 Tf 72 700 Td (\(hidden)) Tj ET
            """
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] /CropBox [0 0 612 600] \
                /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ], rootId: 1)
    }
}
