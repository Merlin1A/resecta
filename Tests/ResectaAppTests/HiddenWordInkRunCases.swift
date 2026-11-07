import Testing
import Foundation
import CoreGraphics
import CoreText
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// Frozen app-side cases for the hidden-word check, written before the check.
//
// V15 runs a page through the app's own run (`runFullPipeline`, so the pages
// are built by `RunInputs.pageData`) and reads the masthead. The page is the
// seeded scan, its layer drifted 4 pt, with a two-word line "Approved:
// Okafor" and a Search box applied over "Okafor". An applied Search box keeps
// the page's text layer, so the export keeps "Approved:" beside the box, the
// line's only anchor: the check cannot place it, so it must read not
// inspected, and the masthead must read "Some Checks Incomplete" for this
// check's row alone. A precondition case pins that today the same run keeps
// the layer and no row could not verify. If the run stops keeping that page's
// layer, V15 is a design question, not a case to re-scope.
//
// V15 (pair) builds the same export directly (the rasterizer and the writer)
// and runs the verifier and the masthead on it.
//
// The cross-check runs the seeded page with its layer drifted 30 pt through
// the app's run, for each box the run either strips by ink or sends to the
// image-only floor: the check reads pass or a note where the run kept the
// layer, and not applicable where it went to the floor; never a fail.

/// The check's `VerificationLayer` case. Not built: nil. The engine lane
/// returns the check's case here and changes nothing else in this file.
enum HiddenWordInkAppSeam {
    static var layer: VerificationLayer? { .hiddenWordInk }
}

@Suite("Hidden word check: the app's run (frozen cases)", .serialized, .tags(.coordination))
@MainActor
struct HiddenWordInkRunCases {

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
    /// V15's lines: the last line is two words.
    static let approvalLines: [String] = Array(seededLines.dropLast()) + ["Approved: Okafor"]
    static let fontSize: CGFloat = 14
    static let left: CGFloat = 72
    static func baseline(_ i: Int) -> CGFloat { 730 - 22 * CGFloat(i) }

    static func ctLine(_ text: String) -> CTLine {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes = [kCTFontAttributeName as String: font] as CFDictionary
        return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes)!)
    }

    static func inkRect(_ lines: [String], line i: Int, phrase: String, through last: String? = nil) -> CGRect {
        let text = lines[i], line = ctLine(text), ns = text as NSString
        let start = ns.range(of: phrase), end = last.map { ns.range(of: $0) } ?? start
        let x0 = CTLineGetOffsetForStringIndex(line, start.location, nil)
        let x1 = CTLineGetOffsetForStringIndex(line, end.location + end.length, nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let r = CGRect(x: left + x0, y: baseline(i) - descent, width: x1 - x0, height: ascent + descent)
        return CGRect(x: r.minX / 612, y: r.minY / 792, width: r.width / 612, height: r.height / 792)
    }

    /// The seeded scan (a noisy picture with the lines printed in it; the
    /// same lines as invisible text shifted `drift` pt along the line).
    static func page(_ lines: [String], drift: CGFloat) -> Data {
        let w = 1275, h = 1650
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
        var body = Data(capacity: w * h * 2 + 2)
        for p in pixels { body.append(hex[Int(p >> 4)]); body.append(hex[Int(p & 0xF)]) }
        body.append(contentsOf: Array(">".utf8))
        var stream = "q 612 0 0 792 0 0 cm /Im1 Do Q\n"
        for (i, text) in lines.enumerated() {
            stream += "BT 3 Tr /F1 \(Int(fontSize)) Tf \(left + drift) \(baseline(i)) Td (\(text)) Tj ET\n"
        }
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
                  + "/Resources << /Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >> >> >>").utf8),
            Data("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream".utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".utf8),
        ]
        var image = Data(("<< /Type /XObject /Subtype /Image /Width \(w) /Height \(h) /ColorSpace /DeviceGray "
                          + "/BitsPerComponent 8 /Filter /ASCIIHexDecode /Length \(body.count) >>\nstream\n").utf8)
        image.append(body); image.append(Data("\nendstream".utf8))
        objects.append(image)
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

    static func hiddenRect(_ page: PDFPage, _ word: String) -> CGRect? {
        let range = ((page.string ?? "") as NSString).range(of: word)
        guard range.location != NSNotFound, let sel = page.selection(for: range) else { return nil }
        return DocumentSearcher().normalizedRect(for: sel, page: page)
    }

    static func coordinator(_ data: Data) throws -> PipelineCoordinator {
        let coord = makeLoadedCoordinator(document: try #require(PDFDocument(data: data)))
        coord.documentState.textLayerStatus = [0: .rich]
        return coord
    }

    /// An applied Search box for `word`: its paint over the print, its strip
    /// the hidden copy's box (the box Search places on such a page).
    static func applySearch(_ coord: PipelineCoordinator, word: String, ink: CGRect) throws {
        let page = try #require(coord.documentState.sourceDocument?.page(at: 0))
        let strip = try #require(hiddenRect(page, word))
        let result = SearchResult(pageIndex: 0, normalizedRect: ink, matchedText: word, contextSnippet: "… \(word) …",
                                  source: .textLayer, term: word.lowercased(), isSelected: true, piiCategory: nil,
                                  textLayerRect: strip)
        let prepared = prepareApply(selected: [result], existingRectsByPage: [:], existingStripRectsByPage: [:],
                                    appliedAt: Date(), searchRecord: nil)
        for region in prepared.createdRegions[0] ?? [] { coord.redactionState.addRegion(region, page: 0, undoManager: nil) }
    }

    /// The app's run in Searchable, to its verified report.
    static func run(_ coord: PipelineCoordinator) async throws -> VerificationReport {
        coord.runFullPipeline(documentOverride: .searchableRedaction)
        let task = try #require(coord.documentState.activePipelineTask, "the run started")
        await task.value
        guard case .verified(let report) = coord.documentState.phase else {
            Issue.record("the run did not end verified: \(coord.documentState.phase)")
            throw CancellationError()
        }
        return report
    }

    static func approvalRun() async throws -> VerificationReport {
        let coord = try coordinator(page(approvalLines, drift: 4))
        try applySearch(coord, word: "Okafor", ink: inkRect(approvalLines, line: 23, phrase: "Okafor"))
        return try await run(coord)
    }

    // MARK: - V15

    @Test("V15 precondition: today the run keeps the page's layer and no check other than this one reads could-not-verify",
          .timeLimit(.minutes(3)))
    func v15Precondition() async throws {
        let report = try await Self.approvalRun()
        #expect(report.perPageModes == [.searchableRedaction], "the run keeps the page's text layer")
        let others = report.layers.filter { $0.couldNotVerify && $0.layer != HiddenWordInkAppSeam.layer }
        #expect(others.isEmpty, "no row other than this check's could not verify: \(others.map(\.name))")
        #expect(!report.overallStatus.isFail && !report.overallStatus.isAttention)
    }

    @Test("V15: through the app's run, a word beside the box that cannot be placed reads Some Checks Incomplete, from this check",
          .timeLimit(.minutes(3)))
    func v15() async throws {
        let report = try await Self.approvalRun()
        #expect(report.perPageModes == [.searchableRedaction], "STOP if not: the run no longer keeps this page's layer")
        #expect(VerificationResultsView.mastheadTitle(report: report) == "Some Checks Incomplete")
        let layer = try #require(HiddenWordInkAppSeam.layer, "the check is not built")
        #expect(report.layers.filter(\.couldNotVerify).map(\.layer) == [layer],
                "the check's row is the one that could not verify")
    }

    @Test("V15 (pair): the same export, built directly and verified, reads Some Checks Incomplete, from this check",
          .timeLimit(.minutes(3)))
    func v15Pair() async throws {
        let data = Self.page(Self.approvalLines, drift: 4)
        let source = try #require(PDFDocument(data: data))
        let page = try #require(source.page(at: 0))
        let cgPage = try #require(page.pageRef)
        let region = RedactionRegion(id: UUID(), normalizedRect: Self.inkRect(Self.approvalLines, line: 23, phrase: "Okafor"),
                                     source: .searchMatch(term: "okafor"),
                                     textLayerRect: try #require(Self.hiddenRect(page, "Okafor")), textAnchored: true)
        let pageData = PDFPageData(page: page, pageIndex: 0, regions: [region], fillColor: .black, targetDPI: 300,
                                   pipelineMode: .searchableRedaction, rotation: page.rotation,
                                   cropBoxBounds: page.bounds(for: .cropBox), cgPage: cgPage,
                                   hasText: page.string?.isEmpty == false)
        let raster = try await PageRasterizer().rasterize(pageData)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hidden-word-pair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tempURL = dir.appendingPathComponent("recon.pdf"), outputURL = dir.appendingPathComponent("output.pdf")
        let reconstructor = PDFStreamReconstructor(tempURL: tempURL)
        try await reconstructor.begin(firstPageSize: page.bounds(for: .cropBox).size)
        try await reconstructor.appendPage(raster.pageOutput)
        await reconstructor.finalize()
        try FileManager.default.moveItem(at: tempURL, to: outputURL)
        let output = try #require(PDFDocument(url: outputURL))
        #expect((output.page(at: 0)?.string ?? "").contains("Approved"), "precondition: the export keeps the line's other word")

        let report = try await VerificationOrchestrator().run(
            outputDocument: SendablePDFDocument(output), sourcePageCount: 1, regions: [0: [region]],
            sensitiveTerms: [SensitiveTerm(text: "Okafor", requiresTokenBoundary: false)],
            pipelineMode: .searchableRedaction, filterDigests: [raster.filterDigest],
            perPageModes: [.searchableRedaction], perPageFallbackReasons: [raster.fallbackReason],
            appliedSearches: [], sourceDocument: SendablePDFDocument(source),
            provisionLayerDocuments: { _ in nil }, events: { _ in })
        #expect(VerificationResultsView.mastheadTitle(report: report) == "Some Checks Incomplete")
        let layer = try #require(HiddenWordInkAppSeam.layer, "the check is not built")
        #expect(report.layers.filter(\.couldNotVerify).map(\.layer) == [layer])
    }

    // MARK: - The cross-check over the strip-by-ink cells

    @Test("Cross-check: through the app's run, the check passes or notes where the run kept the layer, and is not applicable at the floor",
          .timeLimit(.minutes(6)))
    func crossCheck() async throws {
        let lines = Self.seededLines
        let data = Self.page(lines, drift: 30)
        func check(_ id: String, kept: Bool, setUp: (PipelineCoordinator) throws -> Void) async throws {
            let coord = try Self.coordinator(data)
            try setUp(coord)
            let report = try await Self.run(coord)
            #expect(report.perPageModes == [kept ? .searchableRedaction : .secureRasterization],
                    "\(id): precondition, the run \(kept ? "keeps the layer" : "goes to the floor")")
            guard let layer = HiddenWordInkAppSeam.layer else {
                Issue.record("\(id): the check is not built")
                return
            }
            let row = try #require(report.layers.first { $0.layer == layer }, "\(id): the report carries the check's row")
            if kept {
                #expect(row.status == .pass || row.status.isInfo, "\(id): \(row.status)")
            } else {
                #expect(row.status.isNotApplicable, "\(id): \(row.status)")
            }
            #expect(!row.status.isFail, "\(id): a fail here is a STOP")
        }
        func hand(_ rect: CGRect) -> (PipelineCoordinator) throws -> Void {
            { $0.redactionState.addRegion(RedactionRegion(id: UUID(), normalizedRect: rect, source: .manual),
                                          page: 0, undoManager: nil) }
        }
        try await check("P4 name", kept: true, setUp: hand(Self.inkRect(lines, line: 5, phrase: "Marisol", through: "Vance-Oduya")))
        try await check("P9 narrow first word", kept: true, setUp: hand(Self.inkRect(lines, line: 0, phrase: "The")))
        try await check("P6 short word", kept: false, setUp: hand(Self.inkRect(lines, line: 11, phrase: "Lee")))
        try await check("P8 first word", kept: false, setUp: hand(Self.inkRect(lines, line: 11, phrase: "Signed")))
        try await check("P7 widened Search box", kept: false) { coord in
            try Self.applySearch(coord, word: "Signed", ink: Self.inkRect(lines, line: 11, phrase: "Signed"))
            let id = try #require(coord.redactionState.regions[0]?.first?.id)
            _ = coord.redactionState.resizeRegion(id, page: 0, newRect: Self.inkRect(lines, line: 11, phrase: "Signed", through: "Lee"),
                                                  undoManager: nil)
        }
    }
}
