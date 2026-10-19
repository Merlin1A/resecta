import Foundation
import CoreGraphics
@testable import RedactionEngine

// A source PDF that carries a distinct marker string in every place a
// source document can hold text outside its page body: the body line a
// redaction region covers, the document information dictionary, the XMP
// metadata stream, an annotation, an outline entry and a page label. A
// redacted output that carries any of these markers kept a source object
// the writer is meant to leave behind.

struct CanarySource {
    /// The PDF bytes.
    let data: Data
    /// Marker strings by where the source plants them.
    let canaries: [String: String]
    /// A body line outside every region (Searchable output may keep it).
    let keptLine: String
    /// The normalized region (bottom-left origin) over the region marker.
    let regionRect: CGRect
}

extension TestFixtures {

    /// One 612 × 792 pt page: a kept body line at y 700 and the region
    /// marker at y 400 (Helvetica 12 pt), plus markers in `/Info`, the XMP
    /// stream, a text annotation, an outline entry and a page label.
    static func canarySource() -> CanarySource {
        let canaries = [
            "region": "QZXREGIONMARKER",
            "info": "QZXINFOMARKER",
            "xmp": "QZXXMPMARKER",
            "annotation": "QZXANNOTMARKER",
            "outline": "QZXOUTLINEMARKER",
            "pageLabel": "QZXLABELMARKER",
        ]
        let keptLine = "Body text outside every region"
        let content = """
        BT /F1 12 Tf 72 700 Td (\(keptLine)) Tj ET
        BT /F1 12 Tf 72 400 Td (\(canaries["region"]!)) Tj ET
        """
        let xmp = """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title><rdf:Alt><rdf:li xml:lang="x-default">\(canaries["xmp"]!)</rdf:li></rdf:Alt></dc:title>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        <?xpacket end="w"?>
        """
        let data = buildRawPDF(objects: [
            PDFObject(id: 1, content: """
                << /Type /Catalog /Pages 2 0 R /Metadata 7 0 R /Outlines 8 0 R \
                /PageLabels << /Nums [0 << /S /D /P (\(canaries["pageLabel"]!)) >>] >> >>
                """),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
                /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R /Annots [6 0 R] >>
                """),
            PDFObject(id: 4, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
            PDFObject(id: 5, content: "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"),
            PDFObject(id: 6, content: """
                << /Type /Annot /Subtype /Text /Rect [300 600 320 620] /Contents (\(canaries["annotation"]!)) >>
                """),
            PDFObject(id: 7, content: "<< /Type /Metadata /Subtype /XML /Length \(xmp.utf8.count) >>\nstream\n\(xmp)\nendstream"),
            PDFObject(id: 8, content: "<< /Type /Outlines /First 9 0 R /Last 9 0 R /Count 1 >>"),
            PDFObject(id: 9, content: "<< /Title (\(canaries["outline"]!)) /Parent 8 0 R /Dest [3 0 R /XYZ 0 792 0] >>"),
            PDFObject(id: 10, content: "<< /Title (\(canaries["info"]!)) /Author (\(canaries["info"]!)) >>"),
        ], rootId: 1, infoId: 10)
        // 380…428 pt over the marker line at y 400 (12 pt glyphs).
        let regionRect = CGRect(x: 0.1, y: 380.0 / 792.0, width: 0.8, height: 48.0 / 792.0)
        return CanarySource(data: data, canaries: canaries, keptLine: keptLine, regionRect: regionRect)
    }
}
