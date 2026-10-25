import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The page census: the largest image object a page reaches, and whether a
// page with a text layer carries image content. The corpus census at the end
// is a measurement harness, env-gated (RESECTA_IMAGE_CENSUS=1), never in the
// batched gate; it prints the table the floors were set from.
//
// Privacy rule (audit-lint M-1): locate/read/report vocabulary.

@Suite("Page image census", .tags(.search))
struct PageImageCensusTests {

    private static func page(_ data: Data) throws -> PDFPage {
        try #require(PDFDocument(data: data)?.page(at: 0))
    }

    @Test("The largest image object a page reaches, directly or through forms")
    func largestImage() throws {
        let stamped = try Self.page(TestFixtures.stampedScanPDF())
        #expect(PageImageCensus.largestImagePixelArea(of: try #require(stamped.pageRef)) == 1275 * 1650)
        let logo = try Self.page(TestFixtures.letterWithLogoPDF())
        #expect(PageImageCensus.largestImagePixelArea(of: try #require(logo.pageRef)) == 120 * 60)
        let nested = try Self.page(TestFixtures.imageInNestedFormsPDF(depth: 2))
        #expect(PageImageCensus.largestImagePixelArea(of: try #require(nested.pageRef)) == 1275 * 1650)
        let title = try Self.page(TestFixtures.shortTitlePagePDF())
        #expect(PageImageCensus.largestImagePixelArea(of: try #require(title.pageRef)) == nil)
        let blank = try Self.page(TestFixtures.blankPage())
        #expect(PageImageCensus.largestImagePixelArea(of: try #require(blank.pageRef)) == nil)
    }

    @Test("A form chain past the depth bound stops; a form that names itself ends the walk")
    func boundsAndCycles() throws {
        let deep = try Self.page(TestFixtures.imageInNestedFormsPDF(depth: PageImageCensus.maxFormDepth + 1))
        #expect(PageImageCensus.largestImagePixelArea(of: try #require(deep.pageRef)) == nil)
        let cyclic = try Self.page(TestFixtures.imageInNestedFormsPDF(depth: 2, selfReferencing: true))
        #expect(PageImageCensus.largestImagePixelArea(of: try #require(cyclic.pageRef)) == 1275 * 1650)
    }

    @Test("Which pages carry image content")
    func carriesImageContent() throws {
        #expect(PageImageCensus.carriesImageContent(try Self.page(TestFixtures.stampedScanPDF())), "a page-scale scan")
        #expect(PageImageCensus.carriesImageContent(try Self.page(TestFixtures.vendorLayerOverScanPDF())), "a scan under a dense text layer")
        #expect(PageImageCensus.carriesImageContent(try Self.page(TestFixtures.stampedScanPDF(scanWidth: 300, scanHeight: 400))),
                "a scan placed small under a stamp-thin text layer")
        #expect(!PageImageCensus.carriesImageContent(try Self.page(TestFixtures.letterWithLogoPDF())), "a letter with a small logo")
        // An image pasted into a typed letter, below half the page: an ID at a
        // word processor's 220 ppi, a mail client's medium photo. A letterhead
        // logo below the pixel floor stays out.
        #expect(PageImageCensus.carriesImageContent(try Self.page(TestFixtures.letterWithImagePDF(width: 741, height: 469))),
                "a letter with a pasted ID (348k px)")
        #expect(PageImageCensus.carriesImageContent(try Self.page(TestFixtures.letterWithImagePDF(width: 640, height: 480))),
                "a letter with a pasted photo (307k px)")
        #expect(!PageImageCensus.carriesImageContent(try Self.page(TestFixtures.letterWithImagePDF(width: 600, height: 300))),
                "a letter with a letterhead logo (180k px)")
        #expect(!PageImageCensus.carriesImageContent(try Self.page(TestFixtures.shortTitlePagePDF())), "a short page with no image")
    }

    @Test("Search time on a typed letter with a pasted photo vs a logo (env-gated measurement)",
          .enabled(if: ProcessInfo.processInfo.environment["RESECTA_HYBRID_TIMING"] != nil))
    func hybridSearchTiming() async throws {
        var options = SearchOptions()
        options.includeOCR = true
        for (name, data) in [("logo 120x60", TestFixtures.letterWithLogoPDF()),
                             ("photo 741x469", TestFixtures.letterWithImagePDF(width: 741, height: 469))] {
            let doc = try #require(PDFDocument(data: data))
            var times: [Double] = []
            for _ in 0..<3 {
                let start = Date()
                for await _ in DocumentSearcher().search(SendablePDFDocument(doc), mode: .text("records", options: options), progress: { _, _ in }) {}
                times.append(Date().timeIntervalSince(start) * 1000)
            }
            print(String(format: "[HYBRID-TIMING] %@ · hybrid %@ · search ms %@", name,
                         "\(PageImageCensus.carriesImageContent(try #require(doc.page(at: 0))))",
                         times.map { String(format: "%.0f", $0) }.joined(separator: " / ")))
        }
    }

    @Test("Corpus census (env-gated): status, text density and the largest image per page",
          .enabled(if: ProcessInfo.processInfo.environment["RESECTA_IMAGE_CENSUS"] != nil))
    func corpusCensus() throws {
        let root = ProcessInfo.processInfo.environment["RESECTA_SAMPLE_DOC"] ?? (NSHomeDirectory() + "/resecta-sample-doc")
        var paths = ["packet.pdf", "capture-masters-2026-08.pdf", "sample-bank-statement.pdf"]
        for dir in ["variants", "t23"] {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: root + "/" + dir)) ?? []
            paths += items.filter { $0.hasSuffix(".pdf") }.sorted().map { "\(dir)/\($0)" }
        }
        var flipped = 0
        for path in paths {
            guard let doc = PDFDocument(url: URL(fileURLWithPath: root + "/" + path)) else { continue }
            for index in 0..<doc.pageCount {
                guard let page = doc.page(at: index) else { continue }
                let status = TextLayerDetector.detectTextLayer(page)
                let crop = page.bounds(for: .cropBox)
                let meaningful = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count
                let pixels = page.pageRef.flatMap(PageImageCensus.largestImagePixelArea(of:)) ?? 0
                let hybrid = status == .rich && PageImageCensus.carriesImageContent(page)
                if hybrid { flipped += 1 }
                print(String(format: "[IMAGE-CENSUS] %@ · p%d · %@ · %d · density %.1f · image share %.3f%@",
                             path, index + 1, "\(status)", meaningful,
                             PageImageCensus.textDensity(meaningfulCount: meaningful, cropBox: crop),
                             PageImageCensus.imageShare(pixelArea: pixels, cropBox: crop), hybrid ? " · HYBRID" : ""))
            }
        }
        print("[IMAGE-CENSUS] pages read on both legs: \(flipped)")
    }
}
