import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import RedactionEngine

// What the searcher itself reports for each page it visits, read through the
// coverage sink of a real search: the picture fact and the layer fact on a
// page whose text was searched, and the empty-read answer of a page read by
// recognition, fresh and from the cache. The account folds these reports
// (AccountOfWhatWasReadTests); here they are the searcher's, not built by hand.

@Suite("The searcher's coverage reports", .tags(.search))
struct PageCoverageReportTests {

    static let page = CGSize(width: 612, height: 792)
    static let pointSize: CGFloat = 14
    /// Five lines of visible type, enough text that the census does not count
    /// a small picture on the page as image content.
    static let typed: [String] = [
        "The quarterly statement lists every payment made this period.",
        "Each line shows the date, the payee and the amount in dollars.",
        "Questions about a charge go to the number printed overleaf.",
        "Keep this page with your records for at least seven years.",
        "Totals are carried forward to the next statement in January.",
    ]

    /// A gray picture `width` by `height` pixels, white, with `lines` drawn in black.
    static func jpeg(width: Int, height: Int, lines: [String] = []) throws -> Data {
        let cs = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = CGFloat(width) / page.width
        ctx.scaleBy(x: scale, y: scale)
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        for (i, text) in lines.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
            ]
            ctx.textPosition = CGPoint(x: 72, y: 680 - CGFloat(i) * 48)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), ctx)
        }
        let image = try #require(ctx.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// One Letter page: `picture` (a JPEG, its pixel size, and where it is drawn in points), then
    /// `text` in render mode 0 (seen) or 3 (hidden).
    static func pdf(picture: (jpeg: Data, width: Int, height: Int, rect: CGRect)?, text: [String], hidden: Bool,
                    mediaBox: CGSize = page) -> Data {
        var objects: [Data] = []
        func add(_ s: String) -> Int { objects.append(Data(s.utf8)); return objects.count }
        func add(_ d: Data) -> Int { objects.append(d); return objects.count }
        func stream(_ dict: String, _ body: Data) -> Data {
            var d = Data("<< \(dict) /Length \(body.count) >>\nstream\n".utf8); d.append(body); d.append(Data("\nendstream".utf8)); return d
        }
        _ = add("<< /Type /Catalog /Pages 2 0 R >>")
        _ = add("<< /Type /Pages /Kids [6 0 R] /Count 1 >>")
        let font = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        var content = ""
        var xobjects = ""
        if let picture {
            let image = add(stream("/Type /XObject /Subtype /Image /Width \(picture.width) /Height \(picture.height) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", picture.jpeg))
            let r = picture.rect
            content += "q \(Int(r.width)) 0 0 \(Int(r.height)) \(Int(r.minX)) \(Int(r.minY)) cm /Im1 Do Q "
            xobjects = "/XObject << /Im1 \(image) 0 R >>"
        } else {
            _ = add("<< >>")
        }
        if !text.isEmpty {
            content += "\(hidden ? 3 : 0) Tr BT /F1 \(Int(pointSize)) Tf "
            for (i, line) in text.enumerated() { content += "1 0 0 1 72 \(680 - i * 48) Tm (\(line)) Tj " }
            content += "ET"
        }
        let contents = add(stream("", Data(content.utf8)))
        precondition(objects.count == 5)
        _ = add("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(Int(mediaBox.width)) \(Int(mediaBox.height))] /Contents \(contents) 0 R /Resources << \(xobjects) /Font << /F1 \(font) 0 R >> >> >>")
        var out = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (i, object) in objects.enumerated() {
            offsets.append(out.count)
            out.append(Data("\(i + 1) 0 obj\n".utf8)); out.append(object); out.append(Data("\nendobj\n".utf8))
        }
        let xref = out.count
        out.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for o in offsets { out.append(Data(String(format: "%010d 00000 n \n", o).utf8)) }
        out.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return out
    }

    /// Collects every report a search makes.
    final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [PageSearchCoverage] = []
        func record(_ c: PageSearchCoverage) { lock.lock(); list.append(c); lock.unlock() }
        var all: [PageSearchCoverage] { lock.lock(); defer { lock.unlock() }; return list }
    }

    /// The reports of one text search for `word` over `data`, on `searcher` (a fresh one by default).
    static func reports(_ data: Data, word: String = "statement", includeOCR: Bool,
                        on searcher: DocumentSearcher = DocumentSearcher()) async throws -> [PageSearchCoverage] {
        let document = try #require(PDFDocument(data: data))
        let reports = Reports()
        await searcher.setPageCoverageSink { reports.record($0) }
        var options = SearchOptions()
        options.includeOCR = includeOCR
        for await _ in searcher.search(SendablePDFDocument(document), mode: .text(word, options: options), progress: { _, _ in }) {}
        await searcher.setPageCoverageSink(nil)
        return reports.all
    }

    static var fullPage: CGRect { CGRect(origin: .zero, size: page) }

    /// Every report is `expected`, and there is at least one. A page may be reported
    /// more than once in a search (each report can only add a fact).
    static func only(_ reports: [PageSearchCoverage], _ expected: PageSearchCoverage) -> Bool {
        !reports.isEmpty && reports.allSatisfy { $0 == expected }
    }

    @Test("A typed page with no picture reports its text and nothing of pictures")
    func typedPage() async throws {
        let reports = try await Self.reports(Self.pdf(picture: nil, text: Self.typed, hidden: false), includeOCR: true)
        #expect(Self.only(reports, PageSearchCoverage(pageIndex: 0, route: .textLayer)), "\(reports)")
    }

    @Test("A typed page over a full-page picture reports pictures the rule requires, with recognition on or off")
    func fullPagePicture() async throws {
        let picture = (try Self.jpeg(width: 1275, height: 1650), 1275, 1650, Self.fullPage)
        for includeOCR in [true, false] {
            let reports = try await Self.reports(Self.pdf(picture: picture, text: Self.typed, hidden: false), includeOCR: includeOCR)
            #expect(reports.contains(PageSearchCoverage(pageIndex: 0, route: .textLayer, pictures: .required)), "recognition \(includeOCR)")
            #expect(!reports.contains { $0.throughAnotherAppsLayer }, "seen type is the page's own text")
        }
    }

    @Test("A typed page with a 600 by 300 logo reports pictures below the floors")
    func smallLogo() async throws {
        let logo = (try Self.jpeg(width: 600, height: 300), 600, 300, CGRect(x: 400, y: 720, width: 150, height: 50))
        let reports = try await Self.reports(Self.pdf(picture: logo, text: Self.typed, hidden: false), includeOCR: true)
        #expect(reports.contains(PageSearchCoverage(pageIndex: 0, route: .textLayer, pictures: .belowFloors)))
        #expect(!reports.contains { $0.pictures == .required })
    }

    @Test("Hidden text over a page-size picture reports another app's layer")
    func anotherAppsLayer() async throws {
        let scan = (try Self.jpeg(width: 1275, height: 1650, lines: Self.typed), 1275, 1650, Self.fullPage)
        for includeOCR in [true, false] {
            let reports = try await Self.reports(Self.pdf(picture: scan, text: Self.typed, hidden: true), includeOCR: includeOCR)
            #expect(reports.contains(PageSearchCoverage(pageIndex: 0, route: .textLayer, pictures: .required,
                                                        throughAnotherAppsLayer: true)), "recognition \(includeOCR)")
        }
    }

    @Test("A scanned page recognition reads no line on reports an empty read, as ink while no floor is set; the cache reports the same")
    func emptyRead() async throws {
        #expect(PageInk.setting == nil, "while no floor is set an empty read is ink; a set floor changes this test")
        let blank = Self.pdf(picture: (try Self.jpeg(width: 1275, height: 1650), 1275, 1650, Self.fullPage), text: [], hidden: false)
        let searcher = DocumentSearcher()
        let fresh = try await Self.reports(blank, includeOCR: true, on: searcher)
        #expect(Self.only(fresh, PageSearchCoverage(pageIndex: 0, route: .ocr, emptyRead: .ink)), "\(fresh)")
        #expect(await searcher._testOCRCacheKeys == [0], "the second search reads the page from the cache")
        let cached = try await Self.reports(blank, includeOCR: true, on: searcher)
        #expect(cached == fresh)
    }

    @Test("C-06 through the searcher: a scanned page 60 inches wide is too large for recognition")
    func tooLarge() async throws {
        let wide = CGSize(width: 4320, height: 792)
        let scan = Self.pdf(picture: (try Self.jpeg(width: 1800, height: 330), 1800, 330, CGRect(origin: .zero, size: wide)),
                            text: [], hidden: false, mediaBox: wide)
        let reports = try await Self.reports(scan, includeOCR: true)
        #expect(Self.only(reports, PageSearchCoverage(pageIndex: 0, route: .ocrSkippedOversize)), "\(reports)")
    }

    @Test("The suite holds eight tests")
    func rowCount() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
        #expect(source.components(separatedBy: "\n    @Test(\"").count - 1 == 8)
    }

    @Test("A scanned page recognition reads lines on reports no empty read")
    func linesRead() async throws {
        let scan = Self.pdf(picture: (try Self.jpeg(width: 1275, height: 1650, lines: Self.typed), 1275, 1650, Self.fullPage),
                            text: [], hidden: false)
        let reports = try await Self.reports(scan, includeOCR: true)
        #expect(Self.only(reports, PageSearchCoverage(pageIndex: 0, route: .ocr)), "\(reports)")
    }
}
