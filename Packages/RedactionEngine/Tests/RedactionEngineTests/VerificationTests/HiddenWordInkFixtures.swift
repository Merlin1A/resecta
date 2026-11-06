import Testing
import Foundation
import CoreGraphics
import CoreText
import PDFKit
@testable import RedactionEngine

// The pages behind the hidden-word layer cases, made in the test.
//
// The seeded page is a scan-like page: a 1275 × 1650 picture of grey noise
// (levels 150–230, a fixed seed) with the lines printed in it at x 72, and
// over it the same lines drawn as invisible Helvetica 14 pt text, shifted
// `drift` points along the line. Options give the plain twin (visible text,
// no picture), a rotated page with an offset crop box, and other lines.
//
// The leaking outputs come from the corpus mirror's route
// (`VerificationCorpusRunnerTests.buildPages` → `runRedaction` →
// `runVerificationSweep`), not from the app's run: the mirror builds its
// pages without the app's page bridge, so a box over a word's print strips
// only the hidden glyphs under the box and the word's drifted copy stays in
// the export. That is the export the check exists to stop.

enum HiddenWordInkFixtures {
    private typealias Mirror = VerificationCorpusRunnerTests

    static let seededLines: [String] = [
        "The review below covers the second quarter of the year.",
        "Each section lists the work done and the work still open.",
        "Items marked done were checked against the original plan.",
        "Items still open carry a short note on what they wait for.",
        "Questions about this review go to the office named here.",
        "Contact Marisol Vance-Oduya about the file today.",
        "The file holds the plan, the notes and the final summary.",
        "Copies of the summary were sent to each team last week.",
        "Each team read the summary and answered within five days.",
        "The answers are kept with the file for the next review.",
        "Nothing in this review changes the plan for next quarter.",
        "Signed by Lee on the date below.",
        "The next review is planned for the start of next quarter.",
        "It will follow the same order as this one and the last.",
        "Each team will be asked for its notes two weeks before.",
        "The office will send a short reminder one week before.",
        "Late notes are added to the file when they arrive.",
        "The summary is shared once all notes are in the file.",
        "Teams may ask for a short meeting after the summary.",
        "Meetings are held in the main room unless noted.",
        "A record of each meeting is added to the same file.",
        "The file is kept for three years after the review.",
        "After three years the file moves to the long store.",
        "This page ends the review for the second quarter.",
    ]
    static let fontSize: CGFloat = 14
    static let left: CGFloat = 72
    static func baseline(_ i: Int) -> CGFloat { 730 - 22 * CGFloat(i) }

    /// The words no part of the check's output may carry (V14).
    static let distinctiveWords = ["Marisol", "Vance", "Oduya", "uya", "Signed", "Lee"]

    static func ctLine(_ text: String) -> CTLine {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes = [kCTFontAttributeName as String: font] as CFDictionary
        return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes)!)
    }

    /// The printed ink box of `phrase` on line `i`, normalized, bottom-left
    /// origin, on an unrotated 612 × 792 page.
    static func inkRect(line i: Int, phrase: String, through last: String? = nil,
                        lines: [String] = seededLines) -> CGRect {
        let text = lines[i], line = ctLine(text), ns = text as NSString
        let start = ns.range(of: phrase), end = last.map { ns.range(of: $0) } ?? start
        let x0 = CTLineGetOffsetForStringIndex(line, start.location, nil)
        let x1 = CTLineGetOffsetForStringIndex(line, end.location + end.length, nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let r = CGRect(x: left + x0, y: baseline(i) - descent, width: x1 - x0, height: ascent + descent)
        return CGRect(x: r.minX / 612, y: r.minY / 792, width: r.width / 612, height: r.height / 792)
    }

    /// The seeded page. `plain`: the lines drawn as visible text with no
    /// picture. `rotate` and `cropBox`: the page's /Rotate and /CropBox.
    static func seededPage(drift: CGFloat, lines: [String] = seededLines, plain: Bool = false,
                           rotate: Int = 0, cropBox: CGRect? = nil) -> Data {
        let w = 1275, h = 1650
        var body = Data()
        if !plain {
            var pixels = [UInt8](repeating: 0, count: w * h)
            var state: UInt64 = 20_261_105
            for k in 0..<(w * h) {
                state &+= 0x9E3779B97F4A7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                z ^= z >> 31
                pixels[k] = UInt8(150 + Int(z % 81))
            }
            pixels.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                ctx.scaleBy(x: CGFloat(w) / 612, y: CGFloat(h) / 792)
                ctx.setFillColor(gray: 0.05, alpha: 1)
                ctx.textMatrix = .identity
                for (i, text) in lines.enumerated() {
                    ctx.textPosition = CGPoint(x: left, y: baseline(i))
                    CTLineDraw(ctLine(text), ctx)
                }
            }
            let hex = Array("0123456789ABCDEF".utf8)
            body.reserveCapacity(w * h * 2 + 2)
            for p in pixels { body.append(hex[Int(p >> 4)]); body.append(hex[Int(p & 0xF)]) }
            body.append(contentsOf: Array(">".utf8))
        }
        var stream = plain ? "" : "q 612 0 0 792 0 0 cm /Im1 Do Q\n"
        for (i, text) in lines.enumerated() {
            stream += "BT \(plain ? 0 : 3) Tr /F1 \(Int(fontSize)) Tf \(left + (plain ? 0 : drift)) \(baseline(i)) Td (\(text)) Tj ET\n"
        }
        var pageDict = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
        if rotate != 0 { pageDict += "/Rotate \(rotate) " }
        if let c = cropBox { pageDict += "/CropBox [\(c.minX) \(c.minY) \(c.maxX) \(c.maxY)] " }
        pageDict += plain ? "/Resources << /Font << /F1 5 0 R >> >> >>"
            : "/Resources << /Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >> >> >>"
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data(pageDict.utf8),
            Data("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream".utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".utf8),
        ]
        if !plain {
            var image = Data(("<< /Type /XObject /Subtype /Image /Width \(w) /Height \(h) /ColorSpace /DeviceGray "
                              + "/BitsPerComponent 8 /Filter /ASCIIHexDecode /Length \(body.count) >>\nstream\n").utf8)
            image.append(body); image.append(Data("\nendstream".utf8))
            objects.append(image)
        }
        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (i, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(i + 1) 0 obj\n".utf8)); pdf.append(object); pdf.append(Data("\nendobj\n".utf8))
        }
        let xref = pdf.count
        var tail = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { tail += String(format: "%010d 00000 n \n", offset) }
        tail += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(tail.utf8))
        return pdf
    }

    /// The box of `word`'s hidden copy on the source page (the page's own
    /// selection of it), normalized in the frame `RedactionRegion` uses.
    static func hiddenRect(_ page: PDFPage, _ word: String) -> CGRect? {
        let range = ((page.string ?? "") as NSString).range(of: word)
        guard range.location != NSNotFound, let sel = page.selection(for: range) else { return nil }
        return DocumentSearcher().normalizedRect(for: sel, page: page)
    }

    /// A copy of `data` that opens locked (a user password).
    static func lockedCopy(_ data: Data) throws -> Data {
        let doc = try #require(PDFDocument(data: data))
        let out = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: out as CFMutableData))
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let options = [kCGPDFContextUserPassword as String: "case-user", kCGPDFContextOwnerPassword as String: "case-owner"]
        let ctx = try #require(CGContext(consumer: consumer, mediaBox: &box, options as CFDictionary))
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.pageRef else { continue }
            ctx.beginPDFPage(nil); ctx.drawPDFPage(page); ctx.endPDFPage()
        }
        ctx.closePDF()
        return out as Data
    }

    /// One run through the corpus mirror's route: the export and its report.
    struct Run {
        let source: PDFDocument
        let output: PDFDocument
        let region: RedactionRegion
        let report: VerificationReport
    }

    /// A box at `paint` (a hand box, or a Search box for `searchTerm` with its
    /// hidden-glyph `strip`) on page 1 of `data`, exported in `mode` through the
    /// mirror's route and verified once.
    static func mirrorRun(_ data: Data, paint: CGRect, mode: PipelineMode = .searchableRedaction,
                          searchTerm: String? = nil, strip: CGRect? = nil) async throws -> Run {
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let region = searchTerm.map {
            RedactionRegion(id: UUID(), normalizedRect: paint, source: .searchMatch(term: $0), textLayerRect: strip)
        } ?? RedactionRegion(id: UUID(), normalizedRect: paint, source: .manual)
        let status: [Int: TextLayerStatus] = [0: TextLayerDetector.detectTextLayer(page)]
        let regionsByPage = [0: [region]]
        var terms: [SensitiveTerm] = []
        var withoutText = 0
        if let term = searchTerm {
            terms = [SensitiveTerm(text: term, requiresTokenBoundary: false)]
        } else {
            let seed = Mirror.RegionSeed(gtId: "case", value: "", category: "", page: 0, rect: paint)
            let manual = Mirror.manualRegionTerms(seeds: [seed], doc: doc, polygon: false, textLayerStatus: status)
            terms = manual.terms
            withoutText = manual.regionsWithoutText
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hidden-word-case-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outputURL = dir.appendingPathComponent("output.pdf")
        let pages = Mirror.buildPages(doc: doc, effectiveMode: mode, regionsByPage: regionsByPage,
                                      textLayerStatus: status, hasHiddenOCG: Mirror.documentHasHiddenOCG(doc))
        let outcome = try await Mirror.runRedaction(pages: pages, outputURL: outputURL)
        let report = try await Mirror.runVerificationSweep(
            outputURL: outputURL, sourcePageCount: doc.pageCount, regions: regionsByPage,
            sensitiveTerms: terms, effectiveMode: mode, filterDigests: outcome.filterDigests,
            perPageModes: outcome.perPageModes, perPageFallbackReasons: outcome.perPageFallbackReasons,
            appliedSearches: [Mirror.sweepRequest()], manualRegionsWithoutText: withoutText,
            sourceDocument: SendablePDFDocument(doc))
        let output = try #require(PDFDocument(url: outputURL))
        return Run(source: doc, output: output, region: region, report: report)
    }

    /// The text the export's page 1 still holds inside `rect` (normalized, in
    /// the page's visual frame, as `RedactionRegion` holds it): the leak a
    /// case's precondition looks for. On an unrotated page with its crop box
    /// at the origin, the rect is scaled by the page's size.
    static func textInside(_ output: PDFDocument, _ rect: CGRect) -> String {
        guard let page = output.page(at: 0) else { return "" }
        let points = pageSpaceRect(rect, page: page)
        return (page.selection(for: points)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A normalized visual-frame rect in the page's own (unrotated, absolute)
    /// space: the inverse of the crop-box translate and the /Rotate turn
    /// (clockwise, ISO 32000 §8.3.2), written out here rather than taken from
    /// the engine.
    static func pageSpaceRect(_ rect: CGRect, page: PDFPage) -> CGRect {
        let crop = page.bounds(for: .cropBox)
        let w = crop.width, h = crop.height
        let rotation = ((page.rotation % 360) + 360) % 360
        let turned = rotation == 90 || rotation == 270
        let vw = turned ? h : w, vh = turned ? w : h
        let v = CGRect(x: rect.minX * vw, y: rect.minY * vh, width: rect.width * vw, height: rect.height * vh)
        let local: CGRect
        switch rotation {
        case 90: local = CGRect(x: w - v.maxY, y: v.minX, width: v.height, height: v.width)
        case 180: local = CGRect(x: w - v.maxX, y: h - v.maxY, width: v.width, height: v.height)
        case 270: local = CGRect(x: v.minY, y: h - v.maxX, width: v.height, height: v.width)
        default: local = v
        }
        return local.offsetBy(dx: crop.minX, dy: crop.minY)
    }
}
