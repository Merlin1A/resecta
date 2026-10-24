import Testing
import Foundation
import PDFKit
import CoreText
@testable import RedactionEngine

// A text-layer box on a page whose text lies over a page-scale image covers the
// ink it names. The fixture is a Searchable export of the sample statement with
// "Sample" redacted: every page becomes a picture under a monospaced text layer
// on a snapped grid, the shape an earlier export left on a user's device, whose
// selection boxes sit low and to one side of the printed words. A search on the
// re-imported file must box every word's ink, whichever leg ran.
//
// Privacy rule (audit-lint M-1): locate/read/report vocabulary.

@Suite("Page-image ink fit", .tags(.search))
struct PageImageInkFitTests {

    /// The sample statement exported Searchable with every "Sample" redacted.
    static func reimportedExport() async throws -> (export: PDFDocument, source: PDFDocument) {
        let data = try TestFixtures.sampleStatementPDF()
        let source = try #require(PDFDocument(data: data))
        var regions: [Int: [RedactionRegion]] = [:]
        for hit in await hits(source, "Sample", includeOCR: false) {
            regions[hit.pageIndex, default: []].append(
                RedactionRegion(id: UUID(), normalizedRect: hit.normalizedRect, source: .manual))
        }
        let url = try await TestPipeline.processAndExport(data, mode: .searchableRedaction, regions: regions, dpi: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        let export = try #require(PDFDocument(data: try Data(contentsOf: url)))
        return (export, source)
    }

    static func hits(_ doc: PDFDocument, _ query: String, includeOCR: Bool) async -> [SearchResult] {
        var options = SearchOptions()
        options.includeOCR = includeOCR
        var out: [SearchResult] = []
        for await result in DocumentSearcher().search(SendablePDFDocument(doc), mode: .text(query, options: options), progress: { _, _ in }) {
            out.append(result)
        }
        return out
    }

    /// The word's own ink on `page` (a 300 dpi render, DeviceGray below the
    /// ink threshold), taken as the acceptance sweep takes it: from the
    /// columns inside `word` (visual points; a point in from each side), the
    /// inked rows through its middle (up to 8 pt each way), then the columns
    /// on those rows that continue its ink outward with no blank column (up
    /// to 2 pt), so a neighbouring glyph past a gap is not the word's ink.
    /// The share of that ink no box covers, and the farthest such pixel
    /// from the boxes in points. Measured in the page's reading frame, so a
    /// word on a turned page is followed along its line.
    static func inkOutside(_ page: PDFPage, word visualWord: CGRect, boxes visualBoxes: [CGRect]) throws -> (share: Double, reach: Double) {
        let bounds = page.bounds(for: .cropBox)
        let frame = DocumentSearcher.readingFrame(of: page, visual: bounds.size)
        let word = frame.toReading(visualWord), boxes = visualBoxes.map(frame.toReading)
        let window = word.insetBy(dx: -4, dy: -9).intersection(CGRect(origin: .zero, size: frame.size))
        let cgPage = try #require(page.pageRef)
        let bitmap = try #require(DocumentSearcher.renderGray(
            cgPage, rotation: page.rotation, visual: bounds.size, window: window, frame: frame))
        let s = DocumentSearcher.inkFitScale
        func px(_ v: CGFloat, _ origin: CGFloat) -> Int { Int(((v - origin) * s).rounded(.down)) }
        let cx0 = max(0, px(word.minX + 1, window.minX)), cx1 = min(bitmap.width - 1, px(word.maxX - 1, window.minX))
        guard cx1 > cx0 else { return (0, 0) }
        func rowHasInk(_ y: Int) -> Bool { (cx0...cx1).contains { bitmap.isInk($0, y) } }
        let mid = min(max(0, px(word.midY, window.minY)), bitmap.height - 1), lim = Int(8 * s)
        var y0 = mid, y1 = mid
        while y0 > 0, mid - y0 < lim, rowHasInk(y0 - 1) { y0 -= 1 }
        while y1 < bitmap.height - 1, y1 - mid < lim, rowHasInk(y1 + 1) { y1 += 1 }
        func columnHasInk(_ x: Int) -> Bool { (y0...y1).contains { bitmap.isInk(x, $0) } }
        var x0 = cx0, x1 = cx1
        while x0 > 0, cx0 - x0 < Int(2 * s), columnHasInk(x0 - 1) { x0 -= 1 }
        while x1 < bitmap.width - 1, x1 - cx1 < Int(2 * s), columnHasInk(x1 + 1) { x1 += 1 }
        var ink = 0, outside = 0, reach = 0.0
        for y in y0...y1 {
            for x in x0...x1 where bitmap.isInk(x, y) {
                ink += 1
                let point = CGPoint(x: window.minX + (CGFloat(x) + 0.5) / s, y: window.minY + (CGFloat(y) + 0.5) / s)
                guard !boxes.contains(where: { $0.contains(point) }) else { continue }
                outside += 1
                reach = max(reach, boxes.map { Double(hypot(max($0.minX - point.x, 0, point.x - $0.maxX),
                                                            max($0.minY - point.y, 0, point.y - $0.maxY))) }.min() ?? 0)
            }
        }
        return (ink == 0 ? 0 : Double(outside) / Double(ink), reach)
    }

    /// `fit` again while it comes back degraded (a degraded fit is never
    /// cached, so each try reads again), at most `tries` times: on a host
    /// busy with other text recognitions a read can wait out its bound
    /// (`VisionTextGate`), which these pins do not measure.
    static func settled<T>(tries: Int = 4, _ fit: () throws -> T?, degraded: (T) -> Bool) rethrows -> T? {
        var last: T?
        for _ in 0..<tries {
            last = try fit()
            if let last, !degraded(last) { return last }
        }
        return last
    }

    static func points(_ normalized: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: normalized.minX * size.width, y: normalized.minY * size.height,
               width: normalized.width * size.width, height: normalized.height * size.height)
    }

    @Test("Every match on a re-imported Searchable export covers its word's ink, on both legs", arguments: [false, true])
    func everyMatchCoversItsInk(includeOCR: Bool) async throws {
        let (export, source) = try await Self.reimportedExport()
        // The words' own boxes on the source, where the text is the ink.
        let truth = await Self.hits(source, "delia", includeOCR: false)
        let found = await Self.hits(export, "delia", includeOCR: includeOCR)
        #expect(truth.count == 9, "the statement names Delia nine times; got \(truth.count)")
        #expect(found.count == truth.count, "every word is found on the export; got \(found.count)")
        for (index, word) in truth.enumerated() {
            let page = try #require(export.page(at: word.pageIndex))
            let size = page.bounds(for: .cropBox).size
            let cgPage = try #require(page.pageRef)
            #expect(DocumentSearcher.carriesHiddenTextOverImage(page, cgPage: cgPage),
                    "the export's page \(word.pageIndex + 1) is a picture under a hidden text layer")
            let boxes = found.filter { $0.pageIndex == word.pageIndex }.map { Self.points($0.normalizedRect, size) }
            let outside = try Self.inkOutside(page, word: Self.points(word.normalizedRect, size), boxes: boxes)
            #expect(outside.share == 0,
                    "hit \(index + 1) on page \(word.pageIndex + 1): \(String(format: "%.1f", outside.share * 100))% of its ink lies outside the box, up to \(String(format: "%.2f", outside.reach)) pt")
        }
    }

    /// The ink pixels' extent inside `word` (visual points, grown 1.5 pt), nil when none.
    static func inkExtent(_ page: PDFPage, word: CGRect) throws -> CGRect? {
        let bounds = page.bounds(for: .cropBox)
        let window = word.insetBy(dx: -1.5, dy: -1.5)
        let cgPage = try #require(page.pageRef)
        let bitmap = try #require(DocumentSearcher.renderGray(
            cgPage, rotation: page.rotation, visual: bounds.size, window: window))
        var extent: CGRect?
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where bitmap.isInk(x, y) {
                let pixel = CGRect(x: window.minX + CGFloat(x) / DocumentSearcher.inkFitScale,
                                   y: window.minY + CGFloat(y) / DocumentSearcher.inkFitScale,
                                   width: 1 / DocumentSearcher.inkFitScale, height: 1 / DocumentSearcher.inkFitScale)
                extent = extent.map { $0.union(pixel) } ?? pixel
            }
        }
        return extent
    }

    @Test("A match's paint is as tall as its word's ink, not as Vision's box: it does not reach into the leading")
    func paintHeightIsTheInkRows() async throws {
        let (export, source) = try await Self.reimportedExport()
        let truth = await Self.hits(source, "delia", includeOCR: false)
        var paints: [Int: [CGRect]] = [:]
        for index in 0..<export.pageCount {
            let page = try #require(export.page(at: index))
            await DocumentSearcher.prepareInkFit(page)
            let size = page.bounds(for: .cropBox).size
            let text = (page.string ?? "") as NSString
            var at = 0
            while at < text.length {
                let range = text.range(of: "delia", options: .caseInsensitive, range: NSRange(location: at, length: text.length - at))
                guard range.location != NSNotFound else { break }
                at = NSMaxRange(range)
                let fit = try #require(Self.settled({ DocumentSearcher().textLayerAndInkRects(for: range, page: page) }, degraded: \.degraded))
                #expect(!fit.degraded, "the fit on page \(index + 1) is not degraded")
                paints[index, default: []] += fit.paint.map { Self.points($0, size) }
            }
        }
        for (index, word) in truth.enumerated() {
            let page = try #require(export.page(at: word.pageIndex))
            let ink = try #require(try Self.inkExtent(page, word: Self.points(word.normalizedRect, page.bounds(for: .cropBox).size)))
            let mine = (paints[word.pageIndex] ?? []).filter { $0.intersects(ink) }
            #expect(!mine.isEmpty, "hit \(index + 1) has a paint over its ink")
            for paint in mine {
                // The half-point caps, a pixel of the ink box, a pixel of rounding.
                #expect(paint.minY >= ink.minY - 1.0 && paint.maxY <= ink.maxY + 1.0,
                        "hit \(index + 1): paint y \(paint.minY)…\(paint.maxY), ink y \(ink.minY)…\(ink.maxY)")
            }
        }
    }

    /// A Searchable export of the statement turned by `rotation` (the export
    /// bakes the turn into its page: the text runs sideways or upside down
    /// on an unrotated page), re-imported, and the turned source.
    static func turnedExport(_ rotation: Int) async throws -> (export: PDFDocument, source: PDFDocument) {
        let original = try #require(PDFDocument(data: try TestFixtures.sampleStatementPDF()))
        for index in 0..<original.pageCount { original.page(at: index)?.rotation = rotation }
        let data = try #require(original.dataRepresentation())
        let source = try #require(PDFDocument(data: data))
        var regions: [Int: [RedactionRegion]] = [:]
        for hit in await hits(source, "Sample", includeOCR: false) {
            regions[hit.pageIndex, default: []].append(
                RedactionRegion(id: UUID(), normalizedRect: hit.normalizedRect, source: .manual))
        }
        let url = try await TestPipeline.processAndExport(data, mode: .searchableRedaction, regions: regions, dpi: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        return (try #require(PDFDocument(data: try Data(contentsOf: url))), source)
    }

    @Test("On an export whose page carries its source's turn, every match covers its word's ink, or is the envelope",
          arguments: [90, 180, 270])
    func turnedPageMatchesCoverTheirInk(rotation: Int) async throws {
        let (export, source) = try await Self.turnedExport(rotation)
        let truth = await Self.hits(source, "delia", includeOCR: false)
        #expect(truth.count == 9, "the statement names Delia nine times; got \(truth.count)")
        var paints: [Int: [CGRect]] = [:]
        var fitted = 0, matches = 0
        for index in 0..<export.pageCount {
            let page = try #require(export.page(at: index))
            await DocumentSearcher.prepareInkFit(page)
            let size = page.bounds(for: .cropBox).size
            let text = (page.string ?? "") as NSString
            var at = 0
            while at < text.length {
                let range = text.range(of: "delia", options: .caseInsensitive, range: NSRange(location: at, length: text.length - at))
                guard range.location != NSNotFound else { break }
                at = NSMaxRange(range)
                guard let fit = Self.settled({ DocumentSearcher().textLayerAndInkRects(for: range, page: page) }, degraded: \.degraded)
                else { continue }
                matches += 1
                if !fit.degraded { fitted += 1 }
                paints[index, default: []] += fit.paint.map { Self.points($0, size) }
            }
        }
        for (index, word) in truth.enumerated() {
            let page = try #require(export.page(at: word.pageIndex))
            let size = page.bounds(for: .cropBox).size
            let outside = try Self.inkOutside(page, word: Self.points(word.normalizedRect, size), boxes: paints[word.pageIndex] ?? [])
            let inkBox = try Self.inkExtent(page, word: Self.points(word.normalizedRect, size))
            #expect(outside.share == 0,
                    "turn \(rotation), hit \(index + 1): \(String(format: "%.1f", outside.share * 100))% of its ink lies outside, up to \(String(format: "%.2f", outside.reach)) pt; word \(Self.points(word.normalizedRect, size)) ink \(String(describing: inkBox)) paints \((paints[word.pageIndex] ?? []).filter { $0.intersects(Self.points(word.normalizedRect, size).insetBy(dx: -2, dy: -2)) })")
        }
        #expect(matches == truth.count, "turn \(rotation): \(matches) matches on the export")
        // Read upright in the page's reading frame, the words are fitted, not
        // left to the envelope (at most one of the nine).
        #expect(fitted >= matches - 1, "turn \(rotation): \(fitted) of \(matches) words fitted, \(matches - fitted) left to the envelope")
    }

    static let cjkLines = ["客户名称：张伟", "地址：北京市朝阳区建国路八十八号现代城五号楼二十层", "联系电话：一三八零零一三八零零零", "账户余额：八千元整",
                           "旧址：朝阳区东路一号，新址：朝阳区西路十二号院"]

    /// A page of CJK lines (CoreText, a system CJK font, 14 pt), the longest
    /// run 24 ideographs: drawn as ink (`hidden` false), or as a picture of
    /// that page under the same lines in invisible text, each glyph 0.4 em
    /// closer to the last and the line 5 pt low, as a fixed-pitch layer
    /// drifts on CJK (`hidden` true).
    static func cjkPagePDF(hidden: Bool) throws -> Data {
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let font = CTFontCreateWithName("PingFang SC" as CFString, 14, nil)
        func draw(_ ctx: CGContext, kern: CGFloat, drop: CGFloat) {
            for (index, line) in cjkLines.enumerated() {
                let attributed = NSAttributedString(string: line, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTKernAttributeName as String): kern])
                ctx.textPosition = CGPoint(x: 72, y: 700 - CGFloat(index) * 30 - drop)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
            }
        }
        func pdf(_ body: (CGContext) -> Void) throws -> Data {
            let data = NSMutableData()
            let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
            let ctx = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
            ctx.beginPDFPage(nil); body(ctx); ctx.endPDFPage(); ctx.closePDF()
            return data as Data
        }
        let ink = try pdf { draw($0, kern: 0, drop: 0) }
        guard hidden else { return ink }
        let page = try #require(PDFDocument(data: ink)?.page(at: 0)?.pageRef)
        let scale: CGFloat = 300 / 72
        let bitmap = try #require(CGContext(data: nil, width: Int(612 * scale), height: Int(792 * scale), bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        bitmap.setFillColor(gray: 1, alpha: 1); bitmap.fill(CGRect(x: 0, y: 0, width: 612 * scale, height: 792 * scale))
        bitmap.scaleBy(x: scale, y: scale); bitmap.drawPDFPage(page)
        let picture = try #require(bitmap.makeImage())
        return try pdf { ctx in
            ctx.draw(picture, in: media)
            ctx.setTextDrawingMode(.invisible)
            draw(ctx, kern: -0.4 * 14, drop: 5)
        }
    }

    @Test("A CJK word twice on one line: the later one searched is fitted on its own ink, or is the envelope")
    func cjkRepeatOnALineLandsOnItsOwnInk() async throws {
        let source = try #require(PDFDocument(data: try Self.cjkPagePDF(hidden: false)))
        let export = try #require(PDFDocument(data: try Self.cjkPagePDF(hidden: true)))
        let page = try #require(export.page(at: 0)), sourcePage = try #require(source.page(at: 0))
        let size = page.bounds(for: .cropBox).size
        await DocumentSearcher.prepareInkFit(page)
        let searcher = DocumentSearcher()
        let text = (page.string ?? "") as NSString, sourceText = (sourcePage.string ?? "") as NSString
        let first = text.range(of: "朝阳区东路"), sourceFirst = sourceText.range(of: "朝阳区东路")
        let late = text.range(of: "朝阳区", range: NSRange(location: NSMaxRange(first), length: text.length - NSMaxRange(first)))
        let sourceLate = sourceText.range(of: "朝阳区", range: NSRange(location: NSMaxRange(sourceFirst), length: sourceText.length - NSMaxRange(sourceFirst)))
        try #require(late.location != NSNotFound && sourceLate.location != NSNotFound, "the word repeats on the line")
        let raw = try #require(page.selection(for: late).flatMap { searcher.normalizedRect(for: $0, page: page) })
        let truthLate = try #require(sourcePage.selection(for: sourceLate).flatMap { searcher.normalizedRect(for: $0, page: sourcePage) })
        let truthFirst = try #require(sourcePage.selection(for: NSRange(location: sourceFirst.location, length: 3))
            .flatMap { searcher.normalizedRect(for: $0, page: sourcePage) })
        let fit = try #require(Self.settled({ DocumentSearcher.inkFit(raw, page: page, text: "朝阳区", range: late, paintOnly: true) },
                                            degraded: \.degraded))
        let covered = try Self.inkOutside(page, word: Self.points(truthLate, size), boxes: [Self.points(fit.rect, size)])
        #expect(covered.share == 0, "the later word's ink outside its box: \(covered.share * 100)%")
        if !fit.degraded {
            let other = Self.points(truthFirst, size).intersection(Self.points(fit.rect, size))
            #expect(other.isNull || other.width < 1, "the fit is the later word's, not the earlier one's: \(other)")
        }
    }

    @Test("A CJK word deep in its run: degraded on purpose, its envelope holds its ink; fitted, its box covers it")
    func cjkEnvelopeHoldsItsInk() async throws {
        let source = try #require(PDFDocument(data: try Self.cjkPagePDF(hidden: false)))
        let export = try #require(PDFDocument(data: try Self.cjkPagePDF(hidden: true)))
        let page = try #require(export.page(at: 0)), sourcePage = try #require(source.page(at: 0))
        let cgPage = try #require(page.pageRef)
        let size = page.bounds(for: .cropBox).size
        #expect(DocumentSearcher.carriesHiddenTextOverImage(page, cgPage: cgPage), "the page is a picture under a hidden layer")
        let key = InkTokenCache.key(page: page, cgPage: cgPage, visual: size)
        let searcher = DocumentSearcher()
        for word in ["北京市朝阳区", "五号楼二十层"] {
            let range = ((page.string ?? "") as NSString).range(of: word)
            let sourceRange = ((sourcePage.string ?? "") as NSString).range(of: word)
            try #require(range.location != NSNotFound && sourceRange.location != NSNotFound, "\(word) is in both layers")
            let raw = try #require(page.selection(for: range).flatMap { searcher.normalizedRect(for: $0, page: page) })
            let truth = try #require(sourcePage.selection(for: sourceRange).flatMap { searcher.normalizedRect(for: $0, page: sourcePage) })
            let drift = abs(Self.points(raw, size).midX - Self.points(truth, size).midX)
            if word == "五号楼二十层" {
                #expect(drift > DocumentSearcher.inkFitDriftBound, "deep in its run the layer sits past the Latin bound: \(drift) pt")
            }
            // Degraded on purpose: the page's read and its renders stall past their wait.
            DocumentSearcher.inkFitInjectedStalls.set((2.0, 0.3), for: key)
            DocumentSearcher.inkFitInjectedRenderStalls.set((2.0, 0.3), for: key)
            let envelope = DocumentSearcher.inkFit(raw, page: page, text: word, range: range, paintOnly: true)
            DocumentSearcher.inkFitInjectedStalls.set(nil, for: key)
            DocumentSearcher.inkFitInjectedRenderStalls.set(nil, for: key)
            #expect(envelope.degraded, "\(word): the stalled read degrades the fit")
            let held = try Self.inkOutside(page, word: Self.points(truth, size), boxes: [Self.points(envelope.rect, size)])
            #expect(held.share == 0, "\(word) (layer \(drift) pt from its ink): \(held.share * 100)% of its ink outside its envelope, up to \(held.reach) pt")
            await DocumentSearcher.prepareInkFit(page)
            let fit = try #require(Self.settled({ DocumentSearcher.inkFit(raw, page: page, text: word, range: range, paintOnly: true) },
                                                degraded: \.degraded))
            let covered = try Self.inkOutside(page, word: Self.points(truth, size), boxes: [Self.points(fit.rect, size)])
            #expect(covered.share == 0, "\(word): \(covered.share * 100)% of its ink outside its \(fit.degraded ? "envelope" : "fit"), up to \(covered.reach) pt")
        }
    }

    @Test("The live preview on the main thread reads the box the search fitted, and nothing before it")
    func mainThreadPreviewMatchesTheSearch() async throws {
        let (export, _) = try await Self.reimportedExport()
        let shared = SendablePDFDocument(export)
        let pageIndex = 0
        let page = try #require(export.page(at: pageIndex))
        // A word no search above has fitted on this content.
        let range = ((page.string ?? "") as NSString).range(of: "Hartwell")
        @MainActor func ask() -> CGRect? {
            shared.document.page(at: pageIndex).flatMap { DocumentSearcher().boundingRect(for: range, page: $0) }
        }
        let selection = try #require(page.selection(for: range))
        let raw = try #require(DocumentSearcher().normalizedRect(for: selection, page: page))
        let before = await ask()
        #expect(before == raw, "before a search the main thread draws the selection box: it renders and reads nothing")
        // The search, off the main thread on its own copy, fits and caches.
        let bytes = try #require(export.dataRepresentation())
        let copy = try #require(PDFDocument(data: bytes))
        let searched = await Self.hits(copy, "Hartwell", includeOCR: false).filter { $0.pageIndex == pageIndex }
        let after = await ask()
        #expect(after != raw, "after the search the preview's box is fitted")
        #expect(searched.contains { $0.normalizedRect == after }, "and it is the box the search painted")
    }

    @Test("Concurrent fits on separate copies and main-thread preview asks agree, and do not share PDF objects")
    func concurrentFitsAndPreviewAsks() async throws {
        let (export, _) = try await Self.reimportedExport()
        let data = try #require(export.dataRepresentation())
        let reference = await Self.hits(try #require(PDFDocument(data: data)), "delia", includeOCR: false).map(\.normalizedRect)
        let preview = SendablePDFDocument(try #require(PDFDocument(data: data)))
        try await withThrowingTaskGroup(of: [CGRect].self) { group in
            for _ in 0..<4 {
                group.addTask {
                    let copy = try #require(PDFDocument(data: data))
                    return await Self.hits(copy, "delia", includeOCR: false).map(\.normalizedRect)
                }
            }
            // A parallel Searchable export: it creates the layer's fonts (the
            // font registry a stalled run was waiting in) while the fits read.
            group.addTask {
                let data = try TestFixtures.sampleStatementPDF()
                let url = try await TestPipeline.processAndExport(data, mode: .searchableRedaction, regions: [:], dpi: 150)
                try? FileManager.default.removeItem(at: url)
                return reference
            }
            group.addTask {
                for _ in 0..<20 {
                    await MainActor.run {
                        for index in 0..<preview.document.pageCount {
                            guard let page = preview.document.page(at: index) else { continue }
                            let range = ((page.string ?? "") as NSString).range(of: "Delia")
                            if range.location != NSNotFound { _ = DocumentSearcher().boundingRect(for: range, page: page) }
                        }
                    }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                return reference
            }
            for try await rects in group { #expect(rects == reference, "every copy fits the same boxes") }
        }
    }

    @Test("A word inside a longer read token is painted alone: DELIA in INDN:DELIA leaves INDN: unpainted")
    func cutLeavesTheRestOfTheTokenUnpainted() async throws {
        let (export, source) = try await Self.reimportedExport()
        let page = try #require(export.page(at: 0))
        await DocumentSearcher.prepareInkFit(page)
        let sourcePage = try #require(source.page(at: 0))
        let size = page.bounds(for: .cropBox).size
        let text = (page.string ?? "") as NSString
        let sourceText = (sourcePage.string ?? "") as NSString
        let searcher = DocumentSearcher()
        var checked = 0
        var at = 0, sourceAt = 0
        while true {
            let token = text.range(of: "INDN:DELIA", range: NSRange(location: at, length: text.length - at))
            let sourceToken = sourceText.range(of: "INDN:DELIA", range: NSRange(location: sourceAt, length: sourceText.length - sourceAt))
            guard token.location != NSNotFound, sourceToken.location != NSNotFound else { break }
            let delia = NSRange(location: token.location + 5, length: 5)
            let rects = try #require(Self.settled({ searcher.textLayerAndInkRects(for: delia, page: page) }, degraded: \.degraded),
                                     "the page is gated")
            #expect(!rects.degraded, "the fit read its page")
            let paint = rects.paint.map { Self.points($0, size) }
            // "INDN:" on the source, where its text is its ink; its middle (a
            // quarter point in from each edge) must carry no paint.
            let prefix = NSRange(location: sourceToken.location, length: 5)
            let prefixBox = try #require(sourcePage.selection(for: prefix).flatMap { searcher.normalizedRect(for: $0, page: sourcePage) })
            let inner = Self.points(prefixBox, size).insetBy(dx: 0.25, dy: 0.25)
            let cgPage = try #require(page.pageRef)
            let bitmap = try #require(DocumentSearcher.renderGray(cgPage, rotation: page.rotation, visual: size, window: inner))
            var painted = 0
            for y in 0..<bitmap.height { for x in 0..<bitmap.width where bitmap.isInk(x, y) {
                let point = CGPoint(x: inner.minX + (CGFloat(x) + 0.5) / DocumentSearcher.inkFitScale,
                                    y: inner.minY + (CGFloat(y) + 0.5) / DocumentSearcher.inkFitScale)
                if paint.contains(where: { $0.contains(point) }) { painted += 1 }
            } }
            #expect(painted == 0, "INDN: ink under the DELIA paint: \(painted) px")
            checked += 1
            at = NSMaxRange(token); sourceAt = NSMaxRange(sourceToken)
        }
        #expect(checked == 2, "page 1 carries INDN:DELIA twice; checked \(checked)")
    }

    @Test("A document PDFKit cannot write (a malformed /Info) gives no private copy and no crash")
    func malformedInfoGivesNoCopy() throws {
        let document = try #require(PDFDocument(data: MalformedInfoDictionaryTests.malformedInfoPDF))
        #expect(PrivatePDFCopies.shared.copy(of: document) == nil, "the guarded write returns nil; nothing raises")
    }

    @Test("Concurrent first asks for one document's private copy make exactly one")
    func privateCopyIsMadeOnce() async throws {
        let (export, _) = try await Self.reimportedExport()
        let shared = SendablePDFDocument(export)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { _ = PrivatePDFCopies.shared.copy(of: shared.document) } }
        }
        let made = PrivatePDFCopies.shared.madeCount(of: shared.document)
        #expect(made == 1, "made \(made) copies of one document")
    }

    @Test("A page without a page-scale image keeps its selection boxes")
    func plainPageKeepsItsBoxes() async throws {
        let source = try #require(PDFDocument(data: try TestFixtures.sampleStatementPDF()))
        let page = try #require(source.page(at: 0))
        let cgPage = try #require(page.pageRef)
        #expect(!DocumentSearcher.carriesHiddenTextOverImage(page, cgPage: cgPage))
        let range = ((page.string ?? "") as NSString).range(of: "Delia")
        let selection = try #require(page.selection(for: range))
        let raw = try #require(DocumentSearcher().normalizedRect(for: selection, page: page))
        #expect(DocumentSearcher.inkFittedRect(raw, page: page, text: "Delia", range: range) == raw)
        #expect(DocumentSearcher().boundingRect(for: range, page: page) == raw)
    }

    // MARK: - The ink box on a drawn bitmap

    /// A white bitmap with dark blocks; `rows` and `columns` in pixels from the bottom-left.
    static func bitmap(width: Int, height: Int, blocks: [(x: Range<Int>, y: Range<Int>)]) -> DocumentSearcher.GrayBitmap {
        var pixels = [UInt8](repeating: 255, count: width * height)
        for block in blocks { for y in block.y { for x in block.x { pixels[(height - 1 - y) * width + x] = 0 } } }
        return DocumentSearcher.GrayBitmap(pixels: pixels, width: width, height: height)
    }

    @Test("A box set low takes the word's full height; a dot a small gap above joins it")
    func lowBoxTakesTheBand() throws {
        let s = DocumentSearcher.inkFitScale
        // A word 40 px tall at rows 40..<80 with a dot at rows 84..<90; the box covers rows 20..<60.
        let map = Self.bitmap(width: 200, height: 140, blocks: [(60..<140, 40..<80), (70..<76, 84..<90)])
        let window = CGRect(x: 0, y: 0, width: 200 / s, height: 140 / s)
        let box = CGRect(x: 60 / s, y: 20 / s, width: 80 / s, height: 40 / s)
        let reading = DocumentSearcher.inkBox(in: map, box: box, window: window)
        let ink = try #require(reading.box)
        #expect(reading.outcome == .fitted)
        #expect(ink.minY <= 40 / s && ink.maxY >= 90 / s, "rows 40–90 (the dot included); got \(ink.minY * s)…\(ink.maxY * s)")
    }

    @Test("A box short of the word's end grows to it; a word space stops it")
    func shortBoxGrowsToTheWordEnd() throws {
        let s = DocumentSearcher.inkFitScale
        // Letters at columns 40..<60 and 62..<100 (a 2 px letter gap), the next word from 130.
        let map = Self.bitmap(width: 220, height: 80, blocks: [(40..<60, 20..<60), (62..<100, 20..<60), (130..<180, 20..<60)])
        let window = CGRect(x: 0, y: 0, width: 220 / s, height: 80 / s)
        let box = CGRect(x: 40 / s, y: 20 / s, width: 40 / s, height: 40 / s)
        let ink = try #require(DocumentSearcher.inkBox(in: map, box: box, window: window).box)
        #expect(ink.maxX >= 100 / s, "grows over the letter gap to column 100; got \(ink.maxX * s)")
        #expect(ink.maxX < 130 / s, "stops at the word space; got \(ink.maxX * s)")
    }

    @Test("No ink meets the box: no fit")
    func noInkNoFit() {
        let s = DocumentSearcher.inkFitScale
        let map = Self.bitmap(width: 100, height: 100, blocks: [(10..<30, 80..<95)])
        let window = CGRect(x: 0, y: 0, width: 100 / s, height: 100 / s)
        let reading = DocumentSearcher.inkBox(in: map, box: CGRect(x: 40 / s, y: 10 / s, width: 40 / s, height: 30 / s), window: window)
        #expect(reading.box == nil && reading.outcome == .noInk)
    }

    @Test("A rule under the word is neither followed nor ridden across the window")
    func ruleIsNotInk() throws {
        let s = DocumentSearcher.inkFitScale
        // A word at rows 40..<80, columns 60..<140; a rule across the whole window at rows 30..<33.
        let map = Self.bitmap(width: 240, height: 140, blocks: [(60..<140, 40..<80), (0..<240, 30..<33)])
        let window = CGRect(x: 0, y: 0, width: 240 / s, height: 140 / s)
        let box = CGRect(x: 60 / s, y: 25 / s, width: 80 / s, height: 40 / s)
        let reading = DocumentSearcher.inkBox(in: map, box: box, window: window)
        let ink = try #require(reading.box)
        #expect(reading.outcome == .fitted, "the rule does not carry the box to the window's edge")
        #expect(ink.minX >= 58 / s && ink.maxX <= 142 / s, "columns stay on the word; got \(ink.minX * s)…\(ink.maxX * s)")
        #expect(ink.minY >= 38 / s, "rows stop above the rule; got \(ink.minY * s)")
    }

    @Test("A column border beside the word does not stretch the rows")
    func columnBorderIsNotInk() throws {
        let s = DocumentSearcher.inkFitScale
        let map = Self.bitmap(width: 200, height: 160, blocks: [(50..<130, 60..<100), (140..<142, 0..<160)])
        let window = CGRect(x: 0, y: 0, width: 200 / s, height: 160 / s)
        let box = CGRect(x: 50 / s, y: 50 / s, width: 95 / s, height: 40 / s)
        let ink = try #require(DocumentSearcher.inkBox(in: map, box: box, window: window).box)
        #expect(ink.minY >= 58 / s && ink.maxY <= 102 / s, "rows stay on the word; got \(ink.minY * s)…\(ink.maxY * s)")
    }

    @Test("A dark ground is not fitted")
    func darkGroundIsNotFitted() {
        let s = DocumentSearcher.inkFitScale
        // A shaded cell: most of the window is dark.
        let map = Self.bitmap(width: 120, height: 80, blocks: [(0..<120, 10..<75)])
        let window = CGRect(x: 0, y: 0, width: 120 / s, height: 80 / s)
        let reading = DocumentSearcher.inkBox(in: map, box: CGRect(x: 30 / s, y: 30 / s, width: 60 / s, height: 20 / s), window: window)
        #expect(reading.box == nil && reading.outcome == .darkGround)
    }

    @Test("Ink that runs to the window's edge is capped there and reported")
    func growthIsCappedAtTheWindow() throws {
        let s = DocumentSearcher.inkFitScale
        // Text continuing with no word space to the window's right edge.
        let map = Self.bitmap(width: 200, height: 100, blocks: [(40..<200, 30..<60)])
        let window = CGRect(x: 0, y: 0, width: 200 / s, height: 100 / s)
        let reading = DocumentSearcher.inkBox(in: map, box: CGRect(x: 40 / s, y: 30 / s, width: 40 / s, height: 30 / s), window: window)
        let ink = try #require(reading.box)
        #expect(reading.outcome == .capped)
        #expect(ink.maxX <= window.maxX + 2 / s, "never past the window; got \(ink.maxX * s)")
    }
}
