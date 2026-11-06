import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// A Searchable page keeps its text layer only when every box on it was placed
// from a match in that text layer and left where it was placed, or when the
// page is plain: it reaches no image, draws no inline image, shows no text in
// an invisible render mode and uses no Type 3 font. On any other page a box
// can cover printed words whose hidden copies sit beside it, outside the box,
// and the export would keep them; such a page is written as an image only.
//
// These run over `RunInputs.pageData`, the run's own page bridge
// (`TestHelpers.productionRun` in the engine tests builds its pages without it).

@Suite("Scanned page box floor")
@MainActor
struct ScannedPageBoxFloorTests {

    // MARK: - Pages

    /// One letter page from raw objects: the catalog, the page tree, the page
    /// (its content stream and resources), Helvetica, then `extra` from id 6.
    static func page(stream: String, resources: String, extra: [String] = []) -> PDFDocument {
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << \(resources) >> >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]
        objects += extra
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
        return PDFDocument(data: Data(out.utf8))!
    }

    static let lines = [
        "Account holder Delia Hartwell of Lakeport",
        "Statement period the second quarter of the year",
        "Questions about this statement go to the office",
    ]
    static func text(mode: Int = 0) -> String {
        lines.enumerated().map { "BT \(mode) Tr /F1 14 Tf 72 \(700 - 22 * $0.offset) Td (\($0.element)) Tj ET" }
            .joined(separator: "\n")
    }
    /// A 2 × 2 grey image object, hex-coded.
    static let image = "<< /Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray "
        + "/BitsPerComponent 8 /Filter /ASCIIHexDecode /Length 9 >>\nstream\n80C040A0>\nendstream"

    /// Typed text and a small picture (a logo).
    static func imagePage() -> PDFDocument {
        page(stream: "q 60 0 0 30 480 740 cm /Im1 Do Q\n" + text(), resources: "/Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >>",
             extra: [image])
    }
    /// A picture of the page under its text shown in render mode 3 (a scan made searchable).
    static func scanPage() -> PDFDocument {
        page(stream: "q 612 0 0 792 0 0 cm /Im1 Do Q\n" + text(mode: 3),
             resources: "/Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >>", extra: [image])
    }
    /// Text in render mode 3 with no image at all.
    static func invisibleTextPage() -> PDFDocument {
        page(stream: text() + "\nBT 3 Tr /F1 14 Tf 72 600 Td (Hidden line of text) Tj ET", resources: "/Font << /F1 5 0 R >>")
    }
    /// Typed text with one glyph set in a Type 3 font.
    static func type3Page() -> PDFDocument {
        let glyph = "1000 0 0 0 1000 1000 d1\n0 0 500 500 re f"
        return page(stream: text() + "\nBT /T3 14 Tf 72 600 Td (a) Tj ET",
                    resources: "/Font << /F1 5 0 R /T3 6 0 R >>",
                    extra: ["<< /Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] "
                            + "/CharProcs << /square 7 0 R >> /Encoding << /Type /Encoding /Differences [97 /square] >> "
                            + "/FirstChar 97 /LastChar 97 /Widths [1000] >>",
                            "<< /Length \(glyph.utf8.count) >>\nstream\n\(glyph)\nendstream"])
    }
    /// Typed text and a picture drawn inline in the content stream.
    static func inlineImagePage() -> PDFDocument {
        page(stream: "q 60 0 0 30 480 740 cm BI /W 2 /H 2 /CS /G /BPC 8 /F /AHx ID 80C040A0> EI Q\n" + text(),
             resources: "/Font << /F1 5 0 R >>")
    }
    /// Typed text alone.
    static func plainPage() -> PDFDocument {
        page(stream: text(), resources: "/Font << /F1 5 0 R >>")
    }

    // MARK: - Boxes

    /// The box over "Delia Hartwell"'s line position (normalized, bottom-left).
    static let ink = CGRect(x: 0.27, y: 0.880, width: 0.17, height: 0.022)
    static let strip = CGRect(x: 0.32, y: 0.880, width: 0.17, height: 0.022)

    static func hand(_ rect: CGRect = ink) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: rect, source: .manual)
    }

    static func match(_ source: SearchSource, strip: CGRect? = nil) -> SearchResult {
        SearchResult(pageIndex: 0, normalizedRect: ink, matchedText: "Delia Hartwell",
                     contextSnippet: "… Delia Hartwell …", source: source, term: "delia hartwell",
                     isSelected: true, piiCategory: nil, textLayerRect: strip)
    }

    /// A state holding the regions an Apply of `results` makes.
    static func applied(_ results: [SearchResult]) -> RedactionState {
        let state = RedactionState()
        let prepared = prepareApply(selected: results, existingRectsByPage: [:], existingStripRectsByPage: [:],
                                    appliedAt: Date(), searchRecord: nil)
        for region in prepared.createdRegions[0] ?? [] { state.addRegion(region, page: 0, undoManager: nil) }
        return state
    }

    // MARK: - The bridge

    static func settings() -> PipelineCoordinator.RunSettings {
        let name = "scanned-page-box-floor-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let snapshot = PipelineCoordinator.RunSettings.snapshot(from: SettingsState(defaults: defaults))
        defaults.removePersistentDomain(forName: name)
        return snapshot
    }

    /// The page's mode and fallback reason in a Searchable run.
    static func outcome(_ doc: PDFDocument, _ regions: [RedactionRegion]) -> PDFPageData {
        RunInputs.pageData(document: doc, regions: [0: regions], textLayerStatus: [0: .rich],
                           sourceHasHiddenOCG: false, settings: settings(), effectiveMode: .searchableRedaction)[0]
    }

    static func expectImageOnly(_ page: PDFPageData, _ comment: Comment) {
        #expect(page.pipelineMode == .secureRasterization, comment)
        #expect(page.fallbackReason != nil, "an image-only page states why")
    }

    static func expectKept(_ page: PDFPageData, _ comment: Comment) {
        #expect(page.pipelineMode == .searchableRedaction, comment)
        #expect(page.fallbackReason == nil, comment)
    }

    // MARK: - Image only

    @Test("a hand-drawn box on a page with a picture writes the page as an image")
    func handBoxOnImagePage() {
        Self.expectImageOnly(Self.outcome(Self.imagePage(), [Self.hand()]), "image page, hand box")
    }

    @Test("a hand-drawn box on a page with text in an invisible render mode writes the page as an image")
    func handBoxOnInvisibleTextPage() {
        Self.expectImageOnly(Self.outcome(Self.invisibleTextPage(), [Self.hand()]), "invisible text, hand box")
    }

    @Test("a hand-drawn box on a page with a Type 3 font writes the page as an image")
    func handBoxOnType3Page() {
        Self.expectImageOnly(Self.outcome(Self.type3Page(), [Self.hand()]), "Type 3 font, hand box")
    }

    @Test("a hand-drawn box on a page with an inline picture writes the page as an image")
    func handBoxOnInlineImagePage() {
        Self.expectImageOnly(Self.outcome(Self.inlineImagePage(), [Self.hand()]), "inline image, hand box")
    }

    @Test("a duplicated box on a page with a picture writes the page as an image")
    func duplicateOnImagePage() throws {
        let state = Self.applied([Self.match(.textLayer)])
        let source = try #require(state.regions[0]?.first)
        state.duplicateRegion(source.id, page: 0, undoManager: nil)
        Self.expectImageOnly(Self.outcome(Self.imagePage(), state.regions[0] ?? []), "image page, a Duplicate beside a match")
    }

    @Test("a match resized by hand on a scanned page writes the page as an image")
    func resizedMatchOnScanPage() throws {
        let state = Self.applied([Self.match(.textLayer, strip: Self.strip)])
        let region = try #require(state.regions[0]?.first)
        #expect(state.resizeRegion(region.id, page: 0, newRect: Self.ink.insetBy(dx: -0.05, dy: 0), undoManager: nil))
        Self.expectImageOnly(Self.outcome(Self.scanPage(), state.regions[0] ?? []), "scan page, resized match")
    }

    @Test("a match moved by hand on a page with a picture writes the page as an image")
    func movedMatchOnImagePage() throws {
        let state = Self.applied([Self.match(.textLayer)])
        let region = try #require(state.regions[0]?.first)
        #expect(state.moveRegion(region.id, page: 0, newRect: Self.ink.offsetBy(dx: 0, dy: -0.03), undoManager: nil))
        Self.expectImageOnly(Self.outcome(Self.imagePage(), state.regions[0] ?? []), "image page, moved match")
    }

    @Test("matches moved together by hand on a page with a picture write the page as an image")
    func movedTogetherOnImagePage() throws {
        let state = Self.applied([Self.match(.textLayer)])
        let region = try #require(state.regions[0]?.first)
        #expect(state.moveRegions([(id: region.id, newRect: Self.ink.offsetBy(dx: 0.01, dy: 0))], page: 0, undoManager: nil))
        Self.expectImageOnly(Self.outcome(Self.imagePage(), state.regions[0] ?? []), "image page, moved as a group")
    }

    @Test("a match read from the page's picture on a page with a picture writes the page as an image")
    func ocrMatchOnImagePage() {
        let state = Self.applied([Self.match(.ocr(confidence: 0.9))])
        Self.expectImageOnly(Self.outcome(Self.imagePage(), state.regions[0] ?? []), "image page, picture-read match")
    }

    @Test("one hand-drawn box beside a placed match on a page with a picture writes the page as an image")
    func anchoredAndHandOnImagePage() {
        let state = Self.applied([Self.match(.textLayer)])
        state.addRegion(Self.hand(CGRect(x: 0.1, y: 0.5, width: 0.1, height: 0.02)), page: 0, undoManager: nil)
        Self.expectImageOnly(Self.outcome(Self.imagePage(), state.regions[0] ?? []), "image page, match plus hand box")
    }

    // MARK: - Kept

    @Test("a hand-drawn box on a plain typed page keeps the text layer")
    func handBoxOnPlainPage() {
        Self.expectKept(Self.outcome(Self.plainPage(), [Self.hand()]), "plain page, hand box")
    }

    @Test("a match left where it was placed keeps the text layer on a page with a picture")
    func placedMatchOnImagePage() {
        let state = Self.applied([Self.match(.textLayer)])
        Self.expectKept(Self.outcome(Self.imagePage(), state.regions[0] ?? []), "image page, placed match")
    }

    @Test("a match with its hidden glyphs' box, left where it was placed, keeps the text layer on a scanned page")
    func placedStripMatchOnScanPage() {
        let state = Self.applied([Self.match(.textLayer, strip: Self.strip)])
        Self.expectKept(Self.outcome(Self.scanPage(), state.regions[0] ?? []), "scan page, placed match with strip")
    }

    @Test("a box over the whole page keeps the text layer: it removes every glyph")
    func wholePageOnImagePage() {
        let whole = Self.hand(CGRect(x: 0, y: 0, width: 1, height: 1))
        Self.expectKept(Self.outcome(Self.imagePage(), [whole]), "image page, whole-page box")
    }

    @Test("a page with a picture and no box keeps the text layer")
    func noBoxOnImagePage() {
        Self.expectKept(Self.outcome(Self.imagePage(), []), "image page, no box")
    }

    @Test("a match resized and then put back by Undo keeps the text layer")
    func resizeUndoneOnScanPage() throws {
        let state = Self.applied([Self.match(.textLayer, strip: Self.strip)])
        let region = try #require(state.regions[0]?.first)
        let undo = makeUndoManager()
        withUndoGroup(undo) {
            _ = state.resizeRegion(region.id, page: 0, newRect: Self.ink.insetBy(dx: -0.05, dy: 0), undoManager: undo)
        }
        undo.undo()
        #expect(state.regions[0]?.first?.normalizedRect == Self.ink)
        Self.expectKept(Self.outcome(Self.scanPage(), state.regions[0] ?? []), "scan page, resize undone")
    }

    @Test("a Secure run writes every page as an image and states no reason, whatever its boxes")
    func secureRunUnchanged() {
        let page = RunInputs.pageData(document: Self.imagePage(), regions: [0: [Self.hand()]], textLayerStatus: [0: .rich],
                                      sourceHasHiddenOCG: false, settings: Self.settings(),
                                      effectiveMode: .secureRasterization)[0]
        #expect(page.pipelineMode == .secureRasterization)
        #expect(page.fallbackReason == nil)
    }
}
