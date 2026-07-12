import Testing
import PDFKit
@testable import RedactionEngine

// Tests for ENGINE §5A — text layer detection and fallback triggers.

@Suite("Text Layer Detection")
struct TextLayerDetectorTests {

    // MARK: - detectTextLayer()

    @Test("Rich text layer detected for page with substantial text")
    func richTextLayerDetected() throws {
        let data = TestFixtures.textLayerPDF(text: "This is a substantial amount of text for testing")
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))

        let status = TextLayerDetector.detectTextLayer(page)
        #expect(status == .rich)
    }

    @Test("Sparse text layer for fewer than 10 meaningful characters")
    func sparseTextLayerDetected() throws {
        let data = TestFixtures.textLayerPDF(text: "Hi")
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))

        let status = TextLayerDetector.detectTextLayer(page)
        #expect(status == .sparse)
    }

    @Test("No text layer for image-only PDF")
    func noTextLayerForImageOnly() throws {
        let data = TestFixtures.imageOnlyPDF()
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))

        let status = TextLayerDetector.detectTextLayer(page)
        #expect(status == .none)
    }

    @Test("No text layer for blank page")
    func noTextLayerForBlankPage() throws {
        let data = TestFixtures.blankPage()
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))

        let status = TextLayerDetector.detectTextLayer(page)
        #expect(status == .none)
    }

    // MARK: - Fallback Triggers

    @Test("No fallback for normal English text")
    func noFallbackForEnglishText() throws {
        let data = TestFixtures.textLayerPDF(
            text: "The quick brown fox jumps over the lazy dog"
        )
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))

        let reason = TextLayerDetector.checkFallbackTriggers(page)
        #expect(reason == nil)
    }

    @Test("Fallback for blank page with no text")
    func fallbackForNoText() throws {
        let data = TestFixtures.blankPage()
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))

        let reason = TextLayerDetector.checkFallbackTriggers(page)
        #expect(reason == .noExtractableText)
    }

    // MARK: - Character diversity floor (RC-9 / PD-5 part 1)
    //
    // The former unique/total < 0.05 ratio was length-confounded: the
    // distinct-character set saturates (~70 for Latin text) while the total
    // keeps growing, so every normal page ≳1,400 characters tripped
    // .unresolvedEncoding and silently rasterized (sample doc p2: 71/2254,
    // p3: 67/3005). The floor keys on the absolute distinct count instead.

    private func triggerReason(forText text: String, fontSize: CGFloat = 12) throws
        -> TextLayerDetector.FallbackReason? {
        let data = TestFixtures.textLayerPDF(text: text, fontSize: fontSize)
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        return TextLayerDetector.checkFallbackTriggers(page)
    }

    @Test("Repeated-glyph garbage trips unresolvedEncoding (floor target)")
    func repeatedGlyphGarbageTrips() throws {
        // 4 distinct characters over ≥50 — the extraction-failure signature.
        let garbage = String(repeating: "ababa cbcbc ", count: 6) // 72 chars
        #expect(try triggerReason(forText: garbage) == .unresolvedEncoding)
    }

    @Test("Repeated-glyph garbage still trips at page-filling length")
    func repeatedGlyphGarbageTripsLong() throws {
        // 40 lines × 50 chars = 2,049 chars, 4 distinct (a, b, space, newline).
        let line = String(repeating: "abab ", count: 10)
        let garbage = Array(repeating: line, count: 40).joined(separator: "\n")
        #expect(try triggerReason(forText: garbage, fontSize: 10) == .unresolvedEncoding)
    }

    @Test("Exactly 9 distinct characters trips the floor")
    func nineDistinctTrips() throws {
        // Single line, no whitespace: 54 chars, 9 distinct.
        let text = String(repeating: "012345678", count: 6)
        #expect(try triggerReason(forText: text) == .unresolvedEncoding)
    }

    @Test("Exactly 10 distinct characters passes the floor")
    func tenDistinctPasses() throws {
        // Single line, no whitespace: 60 chars, 10 distinct — the
        // digit-heavy-table population starts here.
        let text = String(repeating: "0123456789", count: 6)
        #expect(try triggerReason(forText: text) == nil)
    }

    @Test("Digit-heavy table text passes the floor")
    func digitTableTextPasses() throws {
        let table = String(repeating: "0123456789., $ ", count: 5) // 14 distinct
        #expect(try triggerReason(forText: table) == nil)
    }

    @Test("Long natural text passes (RC-9 regression: the ratio tripped it)")
    func longNaturalTextPasses() throws {
        // 50 lines ≈ 2,299 chars; distinct ≈ 30 → old ratio 0.013 < 0.05
        // rasterized this page. The floor keeps it searchable.
        let text = Array(
            repeating: "The quick brown fox jumps over the lazy dog.",
            count: 50
        ).joined(separator: "\n")
        #expect(try triggerReason(forText: text) == nil)
    }

    @Test("Short low-diversity text is not assessed (<50 chars)")
    func shortTextNotAssessed() throws {
        let text = String(repeating: "ab", count: 15) // 30 chars, 2 distinct
        #expect(try triggerReason(forText: text) == nil)
    }

    @Test("Sample statement: no page trips a pre-flight trigger (RC-9 regression)")
    func sampleStatementNoPreflightTrigger() throws {
        // The defect fingerprint: p1 (70 distinct / 1,006 chars) passed the
        // old ratio while p2 (71/2,254) and p3 (67/3,005) tripped it — the
        // shipped sample doc rasterized 2 of its 3 born-digital pages.
        let data = try TestFixtures.sampleStatementPDF()
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.pageCount == TestFixtures.sampleStatementPageCount)
        for i in 0..<doc.pageCount {
            let page = try #require(doc.page(at: i))
            #expect(TextLayerDetector.checkFallbackTriggers(page) == nil,
                    "sample page \(i + 1) must not trip a pre-flight fallback trigger")
        }
    }
}
