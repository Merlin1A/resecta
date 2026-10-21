import Foundation
import CoreGraphics
@testable import RedactionEngine

// Hidden-content fixtures for the hidden-layer walk and the ink test.
//
// Optional content can be named in three places the walk reads beside a
// page's own `/Properties` entry: a default configuration whose base state
// turns every layer off, a resource dictionary the page inherits from the
// page tree, and a form XObject that carries the group (or names it through
// its own resources). Two more forms hide content without an `/OFF` entry:
// an OFF base state whose `/ON` list names one group twice and another
// never, and a membership dictionary (or a usage-application entry) that
// hides content while every group is on. One page puts its text outside
// the crop box. Three pages draw text that shows almost no ink: near-white,
// nearly transparent, and under a nearly opaque box. Every page draws the
// shared anchor line at
// `hiddenPlantAnchorTd` and the hidden line at `hiddenPlantHiddenTd` (the
// crop-box page moves them inside and outside the box), so the hidden-text
// probe cells can burn a region over exactly one of them.
extension TestFixtures {

    // MARK: - Optional content

    /// The default configuration's base state turns every group off and its
    /// `/ON` list names none of them; there is no `/OFF` array. The page's own
    /// resources name the group; the hidden line sits in its marked content.
    /// With `everyGroupOn` the `/ON` list names the group, so nothing is hidden.
    /// With `duplicateOn` a second group wraps the anchor line and the `/ON`
    /// list names that group twice and the hidden line's group never: the
    /// list is as long as the group list while one group stays off.
    static func ocgBaseStateOffPDF(
        visible: String = "BSO VISIBLE ANCHOR LINE",
        hidden: String = "PLANT-ENGBSO-01",
        everyGroupOn: Bool = false,
        duplicateOn: Bool = false
    ) -> Data {
        let anchor = "BT /F1 18 Tf 72 700 Td (\(visible)) Tj ET"
        let stream = """
            \(duplicateOn ? "/OC /OC2 BDC\n\(anchor)\nEMC" : anchor)
            /OC /OC1 BDC
            BT /F1 18 Tf 72 400 Td (\(hidden)) Tj ET
            EMC
            """
        let groups = duplicateOn ? "[5 0 R 7 0 R]" : "[5 0 R]"
        let on = duplicateOn ? "/ON [7 0 R 7 0 R]" : (everyGroupOn ? "/ON [5 0 R]" : "/ON []")
        let properties = duplicateOn ? "<< /OC1 5 0 R /OC2 7 0 R >>" : "<< /OC1 5 0 R >>"
        var objects = [
            PDFObject(id: 1, content: """
                << /Type /Catalog /Pages 2 0 R \
                /OCProperties << /OCGs \(groups) \
                /D << /BaseState /OFF \(on) >> >> >>
                """),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R \
                /Resources << /Font << /F1 6 0 R >> \
                /Properties \(properties) >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /OCG /Name (Hidden Layer) >>"),
            PDFObject(id: 6, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ]
        if duplicateOn {
            objects.append(PDFObject(id: 7, content: "<< /Type /OCG /Name (Visible Layer) >>"))
        }
        return buildRawPDF(objects: objects, rootId: 1)
    }

    /// `ocgBaseStateOffPDF(duplicateOn: true)` under the probe grid's own
    /// anchor and plant texts.
    static func ocgDuplicateOnPDF(
        visible: String = "DUP VISIBLE ANCHOR LINE",
        hidden: String = "PLANT-ENGDUP-01"
    ) -> Data {
        ocgBaseStateOffPDF(visible: visible, hidden: hidden, duplicateOn: true)
    }

    /// How the page names the optional content that wraps the hidden line
    /// while every group is on.
    enum OptionalContentReference {
        /// A plain group reference: nothing is hidden (the all-on control).
        case plainGroup
        /// A membership dictionary visible only when all its groups are off.
        case allOff
        /// A membership dictionary whose visibility expression negates the group.
        case visibilityExpression
        /// A plain group reference under a configuration whose usage-application
        /// entry lets the viewer turn the group off below a zoom of 1000 %.
        case usageApplication
    }

    /// Every group is on (`/D << /ON [5 0 R] >>`, no `/OFF`, no base state).
    /// The hidden line sits in marked content the page names through
    /// `reference`; the anchor line is plain.
    static func ocgMembershipDictionaryPDF(
        reference: OptionalContentReference = .allOff,
        visible: String = "OCMD VISIBLE ANCHOR LINE",
        hidden: String = "PLANT-ENGOCMD-01"
    ) -> Data {
        let stream = """
            BT /F1 18 Tf 72 700 Td (\(visible)) Tj ET
            /OC /OC1 BDC
            BT /F1 18 Tf 72 400 Td (\(hidden)) Tj ET
            EMC
            """
        let property: String
        var config = "/ON [5 0 R]"
        var group = "<< /Type /OCG /Name (Conditional Layer) >>"
        switch reference {
        case .plainGroup:
            property = "5 0 R"
        case .allOff:
            property = "<< /Type /OCMD /OCGs [5 0 R] /P /AllOff >>"
        case .visibilityExpression:
            property = "<< /Type /OCMD /VE [/Not 5 0 R] >>"
        case .usageApplication:
            property = "5 0 R"
            config += " /AS [<< /Event /View /OCGs [5 0 R] /Category [/Zoom] >>]"
            group = "<< /Type /OCG /Name (Conditional Layer) /Usage << /Zoom << /min 1000 >> >> >>"
        }
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: """
                << /Type /Catalog /Pages 2 0 R \
                /OCProperties << /OCGs [5 0 R] /D << \(config) >> >> >>
                """),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R \
                /Resources << /Font << /F1 6 0 R >> \
                /Properties << /OC1 \(property) >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"),
            PDFObject(id: 5, content: group),
            PDFObject(id: 6, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ], rootId: 1)
    }

    /// The group is turned off by the `/OFF` array. The page's resources are
    /// one shared dictionary (object 7) whose `/XObject` entry lists `forms`
    /// form XObjects, each of which names that same dictionary as its own
    /// resources; only the last form carries `/OC`. A walk that re-reads the
    /// shared dictionary for every form does `forms` × `forms` work here.
    static func ocgSharedResourceDictionaryPDF(forms: Int) -> Data {
        let pageStream = "/Fx1 Do"
        let formStream = "0 0 m 1 1 l S"
        let firstForm = 8
        let entries = (0..<forms).map { "/Fx\($0 + 1) \(firstForm + $0) 0 R" }.joined(separator: " ")
        var objects = [
            PDFObject(id: 1, content: """
                << /Type /Catalog /Pages 2 0 R \
                /OCProperties << /OCGs [5 0 R] /D << /OFF [5 0 R] >> >> >>
                """),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R \
                /Resources 7 0 R >>
                """),
            PDFObject(id: 4, content: "<< /Length \(pageStream.utf8.count) >>\nstream\n\(pageStream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /OCG /Name (Hidden Layer) >>"),
            PDFObject(id: 6, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
            PDFObject(id: 7, content: "<< /Font << /F1 6 0 R >> /XObject << \(entries) >> >>"),
        ]
        for index in 0..<forms {
            let optionalContent = index == forms - 1 ? " /OC 5 0 R" : ""
            objects.append(PDFObject(id: firstForm + index, content: """
                << /Type /XObject /Subtype /Form /BBox [0 0 612 792]\(optionalContent) \
                /Resources 7 0 R /Length \(formStream.utf8.count) >>
                stream
                \(formStream)
                endstream
                """))
        }
        return buildRawPDF(objects: objects, rootId: 1)
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

    // MARK: - Faint ink

    /// The hidden line is drawn in a near-white grey (`0.985 g`) on the
    /// undrawn white page.
    static func nearWhiteTextPDF(
        visible: String = "NW VISIBLE ANCHOR LINE",
        hidden: String = "PLANT-ENGNW-01"
    ) -> Data {
        faintInkPage(stream: """
            BT /F1 18 Tf 72 700 Td (\(visible)) Tj ET
            0.985 g
            BT /F1 18 Tf 72 400 Td (\(hidden)) Tj ET
            0 g
            """)
    }

    /// The hidden line is drawn black through an extended graphics state
    /// whose fill alpha is 0.02.
    static func lowAlphaTextPDF(
        visible: String = "LA VISIBLE ANCHOR LINE",
        hidden: String = "PLANT-ENGLA-01"
    ) -> Data {
        faintInkPage(stream: """
            BT /F1 18 Tf 72 700 Td (\(visible)) Tj ET
            q /GSLow gs
            BT /F1 18 Tf 72 400 Td (\(hidden)) Tj ET
            Q
            """)
    }

    /// The hidden line is drawn black, then a black box at fill alpha 0.97 is
    /// painted over it in the content stream.
    static func translucentBoxCoveredTextPDF(
        visible: String = "TB VISIBLE ANCHOR LINE",
        hidden: String = "PLANT-ENGTB-01"
    ) -> Data {
        faintInkPage(stream: """
            BT /F1 18 Tf 72 700 Td (\(visible)) Tj ET
            BT /F1 18 Tf 72 400 Td (\(hidden)) Tj ET
            q /GSBox gs 0 g 66 392 220 30 re f Q
            """)
    }

    /// One page over `stream` with the Helvetica font and the two extended
    /// graphics states the faint-ink pages use.
    private static func faintInkPage(stream: String) -> Data {
        buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R \
                /Resources << /Font << /F1 5 0 R >> \
                /ExtGState << /GSLow << /ca 0.02 /CA 0.02 >> /GSBox << /ca 0.97 /CA 0.97 >> >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ], rootId: 1)
    }
}
