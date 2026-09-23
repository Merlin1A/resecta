import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

// The import-time active-content walk: the catalog-top keys the original
// import guard refused, plus the four ISO-canonical carriers of document
// JavaScript (/Names → /JavaScript, /OpenAction, page /AA, annotation /A).
// One fixture per location; the clean shapes a real document commonly
// carries at those same locations must pass.

@Suite("Active-content import walk", .tags(.security))
struct ActiveContentScanTests {

    private func scan(_ data: Data) throws -> ActiveContentLocation? {
        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        return ActiveContentScan.firstLocation(in: document)
    }

    // MARK: - One location per carrier

    @Test("Catalog-top /JavaScript is reported as the catalog key")
    func catalogTopJavaScript() throws {
        #expect(try scan(TestFixtures.withJavaScript()) == .catalogKey("JavaScript"))
    }

    @Test("Catalog-top /Launch is reported as the catalog key")
    func catalogTopLaunch() throws {
        let data = TestFixtures.withCatalogKey(
            "Launch", value: "<< /Type /Action /S /Launch /F (calc.exe) >>")
        #expect(try scan(data) == .catalogKey("Launch"))
    }

    @Test("/Names → /JavaScript name tree is reported")
    func namesJavaScript() throws {
        #expect(try scan(TestFixtures.withNamesJavaScript()) == .namesJavaScript)
    }

    @Test("/OpenAction JavaScript action is reported")
    func openActionJavaScript() throws {
        #expect(try scan(TestFixtures.withOpenActionJavaScript()) == .openAction)
    }

    @Test("/OpenAction GoTo whose /Next chains to JavaScript is reported")
    func openActionChainedJavaScript() throws {
        #expect(try scan(TestFixtures.withOpenActionChainedJavaScript()) == .openAction)
    }

    @Test("Page /AA with a JavaScript trigger is reported with the page index")
    func pageAdditionalActionJavaScript() throws {
        #expect(try scan(TestFixtures.withPageAdditionalActionJavaScript())
                == .pageAdditionalAction(pageIndex: 0))
    }

    @Test("Annotation /A JavaScript action is reported with the page index")
    func annotationActionJavaScript() throws {
        #expect(try scan(TestFixtures.withAnnotationActionJavaScript())
                == .annotationAction(pageIndex: 0))
    }

    // MARK: - Clean shapes at the same locations pass

    @Test("Clean shapes at the walked locations are not reported")
    func cleanShapesPass() throws {
        let clean: [(String, Data)] = [
            ("blank page", TestFixtures.blankPage()),
            ("/OpenAction destination array", TestFixtures.withOpenActionDestination()),
            ("/OpenAction GoTo action", TestFixtures.withOpenActionGoTo()),
            ("page /AA with a GoTo trigger", TestFixtures.withPageAdditionalActionGoTo()),
            ("annotation /A URI action", TestFixtures.withAnnotationActionURI()),
            ("/Names with EmbeddedFiles only", TestFixtures.withNamesEmbeddedFilesOnly()),
            // Form-field scripts on widget /AA are outside the walk by
            // design (ordinary forms carry them; the raster omits them;
            // the verification pass reports them on the output).
            ("widget /AA JavaScript (not walked)", TestFixtures.withWidgetAdditionalActionJavaScript()),
        ]
        for (label, data) in clean {
            #expect(try scan(data) == nil, "\(label) must not be reported")
        }
    }

    @Test("A /Next chain longer than the walk's bound is not followed to its end")
    func nextChainIsBounded() throws {
        // Ten GoTo hops and JavaScript at the eleventh: beyond the bound,
        // so the walk stops and reports nothing. The verification pass's
        // structural check covers the output regardless.
        #expect(try scan(TestFixtures.withOpenActionDeepChain(hops: 10)) == nil)
        // Three hops sit inside the bound and are reported.
        #expect(try scan(TestFixtures.withOpenActionDeepChain(hops: 3)) == .openAction)
    }

    // MARK: - Corpus non-regression (env-gated, the H1.2 pattern)

    /// Walks every PDF under RESECTA_DOCS_ROOT. A document outside the
    /// corpus' deliberately hostile directories must not be reported: a hit
    /// there is a clean document the widened guard would newly refuse.
    /// Skips silently when the root is not set.
    @Test("No clean document in the sample corpus is reported")
    func corpusCleanDocumentsPass() throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["RESECTA_DOCS_ROOT"] ?? env["TEST_RUNNER_RESECTA_DOCS_ROOT"],
              !root.isEmpty else { return }
        // The corpus' deliberately hostile sets: robustness and fuzz
        // shapes, and the planted-payload documents (one carries a
        // catalog-top /JavaScript, which the original guard refused too).
        let hostile = ["/robustness/", "/fuzz/", "/planted/", "/hostile/", "/adversarial/"]
        let enumerator = FileManager.default.enumerator(atPath: root)
        var walked = 0
        var reported: [String] = []
        var unparseable = 0
        while let relative = enumerator?.nextObject() as? String {
            guard relative.lowercased().hasSuffix(".pdf") else { continue }
            let path = (root as NSString).appendingPathComponent(relative)
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            // A file CoreGraphics cannot open never reaches the walk in the
            // app either (PDFKit refuses it first); count it and move on.
            guard let provider = CGDataProvider(data: data as CFData),
                  let document = CGPDFDocument(provider) else {
                unparseable += 1
                continue
            }
            walked += 1
            guard let location = ActiveContentScan.firstLocation(in: document) else { continue }
            let marker = "/" + relative
            if hostile.contains(where: { marker.contains($0) }) { continue }
            reported.append("\(relative): \(location)")
        }
        print("active-content corpus walk: \(walked) PDFs opened under \(root) (\(unparseable) not parseable by CoreGraphics, skipped); clean documents reported: \(reported.count)")
        #expect(reported.isEmpty,
                "clean corpus documents the widened guard would refuse:\n  \(reported.joined(separator: "\n  "))")
    }
}

// MARK: - Fixtures

extension TestFixtures {

    /// One blank page with extras spliced into the catalog and the page
    /// dictionary, plus any extra objects (numbered from 5).
    static func activeContentProbe(
        catalogExtras: String = "", pageExtras: String = "",
        extraObjects: [PDFObject] = []
    ) -> Data {
        buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R \(catalogExtras) >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << >> \(pageExtras) >>
                """),
            PDFObject(id: 4, content: "<< /Length 0 >>\nstream\n\nendstream"),
        ] + extraObjects, rootId: 1)
    }

    /// Object 5: a JavaScript action.
    static var javaScriptActionObject: PDFObject {
        PDFObject(id: 5, content: "<< /Type /Action /S /JavaScript /JS (app.alert\\('probe'\\)) >>")
    }

    static func withNamesJavaScript() -> Data {
        activeContentProbe(
            catalogExtras: "/Names << /JavaScript << /Names [(onOpen) 5 0 R] >> >>",
            extraObjects: [javaScriptActionObject])
    }

    static func withNamesEmbeddedFilesOnly() -> Data {
        activeContentProbe(catalogExtras: "/Names << /EmbeddedFiles << /Names [] >> >>")
    }

    static func withOpenActionJavaScript() -> Data {
        activeContentProbe(catalogExtras: "/OpenAction 5 0 R",
                           extraObjects: [javaScriptActionObject])
    }

    static func withOpenActionChainedJavaScript() -> Data {
        activeContentProbe(
            catalogExtras: "/OpenAction << /Type /Action /S /GoTo /D [3 0 R /Fit] /Next 5 0 R >>",
            extraObjects: [javaScriptActionObject])
    }

    static func withOpenActionDestination() -> Data {
        activeContentProbe(catalogExtras: "/OpenAction [3 0 R /Fit]")
    }

    static func withOpenActionGoTo() -> Data {
        activeContentProbe(catalogExtras: "/OpenAction << /Type /Action /S /GoTo /D [3 0 R /Fit] >>")
    }

    /// `hops` GoTo actions chained by /Next, then the JavaScript action.
    static func withOpenActionDeepChain(hops: Int) -> Data {
        var objects: [PDFObject] = [javaScriptActionObject]
        // Objects 6…(5 + hops): hop k points at hop k + 1; the last hop
        // points at the JavaScript action (object 5).
        for k in 0..<hops {
            let id = 6 + k
            let next = (k == hops - 1) ? 5 : id + 1
            objects.append(PDFObject(
                id: id, content: "<< /Type /Action /S /GoTo /D [3 0 R /Fit] /Next \(next) 0 R >>"))
        }
        return activeContentProbe(catalogExtras: "/OpenAction 6 0 R", extraObjects: objects)
    }

    static func withPageAdditionalActionJavaScript() -> Data {
        activeContentProbe(pageExtras: "/AA << /O 5 0 R >>",
                           extraObjects: [javaScriptActionObject])
    }

    static func withPageAdditionalActionGoTo() -> Data {
        activeContentProbe(pageExtras: "/AA << /O << /Type /Action /S /GoTo /D [3 0 R /Fit] >> >>")
    }

    static func withAnnotationActionJavaScript() -> Data {
        activeContentProbe(
            pageExtras: "/Annots [6 0 R]",
            extraObjects: [
                javaScriptActionObject,
                PDFObject(id: 6, content: "<< /Type /Annot /Subtype /Link /Rect [72 700 172 730] /A 5 0 R >>"),
            ])
    }

    static func withAnnotationActionURI() -> Data {
        activeContentProbe(
            pageExtras: "/Annots [6 0 R]",
            extraObjects: [
                PDFObject(id: 6, content: """
                    << /Type /Annot /Subtype /Link /Rect [72 700 172 730] \
                    /A << /Type /Action /S /URI /URI (https://example.invalid/) >> >>
                    """),
            ])
    }

    static func withWidgetAdditionalActionJavaScript() -> Data {
        activeContentProbe(
            pageExtras: "/Annots [6 0 R]",
            extraObjects: [
                javaScriptActionObject,
                PDFObject(id: 6, content: """
                    << /Type /Annot /Subtype /Widget /FT /Tx /T (field) \
                    /Rect [72 600 272 630] /AA << /F 5 0 R >> >>
                    """),
            ])
    }
}
