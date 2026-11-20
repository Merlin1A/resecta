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
        Case(name: "an invisible layer 2 pt off its ink, mode 7", make: { TestFixtures.layerOverScanPDF(mode: 7, drift: 2) },
             reading: .shows, mode: .secureRasterization, reason: .invisibleText),
        Case(name: "an invisible layer 8 pt off its ink, mode 7", make: { TestFixtures.layerOverScanPDF(mode: 7, drift: 8) },
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
    ]

    @Test("The cases are ten, nine of them picture pages")
    func caseCount() {
        #expect(Self.cases.count == 10)
        #expect(Self.cases.filter { $0.mode == .secureRasterization }.count == 9)
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
