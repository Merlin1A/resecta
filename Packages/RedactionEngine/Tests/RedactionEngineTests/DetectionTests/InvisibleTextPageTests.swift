import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

// A Searchable run's page whose content shows text in an invisible render
// mode (3 or 7) is written as an image only, with its own reason; a page
// whose content could not be read is written as an image only with the
// fault's reason, never the invisible-text reason; a page that sets the mode
// and unsets it with no text shown stays Searchable. Each page goes through
// the runner's page loop (`buildPages`, which calls the one page mode
// decision) and the production export; a picture page's file holds no
// text-showing operator. Every page is given rich text, so it reaches the
// test.
// The mode is read as any PDF number; a form's own saves and restores stay
// inside it. Where that matters, Quartz draws the page too, and the case says
// whether the line shows ink.

@Suite("A page that shows invisible text is a picture")
struct InvisibleTextPageTests {

    typealias Reason = TextLayerDetector.FallbackReason
    typealias Runner = VerificationCorpusRunnerTests

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let make: @Sendable () -> Data
        let reading: InvisibleTextReading
        let mode: PipelineMode
        let reason: Reason?
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "a hidden layer over a scan, mode 3", make: { TestFixtures.vendorLayerOverScanPDF() },
             reading: .shows, mode: .secureRasterization, reason: .invisibleText),
        Case(name: "a hidden layer over a scan, mode 7", make: { TestFixtures.layerOverScanPDF(mode: 7) },
             reading: .shows, mode: .secureRasterization, reason: .invisibleText),
        Case(name: "an invisible layer on its ink, mode 3", make: { TestFixtures.layerOverScanPDF(mode: 3, drift: 0) },
             reading: .shows, mode: .secureRasterization, reason: .invisibleText),
        Case(name: "an invisible layer 5 pt off its ink, mode 3", make: { TestFixtures.layerOverScanPDF(mode: 3, drift: 5) },
             reading: .shows, mode: .secureRasterization, reason: .invisibleText),
        Case(name: "an invisible layer 2 pt off its ink, mode 3", make: { TestFixtures.layerOverScanPDF(mode: 3, drift: 2) },
             reading: .shows, mode: .secureRasterization, reason: .invisibleText),
        Case(name: "an invisible layer 8 pt off its ink, mode 3", make: { TestFixtures.layerOverScanPDF(mode: 3, drift: 8) },
             reading: .shows, mode: .secureRasterization, reason: .invisibleText),
        Case(name: "one invisible word on a typed page", make: { TestFixtures.typedPageWithOneInvisibleWordPDF() },
             reading: .shows, mode: .secureRasterization, reason: .invisibleText),
        Case(name: "invisible text inside a form object", make: { TestFixtures.invisibleTextInFormPDF() },
             reading: .shows, mode: .secureRasterization, reason: .invisibleText),
        Case(name: "nine form objects nested one inside the next: content that could not be read",
             make: { TestFixtures.plainNestedFormsPDF(depth: 9) },
             reading: .unreadable, mode: .secureRasterization, reason: .extractionFailed),
        Case(name: "the mode set and unset with no text shown", make: { TestFixtures.invisibleModeSetAndUnsetPDF() },
             reading: .showsNone, mode: .searchableRedaction, reason: nil),
        Case(name: "one invisible word whose mode is written as the real number 3.0",
             make: { TestFixtures.typedPageWithOneInvisibleWordPDF(operand: "3.0") },
             reading: .shows, mode: .secureRasterization, reason: .invisibleText),
        Case(name: "a mode given as a name, not a number: content that could not be read",
             make: { TestFixtures.modeNotANumberPDF() },
             reading: .unreadable, mode: .secureRasterization, reason: .extractionFailed),
        Case(name: "a form that saves the state and never restores it, inside a save the page restores to mode 3",
             make: { TestFixtures.lineAfterPDF(prefix: "3 Tr q 0 Tr /Fx1 Do Q", form: "q") },
             reading: .shows, mode: .secureRasterization, reason: .invisibleText),
        Case(name: "a form that restores a state it never saved, drawn in mode 3",
             make: { TestFixtures.formInModeThreePDF(form: "Q BT /F1 10 Tf 72 480 Td (\(TestFixtures.invisibleLine)) Tj ET") },
             reading: .shows, mode: .secureRasterization, reason: .invisibleText),
        Case(name: "mode 3 set inside a save the page restores before its last line",
             make: { TestFixtures.lineAfterPDF(prefix: "q 3 Tr Q") },
             reading: .showsNone, mode: .searchableRedaction, reason: nil),
        Case(name: "a line in mode 7 with a fill painted through its clip: the words show",
             make: { TestFixtures.clipModeWithFillPDF() },
             reading: .shows, mode: .secureRasterization, reason: .invisibleText),
    ]

    @Test("The cases are sixteen, fourteen of them picture pages")
    func caseCount() {
        #expect(Self.cases.count == 16)
        #expect(Self.cases.filter { $0.mode == .secureRasterization }.count == 14)
    }

    struct Drawn: Sendable, CustomTestStringConvertible {
        let name: String
        let make: @Sendable () -> Data
        let inks: Bool
        var testDescription: String { name }
    }

    /// Pages whose line at 480 Quartz draws, or leaves without ink, as the
    /// reading above says: the reading follows the renderer.
    static let drawn: [Drawn] = [
        Drawn(name: "a word in mode 3", make: { TestFixtures.typedPageWithOneInvisibleWordPDF(operand: "3") }, inks: false),
        Drawn(name: "a word in mode 3.0", make: { TestFixtures.typedPageWithOneInvisibleWordPDF(operand: "3.0") }, inks: false),
        Drawn(name: "control: a word in mode 0.0", make: { TestFixtures.typedPageWithOneInvisibleWordPDF(operand: "0.0") }, inks: true),
        Drawn(name: "a form that saves and never restores, inside a save the page restores to mode 3",
              make: { TestFixtures.lineAfterPDF(prefix: "3 Tr q 0 Tr /Fx1 Do Q", form: "q") }, inks: false),
        Drawn(name: "a form that restores a state it never saved, drawn in mode 3",
              make: { TestFixtures.formInModeThreePDF(form: "Q BT /F1 10 Tf 72 480 Td (\(TestFixtures.invisibleLine)) Tj ET") },
              inks: false),
        Drawn(name: "mode 3 inside a save the page restores", make: { TestFixtures.lineAfterPDF(prefix: "q 3 Tr Q") }, inks: true),
        Drawn(name: "mode 7 with a fill through its clip", make: { TestFixtures.clipModeWithFillPDF() }, inks: true),
    ]

    @Test("Quartz draws the line at 480 with ink, or without, as listed", arguments: drawn)
    func quartzDraws(_ d: Drawn) throws {
        let doc = try #require(PDFDocument(data: d.make()))
        let cgPage = try #require(doc.page(at: 0)?.pageRef)
        let dark = try #require(Self.darkPixels(cgPage, band: 470...495), "\(d.name): the page could not be drawn")
        #expect((dark > 0) == d.inks, "\(d.name): \(dark) dark pixels between 470 and 495 pt")
    }

    /// Dark pixels (grey below 128) in the band `band` (points from the page's
    /// foot, x 60...560) when Quartz draws `page` at 1 px per point on white.
    static func darkPixels(_ page: CGPDFPage, band: ClosedRange<Int>) -> Int? {
        let (width, height) = (612, 792)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.drawPDFPage(page)
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        var dark = 0
        for y in band {
            let row = height - 1 - y
            for x in 60...560 where pixels[row * width + x] < 128 { dark += 1 }
        }
        return dark
    }

    @Test("Each page reads as listed, and the yes-or-no fact is yes for all but a page that shows none",
          arguments: cases)
    func reading(_ c: Case) throws {
        let doc = try #require(PDFDocument(data: c.make()))
        let cgPage = try #require(doc.page(at: 0)?.pageRef)
        #expect(InvisibleTextReading.read(cgPage) == c.reading, "\(c.name)")
        #expect(DocumentSearcher.showsInvisibleText(cgPage) == (c.reading != .showsNone), "\(c.name)")
    }

    @Test("Each page is written in its mode with its reason; a picture page's file holds no text operator",
          .timeLimit(.minutes(2)), arguments: cases)
    func exported(_ c: Case) async throws {
        let doc = try #require(PDFDocument(data: c.make()))
        let pages = Runner.buildPages(
            doc: doc, effectiveMode: .searchableRedaction, regionsByPage: [:],
            textLayerStatus: [0: .rich], hasHiddenOCG: false)
        let page = try #require(pages.first)
        #expect(page.pipelineMode == c.mode, "\(c.name): mode")
        #expect(page.fallbackReason == c.reason, "\(c.name): reason")

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("invisible-text-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try await ProductionPageLoop.runRedaction(pages: pages, outputURL: out)
        #expect(outcome.perPageModes == [c.mode], "\(c.name): written mode")
        #expect(outcome.perPageFallbackReasons == [c.reason], "\(c.name): recorded reason")
        let written = try #require(PDFDocument(url: out)?.page(at: 0)?.pageRef)
        let shown = Self.textOperators(written)
        if c.mode == .secureRasterization {
            #expect(shown == 0, "\(c.name): the picture page's file shows text \(shown) times")
        } else {
            #expect(shown > 0, "\(c.name): the Searchable page's file shows no text")
        }
    }

    @Test("The hidden-word check's leaking page (its case V1), through the app's own decision, is a picture with no text",
          .timeLimit(.minutes(2)))
    func hiddenWordCasePageIsAPicture() async throws {
        typealias F = HiddenWordInkFixtures
        let doc = try #require(PDFDocument(data: F.seededPage(drift: 30)))
        let box = RedactionRegion(id: UUID(), normalizedRect: F.inkRect(line: 5, phrase: "Marisol", through: "Vance-Oduya"),
                                  source: .manual)
        let pages = Runner.buildPages(
            doc: doc, effectiveMode: .searchableRedaction, regionsByPage: [0: [box]],
            textLayerStatus: [0: .rich], hasHiddenOCG: false)
        let page = try #require(pages.first)
        #expect(page.pipelineMode == .secureRasterization)
        #expect(page.fallbackReason == .invisibleText)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("invisible-text-v1-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try await ProductionPageLoop.runRedaction(pages: pages, outputURL: out)
        #expect(outcome.perPageFallbackReasons == [.invisibleText])
        let written = try #require(PDFDocument(url: out)?.page(at: 0))
        #expect(Self.textOperators(try #require(written.pageRef)) == 0)
        let writtenText = written.string ?? ""
        #expect(writtenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// The text-showing operators (`Tj`, `TJ`, `'`, `"`) in a page's content
    /// and in every form object it draws, to a depth of 8.
    static func textOperators(_ page: CGPDFPage) -> Int {
        final class Count { var n = 0; var depth = 0; var table: CGPDFOperatorTableRef? }
        guard let table = CGPDFOperatorTableCreate() else { return -1 }
        defer { CGPDFOperatorTableRelease(table) }
        let show: CGPDFOperatorCallback = { _, info in
            guard let info else { return }
            Unmanaged<Count>.fromOpaque(info).takeUnretainedValue().n += 1
        }
        for op in ["Tj", "TJ", "'", "\""] { CGPDFOperatorTableSetCallback(table, op, show) }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let info else { return }
            let count = Unmanaged<Count>.fromOpaque(info).takeUnretainedValue()
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name, count.depth < 8, let table = count.table else { return }
            let content = CGPDFScannerGetContentStream(scanner)
            var stream: CGPDFStreamRef?
            guard let object = CGPDFContentStreamGetResource(content, "XObject", name),
                  CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
                  String(cString: subtype) == "Form" else { return }
            var resources: CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
            let inner = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, content)
            let innerScanner = CGPDFScannerCreate(inner, table, info)
            count.depth += 1
            _ = CGPDFScannerScan(innerScanner)
            count.depth -= 1
            CGPDFScannerRelease(innerScanner)
            CGPDFContentStreamRelease(inner)
        }
        let count = Count()
        count.table = table
        let content = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(count).toOpaque())
        _ = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(content)
        return count.n
    }
}
