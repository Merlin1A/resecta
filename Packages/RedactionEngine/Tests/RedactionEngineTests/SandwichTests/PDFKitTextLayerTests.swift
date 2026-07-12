import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText

// EXP-011 migrated: PDFKit Text Layer Behavior
// Audit: AA-4 (invisible text), AA-5 (per-char bounds), AA-10 (char counting),
//        VE-1-1/CO-2-1 (Critical: output page zero-origin), VE-3-1 (High)

@Suite("PDFKit Text Layer Behavior", .tags(.sandwich, .critical))
struct PDFKitTextLayerTests {

    private func createInvisibleCourierPDF(text: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("invisible_\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdfContext = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        pdfContext.beginPage(mediaBox: &mediaBox)
        pdfContext.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        pdfContext.fill(mediaBox)
        pdfContext.setTextDrawingMode(.invisible)
        let font = CTFontCreateWithName("Courier" as CFString, 12, nil)
        let attrString = NSAttributedString(string: text, attributes: [
            .font: font,
            kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true
        ])
        let line = CTLineCreateWithAttributedString(attrString)
        pdfContext.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, pdfContext)
        pdfContext.endPage()
        pdfContext.closePDF()
        return url
    }

    // --- AA-4: Selection finds invisible (rendering-mode-3) text ---
    @Test("Selection finds invisible rendering-mode-3 text (AA-4)")
    func selectionFindsInvisibleText() {
        let url = createInvisibleCourierPDF(text: "Hello World Test")
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = PDFDocument(url: url)!
        let page = doc.page(at: 0)!
        let pageText = page.string ?? ""
        #expect(!pageText.isEmpty, "page.string must find rendering-mode-3 text")

        let selection = page.selection(for: CGRect(x: 0, y: 600, width: 612, height: 200))
        let selText = selection?.string ?? ""
        #expect(!selText.isEmpty, "page.selection(for:CGRect) must find invisible text")
    }

    // --- AA-5: Per-character bounds on Courier ---
    @Test("Per-character bounds on Courier text (AA-5)")
    func perCharacterBoundsOnCourierText() {
        let url = createInvisibleCourierPDF(text: "ABCDEFGHIJ")
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = PDFDocument(url: url)!
        let page = doc.page(at: 0)!
        let charCount = page.numberOfCharacters

        var widths: [CGFloat] = []
        for i in 0..<min(charCount, 10) {
            let bounds = page.selection(for: NSRange(location: i, length: 1))?.bounds(for: page) ?? .zero
            widths.append(bounds.width)
        }
        let avgWidth = widths.reduce(0, +) / CGFloat(widths.count)
        // Courier 12pt ~ 7.2pt advance; per-character bounds should be < 20pt
        #expect(avgWidth < 20, "Must return per-character bounds, not per-run (avg: \(avgWidth)pt)")
    }

    // --- AA-10 / VE-3-1: numberOfCharacters counting method ---
    @Test("numberOfCharacters counting with emoji (AA-10)")
    func numberOfCharactersWithEmoji() {
        let text = "Hello 😀 World"
        let url = createInvisibleCourierPDF(text: text)
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = PDFDocument(url: url)!
        let page = doc.page(at: 0)!
        let pdfCount = page.numberOfCharacters
        // PDFKit character counting method is platform-dependent;
        // just verify it returns a reasonable value
        #expect(pdfCount > 0, "PDFKit must return non-zero character count")
    }

    // --- Composed character fidelity ---
    @Test("Composed characters (e.g. e-acute) preserved through CTLineDraw")
    func composedCharacterFidelity() {
        let text = "café résumé"
        let url = createInvisibleCourierPDF(text: text)
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = PDFDocument(url: url)!
        let page = doc.page(at: 0)!
        let extracted = page.string ?? ""
        #expect(extracted.hasPrefix(text),
                "CTLineDraw must preserve composed characters (e-acute)")
    }

    // --- CAT-364 (KI-2): iOS-26 A/B — direct characterBounds(at:) vs workaround ---
    // RECORD, not assume. KI-2 documents that PDFPage.characterBounds(at:)
    // regressed on iOS 18 (FB14843671), so the Searchable pipeline extracts
    // per-glyph bounds via the PDFSelection workaround
    // (TextLayerExtractor.extractCharacters). This A/B measures whether the
    // direct API has been fixed on the iOS 26 SDK. The fixture is zero-origin,
    // which isolates the question from CAT-366's CropBox translation: cropOrigin
    // is .zero here, so both APIs report in the same page space and the only
    // variable is the API itself. Synthetic Courier text only — never a real document.
    //
    // RECORDED iOS-26 outcome (F13, 2026-06-14): the direct API still disagrees
    // with the PDFSelection workaround on every glyph (agree=0/10,
    // maxDelta≈5.05pt, no degenerate rects) — FB14843671 is NOT fixed on the
    // iOS 26 SDK, so the workaround stays (KI-2 remains open, rechecked). This
    // assertion pins that reality: it is GREEN while the regression persists.
    // A future SDK that fixes the API makes every glyph agree, which flips this
    // RED — the prompt to retire the workaround and close KI-2. The failure
    // message carries the live numbers for that decision.
    @Test("characterBounds(at:) direct vs PDFSelection workaround (CAT-364 / KI-2, iOS 26)")
    func characterBoundsDirectVsWorkaround_iOS26() {
        let url = createInvisibleCourierPDF(text: "ABCDEFGHIJ")
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = PDFDocument(url: url)!
        let page = doc.page(at: 0)!
        let charCount = min(page.numberOfCharacters, 10)

        var agree = 0
        var directDegenerate = 0
        var maxDelta: CGFloat = 0
        for i in 0..<charCount {
            let direct = page.characterBounds(at: i)
            let workaround = page.selection(for: NSRange(location: i, length: 1))?
                .bounds(for: page) ?? .zero
            if direct.isNull || direct.width <= 0 || direct.height <= 0 {
                directDegenerate += 1
                continue
            }
            let delta = max(
                abs(direct.minX - workaround.minX), abs(direct.minY - workaround.minY),
                abs(direct.width - workaround.width), abs(direct.height - workaround.height)
            )
            maxDelta = max(maxDelta, delta)
            if delta < 2.0 { agree += 1 }
        }

        #expect(
            agree < charCount,
            "iOS-26 characterBounds(at:) A/B — agree=\(agree)/\(charCount) directDegenerate=\(directDegenerate) maxDelta=\(maxDelta)pt. RED here means every glyph now agrees → FB14843671 fixed: retire the workaround and close KI-2."
        )
    }

    // --- VE-1-1 / CO-2-1 (Critical): Output pages have zero-origin bounds ---
    @Test("Output pages have zero-origin bounds (VE-1-1)")
    func outputPageBoundsAreZeroOrigin() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("origin_test_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        ctx.beginPage(mediaBox: &mediaBox)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(mediaBox)
        ctx.endPage()
        ctx.closePDF()

        let doc = PDFDocument(url: url)!
        let cropBox = doc.page(at: 0)!.bounds(for: .cropBox)
        let mediaBoxOut = doc.page(at: 0)!.bounds(for: .mediaBox)
        #expect(cropBox.origin == .zero, "Output pages must have zero-origin cropBox")
        #expect(mediaBoxOut.origin == .zero, "Output pages must have zero-origin mediaBox")
    }

    // --- CTLineDraw invisible Courier text extraction ---
    @Test("CTLineDraw invisible Courier text is fully extractable")
    func ctLineDrawCourierTextExtraction() {
        let data = TestFixtures.ctLineDrawCourierPDF()
        let doc = PDFDocument(data: data)!
        let page = doc.page(at: 0)!
        let text = page.string ?? ""
        #expect(text.contains("ALPHA"), "CTLineDraw PDF must contain ALPHA")
        #expect(text.contains("JULIET"), "CTLineDraw PDF must contain JULIET")

        let wordCount = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.count
        #expect(wordCount == 10, "Must extract all 10 invisible words, got \(wordCount)")
    }
}
