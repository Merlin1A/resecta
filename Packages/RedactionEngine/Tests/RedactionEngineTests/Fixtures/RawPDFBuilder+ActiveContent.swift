import Foundation
@testable import RedactionEngine

// Active-content fixtures for the carriers the import walk reads beyond the
// catalog-top keys, the name tree, the open action, page additional actions
// and annotation actions: a document-level additional action on the catalog,
// an additional action on a non-widget annotation, an additional action on a
// form field that is not itself a widget, and a rendition action carrying
// JavaScript — each refused — plus XFA form data and an embedded file, which
// import with a notice, and two shapes the walk admits by design (a merged
// field-widget's additional actions, a catalog additional action that only
// jumps to a page). Built on `activeContentProbe` (one blank page with the
// extras spliced in; object 5 is the JavaScript action).
extension TestFixtures {

    /// Catalog `/AA` with a JavaScript action on the will-close trigger.
    static func withCatalogAdditionalActionJavaScript() -> Data {
        activeContentProbe(catalogExtras: "/AA << /WC 5 0 R >>",
                           extraObjects: [javaScriptActionObject])
    }

    /// Catalog `/AA` whose only trigger jumps to a page: admitted.
    static func withCatalogAdditionalActionGoTo() -> Data {
        activeContentProbe(catalogExtras: "/AA << /WC << /Type /Action /S /GoTo /D [3 0 R /Fit] >> >>")
    }

    /// A `/Screen` annotation whose `/AA` runs JavaScript when the page opens.
    static func withScreenAnnotationAdditionalActionJavaScript() -> Data {
        activeContentProbe(
            pageExtras: "/Annots [6 0 R]",
            extraObjects: [
                javaScriptActionObject,
                PDFObject(id: 6, content: """
                    << /Type /Annot /Subtype /Screen /Rect [72 600 272 700] \
                    /AA << /PO 5 0 R >> >>
                    """),
            ])
    }

    /// A text field whose dictionary is not a widget (its widget is a
    /// separate kid) and whose `/AA` runs JavaScript on a keystroke.
    static func withFieldAdditionalActionJavaScript() -> Data {
        activeContentProbe(
            catalogExtras: "/AcroForm << /Fields [6 0 R] >>",
            pageExtras: "/Annots [7 0 R]",
            extraObjects: [
                javaScriptActionObject,
                PDFObject(id: 6, content: """
                    << /FT /Tx /T (field) /Kids [7 0 R] /AA << /K 5 0 R >> >>
                    """),
                PDFObject(id: 7, content: """
                    << /Type /Annot /Subtype /Widget /Parent 6 0 R \
                    /Rect [72 600 272 630] /F 4 /P 3 0 R >>
                    """),
            ])
    }

    /// An `/OpenAction` rendition action that carries a `/JS` entry.
    static func withOpenActionRenditionJavaScript() -> Data {
        activeContentProbe(
            catalogExtras: "/OpenAction << /Type /Action /S /Rendition /OP 0 /JS (app.alert\\('probe'\\)) >>")
    }

    /// An `/AcroForm` whose `/XFA` entry carries an XDP packet stream.
    static func withXFAFormData() -> Data {
        let xdp = "<xdp:xdp xmlns:xdp=\"http://ns.adobe.com/xdp/\"></xdp:xdp>"
        return activeContentProbe(
            catalogExtras: "/AcroForm << /Fields [] /XFA 5 0 R >>",
            extraObjects: [
                PDFObject(id: 5, content: "<< /Length \(xdp.utf8.count) >>\nstream\n\(xdp)\nendstream"),
            ])
    }
}
