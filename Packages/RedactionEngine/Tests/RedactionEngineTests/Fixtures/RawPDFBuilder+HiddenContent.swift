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
// hides content while every group is on. Three more name the group through
// a Type 3 font, a tiling pattern or a soft mask; three carry an entry of
// the wrong shape; and three carry no optional content at all (a nested form
// chain, a form cycle, a deep page tree) for the walk's bounds. One page
// puts its text outside the crop box. Three pages draw text that shows
// almost no ink: near-white, nearly transparent, and under a nearly opaque
// box. Every page draws the shared anchor line at
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

    // MARK: - The other content resources, malformed shapes, bounds and cycles

    /// Where a page's resources can draw content that names a group beside a
    /// form XObject.
    enum ContentResourceKind {
        /// A Type 3 font whose glyph procedure sits in marked content named
        /// through the font's own `/Resources`.
        case type3Font
        /// A tiling pattern whose cell sits in marked content named through
        /// the pattern's own `/Resources`.
        case tilingPattern
        /// A graphics state whose soft mask is a form XObject carrying `/OC`.
        case softMask
    }

    /// The hidden line is drawn through `kind`. With `membership` false the
    /// group is turned off by the `/OFF` array and the reference is the plain
    /// group; with it true every group is on and the reference is a
    /// membership dictionary visible only when all its groups are off, so
    /// only a walk that reaches `kind` reads the document as hidden.
    static func ocgResourceKindPDF(
        kind: ContentResourceKind,
        membership: Bool = false,
        visible: String = "KIND VISIBLE ANCHOR LINE"
    ) -> Data {
        let config = membership ? "/ON [5 0 R]" : "/OFF [5 0 R]"
        let reference = membership ? "<< /Type /OCMD /OCGs [5 0 R] /P /AllOff >>" : "5 0 R"
        let anchor = "BT /F1 18 Tf 72 700 Td (\(visible)) Tj ET"
        let pageStream: String
        let resources: String
        var objects: [PDFObject] = []
        switch kind {
        case .type3Font:
            pageStream = "\(anchor)\nBT /T3 400 Tf 72 400 Td (a) Tj ET"
            resources = "/Font << /F1 6 0 R /T3 7 0 R >>"
            let glyph = "1000 0 0 0 1000 1000 d1\n/OC /OC1 BDC\n0 0 500 500 re f\nEMC"
            objects.append(PDFObject(id: 7, content: """
                << /Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] \
                /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /square 8 0 R >> \
                /Encoding << /Type /Encoding /Differences [97 /square] >> \
                /FirstChar 97 /LastChar 97 /Widths [1000] \
                /Resources << /Properties << /OC1 \(reference) >> >> >>
                """))
            objects.append(PDFObject(id: 8, content: "<< /Length \(glyph.utf8.count) >>\nstream\n\(glyph)\nendstream"))
        case .tilingPattern:
            pageStream = "\(anchor)\n/Pattern cs /P1 scn 72 380 300 40 re f"
            resources = "/Font << /F1 6 0 R >> /Pattern << /P1 7 0 R >>"
            let cell = "/OC /OC1 BDC\n0 0 10 10 re f\nEMC"
            objects.append(PDFObject(id: 7, content: """
                << /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 20 20] \
                /XStep 20 /YStep 20 /Resources << /Properties << /OC1 \(reference) >> >> \
                /Length \(cell.utf8.count) >>
                stream
                \(cell)
                endstream
                """))
        case .softMask:
            pageStream = "\(anchor)\n/GS1 gs 72 380 300 40 re f"
            resources = "/Font << /F1 6 0 R >> /ExtGState << /GS1 7 0 R >>"
            let mask = "0 g 0 0 612 792 re f"
            objects.append(PDFObject(id: 7, content: "<< /Type /ExtGState /SMask << /S /Alpha /G 8 0 R >> >>"))
            objects.append(PDFObject(id: 8, content: """
                << /Type /XObject /Subtype /Form /BBox [0 0 612 792] \
                /Group << /S /Transparency /CS /DeviceGray >> /OC \(reference) \
                /Length \(mask.utf8.count) >>
                stream
                \(mask)
                endstream
                """))
        }
        objects.append(contentsOf: [
            PDFObject(id: 1, content: """
                << /Type /Catalog /Pages 2 0 R \
                /OCProperties << /OCGs [5 0 R] /D << \(config) >> >> >>
                """),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R \
                /Resources << \(resources) >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(pageStream.utf8.count) >>\nstream\n\(pageStream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /OCG /Name (Hidden Layer) >>"),
            PDFObject(id: 6, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ])
        return buildRawPDF(objects: objects.sorted { $0.id < $1.id }, rootId: 1)
    }

    /// An optional-content entry that is not of its declared shape.
    enum MalformedOptionalContent {
        /// The page's `/Properties` is an array, not a dictionary; the group
        /// is turned off by the `/OFF` array.
        case propertiesNotDictionary
        /// A form XObject carrying `/OC` has no `/Subtype`; the group is
        /// turned off by the `/OFF` array.
        case xobjectWithoutSubtype
        /// The configuration's `/OFF` is a group reference, not an array;
        /// the page names the group through `/Properties`.
        case offNotArray
        /// An `/XObject` entry is a dictionary, not a stream; the group is
        /// turned off by the `/OFF` array.
        case xobjectNotStream
    }

    static func ocgMalformedPDF(shape: MalformedOptionalContent) -> Data {
        let anchor = "BT /F1 18 Tf 72 700 Td (MAL VISIBLE ANCHOR LINE) Tj ET"
        let hiddenLine = "BT /F1 18 Tf 72 400 Td (PLANT-ENGMAL-01) Tj ET"
        let marked = "/OC /OC1 BDC\n\(hiddenLine)\nEMC"
        let config: String
        let pageStream: String
        let resources: String
        var objects: [PDFObject] = []
        switch shape {
        case .propertiesNotDictionary:
            config = "/OFF [5 0 R]"
            pageStream = "\(anchor)\n\(marked)"
            resources = "/Font << /F1 6 0 R >> /Properties [5 0 R]"
        case .xobjectWithoutSubtype:
            config = "/OFF [5 0 R]"
            pageStream = "\(anchor)\n/Fx1 Do"
            resources = "/Font << /F1 6 0 R >> /XObject << /Fx1 7 0 R >>"
            objects.append(PDFObject(id: 7, content: """
                << /Type /XObject /BBox [0 0 612 792] /OC 5 0 R \
                /Resources << /Font << /F1 6 0 R >> >> /Length \(hiddenLine.utf8.count) >>
                stream
                \(hiddenLine)
                endstream
                """))
        case .offNotArray:
            config = "/OFF 5 0 R"
            pageStream = "\(anchor)\n\(marked)"
            resources = "/Font << /F1 6 0 R >> /Properties << /OC1 5 0 R >>"
        case .xobjectNotStream:
            config = "/OFF [5 0 R]"
            pageStream = "\(anchor)\n\(marked)"
            resources = "/Font << /F1 6 0 R >> /XObject << /Fx1 5 0 R >>"
        }
        objects.append(contentsOf: [
            PDFObject(id: 1, content: """
                << /Type /Catalog /Pages 2 0 R \
                /OCProperties << /OCGs [5 0 R] /D << \(config) >> >> >>
                """),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R \
                /Resources << \(resources) >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(pageStream.utf8.count) >>\nstream\n\(pageStream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /OCG /Name (Hidden Layer) >>"),
            PDFObject(id: 6, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ])
        return buildRawPDF(objects: objects.sorted { $0.id < $1.id }, rootId: 1)
    }

    /// No optional content anywhere. The page draws form 1, which draws form
    /// 2, and so on `depth` deep; the innermost form draws a line. A walk
    /// bounded at `maxFormXObjectDepth` reads a chain deeper than the bound
    /// as not known clean.
    static func plainNestedFormsPDF(depth: Int) -> Data {
        let firstForm = 6
        let pageStream = "BT /F1 18 Tf 72 700 Td (NEST VISIBLE ANCHOR LINE) Tj ET\n/Fx1 Do"
        var objects = [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R \
                /Resources << /Font << /F1 5 0 R >> /XObject << /Fx1 \(firstForm) 0 R >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(pageStream.utf8.count) >>\nstream\n\(pageStream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ]
        for index in 0..<depth {
            let last = index == depth - 1
            let stream = last ? "0 0 m 100 100 l S" : "/Fx\(index + 2) Do"
            let resources = last ? "<< >>" : "<< /XObject << /Fx\(index + 2) \(firstForm + index + 1) 0 R >> >>"
            objects.append(PDFObject(id: firstForm + index, content: """
                << /Type /XObject /Subtype /Form /BBox [0 0 612 792] \
                /Resources \(resources) /Length \(stream.utf8.count) >>
                stream
                \(stream)
                endstream
                """))
        }
        return buildRawPDF(objects: objects, rootId: 1)
    }

    /// No optional content anywhere. Form 1's resources name form 2 and form
    /// 2's name form 1 (each also names itself); the page names form 1.
    static func cyclicFormsPDF() -> Data {
        let pageStream = "BT /F1 18 Tf 72 700 Td (CYC VISIBLE ANCHOR LINE) Tj ET\n/Fx1 Do"
        let one = "/Fx2 Do"
        let two = "0 0 m 100 100 l S"
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R \
                /Resources << /Font << /F1 5 0 R >> /XObject << /Fx1 6 0 R >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(pageStream.utf8.count) >>\nstream\n\(pageStream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
            PDFObject(id: 6, content: """
                << /Type /XObject /Subtype /Form /BBox [0 0 612 792] \
                /Resources << /XObject << /Fx1 6 0 R /Fx2 7 0 R >> >> /Length \(one.utf8.count) >>
                stream
                \(one)
                endstream
                """),
            PDFObject(id: 7, content: """
                << /Type /XObject /Subtype /Form /BBox [0 0 612 792] \
                /Resources << /XObject << /Fx1 6 0 R /Fx2 7 0 R >> >> /Length \(two.utf8.count) >>
                stream
                \(two)
                endstream
                """),
        ], rootId: 1)
    }

    /// No optional content and no resources anywhere. The page's `/Parent`
    /// is a node whose `/Parent` is the page again: the chain never reaches
    /// a resource dictionary or an end.
    static func parentCyclePDF() -> Data {
        let stream = "0 0 m 100 100 l S"
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 /Parent 3 0 R >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] /Contents 4 0 R >>
                """),
            PDFObject(id: 4, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"),
        ], rootId: 1)
    }

    /// No optional content anywhere. The page has no `/Resources` of its own
    /// and sits under `depth` page-tree nodes (the root and `depth - 1`
    /// between); only the root carries the resources, so a walk reads the
    /// page and then `depth` ancestors to reach them. A walk bounded at
    /// `maxPageTreeDepth` nodes reads a longer chain as not known clean.
    static func deepPageTreePDF(depth: Int) -> Data {
        // Object ids: 1 catalog, 2 root pages node, 3 ... 2 + depth - 1 the
        // intermediate nodes, then the page, its contents and the font.
        let pageId = 2 + depth
        let contentsId = pageId + 1
        let fontId = pageId + 2
        let stream = "BT /F1 18 Tf 72 700 Td (TREE VISIBLE ANCHOR LINE) Tj ET"
        var objects = [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: """
                << /Type /Pages /Kids [\(depth > 1 ? 3 : pageId) 0 R] /Count 1 \
                /Resources << /Font << /F1 \(fontId) 0 R >> >> >>
                """),
        ]
        for index in 0..<(depth - 1) {
            let id = 3 + index
            let child = index == depth - 2 ? pageId : id + 1
            objects.append(PDFObject(id: id, content: "<< /Type /Pages /Parent \(id - 1) 0 R /Kids [\(child) 0 R] /Count 1 >>"))
        }
        objects.append(contentsOf: [
            PDFObject(id: pageId, content: """
                << /Type /Page /Parent \(pageId - 1) 0 R \
                /MediaBox [0 0 612 792] /Contents \(contentsId) 0 R >>
                """),
            PDFObject(id: contentsId, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"),
            PDFObject(id: fontId, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ])
        return buildRawPDF(objects: objects, rootId: 1)
    }

    // MARK: - The crop box

    /// A page whose crop box (`[0 0 612 600]`) is shorter than its media box:
    /// the visible anchor sits inside the box, the hidden line outside it.
    /// PDFKit leaves text outside the crop box out of `page.string`, so that
    /// line never reaches the layer. With `cropBoxPastMediaBox` the boxes
    /// swap: the media box is the short one and the crop box reaches past
    /// it. The visible page is their intersection, so the line at 700 is
    /// never rendered, but PDFKit extracts it — the layer would carry it
    /// without the visible-page arm of the ink test.
    static func offCropBoxTextPDF(
        visible: String = "CROP VISIBLE ANCHOR LINE",
        hidden: String = "PLANT-ENGCROP-01",
        cropBoxPastMediaBox: Bool = false
    ) -> Data {
        let boxes = cropBoxPastMediaBox
            ? "/MediaBox [0 0 612 600] /CropBox [0 0 612 792]"
            : "/MediaBox [0 0 612 792] /CropBox [0 0 612 600]"
        let stream = """
            BT /F1 18 Tf 72 400 Td (\(visible)) Tj ET
            BT /F1 18 Tf 72 700 Td (\(hidden)) Tj ET
            """
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                \(boxes) \
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
