import Testing
import PDFKit
@testable import RedactionEngine

@Suite("DocumentSearcher", .tags(.search))
struct DocumentSearcherTests {

    // MARK: - CAT-054 process-shared PIIDetector

    @Test("Two searchers share one process-level PIIDetector Bloom buffer (CAT-054)")
    func sharedPIIDetectorIdentity() {
        let a = DocumentSearcher()
        let b = DocumentSearcher()
        let addrA = a._testNameBloomBufferAddress
        let addrB = b._testNameBloomBufferAddress
        // The name gazetteer is bundled in the engine test context (see
        // NameGazetteerIntegrationTests), so both searchers must report the
        // SAME copy-on-write buffer address — proving the shared static. A
        // per-instance `PIIDetector()` would load two independent Bloom
        // allocations at different addresses.
        #expect(addrA != nil, "Name gazetteer bloom not bundled in test context")
        #expect(addrA == addrB,
                "Both DocumentSearchers must share the process-level PIIDetector's Bloom buffer")
    }

    // MARK: - Text-Layer Search

    @Test("Basic text match finds known term")
    func basicTextMatch() async {
        let data = TestFixtures.textLayerPDF(text: "John Smith SSN 123-45-6789")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        let mode = SearchMode.text("John", options: SearchOptions())
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        #expect(results.count >= 1)
        // UXF-15: matchedText displays the original casing, re-sliced from
        // the case-preserved base text. Matching itself still runs on the
        // normalized form (REDACTION_ENGINE.md §9.6).
        #expect(results.first?.matchedText == "John")
        #expect(results.first?.pageIndex == 0)
        #expect(results.first?.term == "John")
        #expect(results.first?.source == .textLayer)
    }

    @Test("Case-insensitive match")
    func caseInsensitiveMatch() async {
        let data = TestFixtures.textLayerPDF(text: "Hello World")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        let options = SearchOptions(caseSensitive: false)
        let mode = SearchMode.text("hello", options: options)
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        #expect(results.count >= 1)
        // UXF-15: the case-insensitive match still displays the document's
        // original casing ("Hello"), not the case-folded search form.
        #expect(results.first?.matchedText == "Hello")
    }

    @Test("Case-sensitive match respects case")
    func caseSensitiveMatch() async {
        let data = TestFixtures.textLayerPDF(text: "Hello World")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        let options = SearchOptions(caseSensitive: true)
        let mode = SearchMode.text("hello", options: options)
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        #expect(results.isEmpty)
    }

    @Test("Whole-word matching excludes partial matches")
    func wholeWordMatch() async {
        let data = TestFixtures.textLayerPDF(text: "start art artist")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        let options = SearchOptions(wholeWord: true)
        let mode = SearchMode.text("art", options: options)
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        // Should only match standalone "art", not "start" or "artist"
        #expect(results.count == 1)
        #expect(results.first?.matchedText == "art")
    }

    @Test("No matches returns empty stream")
    func noMatches() async {
        let data = TestFixtures.textLayerPDF(text: "Hello World")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        let mode = SearchMode.text("ZZZZZ", options: SearchOptions())
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        #expect(results.isEmpty)
    }

    @Test("Multiple matches on same page")
    func multipleMatchesSamePage() async {
        let data = TestFixtures.textLayerPDF(text: "the cat sat on the mat")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        let mode = SearchMode.text("the", options: SearchOptions())
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        #expect(results.count == 2)
    }

    @Test("Search result has valid normalized coordinates")
    func normalizedCoordinates() async {
        let data = TestFixtures.textLayerPDF(text: "Searchable Text Here")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        let mode = SearchMode.text("Text", options: SearchOptions())
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        #expect(results.count >= 1)
        if let rect = results.first?.normalizedRect {
            // Normalized coordinates must be in [0, 1] range
            #expect(rect.minX >= 0 && rect.minX <= 1)
            #expect(rect.minY >= 0 && rect.minY <= 1)
            #expect(rect.maxX >= 0 && rect.maxX <= 1)
            #expect(rect.maxY >= 0 && rect.maxY <= 1)
            #expect(rect.width > 0)
            #expect(rect.height > 0)
        }
    }

    // MARK: - Context window (UXC-45 / RB-101 — the contract these pin)
    //
    // `contextSnippet` returns the window text AND the match's Character
    // range inside it; every builder path threads that range onto
    // `SearchResult.matchRangeInSnippet`. The pins below replaced the
    // former loose "contains the term" check.

    /// The snippet slice the result's `matchRangeInSnippet` addresses.
    private func windowSlice(_ result: SearchResult) -> String? {
        guard let range = result.matchRangeInSnippet else { return nil }
        let chars = Array(result.contextSnippet)
        guard range.lowerBound >= 0, range.upperBound <= chars.count else { return nil }
        return String(chars[range])
    }

    @Test("Context window on the text path: short page, no cuts, range addresses the match")
    func contextSnippet() async {
        let text = "The quick brown fox jumps over the lazy dog"
        let data = TestFixtures.textLayerPDF(text: text)
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        let mode = SearchMode.text("fox", options: SearchOptions())
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        #expect(results.count == 1)
        guard let result = results.first else { return }
        // 43 characters sit inside the radius on both sides: nothing is
        // cut, so no ellipsis on either side and the window is the text.
        #expect(result.contextSnippet == text)
        #expect(result.matchRangeInSnippet == 16..<19)
        #expect(windowSlice(result) == "fox")
        #expect(windowSlice(result) == result.matchedText)
    }

    @Test("Context window: radius 44 honored, both sides ellipsized, no partial word at either cut")
    func contextWindowRadiusAndWordTrim() async {
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf",
                     "hotel", "india", "juliet", "kilo", "lima", "MATCH", "mike",
                     "november", "oscar", "papa", "quebec", "romeo", "sierra", "tango",
                     "uniform", "victor", "whiskey", "xray", "yankee", "zulu"]
        let text = words.joined(separator: " ")
        let matchStart = text.distance(from: text.startIndex, to: text.range(of: "MATCH")!.lowerBound)

        let searcher = DocumentSearcher()
        let window = await searcher.contextSnippet(text: text, matchStart: matchStart, matchLength: 5)

        #expect(window.snippet.hasPrefix("…"))
        #expect(window.snippet.hasSuffix("…"))
        let body = String(window.snippet.dropFirst().dropLast())
        // Never longer than the raw window; the trim only shortens.
        #expect(body.count <= DocumentSearcher.contextRadius * 2 + 5)
        // No leading/trailing separator run survives a cut side.
        #expect(body.first?.isLetter == true)
        #expect(body.last?.isLetter == true)
        // The first and last words of the window are WHOLE words of the
        // text (a partial word would not appear space-delimited in it).
        let bodyWords = body.split(separator: " ").map(String.init)
        #expect(words.contains(bodyWords.first ?? ""))
        #expect(words.contains(bodyWords.last ?? ""))
        // The range addresses the match after the trim.
        let chars = Array(window.snippet)
        #expect(String(chars[window.matchRange]) == "MATCH")
    }

    @Test("Context window never trims into the match: an adjoining partial word keeps the raw cut")
    func contextWindowKeepsRawCutAgainstTheMatch() async {
        let text = String(repeating: "a", count: 60) + "MATCH" + String(repeating: "b", count: 60)
        let searcher = DocumentSearcher()
        let window = await searcher.contextSnippet(text: text, matchStart: 60, matchLength: 5)

        let radius = DocumentSearcher.contextRadius
        #expect(window.snippet
                == "…" + String(repeating: "a", count: radius) + "MATCH"
                + String(repeating: "b", count: radius) + "…")
        #expect(window.matchRange == (radius + 1)..<(radius + 6))
        #expect(String(Array(window.snippet)[window.matchRange]) == "MATCH")
    }

    @Test("Context window: ellipsis only on a cut side; a separator-run cut starts the window at the next word")
    func contextWindowEllipsisSides() async {
        let searcher = DocumentSearcher()

        // Match at the very start: nothing cut on the left.
        let tail = String(repeating: "x", count: 100)
        let atStart = await searcher.contextSnippet(text: "MATCH " + tail, matchStart: 0, matchLength: 5)
        #expect(!atStart.snippet.hasPrefix("…"))
        #expect(atStart.snippet.hasSuffix("…"))
        #expect(atStart.matchRange == 0..<5)
        #expect(String(Array(atStart.snippet)[atStart.matchRange]) == "MATCH")

        // Match at the very end, the raw left cut lands inside the x-run:
        // the partial run is dropped, the space after it too, so the
        // window begins at the match.
        let atEnd = await searcher.contextSnippet(text: tail + " MATCH", matchStart: 101, matchLength: 5)
        #expect(atEnd.snippet == "…MATCH")
        #expect(atEnd.matchRange == 1..<6)

        // A raw cut that lands on a separator run: the run is dropped
        // (no "… word" with a stranded leading space).
        let sentence = String(repeating: "y", count: 20) + " " + String(repeating: "z", count: 23)
            + " MATCH " + String(repeating: "w", count: 50)
        let matchStart = sentence.distance(from: sentence.startIndex,
                                           to: sentence.range(of: "MATCH")!.lowerBound)
        let onSeparator = await searcher.contextSnippet(text: sentence, matchStart: matchStart, matchLength: 5)
        #expect(onSeparator.snippet.hasPrefix("…z"))
        #expect(String(Array(onSeparator.snippet)[onSeparator.matchRange]) == "MATCH")
    }

    @Test("Context window flattens newlines LAST, one Character each, so the range stays valid")
    func contextWindowNewlineFlatten() async {
        let text = "line one\nMATCH here\r\nend"
        let searcher = DocumentSearcher()
        let window = await searcher.contextSnippet(text: text, matchStart: 9, matchLength: 5)
        let keepsANewline = window.snippet.contains { $0.isNewline }
        #expect(!keepsANewline)
        #expect(window.snippet == "line one MATCH here end")
        #expect(window.matchRange == 9..<14)
        #expect(String(Array(window.snippet)[window.matchRange]) == "MATCH")
    }

    @Test("Context window NSRange overload converts UTF-16 offsets past non-BMP characters")
    func contextWindowNSRangeOverload() async {
        let text = "😀😀 MATCH tail"
        let searcher = DocumentSearcher()
        let ns = text as NSString
        let window = await searcher.contextSnippet(text: text, matchNSRange: ns.range(of: "MATCH"))
        #expect(window.snippet == text)
        #expect(window.matchRange == 3..<8)
        #expect(String(Array(window.snippet)[window.matchRange]) == "MATCH")
    }

    @Test("Regex path threads the window range onto the result")
    func contextWindowRegexPath() async {
        let data = TestFixtures.textLayerPDF(text: "Call 555-0100 before noon")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }
        let searcher = DocumentSearcher()
        let stream = searcher.search(
            SendablePDFDocument(doc),
            mode: .regex("\\d{3}-\\d{4}", options: SearchOptions()),
            progress: { _, _ in }
        )
        var results: [SearchResult] = []
        for await result in stream { results.append(result) }

        #expect(results.count == 1)
        guard let result = results.first else { return }
        #expect(result.matchedText == "555-0100")
        #expect(windowSlice(result) == result.matchedText)
    }

    @Test("PII scan path threads the window range onto the result")
    func contextWindowPIIPath() async {
        let data = TestFixtures.textLayerPDF(text: "Taxpayer SSN 123-45-6789 on file")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }
        let searcher = DocumentSearcher()
        let stream = searcher.search(
            SendablePDFDocument(doc),
            mode: .piiScan(categories: [.ssn], options: SearchOptions()),
            progress: { _, _ in }
        )
        var results: [SearchResult] = []
        for await result in stream { results.append(result) }

        #expect(!results.isEmpty)
        for result in results {
            #expect(result.matchRangeInSnippet != nil)
            #expect(windowSlice(result) == result.matchedText)
        }
    }

    @Test("OCR literal path yields the canonical window shape with the range (CR-1c)")
    func contextWindowOCRLiteralPath() async {
        let data = TestFixtures.imageOnlyPDF()
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }
        let line = "Invoice total due to Delia Hartwell on Monday"
        let searcher = DocumentSearcher()
        await searcher._testSeedOCRLines(
            [OCREngine.TextLine(
                text: line,
                normalizedRect: CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.05),
                confidence: 0.9
            )],
            forPageIndex: 0
        )
        let stream = searcher.search(
            SendablePDFDocument(doc),
            mode: .text("Hartwell", options: SearchOptions(includeOCR: true)),
            progress: { _, _ in }
        )
        var results: [SearchResult] = []
        for await result in stream { results.append(result) }

        #expect(results.count == 1)
        guard let result = results.first else { return }
        if case .ocr = result.source {} else {
            Issue.record("Expected .ocr source; got \(String(describing: result.source))")
        }
        // The whole line fits inside the radius: same shape as the text
        // path — no ellipsis, the line itself, the range on the match.
        #expect(result.contextSnippet == line)
        #expect(result.matchRangeInSnippet == 27..<35)
        #expect(windowSlice(result) == "Hartwell")
        #expect(windowSlice(result) == result.matchedText)
    }

    @Test("OCR PII path yields the canonical window with the range (CR-1c)")
    func contextWindowOCRPIIPath() async {
        let data = TestFixtures.imageOnlyPDF()
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }
        let searcher = DocumentSearcher()
        await searcher._testSeedOCRLines(
            [OCREngine.TextLine(
                text: "Taxpayer SSN 123-45-6789 on file",
                normalizedRect: CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.05),
                confidence: 0.9
            )],
            forPageIndex: 0
        )
        let stream = searcher.search(
            SendablePDFDocument(doc),
            mode: .piiScan(categories: [.ssn], options: SearchOptions(includeOCR: true)),
            progress: { _, _ in }
        )
        var results: [SearchResult] = []
        for await result in stream { results.append(result) }

        #expect(!results.isEmpty)
        for result in results {
            if case .ocr = result.source {} else {
                Issue.record("Expected .ocr source; got \(String(describing: result.source))")
            }
            #expect(!result.contextSnippet.hasPrefix("…"))
            #expect(!result.contextSnippet.hasSuffix("…"))
            #expect(result.matchRangeInSnippet != nil)
            #expect(windowSlice(result) == result.matchedText)
        }
    }

    @Test("Progress callback reports page numbers")
    func progressCallback() async {
        let data = TestFixtures.textLayerPDF(text: "Some text")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        let mode = SearchMode.text("text", options: SearchOptions())
        nonisolated(unsafe) var progressCalls: [(Int, Int)] = []
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { current, total in
                progressCalls.append((current, total))
            }
        )

        // Consume stream
        for await _ in stream {}

        #expect(!progressCalls.isEmpty)
        #expect(progressCalls.first?.1 == doc.pageCount)
    }

    @Test("Multi-page search finds matches across pages")
    func multiPageSearch() async {
        let data = multiPageTextPDF(pages: [
            "Page one has apple and banana",
            "Page two has cherry and apple",
            "Page three has date"
        ])
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        let mode = SearchMode.text("apple", options: SearchOptions())
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        #expect(results.count == 2)
        let pages = Set(results.map(\.pageIndex))
        #expect(pages.contains(0))
        #expect(pages.contains(1))
    }

    @Test("Ligature-authored text layer yields one match for the decomposed query")
    func ligatureMatching() async {
        // The fixture is authored with U+FB01 ("\u{FB01}le cabinet"). PDFKit's
        // text layer for the generated PDF already carries the decomposed
        // pair — measured 2026-08-27 on the macOS 26 host and the iOS 26.4
        // simulator: `PDFPage.string` reads "file cabinet" — so this match is
        // produced by the plain text-layer path, and the ligature expansion
        // itself is pinned directly in TextNormalizerTests. What this test
        // pins: a ligature-authored fixture yields exactly one match for the
        // decomposed query with normalization on, whichever path serves it.
        let data = TestFixtures.textLayerPDF(text: "\u{FB01}le cabinet")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        let options = SearchOptions(normalizeUnicode: true)
        let mode = SearchMode.text("file", options: options)
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        #expect(results.count == 1)
        #expect(results.first?.matchedText == "file")
    }

    @Test("Multi-term search finds matches for each term")
    func multiTermSearch() async {
        let data = TestFixtures.textLayerPDF(text: "John Smith SSN 123-45-6789")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        let mode = SearchMode.multiTerm(["John", "123"], options: SearchOptions())
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        let terms = Set(results.map(\.term))
        #expect(terms.contains("John"))
        #expect(terms.contains("123"))
    }

    @Test("SearchResult → DetectionResult → RedactionRegion preserves searchMatch")
    func searchMatchRoundTrip() {
        let detection = DetectionResult(
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
            kind: .searchMatch(term: "test"),
            confidence: 1.0,
            matchedText: "test"
        )

        let region = detection.toRegion()

        if case .searchMatch(let term, _) = region.source {
            #expect(term == "test")
        } else {
            Issue.record("Expected .searchMatch source, got \(region.source)")
        }
    }

    // MARK: - Regex Search Tests

    @Test("Regex matches SSN pattern")
    func regexSSNPattern() async {
        let data = TestFixtures.textLayerPDF(text: "SSN 123-45-6789 here")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        let mode = SearchMode.regex("\\d{3}-\\d{2}-\\d{4}", options: SearchOptions())
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        #expect(results.count >= 1)
        #expect(results.first?.matchedText == "123-45-6789")
    }

    @Test("Regex rejects pattern longer than 200 characters")
    func regexPatternLengthCap() async {
        let longPattern = String(repeating: "a", count: 201)
        let result = DocumentSearcher.validateRegexPattern(longPattern)
        #expect(result == nil)
    }

    @Test("Regex rejects nested quantifiers")
    func regexNestedQuantifiers() async {
        // (a+)+ is a classic ReDoS pattern
        let result = DocumentSearcher.validateRegexPattern("(a+)+b")
        #expect(result == nil)
    }

    @Test("Regex accepts valid pattern within length limit")
    func regexValidPattern() async {
        let result = DocumentSearcher.validateRegexPattern("\\d{3}-\\d{2}-\\d{4}")
        #expect(result != nil)
    }

    @Test("Invalid regex returns nil from validation")
    func regexInvalidPattern() async {
        let result = DocumentSearcher.validateRegexPattern("[unclosed")
        #expect(result == nil)
    }

    @Test("Regex with no matches returns empty stream")
    func regexNoMatches() async {
        let data = TestFixtures.textLayerPDF(text: "Hello World")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        let mode = SearchMode.regex("\\d{3}-\\d{2}-\\d{4}", options: SearchOptions())
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        #expect(results.isEmpty)
    }

    // MARK: - B1: Per-Page CJK Detection

    @Test("CJK detection is per-page for multilingual documents (§9.7)")
    func perPageCJKDetection() async {
        // Page 0: English text — whole-word should apply
        // Page 1: Japanese text — whole-word should be disabled
        let data = multiPageTextPDF(pages: [
            "The art of painting is beautiful",
            "美術の技法は素晴らしい art exhibition"
        ])
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        let options = SearchOptions(wholeWord: true)
        let mode = SearchMode.text("art", options: options)
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        // Page 0 (English): "art" is standalone word → should match
        let page0Results = results.filter { $0.pageIndex == 0 }
        #expect(page0Results.count == 1, "English page should find standalone 'art'")

        // Page 1 (Japanese): whole-word disabled for CJK →
        // "art" appears as part of text, should match without word boundary check
        let page1Results = results.filter { $0.pageIndex == 1 }
        #expect(page1Results.count >= 1, "CJK page should find 'art' without word-boundary restriction")
    }

    // MARK: - S1: OCR Memory Guard

    @Test("OCR skips oversized pages gracefully (ENGINE §2.5)")
    func ocrSkipsOversizedPages() async {
        // Create a PDF with a very large cropBox (5000×5000 points).
        // At 300/72 DPI scale = 4.167, this gives ~20833×20833 pixels,
        // exceeding the 10000-pixel cap.
        let pageRect = CGRect(x: 0, y: 0, width: 5000, height: 5000)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let data = renderer.pdfData { context in
            context.beginPage()
            // Draw only an image, no text layer → forces OCR path
            let rect = CGRect(x: 100, y: 100, width: 200, height: 200)
            UIColor.red.setFill()
            context.cgContext.fill(rect)
        }
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        let options = SearchOptions(includeOCR: true)
        let mode = SearchMode.text("anything", options: options)
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }

        // Should return empty (OCR skipped), not crash
        #expect(results.isEmpty)
    }

    @Test("OCR processes normal-sized pages")
    func ocrProcessesNormalPages() async {
        // Standard Letter page: 612×792 points → 2550×3300 at 300 DPI
        // Well under the 10000 pixel cap.
        let data = TestFixtures.textLayerPDF(text: "Normal page")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        // Verify the page dimensions would pass the memory guard
        let page = doc.page(at: 0)!
        let bounds = page.bounds(for: .cropBox)
        let scale: CGFloat = 300.0 / 72.0
        let pixelW = bounds.width * scale
        let pixelH = bounds.height * scale
        #expect(pixelW <= 10_000, "Letter page width at 300 DPI should be under cap")
        #expect(pixelH <= 10_000, "Letter page height at 300 DPI should be under cap")
    }

    // MARK: - D06-F2 Part 1: belowThresholdSink

    /// Thread-safe accumulator for the `@Sendable` below-threshold sink. The sink
    /// fires synchronously on the searcher actor during page processing, so by the
    /// time the result stream is fully drained every fire has been recorded.
    private final class DropSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _total = 0
        private var _fires = 0
        func record(_ n: Int) { lock.lock(); _total += n; _fires += 1; lock.unlock() }
        var total: Int { lock.lock(); defer { lock.unlock() }; return _total }
        var fires: Int { lock.lock(); defer { lock.unlock() }; return _fires }
    }

    /// Run a single-category PII scan and return (result count, drop sink).
    private func runSSNScan(doc: PDFDocument, ssnCutoff: Double) async -> (results: Int, sink: DropSink) {
        let searcher = DocumentSearcher()
        await searcher.setThresholdVector(
            PresetThresholdVector(thresholdsByWireName: ["ssn": ssnCutoff]))
        let sink = DropSink()
        await searcher.setBelowThresholdSink { n in sink.record(n) }
        let stream = searcher.search(
            SendablePDFDocument(doc),
            mode: .piiScan(categories: [.ssn], options: SearchOptions()),
            progress: { _, _ in }
        )
        var count = 0
        for await _ in stream { count += 1 }
        return (count, sink)
    }

    @Test("belowThresholdSink reports the exact drop count and stays silent at zero")
    func belowThresholdSinkReportsDropCount() async {
        // SSN is detected deterministically (state machine, no NER) and is a
        // NON-scored family, so it flows through the raw `applyingCountingDrops`
        // gate that fires the sink.
        let data = TestFixtures.textLayerPDF(text: "SSN 123-45-6789")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        // Phase 1 — floor cutoff: every match clears it, so zero below-threshold
        // drops. The guarded sink (`if > 0`) must never fire.
        let baseline = await runSSNScan(doc: doc, ssnCutoff: 0.0)
        #expect(baseline.sink.fires == 0, "no drops → the guarded sink must stay silent")

        // Phase 2 — ceiling cutoff: any SSN match (confidence < 1.0) drops. The
        // sink must report EXACTLY the matches the raised cutoff removed relative
        // to the floor run — proving the searcher routes the real drop count.
        let high = await runSSNScan(doc: doc, ssnCutoff: 1.0)
        let droppedByRaisingCutoff = baseline.results - high.results
        #expect(high.sink.total == droppedByRaisingCutoff,
                "sink total must equal the matches the raised cutoff removed")
        #expect(droppedByRaisingCutoff >= 1,
                "fixture precondition: the SSN match (confidence < 1.0) drops at cutoff 1.0")
    }

    // MARK: - UXF-15 display re-slice helper

    @Test("displaySlice returns the fallback on Character-count drift")
    func displaySliceDriftFallback() {
        // Simulated drift: the case-preserved analog has a different
        // Character count than the base text (the BUG-006-norm-drift
        // trap). The helper must refuse the re-slice and return the
        // normalized fallback rather than index with drifted offsets.
        let result = DocumentSearcher.displaySlice(
            start: 0, length: 4, offsetMap: nil,
            displayChars: Array("file"), baseCount: 5, fallback: "fallback")
        #expect(result == "fallback")
    }

    @Test("displaySlice restores original casing through an offset map")
    func displaySliceMapsThroughOffsets() {
        // Base "A-B" (3 Characters); matching ran on the stripped "ab"
        // whose offset map back to base is [0, 2]. The display slice must
        // cover the full base span including the separator.
        let result = DocumentSearcher.displaySlice(
            start: 0, length: 2, offsetMap: [0, 2],
            displayChars: Array("A-B"), baseCount: 3, fallback: "ab")
        #expect(result == "A-B")
    }

    // MARK: - Helpers

    /// Create a multi-page PDF with one text string per page.
    private func multiPageTextPDF(pages: [String]) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return renderer.pdfData { context in
            for text in pages {
                context.beginPage()
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 24),
                    .foregroundColor: UIColor.black
                ]
                (text as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: attrs)
            }
        }
    }
}
