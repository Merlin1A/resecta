import Testing
import Foundation
import PDFKit
import CoreText
@testable import RedactionEngine

// The ink fit's reads on a page of several CJK scripts (`inkFitReads`): one
// read per script, each line fitted on its own script's read, so a Chinese
// line on a page with Korean is not read by the Korean model.

@Suite("Ink fit: one read per script")
struct InkFitScriptsTests {
    /// Lines of text, each in its font (14 pt), drawn as ink (`hidden` false)
    /// or as a picture of that page under the same lines in invisible text,
    /// 2 pt low and each glyph 0.2 pt closer (a re-imported export's drift).
    static func pagePDF(_ lines: [(text: String, font: String)], hidden: Bool) throws -> Data {
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        func draw(_ ctx: CGContext, kern: CGFloat, drop: CGFloat) {
            for (index, line) in lines.enumerated() {
                let font = CTFontCreateWithName(line.font as CFString, 14, nil)
                let attributed = NSAttributedString(string: line.text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTKernAttributeName as String): kern])
                ctx.textPosition = CGPoint(x: 72, y: 680 - CGFloat(index) * 36 - drop)
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
        let cg = try #require(PDFDocument(data: ink)?.page(at: 0)?.pageRef)
        let scale: CGFloat = 300 / 72
        let bitmap = try #require(CGContext(data: nil, width: Int(612 * scale), height: Int(792 * scale), bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        bitmap.setFillColor(gray: 1, alpha: 1); bitmap.fill(CGRect(x: 0, y: 0, width: 612 * scale, height: 792 * scale))
        bitmap.scaleBy(x: scale, y: scale); bitmap.drawPDFPage(cg)
        let picture = try #require(bitmap.makeImage())
        return try pdf { ctx in ctx.draw(picture, in: media); ctx.setTextDrawingMode(.invisible); draw(ctx, kern: -0.2, drop: 2) }
    }

    /// `word`'s fit on the hidden page and the share of its printed ink
    /// outside it (its glyph box taken from the printed page).
    static func fit(_ word: String, lines: [(text: String, font: String)]) async throws -> (degraded: Bool, outside: Double) {
        let export = try #require(PDFDocument(data: try pagePDF(lines, hidden: true)))
        let source = try #require(PDFDocument(data: try pagePDF(lines, hidden: false)))
        let page = try #require(export.page(at: 0)), sourcePage = try #require(source.page(at: 0))
        let size = page.bounds(for: .cropBox).size
        let range = ((page.string ?? "") as NSString).range(of: word)
        let sourceRange = ((sourcePage.string ?? "") as NSString).range(of: word)
        try #require(range.location != NSNotFound && sourceRange.location != NSNotFound, "\(word) is in both layers")
        let truth = try #require(sourcePage.selection(for: sourceRange).flatMap { DocumentSearcher().normalizedRect(for: $0, page: sourcePage) })
        // Read, then fitted from that read; again while the fit is degraded:
        // in a saturated run a read can run past its limit (not cached), or
        // other tests' pages can push this page's tokens out of the cache.
        await DocumentSearcher.prepareInkFit(page)
        var fit = try #require(DocumentSearcher().textLayerAndInkRects(for: range, page: page))
        for _ in 0..<5 where fit.degraded {
            await DocumentSearcher.prepareInkFit(page)
            fit = try #require(DocumentSearcher().textLayerAndInkRects(for: range, page: page))
        }
        let outside = try PageImageInkFitTests.inkOutside(page, word: PageImageInkFitTests.points(truth, size),
                                                          boxes: fit.paint.map { PageImageInkFitTests.points($0, size) })
        return (fit.degraded, outside.share)
    }

    static let korean = "고객 계좌 번호 확인 요청서", chinese = "客户账户号码确认申请书", chineseTwo = "本月存款总额为人民币"

    static let mixedLines = [(korean, "AppleSDGothicNeo-Regular"), (chinese, "PingFangSC-Regular"),
                             (chineseTwo, "PingFangSC-Regular")]

    @Test("On a page with Korean and Chinese lines, a Chinese word is fitted on the Chinese read and holds its ink",
          arguments: ["账户", "存款"])
    func mixedHangulAndHanPageFitsChineseLines(word: String) async throws {
        let fit = try await Self.fit(word, lines: Self.mixedLines)
        #expect(!fit.degraded, "\(word) is fitted on its own script's read, not left to an envelope")
        #expect(fit.outside == 0, "\(word)'s ink outside its box: \(fit.outside * 100)%")
    }

    @Test("On the same page a Korean word, read by the Korean read, holds its ink")
    func mixedHangulAndHanPageKoreanWordHoldsItsInk() async throws {
        // Its render fit grows past its window on this page (degraded, the
        // read word's box): its ink is held either way.
        let fit = try await Self.fit("계좌", lines: Self.mixedLines)
        #expect(fit.outside == 0, "계좌's ink outside its box: \(fit.outside * 100)%")
    }

    @Test("A kanji word on a line with kana is fitted on the Japanese read and holds its ink")
    func kanjiOnAKanaLineReadsJapanese() async throws {
        let lines = [("お客様の口座番号を確認します", "HiraginoSans-W3"), ("今月の入金合計は次のとおりです", "HiraginoSans-W3")]
        let fit = try await Self.fit("口座", lines: lines)
        #expect(!fit.degraded, "口座 is fitted on the Japanese read")
        #expect(fit.outside == 0, "口座's ink outside its box: \(fit.outside * 100)%")
    }

    @Test("The reads a page takes and the read each line is fitted on")
    func readsAndLineRouting() {
        let ja = ["ja-JP", "en-US"], ko = ["ko-KR", "en-US"], zh = ["zh-Hans", "zh-Hant", "en-US"]
        #expect(DocumentSearcher.inkFitReads(for: "Account 4100") == [nil], "a Latin page reads once, in Vision's default")
        #expect(DocumentSearcher.inkFitReads(for: "お客様の口座") == [ja], "kana with kanji: one Japanese read")
        #expect(DocumentSearcher.inkFitReads(for: "\(Self.korean)\n\(Self.chinese)") == [ko, zh], "Hangul and Han: two reads")
        #expect(DocumentSearcher.inkFitReads(for: "口座\nお客様\n계좌") == [ja, ko], "kana, kanji and Hangul: Japanese and Korean")
        let mixed = DocumentSearcher.inkFitReads(for: "お客様\n口座番号\n계좌")
        #expect(DocumentSearcher.inkFitRead(forLine: "口座番号", reads: mixed) == 0, "a kanji line on a page with kana reads Japanese")
        #expect(DocumentSearcher.inkFitRead(forLine: "계좌", reads: mixed) == 1)
        let hanja = DocumentSearcher.inkFitReads(for: "\(Self.korean)\n\(Self.chinese)")
        #expect(DocumentSearcher.inkFitRead(forLine: Self.chinese, reads: hanja) == 1, "a Chinese line reads Chinese")
        #expect(DocumentSearcher.inkFitRead(forLine: "Account 4100", reads: hanja) == 0, "a Latin line reads on the page's first")
        // The first read keeps the page's own key: a page of one script reads as before.
        #expect(DocumentSearcher.inkFitReadKey(pageKey: 42, read: 0) == 42)
        #expect(DocumentSearcher.inkFitReadKey(pageKey: 42, read: 1) != 42)
    }

    @Test("A mixed page reads once per script, not once per line (the read times reported)")
    func mixedPageReadsOncePerScript() async throws {
        let mixed = [(Self.korean, "AppleSDGothicNeo-Regular"), (Self.chinese, "PingFangSC-Regular"),
                     (Self.chineseTwo, "PingFangSC-Regular"), ("계좌 잔액 안내", "AppleSDGothicNeo-Regular")]
        let single = [(Self.chinese, "PingFangSC-Regular"), (Self.chineseTwo, "PingFangSC-Regular")]
        func readTime(_ lines: [(text: String, font: String)]) async throws -> (seconds: Double, reads: Int) {
            // The document held (a page keeps its document weakly; the read draws a copy of it).
            let doc = try #require(PDFDocument(data: try Self.pagePDF(lines, hidden: true)))
            let page = try #require(doc.page(at: 0))
            let reads = DocumentSearcher.pendingInkReads(page).count
            let started = Date()
            await DocumentSearcher.prepareInkFit(page)
            withExtendedLifetime(doc) {}
            return (Date().timeIntervalSince(started), reads)
        }
        let two = try await readTime(mixed), one = try await readTime(single)
        #expect(two.reads == 2, "four lines in two scripts: two reads, not four")
        #expect(one.reads == 1)
        print("script reads: mixed page \(two.reads) reads in \(two.seconds) s; one script \(one.reads) read in \(one.seconds) s")
    }
}
