import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

// S01 — Searchable-Redaction merge measurement harness.
//
// Permanent re-creation of the prior session's Probe 2/4/5 diagnostics (which
// were reverted after capture). Drives `TestFixtures.searchableMergeReproPDF`
// through the real pipeline + all 10 `VerificationEngine.runLayer` calls and
// measures the reconstructed output to settle the master plan's open questions
// (the searchable-verify-fix plan, OQ-1/2/4).
//
// ARCH §12.2 (VERBATIM): never log/record document content, file paths, or
// redaction coordinates. Every measurement below emits ONLY counts, ratios,
// geometry (widths/deviations in points), and font *resource* names — exactly
// the discipline of the engine's own count-only `PageFilterDigest`. Character
// content is read internally (to categorize / count scalars) but never printed,
// asserted-on, or returned as text.

// MARK: - §12.2-safe measurement records

/// One off-grid / near-zero composed-character advance observation. Carries
/// geometry + font *resource* name + scalar count only — no character content.
struct AdvanceOutlier: Sendable {
    let family: String
    let pointSize: Double
    let width: Double
    let expected: Double
    let deviation: Double
    let scalarCount: Int
    /// CoreText "Courier" horizontal advance summed over the grapheme's scalars
    /// at 12pt (OQ-2): distinguishes a single-grapheme ~0-width glyph (genuine
    /// residual) from a multi-scalar merge artifact.
    let courierAdvance12pt: Double
}

/// Composed-character advance profile of one output page (Probe 4 + Probe 2
/// scalar census). Content-free.
struct ComposedProfile: Sendable {
    var totalNonZeroBounds = 0       // counted by the SVT output walks
    var zeroOrNegBoundsCount = 0     // skipped by every output walk (case (a) candidates)
    var multiScalarCount = 0         // output composed sequences with >1 unicode scalar
    var monospaceCount = 0
    var nonMonospaceCount = 0
    var pointSizes: [Double] = []    // distinct rounded point sizes seen
    var offGridOutliers: [AdvanceOutlier] = []   // |width-expected| > tol on a monospace glyph
    var nearZeroPositive: [AdvanceOutlier] = []  // 0 < width on a monospace glyph, width ≪ expected
}

/// Per-character-category counts (Probe 2). Content-free — category buckets only.
struct CategoryCensus: Sendable {
    var letter = 0, digit = 0, whitespace = 0, punct = 0, symbol = 0, other = 0
    var multiScalar = 0
    static func - (lhs: CategoryCensus, rhs: CategoryCensus) -> CategoryCensus {
        var d = CategoryCensus()
        d.letter = lhs.letter - rhs.letter
        d.digit = lhs.digit - rhs.digit
        d.whitespace = lhs.whitespace - rhs.whitespace
        d.punct = lhs.punct - rhs.punct
        d.symbol = lhs.symbol - rhs.symbol
        d.other = lhs.other - rhs.other
        d.multiScalar = lhs.multiScalar - rhs.multiScalar
        return d
    }
    var description: String {
        "letter \(letter), digit \(digit), whitespace \(whitespace), "
        + "punct \(punct), symbol \(symbol), other \(other); multiScalar \(multiScalar)"
    }
}

/// One emitted output font dict: BaseFont *resource* name + /ToUnicode presence.
struct FontResourceInfo: Sendable {
    let baseFont: String
    let hasToUnicode: Bool
}

/// One-line §12.2-safe pipeline measurement: per-layer FAIL flags + count
/// deltas. `deficit > 0` is the ONLY thing that fails Layer 7 (output composed
/// fewer characters than survived); a non-positive deficit means output ≥
/// surviving (no loss). Counts/booleans only — no content.
struct QuickMeasure: Sendable, CustomStringConvertible {
    let tags: String
    let surviving: Int
    let output: Int
    let zeroBounds: Int
    let multiOut: Int
    let offGrid: Int
    let l6Fail, l7Fail, l8Fail, l9Fail, l10Fail: Bool
    /// surviving − output. > 0 ⇒ output composed < surviving (a genuine Layer-7 deficit).
    var deficit: Int { surviving - output }
    var description: String {
        "\(tags) | surv=\(surviving) out=\(output) deficit=\(deficit) "
        + "zeroB=\(zeroBounds) multiOut=\(multiOut) offGrid=\(offGrid)"
    }
}

enum ProbeMeasureError: Error { case noOutput }

// MARK: - Measurement harness

enum SearchableMergeProbe {

    static let cellWidth = TextLayerReconstructor.cellWidth          // 7.20117…pt
    static let advanceTol = SandwichVerification.advanceWidthTolerance // 0.25pt
    static let courierPerPt = SandwichVerification.courierAdvancePerPoint

    /// Run verification layers `0..<count` on an output document. Returns the
    /// LayerResult keyed by runtime array index.
    static func runLayers(
        outputDocument: SendablePDFDocument,
        sourcePageCount: Int,
        regions: [Int: [RedactionRegion]],
        digests: [PageFilterDigest?],
        perPageModes: [PipelineMode],
        sensitiveTerms: [String] = []
    ) async -> [Int: LayerResult] {
        let engine = VerificationEngine()
        let count = engine.layerCount(for: .searchableRedaction)
        var out: [Int: LayerResult] = [:]
        for idx in 0..<count {
            out[idx] = await engine.runLayer(
                idx,
                outputDocument: outputDocument,
                sourcePageCount: sourcePageCount,
                regions: regions,
                sensitiveTerms: sensitiveTerms,
                pipelineMode: .searchableRedaction,
                filterDigests: digests,
                perPageModes: perPageModes
            )
        }
        return out
    }

    /// Surviving `[CharacterInfo]` per page under the SAME extract+filter the
    /// pipeline performs (deterministic), so this matches the exported layer's
    /// input when called with the same `regions`. Needed for OQ-1 run-structure
    /// and the filter-side category census.
    static func survivingPerPage(
        _ fixtureData: Data,
        regions: [Int: [RedactionRegion]]
    ) async throws -> [[CharacterInfo]] {
        guard let doc = PDFDocument(data: fixtureData) else { return [] }
        let extractor = TextLayerExtractor()
        var result: [[CharacterInfo]] = []
        for pageIndex in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIndex) else { result.append([]); continue }
            guard let chars = try? await extractor.extractCharacters(from: page),
                  !chars.isEmpty else { result.append([]); continue }
            let pageRegions = regions[pageIndex] ?? []
            let pageBounds = page.bounds(for: .cropBox)
            let rects = pageRegions.map {
                normalizedToPDFPageCoordinates($0.normalizedRect, pageRect: pageBounds)
            }
            let filtered = try await filterCharacters(characters: chars, redactionRects: rects)
            result.append(filtered.surviving)
        }
        return result
    }

    /// Probe 4 + scalar census on one output page's composed-character walk.
    static func composedProfile(_ page: PDFPage) -> ComposedProfile {
        var p = ComposedProfile()
        guard let text = page.string else { return p }
        let ns = text as NSString
        let total = page.numberOfCharacters
        var sizeSet = Set<Double>()
        let courier12 = CTFontCreateWithName("Courier" as CFString, 12.0, nil)
        var offset = 0
        while offset < total {
            let range = ns.rangeOfComposedCharacterSequence(at: offset)
            defer { offset += max(range.length, 1) }
            guard let sel = page.selection(for: range) else { continue }
            let b = sel.bounds(for: page)
            let sub = ns.substring(with: range)
            let scalarCount = sub.unicodeScalars.count
            guard b.width > 0, b.height > 0 else {
                p.zeroOrNegBoundsCount += 1
                continue
            }
            p.totalNonZeroBounds += 1
            if scalarCount > 1 { p.multiScalarCount += 1 }

            var family = ""
            var pointSize = 0.0
            if let attr = sel.attributedString, attr.length > 0,
               let font = attr.attribute(.font, at: 0, effectiveRange: nil) as? UIFont {
                #if canImport(UIKit)
                family = font.familyName
                #else
                family = font.familyName ?? font.fontName
                #endif
                pointSize = Double(font.pointSize)
                sizeSet.insert((pointSize * 100).rounded() / 100)
            }
            let isMono = SandwichVerification.isCourierMonospaceFamily(family)
            if isMono { p.monospaceCount += 1 } else { p.nonMonospaceCount += 1 }
            guard isMono, pointSize > 0 else { continue }

            let expected = courierPerPt * pointSize
            let deviation = Double(b.width) - expected
            if abs(deviation) > Double(advanceTol) {
                let outlier = AdvanceOutlier(
                    family: family, pointSize: pointSize, width: Double(b.width),
                    expected: expected, deviation: deviation, scalarCount: scalarCount,
                    courierAdvance12pt: courierHorizontalAdvance(of: sub, font: courier12)
                )
                p.offGridOutliers.append(outlier)
                if Double(b.width) < expected {  // narrow side — near-zero positive class
                    p.nearZeroPositive.append(outlier)
                }
            }
        }
        p.pointSizes = sizeSet.sorted()
        return p
    }

    /// Category census of a sequence of composed-character strings. Content is
    /// inspected to bucket; only counts are retained (ARCH §12.2).
    static func census<S: Sequence>(_ composed: S) -> CategoryCensus where S.Element == String {
        var c = CategoryCensus()
        for s in composed {
            if s.unicodeScalars.count > 1 { c.multiScalar += 1 }
            guard let first = s.unicodeScalars.first else { continue }
            if s.allSatisfy({ $0.isWhitespace }) { c.whitespace += 1 }
            else if s.allSatisfy(\.isLetter) { c.letter += 1 }
            else if s.allSatisfy(\.isNumber) { c.digit += 1 }
            else if s.allSatisfy(\.isPunctuation) { c.punct += 1 }
            else if first.properties.isMath || s.allSatisfy(\.isSymbol) { c.symbol += 1 }
            else { c.other += 1 }
        }
        return c
    }

    /// Census of the surviving filter-side set (CharacterInfo.character strings).
    static func censusSurviving(_ chars: [CharacterInfo]) -> CategoryCensus {
        census(chars.map(\.character))
    }

    /// Census of an output page's non-zero-bounds composed-character walk.
    static func censusOutputNonZero(_ page: PDFPage) -> CategoryCensus {
        guard let text = page.string else { return CategoryCensus() }
        let ns = text as NSString
        let total = page.numberOfCharacters
        var emitted: [String] = []
        var offset = 0
        while offset < total {
            let range = ns.rangeOfComposedCharacterSequence(at: offset)
            defer { offset += max(range.length, 1) }
            guard let sel = page.selection(for: range) else { continue }
            let b = sel.bounds(for: page)
            guard b.width > 0, b.height > 0 else { continue }
            emitted.append(ns.substring(with: range))
        }
        return census(emitted)
    }

    /// Probe 5 — count drawn glyph operands on an output page by summing the
    /// byte-lengths of every Tj/'/"/TJ string operand (NO decode). For the
    /// reconstructor's simple Courier encoding this is ~one byte per drawn glyph.
    static func drawnGlyphOperandCount(_ page: PDFPage) -> Int {
        guard let pageRef = page.pageRef else { return 0 }
        var total = 0
        withUnsafeMutablePointer(to: &total) { totalPtr in
            guard let table = CGPDFOperatorTableCreate() else { return }
            defer { CGPDFOperatorTableRelease(table) }
            CGPDFOperatorTableSetCallback(table, "Tj") { sc, info in probeAppendStringLen(sc, info) }
            CGPDFOperatorTableSetCallback(table, "'") { sc, info in probeAppendStringLen(sc, info) }
            CGPDFOperatorTableSetCallback(table, "\"") { sc, info in probeAppendStringLen(sc, info) }
            CGPDFOperatorTableSetCallback(table, "TJ") { sc, info in
                var arr: CGPDFArrayRef?
                guard CGPDFScannerPopArray(sc, &arr), let a = arr, let info else { return }
                let ptr = info.assumingMemoryBound(to: Int.self)
                for i in 0..<CGPDFArrayGetCount(a) {
                    var s: CGPDFStringRef?
                    if CGPDFArrayGetString(a, i, &s), let str = s {
                        ptr.pointee += CGPDFStringGetLength(str)
                    }
                }
            }
            let cs = CGPDFContentStreamCreateWithPage(pageRef)
            defer { CGPDFContentStreamRelease(cs) }
            let scanner = CGPDFScannerCreate(cs, table, UnsafeMutableRawPointer(totalPtr))
            defer { CGPDFScannerRelease(scanner) }
            _ = CGPDFScannerScan(scanner)
        }
        return total
    }

    /// Emitted font dicts on an output page: BaseFont *resource* name +
    /// /ToUnicode presence. Mirrors what Layer 8 SVT-4 inspects.
    static func fontReport(_ page: PDFPage) -> [FontResourceInfo] {
        guard let pageRef = page.pageRef, let dict = pageRef.dictionary else { return [] }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let res = resources
        else { return [] }
        var fonts: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(res, "Font", &fonts), let fontDict = fonts
        else { return [] }

        var collected: [FontResourceInfo] = []
        withUnsafeMutablePointer(to: &collected) { collectedPtr in
            CGPDFDictionaryApplyBlock(fontDict, { _, value, ctx in
                var fontObj: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(value, .dictionary, &fontObj), let font = fontObj,
                      let ctx else { return true }
                var baseFont: UnsafePointer<CChar>?
                var name = "(unnamed)"
                if CGPDFDictionaryGetName(font, "BaseFont", &baseFont), let n = baseFont {
                    name = String(cString: n)
                }
                var cmap: CGPDFStreamRef?
                let hasToUnicode = CGPDFDictionaryGetStream(font, "ToUnicode", &cmap)
                ctx.assumingMemoryBound(to: [FontResourceInfo].self).pointee.append(
                    FontResourceInfo(baseFont: name, hasToUnicode: hasToUnicode)
                )
                return true
            }, collectedPtr)
        }
        return collected
    }

    /// CGPDFContext + CTLineDraw PDF builder for deficit-mechanism experiments
    /// (the same writer the reconstructor uses). Each entry is (text, x, y) in
    /// bottom-left PDF points.
    static func ctLinePDF(_ lines: [(text: String, x: CGFloat, y: CGFloat)], fontSize: CGFloat) -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctprobe_\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { return Data() }
        let font = CTFontCreateWithName("Courier" as CFString, fontSize, nil)
        ctx.beginPDFPage(nil)
        for entry in lines {
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: entry.text, attributes: attrs)
            )
            ctx.textPosition = CGPoint(x: entry.x, y: entry.y)
            CTLineDraw(line, ctx)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? Data(contentsOf: url)) ?? Data()
    }

    /// One-line §12.2-safe summary of a fixture through the full pipeline +
    /// the sandwich layers: which of Layers 6/7/8/9/10 FAIL, and the count
    /// deltas. Used to compare deficit mechanisms quickly.
    static func quickMeasure(_ fixture: Data, regions: [Int: [RedactionRegion]]) async throws -> QuickMeasure {
        let url = try await TestPipeline.processAndExport(
            fixture, mode: .searchableRedaction, regions: regions, dpi: 150
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let digests = try await TestPipeline.searchableDigests(fixture, regions: regions)
        guard let outDoc = PDFDocument(url: url) else { throw ProbeMeasureError.noOutput }
        let perPageModes = Array(repeating: PipelineMode.searchableRedaction, count: outDoc.pageCount)
        let layers = await runLayers(
            outputDocument: SendablePDFDocument(outDoc), sourcePageCount: outDoc.pageCount,
            regions: regions, digests: digests, perPageModes: perPageModes
        )
        var survTotal = 0, outTotal = 0, zeroB = 0, multi = 0, off = 0
        for pi in 0..<outDoc.pageCount {
            guard let page = outDoc.page(at: pi) else { continue }
            let prof = composedProfile(page)
            outTotal += prof.totalNonZeroBounds
            zeroB += prof.zeroOrNegBoundsCount
            multi += prof.multiScalarCount
            off += prof.offGridOutliers.count
            survTotal += (pi < digests.count ? digests[pi]?.survivingCount : nil) ?? 0
        }
        func tag(_ i: Int) -> String {
            guard let s = layers[i]?.status else { return "?" }
            if s.isFail { return "F" }; if s.isInfo { return "i" }; if s.isWarn { return "W" }
            return "P"
        }
        func fails(_ i: Int) -> Bool { layers[i]?.status.isFail == true }
        let tags = "L6=\(tag(5)) L7=\(tag(6)) L8=\(tag(7)) L9=\(tag(8)) L10=\(tag(9))"
        return QuickMeasure(
            tags: tags, surviving: survTotal, output: outTotal,
            zeroBounds: zeroB, multiOut: multi, offGrid: off,
            l6Fail: fails(5), l7Fail: fails(6), l8Fail: fails(7), l9Fail: fails(8), l10Fail: fails(9)
        )
    }

    /// Render a constructed `[CharacterInfo]` set through the REAL
    /// `TextLayerReconstructor.drawInvisibleTextLayer` into a throwaway
    /// CGPDFContext and return the output PDF data. This is the production
    /// reconstructor (not a modified copy) — the same path the round-trip
    /// adversarial tests use. Constructing the surviving set directly (rather
    /// than via a source PDF + extraction) is what lets us reproduce the
    /// run-boundary co-location merge: PDFKit's source-side gap-bridging — a
    /// synthetic-source artifact, not a real-doc one — is bypassed, so the
    /// surviving set carries the real-doc-shaped column gaps that the
    /// reconstructor then redraws into overlapping runs.
    static func renderInvisibleLayer(_ chars: [CharacterInfo], pageSize: CGSize) -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recon_\(UUID().uuidString).pdf")
        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        TextLayerReconstructor.drawInvisibleTextLayer(
            context: ctx, entries: chars,
            pageWidth: pageSize.width
        )
        ctx.endPDFPage()
        ctx.closePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? Data(contentsOf: url)) ?? Data()
    }

    /// OQ-4 FIX-A prototype (TEST-LOCAL — does NOT import or modify
    /// `TextLayerReconstructor`; draws into a throwaway CGPDFContext). Implements
    /// the master plan §4.1 monotonic cell assignment by hand and draws EACH
    /// grapheme as its own positioned Courier-12pt unit:
    ///   `x_k = max(floor(srcMinX/cw)·cw, x_{k-1}+cw)` per line; reset on a new
    /// line (Y change). This is the SHAPE S02 would put in the reconstructor —
    /// prototyped here so S01 can validate it produces on-grid, 1:1,
    /// non-overlapping placement before any production code is written.
    static func renderMonotonicPrototype(_ chars: [CharacterInfo], pageSize: CGSize) -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixaproto_\(UUID().uuidString).pdf")
        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return Data() }
        let font = CTFontCreateWithName("Courier" as CFString, 12.0, nil)
        let cw = cellWidth
        // Same sort groupIntoRuns uses (Y desc, then X asc) so lines are stable.
        let sorted = chars.sorted {
            if abs($0.bounds.midY - $1.bounds.midY) > $0.bounds.height * 0.5 {
                return $0.bounds.midY > $1.bounds.midY
            }
            return $0.bounds.minX < $1.bounds.minX
        }
        ctx.beginPDFPage(nil)
        var lastMidY = CGFloat.greatestFiniteMagnitude
        var prevX = -CGFloat.greatestFiniteMagnitude
        for c in sorted {
            let newLine = lastMidY == .greatestFiniteMagnitude
                || abs(c.bounds.midY - lastMidY) > c.bounds.height * 0.5
            if newLine { lastMidY = c.bounds.midY; prevX = -.greatestFiniteMagnitude }
            let snapped = (c.bounds.minX / cw).rounded(.down) * cw
            let x = prevX == -.greatestFiniteMagnitude ? snapped : max(snapped, prevX + cw)
            prevX = x
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: c.character, attributes: attrs))
            ctx.textPosition = CGPoint(x: x, y: c.bounds.minY)
            CTLineDraw(line, ctx)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? Data(contentsOf: url)) ?? Data()
    }

    /// Construct a surviving set mimicking a born-digital small-font two-column
    /// table: each row's left column starts at x=72, the right column at
    /// `rightX`, with per-glyph advance `advance` (the cell width the reconstructor
    /// does NOT honor — it redraws at 7.20pt). The gap breaks `groupIntoRuns`
    /// into two runs whose 12pt redraw overlaps. `y` descends per row.
    static func constructedTableSurviving(
        rows: [(left: String, right: String)],
        advance: CGFloat = 4.2, rightX: CGFloat = 140, glyphHeight: CGFloat = 7
    ) -> [CharacterInfo] {
        var chars: [CharacterInfo] = []
        var idx = 0
        var y: CGFloat = 700
        for row in rows {
            var x: CGFloat = 72
            for ch in row.left {
                chars.append(CharacterInfo(
                    character: String(ch),
                    bounds: CGRect(x: x, y: y, width: advance * 0.9, height: glyphHeight),
                    stringIndex: idx))
                x += advance; idx += 1
            }
            x = rightX
            for ch in row.right {
                chars.append(CharacterInfo(
                    character: String(ch),
                    bounds: CGRect(x: x, y: y, width: advance * 0.9, height: glyphHeight),
                    stringIndex: idx))
                x += advance; idx += 1
            }
            y -= 14
        }
        return chars
    }

    /// CoreText horizontal advance of `grapheme` summed over its UTF-16 units
    /// in the given font. Used to classify near-zero output glyphs (OQ-2)
    /// without printing the grapheme.
    static func courierHorizontalAdvance(of grapheme: String, font: CTFont) -> Double {
        let utf16 = Array(grapheme.utf16)
        guard !utf16.isEmpty else { return 0 }
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        let ok = CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count)
        guard ok else { return -1 }  // -1 = font lacks a glyph for some scalar
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        return advances.reduce(0.0) { $0 + Double($1.width) }
    }

    /// Source-side (pre-reconstruction) structure of a surviving set. Explains
    /// why `groupIntoRuns` does or does not split a line. Geometry/counts only.
    struct SourceAnalysis: Sendable {
        var survivingCount = 0
        var whitespaceCount = 0   // surviving chars that are whitespace (bridge gaps)
        var multiScalarCount = 0  // surviving graphemes with >1 unicode scalar
        var lineCount = 0
        var breakCount = 0        // same-line adjacencies groupIntoRuns would split
        var sampleBreakGaps: [Double] = []  // first few break gaps (points)
        var medianGlyphWidth = 0.0
    }
    static func sourceAnalysis(_ chars: [CharacterInfo]) -> SourceAnalysis {
        var a = SourceAnalysis()
        a.survivingCount = chars.count
        var widths: [Double] = []
        for c in chars {
            if !c.character.isEmpty, c.character.allSatisfy({ $0.isWhitespace }) { a.whitespaceCount += 1 }
            if c.character.unicodeScalars.count > 1 { a.multiScalarCount += 1 }
            widths.append(Double(c.bounds.width))
        }
        if !widths.isEmpty { a.medianGlyphWidth = widths.sorted()[widths.count / 2] }
        // Mirror groupIntoRuns' sort + adjacency rule exactly.
        let sorted = chars.sorted {
            if abs($0.bounds.midY - $1.bounds.midY) > $0.bounds.height * 0.5 {
                return $0.bounds.midY > $1.bounds.midY
            }
            return $0.bounds.minX < $1.bounds.minX
        }
        var lineYs: [CGFloat] = []
        for c in sorted where !lineYs.contains(where: { abs($0 - c.bounds.midY) < c.bounds.height * 0.5 }) {
            lineYs.append(c.bounds.midY)
        }
        a.lineCount = lineYs.count
        if sorted.count > 1 {
            let lineHeight = sorted[0].bounds.height
            for i in 1..<sorted.count {
                let prev = sorted[i - 1], curr = sorted[i]
                let sameLine = abs(prev.bounds.midY - curr.bounds.midY) < lineHeight * 0.5
                let gap = curr.bounds.minX - prev.bounds.maxX
                if sameLine && gap >= prev.bounds.width * 1.5 {
                    a.breakCount += 1
                    if a.sampleBreakGaps.count < 6 { a.sampleBreakGaps.append(Double(gap)) }
                }
            }
        }
        return a
    }

    /// `groupIntoRuns` structure of a surviving set: run count + per-run length.
    static func runStructure(_ chars: [CharacterInfo]) -> (runCount: Int, runLengths: [Int]) {
        let runs = TextLayerReconstructor.groupIntoRuns(chars)
        let lengths = runs.map { ($0.text as NSString).length == 0 ? 0
            : composedLength(of: $0.text) }
        return (runs.count, lengths)
    }

    /// Number of NSString composed-character sequences in a string.
    static func composedLength(of s: String) -> Int {
        let ns = s as NSString
        var count = 0, offset = 0
        while offset < ns.length {
            let r = ns.rangeOfComposedCharacterSequence(at: offset)
            count += 1
            offset += max(r.length, 1)
        }
        return count
    }
}

// `@convention(c)` scanner callback can't capture Swift context — file-private
// global, same pattern as SandwichVerification's Layer 10 helpers.
fileprivate func probeAppendStringLen(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    var s: CGPDFStringRef?
    guard CGPDFScannerPopString(scanner, &s), let str = s, let info else { return }
    info.assumingMemoryBound(to: Int.self).pointee += CGPDFStringGetLength(str)
}
