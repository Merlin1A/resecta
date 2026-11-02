import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// On iOS 27 a scanned page's recognized text is read twice, accurate and
// fast, and the literal, regex and PII Scan routes add what only the fast
// read matched (`DocumentSearcher+OCRFastUnion`). A fast match on the same
// term over at least half of an accurate match's box is that match, boxed
// by the union of the two. iOS 26 reads one recognition.

@Suite("OCR on iOS 27: the fast read beside the accurate one", .tags(.search))
struct OCRFastUnionTests {

    private func result(_ term: String, _ rect: CGRect, text: String = "x") -> SearchResult {
        SearchResult(pageIndex: 0, normalizedRect: rect, matchedText: text, contextSnippet: text,
                     source: .ocr(confidence: 0.5), term: term)
    }

    @Test("A fast match over half an accurate match's box is that match, boxed by both")
    func overlappingMatchIsOneWithTheUnionBox() {
        let a = result("INV-00731", CGRect(x: 0.10, y: 0.50, width: 0.40, height: 0.02), text: "accurate")
        let f = result("INV-00731", CGRect(x: 0.12, y: 0.495, width: 0.40, height: 0.02), text: "fast")
        let merged = DocumentSearcher.unionFastOCRResults(accurate: [a], fast: [f])
        #expect(merged.count == 1)
        #expect(merged.first?.id == a.id && merged.first?.matchedText == "accurate", "the accurate match is kept")
        #expect(merged.first?.normalizedRect == a.normalizedRect.union(f.normalizedRect))
    }

    @Test("A fast match on another box, on another term, or over less than half is added")
    func otherFastMatchesAreAdded() {
        let a = result("INV-00731", CGRect(x: 0.10, y: 0.50, width: 0.40, height: 0.02))
        let elsewhere = result("INV-00731", CGRect(x: 0.10, y: 0.30, width: 0.40, height: 0.02))
        let otherTerm = result("2026-CV-0042", a.normalizedRect)
        let sliver = result("INV-00731", CGRect(x: 0.45, y: 0.50, width: 0.40, height: 0.02))
        let merged = DocumentSearcher.unionFastOCRResults(accurate: [a], fast: [elsewhere, otherTerm, sliver])
        #expect(merged.count == 4)
        #expect(merged.first?.normalizedRect == a.normalizedRect, "the accurate box is untouched")
    }

    private func searched(_ mode: SearchMode, accurate: String, fast: String) async throws -> [SearchResult] {
        let doc = try #require(PDFDocument(data: TestFixtures.imageOnlyPDF()))
        let rect = CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.03)
        let searcher = DocumentSearcher()
        await searcher._testSeedOCRLines([OCREngine.TextLine(text: accurate, normalizedRect: rect, confidence: 0.6)], forPageIndex: 0)
        await searcher._testSeedOCRFastLines([OCREngine.TextLine(text: fast, normalizedRect: rect, confidence: 0.5)], forPageIndex: 0)
        var results: [SearchResult] = []
        for await r in searcher.search(SendablePDFDocument(doc), mode: mode, progress: { _, _ in }) { results.append(r) }
        return results
    }

    @Test("Text search: a value only the fast read has is matched on iOS 27, not on iOS 26")
    func literalRouteAddsTheFastOnlyValue() async throws {
        let results = try await searched(.text("INV-00731", options: SearchOptions()),
                                         accurate: "Reference PR4471-A / frøn R (00 00",
                                         fast: "Reference PR4471-A / Case 2026-CV-0042 / Invoice INV-00731")
        if DocumentSearcher.readsFastOCRBeside {
            #expect(results.count == 1)
            if case .ocr = results.first?.source {} else { Issue.record("expected an OCR result") }
        } else {
            #expect(results.isEmpty)
        }
    }

    @Test("Text search: a value both reads have is one result")
    func literalRouteKeepsOneWhenBothRead() async throws {
        let results = try await searched(.text("PR4471-A", options: SearchOptions()),
                                         accurate: "Reference PR4471-A / frøn R (00 00",
                                         fast: "Reference PR4471-A / Case 2026-CV-0042 / Invoice INV-00731")
        #expect(results.count == 1)
    }

    @Test("Regex search: a value only the fast read has is matched on iOS 27, not on iOS 26")
    func regexRouteAddsTheFastOnlyValue() async throws {
        let results = try await searched(.regex(#"INV-\d{5}"#, options: SearchOptions()),
                                         accurate: "Reference PR4471-A / frøn R (00 00",
                                         fast: "Reference PR4471-A / Case 2026-CV-0042 / Invoice INV-00731")
        #expect(results.count == (DocumentSearcher.readsFastOCRBeside ? 1 : 0))
    }

    @Test("PII Scan: a phone only the fast read has is matched on iOS 27, not on iOS 26")
    func piiScanAddsTheFastOnlyPhone() async throws {
        let results = try await searched(.piiScan(categories: [.phone], options: SearchOptions(includeOCR: true)),
                                         accurate: "Home Phone: frøn R эçæ",
                                         fast: "Home Phone: (208) 555-0147")
        let phones = results.filter { $0.piiCategory == .phone }
        #expect(phones.count == (DocumentSearcher.readsFastOCRBeside ? 1 : 0), "\(results.map(\.matchedText))")
    }

    // MARK: - The reports: counted once, not again for the fast read

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add(_ n: Int) { lock.lock(); value += n; lock.unlock() }
        var total: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test("PII Scan: a below-threshold drop is counted once, not again for the fast read")
    func belowThresholdCountedOnce() async throws {
        func drops(seedingFast: Bool) async throws -> Int {
            let doc = try #require(PDFDocument(data: TestFixtures.imageOnlyPDF()))
            let rect = CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.03)
            let searcher = DocumentSearcher()
            await searcher._testSeedOCRLines([OCREngine.TextLine(text: "SSN 123-45-6789", normalizedRect: rect, confidence: 0.6)], forPageIndex: 0)
            if seedingFast {
                await searcher._testSeedOCRFastLines([OCREngine.TextLine(text: "SSN 123-45-6789", normalizedRect: rect, confidence: 0.5)], forPageIndex: 0)
            }
            await searcher.setThresholdVector(PresetThresholdVector(thresholdsByWireName: ["ssn": 1.0]))
            let counter = Counter()
            await searcher.setBelowThresholdSink { counter.add($0) }
            for await _ in searcher.search(SendablePDFDocument(doc), mode: .piiScan(categories: [.ssn], options: SearchOptions(includeOCR: true)),
                                           progress: { _, _ in }) {}
            return counter.total
        }
        let accurateOnly = try await drops(seedingFast: false)
        #expect(accurateOnly >= 1, "the fixture drops the SSN below the cutoff")
        #expect(try await drops(seedingFast: true) == accurateOnly)
    }

    @Test("Regex search: a page's timeout is reported once, not again for the fast read")
    func regexTimeoutReportedOnce() async throws {
        func timeouts(seedingFast: Bool) async throws -> Int {
            let doc = try #require(PDFDocument(data: TestFixtures.imageOnlyPDF()))
            let rect = CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.03)
            let searcher = DocumentSearcher(regexTimeoutOverride: .zero)
            await searcher._testSeedOCRLines([OCREngine.TextLine(text: "Invoice INV-00731", normalizedRect: rect, confidence: 0.6)], forPageIndex: 0)
            if seedingFast {
                await searcher._testSeedOCRFastLines([OCREngine.TextLine(text: "Invoice INV-00731", normalizedRect: rect, confidence: 0.5)], forPageIndex: 0)
            }
            let counter = Counter()
            await searcher.setRegexTimeoutSink { _ in counter.add(1) }
            for await _ in searcher.search(SendablePDFDocument(doc), mode: .regex(#"INV-\d{5}"#, options: SearchOptions()),
                                           progress: { _, _ in }) {}
            return counter.total
        }
        let accurateOnly = try await timeouts(seedingFast: false)
        #expect(accurateOnly == 1, "the zero timeout stops the page's read once")
        #expect(try await timeouts(seedingFast: true) == accurateOnly)
    }

    // MARK: - More fast matches than accurate ones on a line; the order

    @Test("A line the fast read holds more matches on than the accurate read keeps the fast matches, in either order")
    func moreFastMatchesOnALineKeepTheFastOnes() {
        // Binary-exact boxes, so a union is compared without rounding.
        let line = CGRect(x: 0.125, y: 0.5, width: 0.625, height: 0.03125)
        let left = CGRect(x: 0.125, y: 0.5, width: 0.25, height: 0.03125)
        let right = CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.03125)
        let a = result("delia hartwell", line)
        for fast in [[result("delia hartwell", left), result("delia hartwell", right)],
                     [result("delia hartwell", right), result("delia hartwell", left)]] {
            let merged = DocumentSearcher.unionFastOCRResults(accurate: [a], fast: fast)
            #expect(Set(merged.map(\.normalizedRect)) == [left, right], "\(merged.map(\.normalizedRect))")
        }
        let twoAccurate = DocumentSearcher.unionFastOCRResults(
            accurate: [a, result("delia hartwell", line)],
            fast: [result("delia hartwell", left), result("delia hartwell", right)])
        #expect(twoAccurate.count == 2, "as many accurate matches as fast ones: the accurate ones stay")
        #expect(twoAccurate.allSatisfy { $0.normalizedRect == line })
    }

    @Test("Hybrid page: an occurrence only the page image holds is boxed when the fast read holds it, in either order")
    func hybridImageOnlyOccurrenceIsBoxed() async throws {
        let doc = try #require(PDFDocument(data: TestFixtures.lineOverScanPDF("Pay Delia Hartwell")))
        let page = try #require(doc.page(at: 0))
        let line = CGRect(x: 0.11, y: 0.925, width: 0.60, height: 0.025)
        let left = CGRect(x: 0.11, y: 0.925, width: 0.28, height: 0.025)
        let right = CGRect(x: 0.42, y: 0.925, width: 0.29, height: 0.025)
        for fastOrder in [[("Pay Delia Hartwell", left), ("and Delia Hartwell", right)],
                          [("and Delia Hartwell", right), ("Pay Delia Hartwell", left)]] {
            let searcher = DocumentSearcher()
            await searcher._testSeedOCRLines(
                [OCREngine.TextLine(text: "Pay Delia Hartwell and Dclia Hartwcll", normalizedRect: line, confidence: 0.6)],
                forPageIndex: 0)
            await searcher._testSeedOCRFastLines(
                fastOrder.map { OCREngine.TextLine(text: $0.0, normalizedRect: $0.1, confidence: 0.5) }, forPageIndex: 0)
            var results: [SearchResult] = []
            var options = SearchOptions()
            options.includeOCR = true
            for await r in searcher.search(SendablePDFDocument(doc), mode: .text("Delia Hartwell", options: options),
                                           progress: { _, _ in }) { results.append(r) }
            let textLayer = results.filter { $0.source == .textLayer }
            let ocr = results.filter { if case .ocr = $0.source { true } else { false } }
            #expect(textLayer.count == 1, "the text layer holds the first occurrence")
            if DocumentSearcher.readsFastOCRBeside {
                #expect(ocr.map(\.normalizedRect) == [DocumentSearcher.paddedNormalizedRect(right, in: page)],
                        "the second occurrence, in the image only, is boxed by its fast line: \(ocr.map(\.normalizedRect))")
            } else {
                #expect(ocr.isEmpty, "iOS 26 reads one recognition, which misreads the second occurrence")
            }
        }
    }

    @Test("A phrase the accurate read splits across two lines and the fast read holds on one is one occurrence")
    func crossLineAndFastLineAreOneOccurrence() async throws {
        let doc = try #require(PDFDocument(data: TestFixtures.imageOnlyPDF()))
        let searcher = DocumentSearcher()
        await searcher._testSeedOCRLines([
            OCREngine.TextLine(text: "Account holder Jane", normalizedRect: CGRect(x: 0.1, y: 0.60, width: 0.5, height: 0.03), confidence: 0.6),
            OCREngine.TextLine(text: "Doe of Boise", normalizedRect: CGRect(x: 0.1, y: 0.56, width: 0.5, height: 0.03), confidence: 0.6),
        ], forPageIndex: 0)
        await searcher._testSeedOCRFastLines([
            OCREngine.TextLine(text: "Account holder Jane Doe of Boise",
                               normalizedRect: CGRect(x: 0.1, y: 0.56, width: 0.5, height: 0.07), confidence: 0.5),
        ], forPageIndex: 0)
        var results: [SearchResult] = []
        for await r in searcher.search(SendablePDFDocument(doc), mode: .text("Jane Doe", options: SearchOptions()),
                                       progress: { _, _ in }) { results.append(r) }
        #expect(results.count == 2, "one box per line the accurate read splits it over: \(results.map(\.normalizedRect))")
        #expect(Set(results.map(\.occurrenceID)).count == 1, "one occurrence")
    }

    @Test("A match only the fast read has takes its place on the page among the others")
    func fastOnlyMatchIsInPageOrder() async throws {
        let doc = try #require(PDFDocument(data: TestFixtures.imageOnlyPDF()))
        let searcher = DocumentSearcher()
        let r1 = CGRect(x: 0.1, y: 0.70, width: 0.6, height: 0.03)
        let r2 = CGRect(x: 0.1, y: 0.60, width: 0.6, height: 0.03)
        let r3 = CGRect(x: 0.1, y: 0.50, width: 0.6, height: 0.03)
        await searcher._testSeedOCRLines([
            OCREngine.TextLine(text: "Invoice INV-00731 due", normalizedRect: r1, confidence: 0.6),
            OCREngine.TextLine(text: "frøn R (00 00", normalizedRect: r2, confidence: 0.3),
            OCREngine.TextLine(text: "Copy of INV-00733", normalizedRect: r3, confidence: 0.6),
        ], forPageIndex: 0)
        await searcher._testSeedOCRFastLines([
            OCREngine.TextLine(text: "Invoice INV-00731 due", normalizedRect: r1, confidence: 0.5),
            OCREngine.TextLine(text: "Reissued INV-00732", normalizedRect: r2, confidence: 0.5),
            OCREngine.TextLine(text: "Copy of INV-00733", normalizedRect: r3, confidence: 0.5),
        ], forPageIndex: 0)
        var results: [SearchResult] = []
        for await r in searcher.search(SendablePDFDocument(doc), mode: .text("INV-0073", options: SearchOptions()),
                                       progress: { _, _ in }) { results.append(r) }
        let tops = results.map(\.normalizedRect.midY)
        #expect(results.count == (DocumentSearcher.readsFastOCRBeside ? 3 : 2))
        #expect(tops == tops.sorted(by: >), "top to bottom: \(tops)")
    }
}
