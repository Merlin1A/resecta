import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// SV-3/SV-4 — extraction-domain regressions for `TextLayerExtractor`
// (ENGINE §5B.1).
//
// `page.string` interleaves PDFKit-SYNTHESIZED separator characters (inter-run
// newlines and spaces) between text runs. A synthesized separator has no glyph
// of its own: `selection(for:)` over its offset clamps to the preceding glyph
// and reports that glyph's CHARACTER with its full-size bounds, so a
// bounds-based guard alone does not exclude it — each such offset would append
// a duplicate of the preceding character, and every affected run would end
// with a doubled terminal character (amounts, dates, names). The extractor
// therefore skips a lineage-whitespace offset whose selection returns a
// different character (the clamp signature).
//
// Matching-selection whitespace splits two ways (PD-11): an entry whose
// selection box spans a whole inter-run gutter would sit gap-free against
// BOTH flanking columns, so run grouping could never split there and the
// drawn line would compress the gutter to one cell — glyph geometry far off
// the raster. The extractor skips a whitespace entry at the grouping
// adjacency break (width ≥ previous entry's width × 1.5); narrower
// whitespace cannot change grouping and keeps its entry, so run texts
// retain their word spacing.
// These tests pin that contract at three ends:
//   1. extraction-side separator invariant on the committed sample statement;
//   2. byte-level text-show operand regression on the written output (the
//      downstream artifact a clamp duplicate produces);
//   3. gutter-whitespace invariant + drawn label/value geometry (the
//      downstream artifact a gutter-wide entry produces).
//
// The fixture is FULLY SYNTHETIC with a public value set (see TestHelpers
// `sampleStatementPDF`), so test diagnostics MAY reference matched text (the
// W2 logging exemption). Production logging rules (ARCH §12.2) are unchanged.

@Suite("Text Layer Extractor", .tags(.sandwich), .serialized)
struct TextLayerExtractorTests {

    // MARK: 1 — separator invariant (extraction side)

    /// Every page of the committed sample statement:
    ///  (a) every entry's stored character equals the source composed
    ///      character at its `stringIndex` — a selection that clamps to a
    ///      neighboring glyph must not survive extraction;
    ///  (b) no entry sits on a line-separator offset (synthesized newlines
    ///      have no glyph);
    ///  (c) every non-whitespace composed unit yields exactly one entry on
    ///      this fixture (count parity).
    @Test("Separator invariant — clamped separator offsets produce no entries")
    func separatorInvariant() async throws {
        let data = try TestFixtures.sampleStatementPDF()
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.pageCount == TestFixtures.sampleStatementPageCount)
        let extractor = TextLayerExtractor()

        for pageIndex in 0..<doc.pageCount {
            let page = try #require(doc.page(at: pageIndex))
            let entries = try await extractor.extractCharacters(from: page)
            let ns = try #require(page.string) as NSString

            // Composed walk of the source `page.string` — the extractor's own
            // iteration unit — recording each composed unit by start offset.
            var composedAt: [Int: String] = [:]
            var nonWhitespaceCount = 0
            var offset = 0
            while offset < ns.length {
                let range = ns.rangeOfComposedCharacterSequence(at: offset)
                let sub = ns.substring(with: range)
                composedAt[range.location] = sub
                if !FilterResult.isLineageWhitespace(sub) {
                    nonWhitespaceCount += 1
                }
                offset += max(range.length, 1)
            }

            // (a) stored character == source composed character.
            let mismatched = entries.filter {
                composedAt[$0.stringIndex] != $0.character
            }
            let mismatchDetail = mismatched.first.map {
                "stringIndex \($0.stringIndex) stored '\($0.character)' "
                    + "source '\(composedAt[$0.stringIndex] ?? "?")'"
            } ?? "-"
            #expect(
                mismatched.isEmpty,
                "page \(pageIndex + 1): \(mismatched.count) entries store a character that differs from the source composed character (first: \(mismatchDetail))")

            // (b) no entry on a line-separator offset.
            let newlineEntries = entries.filter {
                composedAt[$0.stringIndex]?.contains(where: \.isNewline) == true
            }
            #expect(
                newlineEntries.isEmpty,
                "page \(pageIndex + 1): \(newlineEntries.count) entries sit on synthesized line-separator offsets")

            // (c) non-whitespace count parity.
            let nonWhitespaceEntries = entries.filter {
                !FilterResult.isLineageWhitespace($0.character)
            }
            #expect(
                nonWhitespaceEntries.count == nonWhitespaceCount,
                "page \(pageIndex + 1): non-whitespace entry count \(nonWhitespaceEntries.count) != non-whitespace composed count \(nonWhitespaceCount)")
        }
    }

    // MARK: 2 — newline-clamp operand regression (written output side)

    /// Doubled-terminal-character forms a clamp duplicate would place in the
    /// written text layer (each source line's final character, doubled).
    static let doubledForms = ["Hartwelll", "Bankk", "20266", "PPDD", "Page 1 of 33"]
    /// The corresponding correct text — present-checks so an over-broad
    /// extraction change (dropping real characters or their spacing) also
    /// reads as a red here.
    static let correctForms =
        ["Delia R. Hartwell", "Sablebrook Bank", "2026", "PPD", "Page 1 of 3"]

    /// Run the sandwich writer end-to-end on the fixture (searchable mode, no
    /// redaction regions — an empty region map still reconstructs every page's
    /// full text layer) and decode page 1's content-stream text-show operands.
    @Test("Newline-clamp regression — page-1 operands carry no doubled terminal characters")
    func newlineClampOperandRegression() async throws {
        let fixture = try TestFixtures.sampleStatementPDF()
        let url = try await TestPipeline.processAndExport(
            fixture, mode: .searchableRedaction, regions: [:], dpi: 150)
        defer { try? FileManager.default.removeItem(at: url) }
        let outDoc = try #require(PDFDocument(url: url))
        #expect(outDoc.pageCount == TestFixtures.sampleStatementPageCount)
        let page1 = try #require(outDoc.page(at: 0))
        let pageRef = try #require(page1.pageRef)

        let scan = Self.decodedTextShowOperands(pageRef)
        #expect(scan.scanned == true, "Operator scanner must traverse page 1")
        // 0x1F between operands so a form cannot straddle two operands.
        let joined = scan.operands.joined(separator: "\u{1F}")
        print("XTR-OP operands=\(scan.operands.count) joinedLength=\(joined.count)")

        for doubled in Self.doubledForms {
            let found = joined.contains(doubled)
            #expect(found == false,
                    "doubled terminal form in page-1 operands: '\(doubled)'")
        }
        for correct in Self.correctForms {
            let found = joined.contains(correct)
            #expect(found == true,
                    "expected text missing from page-1 operands: '\(correct)'")
        }
    }

    // MARK: 3 — gutter-whitespace invariant (extraction side, PD-11)

    /// Every page of the committed sample statement: no whitespace entry is
    /// wide enough to bridge a run-grouping break — the direct restatement
    /// of the extractor's skip predicate (width ≥ previous entry's width ×
    /// 1.5, the `runMemberGroups` adjacency constant). Word-spacing entries
    /// stay: each page keeps a nonzero whitespace-entry count, and the
    /// separator invariant's count parity (test 1c) pins that no
    /// non-whitespace entry was dropped with them.
    @Test("Gutter invariant — no whitespace entry spans a run-grouping break")
    func gutterWhitespaceInvariant() async throws {
        let data = try TestFixtures.sampleStatementPDF()
        let doc = try #require(PDFDocument(data: data))
        let extractor = TextLayerExtractor()

        for pageIndex in 0..<doc.pageCount {
            let page = try #require(doc.page(at: pageIndex))
            let entries = try await extractor.extractCharacters(from: page)

            var whitespaceCount = 0
            var breakWide: [(index: Int, width: CGFloat, reference: CGFloat)] = []
            for (k, entry) in entries.enumerated()
            where FilterResult.isLineageWhitespace(entry.character) {
                whitespaceCount += 1
                let reference = k > 0
                    ? entries[k - 1].bounds.width : entry.bounds.height
                if entry.bounds.width >= reference * 1.5 {
                    breakWide.append((k, entry.bounds.width, reference))
                }
            }
            let detail = breakWide.first.map {
                "entry \($0.index) width \($0.width) vs reference \($0.reference)"
            } ?? "-"
            #expect(
                breakWide.isEmpty,
                "page \(pageIndex + 1): \(breakWide.count) whitespace entries at or beyond the grouping break (first: \(detail))")
            #expect(
                whitespaceCount > 0,
                "page \(pageIndex + 1): word-spacing whitespace entries must remain")
        }
    }

    // MARK: 4 — drawn label/value geometry regression (written output side)

    /// Rows whose gutter got a gap-wide whitespace entry drew their value
    /// column at one cell after the label — ~89–409pt left of the raster on
    /// the sample's page 1 (measured pre-fix). With gutter entries skipped,
    /// the flanking columns split into separate run groups and the bridge
    /// re-tiles the gutter with whole cells, so each value column draws at
    /// its raster position. Asserts the drawn X of two previously-glued
    /// value columns against their source X.
    @Test("Gutter regression — page-1 value columns draw at their source X")
    func gutterDrawnGeometryRegression() async throws {
        let fixture = try TestFixtures.sampleStatementPDF()
        let url = try await TestPipeline.processAndExport(
            fixture, mode: .searchableRedaction, regions: [:], dpi: 150)
        defer { try? FileManager.default.removeItem(at: url) }

        let srcDoc = try #require(PDFDocument(data: fixture))
        let srcPage = try #require(srcDoc.page(at: 0))
        let outDoc = try #require(PDFDocument(url: url))
        let outPage = try #require(outDoc.page(at: 0))

        let extractor = TextLayerExtractor()
        let srcEntries = try await extractor.extractCharacters(from: srcPage)
        let outEntries = try await extractor.extractCharacters(from: outPage)

        // The Beginning Balance row (gutter measured 116.9pt wide) and the
        // transaction-table header row (gutter measured 397.4pt wide).
        for anchor in ["$2,847.13", "AMOUNT"] {
            let srcX = try #require(
                Self.bandTextMinX(of: anchor, in: srcEntries),
                "source page 1 must contain '\(anchor)'")
            let outX = try #require(
                Self.bandTextMinX(of: anchor, in: outEntries),
                "output page 1 must contain '\(anchor)'")
            let dx = abs(srcX - outX)
            #expect(
                dx < 20,
                "'\(anchor)' drawn \(dx)pt from its source X (source \(srcX), drawn \(outX))")
        }
    }

    /// minX of the first character of `needle` within the Y band whose
    /// concatenated non-whitespace text contains it (bands via the shared
    /// `yBands` sweep, X ascending — the drawn-line structure).
    static func bandTextMinX(
        of needle: String, in entries: [CharacterInfo]
    ) -> CGFloat? {
        let nonWS = entries.filter {
            !FilterResult.isLineageWhitespace($0.character)
        }
        guard !nonWS.isEmpty else { return nil }
        let bands = SandwichVerification.yBands(nonWS.map(\.bounds.minY))
        let bandCount = (bands.max() ?? 0) + 1
        var members: [[Int]] = Array(repeating: [], count: bandCount)
        for (k, band) in bands.enumerated() { members[band].append(k) }
        let compact = needle.filter { !$0.isWhitespace }
        for band in members {
            let ordered = band.sorted {
                nonWS[$0].bounds.minX < nonWS[$1].bounds.minX
            }
            let text = ordered.map { nonWS[$0].character }.joined()
            guard let range = text.range(of: compact) else { continue }
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            // Map the character offset back to the entry index: entries are
            // single composed sequences, so offsets align 1:1 in `ordered`.
            var seen = 0
            for idx in ordered {
                if seen >= offset { return nonWS[idx].bounds.minX }
                seen += nonWS[idx].character.count
            }
        }
        return nil
    }

    // MARK: scanner (the Layer-10 accumulator pattern —
    // `SandwichVerification.verifyTextOperatorSemantics` — with per-operand
    // strings instead of separator-joined bytes)

    static func decodedTextShowOperands(
        _ pageRef: CGPDFPage
    ) -> (scanned: Bool, operands: [String]) {
        var operands: [String] = []
        let scanned: Bool = withUnsafeMutablePointer(to: &operands) { accPtr in
            guard let table = CGPDFOperatorTableCreate() else { return false }
            defer { CGPDFOperatorTableRelease(table) }

            // PDF 1.7 §9.4.3 Table 107 — text-showing operators.
            CGPDFOperatorTableSetCallback(table, "Tj") { scanner, info in
                extractorTestAppendPoppedOperand(scanner: scanner, info: info)
            }
            CGPDFOperatorTableSetCallback(table, "'") { scanner, info in
                extractorTestAppendPoppedOperand(scanner: scanner, info: info)
            }
            CGPDFOperatorTableSetCallback(table, "\"") { scanner, info in
                extractorTestAppendPoppedOperand(scanner: scanner, info: info)
            }
            CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
                var pdfArray: CGPDFArrayRef?
                guard CGPDFScannerPopArray(scanner, &pdfArray),
                      let arr = pdfArray,
                      let info else { return }
                let ptr = info.assumingMemoryBound(to: [String].self)
                for i in 0..<CGPDFArrayGetCount(arr) {
                    var obj: CGPDFObjectRef?
                    guard CGPDFArrayGetObject(arr, i, &obj), let o = obj else {
                        // Numeric kerning displacements carry no text content.
                        continue
                    }
                    extractorTestAppendObjectText(o, into: ptr)
                }
            }

            let contentStream = CGPDFContentStreamCreateWithPage(pageRef)
            defer { CGPDFContentStreamRelease(contentStream) }
            let scanner = CGPDFScannerCreate(
                contentStream, table, UnsafeMutableRawPointer(accPtr))
            defer { CGPDFScannerRelease(scanner) }
            return CGPDFScannerScan(scanner)
        }
        return (scanned, operands)
    }
}

// MARK: - Scanner callback helpers
//
// `@convention(c)` callbacks installed via `CGPDFOperatorTableSetCallback`
// cannot capture Swift context. These file-private helpers operate on the
// scanner ref + the info pointer (which the callback site populates with a
// `&[String]` accumulator).

private func extractorTestAppendPoppedOperand(
    scanner: CGPDFScannerRef,
    info: UnsafeMutableRawPointer?
) {
    var obj: CGPDFObjectRef?
    guard CGPDFScannerPopObject(scanner, &obj),
          let o = obj,
          let info else { return }
    extractorTestAppendObjectText(o, into: info.assumingMemoryBound(to: [String].self))
}

private func extractorTestAppendObjectText(
    _ obj: CGPDFObjectRef,
    into ptr: UnsafeMutablePointer<[String]>
) {
    guard CGPDFObjectGetType(obj) == .string else { return }
    var s: CGPDFStringRef?
    let popped = withUnsafeMutablePointer(to: &s) { sPtr in
        CGPDFObjectGetValue(obj, .string, UnsafeMutableRawPointer(sPtr))
    }
    guard popped, let str = s,
          let decoded = CGPDFStringCopyTextString(str) else { return }
    ptr.pointee.append(decoded as String)
}
