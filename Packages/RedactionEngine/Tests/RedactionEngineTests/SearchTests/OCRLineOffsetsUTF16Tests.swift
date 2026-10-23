import Testing
import PDFKit
@testable import RedactionEngine

// The Scan OCR leg records each normalized line's start inside the page's
// concatenation and compares it with the detector's `NSRange`s. Both must
// count UTF-16 units: a Character count drifts one unit behind per emoji or
// other astral Character on the page, and a match near the end of a later
// line is then mapped onto the line after it — the line that carries the
// value gets no box. The seam `_testSeedOCRLines` plants the lines, so no
// Vision OCR runs.
//
// Privacy rule (audit-lint M-1): test names use locate/map/resolve
// vocabulary.

@Suite("Scan OCR leg: line offsets in UTF-16 units", .tags(.search))
struct OCRLineOffsetsUTF16Tests {

    private static func line(_ text: String, y: CGFloat) -> OCREngine.TextLine {
        OCREngine.TextLine(
            text: text,
            normalizedRect: CGRect(x: 0.1, y: y, width: 0.6, height: 0.04),
            confidence: 0.9
        )
    }

    private static func ocrResults(
        lines: [OCREngine.TextLine], categories: Set<PIICategory>
    ) async -> [SearchResult] {
        guard let doc = PDFDocument(data: TestFixtures.imageOnlyPDF()) else {
            Issue.record("Failed to create PDFDocument")
            return []
        }
        let searcher = DocumentSearcher()
        await searcher._testSeedOCRLines(lines, forPageIndex: 0)
        let stream = searcher.search(
            SendablePDFDocument(doc),
            mode: .piiScan(categories: categories, options: SearchOptions(includeOCR: true)),
            progress: { _, _ in }
        )
        var results: [SearchResult] = []
        for await result in stream { results.append(result) }
        return results
    }

    @Test("Sixteen emoji on the line above: the line-final value maps to its own line")
    func astralCharactersBeforeTheMatchMapToTheValuesLine() async {
        // The first line is 21 Characters and 37 UTF-16 units; the value ends
        // its own line, so a shift of 16 units lands the match's range wholly
        // on the trailing line in a Character-counted map.
        let emojiLine = String(repeating: "\u{1F642}", count: 16) + " note"
        let valueLine = "Taxpayer SSN 123-45-6789"
        let valueRect = CGRect(x: 0.1, y: 0.40, width: 0.6, height: 0.04)
        let trailingRect = CGRect(x: 0.1, y: 0.80, width: 0.6, height: 0.04)
        let results = await Self.ocrResults(
            lines: [
                Self.line(emojiLine, y: 0.10),
                Self.line(valueLine, y: 0.40),
                Self.line("end of page", y: 0.80),
            ],
            categories: [.ssn]
        )
        #expect(results.count == 1, "expected the SSN once; got \(results.map(\.matchedText))")
        guard let result = results.first else { return }
        #expect(result.normalizedRect.intersects(valueRect),
                "the box must cover the value's line: \(result.normalizedRect)")
        #expect(!result.normalizedRect.intersects(trailingRect),
                "the box must not reach the trailing line: \(result.normalizedRect)")
    }

    @Test("Single-unit lines map as before")
    func singleUnitLinesUnchanged() async {
        let valueRect = CGRect(x: 0.1, y: 0.40, width: 0.6, height: 0.04)
        let results = await Self.ocrResults(
            lines: [
                Self.line("Intake note", y: 0.10),
                Self.line("Taxpayer SSN 123-45-6789", y: 0.40),
                Self.line("end of page", y: 0.80),
            ],
            categories: [.ssn]
        )
        #expect(results.count == 1)
        #expect(results.first?.normalizedRect.intersects(valueRect) == true)
    }
}
