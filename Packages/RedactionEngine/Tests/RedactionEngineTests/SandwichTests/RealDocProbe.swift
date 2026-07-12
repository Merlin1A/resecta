import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

// S03 — pipeline measurement helpers for `RealDocProbeTests`.
//
// Operates on a committed synthetic fixture (the parameterized
// fixture-plus-regions pipeline probe; the fixture payload is `Data`).
// Logging scope for the document under test: per-glyph data only —
// Unicode scalar values (hex), UTF-16 offsets, bounds/geometry, font and
// subset names, page numbers. NEVER running text (words/lines/sentences).
// Content strings are held internally for sequence alignment; everything
// printed goes through `scalarHex`, counts, or geometry. Production code
// rules (ARCH §12.2) are untouched — this file is test-only measurement.

// MARK: - Records

/// One composed unit of an output page's full `page.string` walk — NO skip
/// conditions applied, so the three verifier skip classes (nil selection,
/// zero/negative bounds, whitespace) are all observable per unit.
struct RealDocOutputUnit {
    let utf16Offset: Int
    let string: String
    let hasSelection: Bool
    let bounds: CGRect
    let family: String
    let pointSize: Double
    var positiveBounds: Bool { hasSelection && bounds.width > 0 && bounds.height > 0 }
    var zeroOrNegBounds: Bool { hasSelection && !(bounds.width > 0 && bounds.height > 0) }
}

/// One composed unit of the filter-side walk — the SAME iteration the
/// lineage hash uses (`groupIntoRuns(surviving)` run texts, composed-
/// sequence ranges). `memberIndices` are indices into the surviving
/// `[CharacterInfo]` array whose UTF-16 units this composed unit spans
/// (>1 member = run-text recomposition fused source graphemes).
struct RealDocFilterUnit {
    let runIndex: Int
    let string: String
    let memberIndices: [Int]
}

/// Probe-A deficit buckets (handoff step 3A).
enum RealDocDeficitBucket: String, CaseIterable {
    /// (i) present in page.string with selection bounds w≤0 || h≤0 — counted
    /// out by `countComposedCharacters` (§3.5 case (a) at scale).
    case zeroBounds = "ZERO/NEG-BOUNDS"
    /// (i-adjacent) present in page.string but `selection(for:)` is nil —
    /// also counted out by every output walk; tracked separately.
    case nilSelection = "NIL-SELECTION"
    /// (ii) not present in the output composed string at all.
    case absent = "ABSENT-FROM-STRING"
    /// (iii) present but fused with a neighbor into one composed unit.
    case merged = "MERGED"
    /// (iv) unclear — described in the row.
    case other = "OTHER"
}

/// One capped-table row for a deficit-bucketed glyph. §12.2-scoped per the
/// real-doc approval: scalar hex + offsets + geometry + font names only.
struct RealDocGlyphRow {
    let bucket: RealDocDeficitBucket
    let fUnitIndex: Int       // index into the filter-unit walk (probe-C co-location)
    let scalarsHex: String
    let srcOffset: Int        // CharacterInfo.stringIndex on the SOURCE page
    let outOffset: Int        // aligned output UTF-16 offset; −1 when absent
    let srcBounds: CGRect
    let outBounds: CGRect     // .null when absent / nil selection
    let family: String        // output selection font family ("" when absent)
    let courierAdv12: Double  // CoreText Courier-12 natural advance of the grapheme
}

/// Probe-A reconciliation result for one page. The counters decompose the
/// Layer-7 deficit exactly:
///   surviving − outputPositive =
///       zeroBounds + nilSelection + absent
///     + (mergedFilterMembers − mergedOutputUnitsPositive)
///     + (splitFilterUnits − splitOutputUnitsPositive)
///     + (survivingCount − filterUnitCount)   ← run-text fusion (+) / expansion (−)
///     − synthesizedPositive
/// (`survivingCount − filterUnitCount`: a multi-scalar CharacterInfo whose
/// scalars re-walk as MORE composed units in run.text yields F > S —
/// "expansion"; recomposition across CharacterInfos yields F < S — "fusion".)
struct RealDocReconciliation {
    var survivingCount = 0           // CharacterInfo count (== digest.survivingCount)
    var filterUnitCount = 0
    var outputUnitCount = 0
    var outputPositiveCount = 0      // O-units with positive bounds (== countComposedCharacters)
    var matchedPositive = 0          // F-unit ↔ positive-bounds O-unit, 1:1
    var bucketCounts: [RealDocDeficitBucket: Int] = [:]
    var rows: [RealDocGlyphRow] = []
    var synthesizedPositive = 0      // O-units with positive bounds, no F counterpart
    var synthesizedOther = 0         // O-units without positive bounds, no F counterpart
    var fusedFilterMembers = 0       // surviving CharacterInfos beyond 1 per F-unit
    var mergedOutputUnits = 0        // O-units carrying ≥2 F-units (bucket iii)
    var mergedOutputUnitsPositive = 0
    var splitFilterUnits = 0         // F-units re-extracted as ≥2 O-units
    var splitOutputUnits = 0
    var splitOutputUnitsPositive = 0
    func bucket(_ b: RealDocDeficitBucket) -> Int { bucketCounts[b] ?? 0 }
    /// Right-hand side of the deficit identity above.
    var explainedDeficit: Int {
        bucket(.zeroBounds) + bucket(.nilSelection) + bucket(.absent)
            + (bucket(.merged) - mergedOutputUnitsPositive)
            + (splitFilterUnits - splitOutputUnitsPositive)
            + (survivingCount - filterUnitCount)
            - synthesizedPositive
    }
}

/// Off-page draw prediction for one page (the S03-measured mechanism
/// hypothesis): the reconstructor redraws each run at the pinned 12pt /
/// 7.2pt cell pitch from its snapped source origin, so a long small-font
/// source line extends past the page's right edge; glyphs drawn off-page do
/// not surface in PDFKit's composed re-extraction.
struct RealDocOffPagePrediction {
    var runCount = 0
    var overrunningRuns = 0
    var predictedFullyOffPage = 0    // cell start ≥ page width
    var predictedEdgeClipped = 0     // cell straddles the page edge
    var maxRunEndX = 0.0
    var perRun: [(originX: Double, length: Int, endX: Double, offPage: Int)] = []
}

/// Coverage row for probe D: one distinct surviving grapheme.
struct RealDocCoverageRow {
    let scalarsHex: String
    let occurrences: Int
    let courierCovered: Bool
    let menloCovered: Bool
}

/// Everything one pipeline pass produces (config-scoped). The output
/// document is URL-backed (Layer 0's /AcroForm walk needs `documentURL`;
/// a data-backed document degrades it to WARN) — callers remove
/// `outputURL` when finished.
struct RealDocPipelineRun {
    let outputURL: URL
    let outputDocument: PDFDocument
    let digests: [PageFilterDigest?]
    let layers: [Int: LayerResult]
    let surviving: [[CharacterInfo]]
}

// MARK: - Harness

enum RealDocProbe {

    // Redaction configs. A is the original 2026-06-03 run's box (page-1 top
    // margin, normalized bottom-left origin; filtered ≈0 chars). B covers
    // page-1 dense mid-body. C moves A's box to page 6 (index 5) only.
    static func regionsA() -> [Int: [RedactionRegion]] {
        [0: [RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.05),
            source: .manual)]]
    }
    static func regionsB() -> [Int: [RedactionRegion]] {
        [0: [RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.45, width: 0.8, height: 0.10),
            source: .manual)]]
    }
    static func regionsC() -> [Int: [RedactionRegion]] {
        [5: [RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.05),
            source: .manual)]]
    }

    /// Simulator runtime version string, e.g. "26.4.0" — per-runtime results
    /// in the printed reports key off this.
    static var runtimeTag: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
    /// True on the iOS 26.5+ simulator runtime (runtime-guarded pins).
    static var isRuntime265OrLater: Bool {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.majorVersion > 26 || (v.majorVersion == 26 && v.minorVersion >= 5)
    }

    /// Full pipeline pass + all 10 verification layers on the fixture.
    /// Caller removes `outputURL` when finished with the run.
    static func run(
        _ fixture: Data, regions: [Int: [RedactionRegion]]
    ) async throws -> RealDocPipelineRun {
        let url = try await TestPipeline.processAndExport(
            fixture, mode: .searchableRedaction, regions: regions, dpi: 150)
        let digests = try await TestPipeline.searchableDigests(fixture, regions: regions)
        let surviving = try await SearchableMergeProbe.survivingPerPage(fixture, regions: regions)
        guard let outDoc = PDFDocument(url: url) else { throw ProbeMeasureError.noOutput }
        let perPageModes = [PipelineMode](
            repeating: PipelineMode.searchableRedaction, count: outDoc.pageCount)
        let layers = await SearchableMergeProbe.runLayers(
            outputDocument: SendablePDFDocument(outDoc),
            sourcePageCount: outDoc.pageCount,
            regions: regions, digests: digests, perPageModes: perPageModes)
        return RealDocPipelineRun(
            outputURL: url, outputDocument: outDoc, digests: digests,
            layers: layers, surviving: surviving)
    }

    /// Cross-run overlap spans for a page's surviving set: runs grouped by
    /// line (shared origin.y), spans computed at the redraw pitch. A line
    /// split into two runs whose 12pt redraw spans intersect co-locates the
    /// overlapped glyphs mid-page — the degenerate-selection-width locus.
    static func runOverlaps(
        _ surviving: [CharacterInfo]
    ) -> [(runA: Int, runB: Int, startX: Double, endX: Double, y: Double)] {
        let cw = Double(TextLayerReconstructor.cellWidth)
        let runs = TextLayerReconstructor.groupIntoRuns(surviving)
        let spans = runs.enumerated().map { (i, run) in
            (idx: i, y: Double(run.origin.y), startX: Double(run.origin.x),
             endX: Double(run.origin.x)
                + Double(SearchableMergeProbe.composedLength(of: run.text)) * cw)
        }
        var pairs: [(Int, Int, Double, Double, Double)] = []
        for i in 0..<spans.count {
            for j in (i + 1)..<spans.count where abs(spans[i].y - spans[j].y) < 1.0 {
                let s = max(spans[i].startX, spans[j].startX)
                let e = min(spans[i].endX, spans[j].endX)
                if e > s { pairs.append((spans[i].idx, spans[j].idx, s, e, spans[i].y)) }
            }
        }
        return pairs
    }

    /// J-10/d-1 candidate-fit evaluation for one page at an arbitrary
    /// candidate base size: groups the surviving set with `groupIntoRuns`'
    /// exact sort + adjacency rule (cellWidth-INDEPENDENT), then evaluates
    /// the redraw geometry at `cw(b) = 0.60009765625 × b` from re-snapped
    /// raw origins — without touching the production constants. Criteria
    /// per the approved J-10 scope: every run's span must end ≥ 1 full
    /// cell inside the page box, and no same-line run-pair spans intersect.
    struct CandidateFit {
        var runCount = 0
        var overrunningRuns = 0      // snapped + len·cw > pageWidth
        var marginViolations = 0     // snapped + (len+1)·cw > pageWidth
        var overlapPairs = 0         // same-line run-pair span intersections
        var maxRunEndX = 0.0
        var minMarginCells = Double.infinity  // (pageWidth − endX)/cw, min over runs
    }
    /// groupIntoRuns' sort + adjacency mirror (same derivation as
    /// `filterUnits`), returning member-index groups so raw origins stay
    /// recoverable (production `TextRun` only carries the snapped origin).
    static func runGroups(_ surviving: [CharacterInfo]) -> [[Int]] {
        guard !surviving.isEmpty else { return [] }
        let sortedIdx = surviving.indices.sorted {
            let a = surviving[$0], b = surviving[$1]
            if abs(a.bounds.midY - b.bounds.midY) > a.bounds.height * 0.5 {
                return a.bounds.midY > b.bounds.midY
            }
            return a.bounds.minX < b.bounds.minX
        }
        var groups: [[Int]] = []
        var current: [Int] = [sortedIdx[0]]
        let lineHeight = surviving[sortedIdx[0]].bounds.height
        for i in 1..<sortedIdx.count {
            let prev = surviving[sortedIdx[i - 1]], curr = surviving[sortedIdx[i]]
            let sameLine = abs(prev.bounds.midY - curr.bounds.midY) < lineHeight * 0.5
            let adjacent = (curr.bounds.minX - prev.bounds.maxX) < prev.bounds.width * 1.5
            if sameLine && adjacent { current.append(sortedIdx[i]) }
            else { groups.append(current); current = [sortedIdx[i]] }
        }
        groups.append(current)
        return groups
    }

    static func candidateFit(
        _ surviving: [CharacterInfo], pageWidth: Double, base: Double
    ) -> CandidateFit {
        var f = CandidateFit()
        guard !surviving.isEmpty else { return f }
        let cw = Double(SandwichVerification.courierAdvancePerPoint) * base
        var spans: [(y: Double, startX: Double, endX: Double)] = []
        for members in runGroups(surviving) {
            let rawX = Double(surviving[members[0]].bounds.minX)
            let y = Double(surviving[members[0]].bounds.origin.y)
            let text = members.map { surviving[$0].character }.joined()
            let len = SearchableMergeProbe.composedLength(of: text)
            let snapped = (rawX / cw).rounded(.down) * cw
            let endX = snapped + Double(len) * cw
            spans.append((y, snapped, endX))
            f.runCount += 1
            f.maxRunEndX = max(f.maxRunEndX, endX)
            if endX > pageWidth { f.overrunningRuns += 1 }
            if endX + cw > pageWidth { f.marginViolations += 1 }
            f.minMarginCells = min(f.minMarginCells, (pageWidth - endX) / cw)
        }
        for i in 0..<spans.count {
            for j in (i + 1)..<spans.count where abs(spans[i].y - spans[j].y) < 1.0 {
                if min(spans[i].endX, spans[j].endX) > max(spans[i].startX, spans[j].startX) {
                    f.overlapPairs += 1
                }
            }
        }
        return f
    }

    /// S05-B measurement — test-local single-page per-GLYPH redraw at an
    /// arbitrary base: the retired FIX-A monotonic-cell shape
    /// (`x_k = max(floor(srcMinX/cw)·cw, x_{k-1}+cw)` per line, each glyph
    /// its own CTLine) evaluated at a REDUCED pitch. FIX-A was retired at
    /// the 12pt pitch because cw (7.2pt) exceeded the source advance
    /// (~5pt), so the monotonic bump accumulated rightward; at cw ≤ the
    /// source advance the bump rarely engages and every glyph stays
    /// source-anchored within one cell — the candidate the S05 blocker
    /// measures as "d-5". The production reconstructor is NOT exercised.
    static func perGlyphRedrawPDF(
        _ surviving: [CharacterInfo], pageBox: CGRect, base: Double
    ) -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rdglyph_\(UUID().uuidString).pdf")
        var box = pageBox
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return Data() }
        let cw = Double(SandwichVerification.courierAdvancePerPoint) * base
        let font = CTFontCreateWithName("Courier" as CFString, CGFloat(base), nil)
        ctx.beginPDFPage(nil)
        ctx.setTextDrawingMode(.invisible)
        for members in runGroups(surviving) {
            var prevX = -Double.greatestFiniteMagnitude
            let y = surviving[members[0]].bounds.origin.y
            for m in members {
                let snapped = (Double(surviving[m].bounds.minX) / cw).rounded(.down) * cw
                let x = prevX == -.greatestFiniteMagnitude ? snapped : max(snapped, prevX + cw)
                prevX = x
                let line = CTLineCreateWithAttributedString(NSAttributedString(
                    string: surviving[m].character,
                    attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
                ctx.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(line, ctx)
            }
        }
        ctx.endPDFPage()
        ctx.closePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? Data(contentsOf: url)) ?? Data()
    }

    /// S05-B measurement — test-local single-page redraw at a PER-LINE
    /// pitch ("d-2-generalized"): each line draws at the font size whose
    /// Courier advance equals that line's median source glyph width
    /// (`size = medianWidth / 0.60009765625`), runs at origins snapped to
    /// that line's grid. The drawn layout therefore tracks the SOURCE
    /// layout (extents, gaps, indentation ≈ source), which is the property
    /// the order probes show PDFKit's reading order keys on. CONTENT-
    /// DEPENDENT geometry (the J-10 d-2 arm): per-line size is derived
    /// from source metrics, so shipping it requires the §5C.4 leakage
    /// argument + spec amendment (quantization policy etc.) — this probe
    /// only measures the mechanics. SVT-1 is size-agnostic (expected
    /// advance = 0.6001 × the output glyph's own pointSize), so per-line
    /// sizes keep the advance crosscheck green for natural one-cell glyphs.
    static func perLinePitchRedrawPDF(
        _ surviving: [CharacterInfo], pageBox: CGRect
    ) -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rdperline_\(UUID().uuidString).pdf")
        var box = pageBox
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        ctx.setTextDrawingMode(.invisible)
        let groups = runGroups(surviving)
        var i = 0
        while i < groups.count {
            let y0 = Double(surviving[groups[i][0]].bounds.origin.y)
            var lineGroups = [groups[i]]
            var j = i + 1
            while j < groups.count,
                  abs(Double(surviving[groups[j][0]].bounds.origin.y) - y0) < 1.0 {
                lineGroups.append(groups[j]); j += 1
            }
            i = j
            let widths = lineGroups.flatMap { $0 }
                .map { Double(surviving[$0].bounds.width) }.sorted()
            let medianW = widths.isEmpty ? 4.2 : widths[widths.count / 2]
            let size = max(1.0, medianW / Double(SandwichVerification.courierAdvancePerPoint))
            let cwL = medianW
            let font = CTFontCreateWithName("Courier" as CFString, CGFloat(size), nil)
            for members in lineGroups {
                let rawX = Double(surviving[members[0]].bounds.minX)
                let snapped = (rawX / cwL).rounded(.down) * cwL
                let text = members.map { surviving[$0].character }.joined()
                let line = CTLineCreateWithAttributedString(NSAttributedString(
                    string: text,
                    attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
                ctx.textPosition = CGPoint(x: snapped, y: surviving[members[0]].bounds.origin.y)
                CTLineDraw(line, ctx)
            }
        }
        ctx.endPDFPage()
        ctx.closePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? Data(contentsOf: url)) ?? Data()
    }

    /// S05-B measurement — test-local single-page redraw with same-line
    /// LAYOUT-GAP BRIDGING ("d-6"): same-line runs merge into ONE CTLine,
    /// the inter-run gap filled with invisible space glyphs so every gap
    /// cell carries a real on-grid space (count = quantized gap width — the
    /// same information the two snapped origins already expose, so zero new
    /// leakage bits). Kills both measured failure modes at a reduced base:
    /// no same-line gap for PDFKit's column heuristic to break reading
    /// order on, and no overlap by construction. Whitespace is excluded
    /// from the lineage hash on both sides, and the count layer tolerates
    /// the bridged-space excess. NOTE for any production design: a bridge
    /// must NOT cross a redaction region's span (drawing a glyph inside a
    /// region trips Layer 6's spatial check) — region-gap detection is a
    /// production concern this test-local probe does not model (config A's
    /// box holds no characters and bridges no redacted span).
    static func bridgedRedrawPDF(
        _ surviving: [CharacterInfo], pageBox: CGRect, base: Double
    ) -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rdbridge_\(UUID().uuidString).pdf")
        var box = pageBox
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return Data() }
        let cw = Double(SandwichVerification.courierAdvancePerPoint) * base
        let font = CTFontCreateWithName("Courier" as CFString, CGFloat(base), nil)
        ctx.beginPDFPage(nil)
        ctx.setTextDrawingMode(.invisible)
        let groups = runGroups(surviving)
        var i = 0
        while i < groups.count {
            // Collect the maximal same-line group run (runGroups order is
            // Y-desc then X-asc, so same-line groups are adjacent).
            let y0 = Double(surviving[groups[i][0]].bounds.origin.y)
            var lineGroups = [groups[i]]
            var j = i + 1
            while j < groups.count,
                  abs(Double(surviving[groups[j][0]].bounds.origin.y) - y0) < 1.0 {
                lineGroups.append(groups[j]); j += 1
            }
            i = j
            let originX = (Double(surviving[lineGroups[0][0]].bounds.minX) / cw)
                .rounded(.down) * cw
            var text = ""
            for members in lineGroups {
                if !text.isEmpty {
                    let target = (Double(surviving[members[0]].bounds.minX) / cw)
                        .rounded(.down) * cw
                    let cursorEnd = originX
                        + Double(SearchableMergeProbe.composedLength(of: text)) * cw
                    let gapCells = max(1, Int(((target - cursorEnd) / cw).rounded()))
                    text += String(repeating: " ", count: gapCells)
                }
                text += members.map { surviving[$0].character }.joined()
            }
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            ctx.textPosition = CGPoint(x: originX, y: surviving[lineGroups[0][0]].bounds.origin.y)
            CTLineDraw(line, ctx)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? Data(contentsOf: url)) ?? Data()
    }

    /// S05-B measurement — test-local single-page redraw of a surviving set
    /// at an arbitrary candidate base (the d-1 drawing shape: one CTLine
    /// per run, Courier at `base`, origin floor-snapped to the candidate
    /// cell grid, Y source-aligned). `scaleOrigins` draws the d-1′ variant
    /// instead: raw origin X is first scaled by `base/12` (a single global
    /// constant — uniform horizontal compression of the whole layout) and
    /// then snapped, which preserves the 12pt-era inter-run gap RATIOS.
    /// The production reconstructor is NOT exercised.
    static func candidateRedrawPDF(
        _ surviving: [CharacterInfo], pageBox: CGRect,
        base: Double, scaleOrigins: Bool
    ) -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rdcand_\(UUID().uuidString).pdf")
        var box = pageBox
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return Data() }
        let cw = Double(SandwichVerification.courierAdvancePerPoint) * base
        let font = CTFontCreateWithName("Courier" as CFString, CGFloat(base), nil)
        let originScale = scaleOrigins ? base / 12.0 : 1.0
        ctx.beginPDFPage(nil)
        ctx.setTextDrawingMode(.invisible)
        for members in runGroups(surviving) {
            let rawX = Double(surviving[members[0]].bounds.minX)
            let y = surviving[members[0]].bounds.origin.y
            let snapped = ((rawX * originScale) / cw).rounded(.down) * cw
            let text = members.map { surviving[$0].character }.joined()
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            ctx.textPosition = CGPoint(x: snapped, y: y)
            CTLineDraw(line, ctx)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? Data(contentsOf: url)) ?? Data()
    }

    /// Predict per-run off-page glyph counts for a page's surviving set:
    /// each run draws at `snappedOrigin.x + cellIndex × cellWidth`; cells at
    /// or past the page's right edge are predicted to vanish from the
    /// composed re-extraction, the straddling cell to clip.
    static func offPagePrediction(
        _ surviving: [CharacterInfo], pageWidth: Double
    ) -> RealDocOffPagePrediction {
        var p = RealDocOffPagePrediction()
        let cw = Double(TextLayerReconstructor.cellWidth)
        let runs = TextLayerReconstructor.groupIntoRuns(surviving)
        p.runCount = runs.count
        for run in runs {
            let len = SearchableMergeProbe.composedLength(of: run.text)
            let originX = Double(run.origin.x)
            let endX = originX + Double(len) * cw
            var offPage = 0
            for k in 0..<len {
                let cellStart = originX + Double(k) * cw
                if cellStart >= pageWidth {
                    offPage += 1
                } else if cellStart + cw > pageWidth {
                    p.predictedEdgeClipped += 1
                }
            }
            p.predictedFullyOffPage += offPage
            if endX > pageWidth { p.overrunningRuns += 1 }
            p.maxRunEndX = max(p.maxRunEndX, endX)
            p.perRun.append((originX, len, endX, offPage))
        }
        return p
    }

    // MARK: Walks

    /// Full composed-unit walk of an output page (no skip conditions).
    static func outputUnits(_ page: PDFPage) -> [RealDocOutputUnit] {
        guard let text = page.string else { return [] }
        let ns = text as NSString
        let total = page.numberOfCharacters
        var units: [RealDocOutputUnit] = []
        var offset = 0
        while offset < total {
            let range = ns.rangeOfComposedCharacterSequence(at: offset)
            defer { offset += max(range.length, 1) }
            let sub = ns.substring(with: range)
            guard let sel = page.selection(for: range) else {
                units.append(RealDocOutputUnit(
                    utf16Offset: range.location, string: sub, hasSelection: false,
                    bounds: .null, family: "", pointSize: 0))
                continue
            }
            let b = sel.bounds(for: page)
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
            }
            units.append(RealDocOutputUnit(
                utf16Offset: range.location, string: sub, hasSelection: true,
                bounds: b, family: family, pointSize: pointSize))
        }
        return units
    }

    /// Filter-side composed-unit walk over `groupIntoRuns(surviving)` run
    /// texts — the lineage hash's iteration — with member back-links into the
    /// surviving array. Mirrors run construction (sort + concatenation) so
    /// member spans line up with composed ranges in each run text.
    static func filterUnits(_ surviving: [CharacterInfo]) -> [RealDocFilterUnit] {
        guard !surviving.isEmpty else { return [] }
        // Re-derive groupIntoRuns' sorted order WITH original indices.
        let sortedIdx = surviving.indices.sorted {
            let a = surviving[$0], b = surviving[$1]
            if abs(a.bounds.midY - b.bounds.midY) > a.bounds.height * 0.5 {
                return a.bounds.midY > b.bounds.midY
            }
            return a.bounds.minX < b.bounds.minX
        }
        // Re-derive the run boundaries with groupIntoRuns' adjacency rule.
        var runsMembers: [[Int]] = []
        var current: [Int] = [sortedIdx[0]]
        let lineHeight = surviving[sortedIdx[0]].bounds.height
        for i in 1..<sortedIdx.count {
            let prev = surviving[sortedIdx[i - 1]], curr = surviving[sortedIdx[i]]
            let sameLine = abs(prev.bounds.midY - curr.bounds.midY) < lineHeight * 0.5
            let adjacent = (curr.bounds.minX - prev.bounds.maxX) < prev.bounds.width * 1.5
            if sameLine && adjacent {
                current.append(sortedIdx[i])
            } else {
                runsMembers.append(current)
                current = [sortedIdx[i]]
            }
        }
        runsMembers.append(current)

        var units: [RealDocFilterUnit] = []
        for (runIdx, members) in runsMembers.enumerated() {
            // Build the run text and the UTF-16 span of each member in it.
            var text = ""
            var spans: [(member: Int, range: NSRange)] = []
            var loc = 0
            for m in members {
                let s = surviving[m].character
                let len = (s as NSString).length
                spans.append((m, NSRange(location: loc, length: len)))
                text.append(contentsOf: s)
                loc += len
            }
            let ns = text as NSString
            var offset = 0
            while offset < ns.length {
                let range = ns.rangeOfComposedCharacterSequence(at: offset)
                defer { offset += max(range.length, 1) }
                let owners = spans.filter {
                    NSIntersectionRange($0.range, range).length > 0
                }.map(\.member)
                units.append(RealDocFilterUnit(
                    runIndex: runIdx,
                    string: ns.substring(with: range),
                    memberIndices: owners))
            }
        }
        return units
    }

    // MARK: Alignment (probe A)

    /// Longest-common-subsequence alignment over the two unit-string
    /// sequences. Returns aligned index pairs; nil on one side = gap
    /// (deletion from F / insertion into O).
    static func lcsAlign(_ f: [String], _ o: [String]) -> [(fIdx: Int?, oIdx: Int?)] {
        let m = f.count, n = o.count
        // DP table, row-major (m+1)×(n+1).
        var dp = [Int32](repeating: 0, count: (m + 1) * (n + 1))
        func at(_ i: Int, _ j: Int) -> Int { i * (n + 1) + j }
        if m > 0, n > 0 {
            for i in 1...m {
                for j in 1...n {
                    if f[i - 1] == o[j - 1] {
                        dp[at(i, j)] = dp[at(i - 1, j - 1)] + 1
                    } else {
                        dp[at(i, j)] = max(dp[at(i - 1, j)], dp[at(i, j - 1)])
                    }
                }
            }
        }
        var pairs: [(Int?, Int?)] = []
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0, j > 0, f[i - 1] == o[j - 1],
               dp[at(i, j)] == dp[at(i - 1, j - 1)] + 1 {
                pairs.append((i - 1, j - 1)); i -= 1; j -= 1
            } else if j > 0, (i == 0 || dp[at(i, j - 1)] >= dp[at(i - 1, j)]) {
                pairs.append((nil, j - 1)); j -= 1
            } else {
                pairs.append((i - 1, nil)); i -= 1
            }
        }
        return pairs.reversed()
    }

    /// Probe-A reconciliation of one page: classify every filter unit that
    /// does not appear 1:1 as a positive-bounds output unit.
    static func reconcile(
        surviving: [CharacterInfo], page: PDFPage, capRows: Int = 60
    ) -> RealDocReconciliation {
        let fUnits = filterUnits(surviving)
        let oUnits = outputUnits(page)
        var r = RealDocReconciliation()
        r.survivingCount = surviving.count
        r.filterUnitCount = fUnits.count
        r.outputUnitCount = oUnits.count
        r.outputPositiveCount = oUnits.filter(\.positiveBounds).count
        r.fusedFilterMembers = fUnits.reduce(0) { $0 + max($1.memberIndices.count - 1, 0) }

        let courier12 = CTFontCreateWithName("Courier" as CFString, 12.0, nil)
        let pairs = lcsAlign(fUnits.map(\.string), oUnits.map(\.string))

        func addRow(_ bucket: RealDocDeficitBucket, fIdx: Int, o: RealDocOutputUnit?) {
            r.bucketCounts[bucket, default: 0] += 1
            guard r.rows.count < capRows else { return }
            let f = fUnits[fIdx]
            let firstMember = f.memberIndices.first.map { surviving[$0] }
            r.rows.append(RealDocGlyphRow(
                bucket: bucket,
                fUnitIndex: fIdx,
                scalarsHex: scalarHex(f.string),
                srcOffset: firstMember?.stringIndex ?? -1,
                outOffset: o?.utf16Offset ?? -1,
                srcBounds: firstMember?.bounds ?? .null,
                outBounds: o?.bounds ?? .null,
                family: o?.family ?? "",
                courierAdv12: SearchableMergeProbe.courierHorizontalAdvance(
                    of: f.string, font: courier12)))
        }
        func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

        // Walk the alignment; gap groups between matches feed merge/split
        // detection, the rest become absent/synthesized.
        var pendingF: [Int] = []
        var pendingO: [Int] = []
        func flushGaps() {
            var fPool = pendingF
            var oPool = pendingO
            // MERGE: a contiguous F-subrange (≥2 units) whose NFC concatenation
            // equals one O-unit = neighbors fused into one composed unit.
            var oConsumed = Set<Int>()
            for oIdx in oPool where fPool.count >= 2 {
                let o = oUnits[oIdx]
                let target = nfc(o.string)
                var matched: Range<Int>? = nil
                outer: for start in fPool.indices {
                    var concat = ""
                    for end in start..<fPool.count {
                        concat += fUnits[fPool[end]].string
                        if end - start >= 1, nfc(concat) == target {
                            matched = start..<(end + 1); break outer
                        }
                        if concat.unicodeScalars.count
                            > o.string.unicodeScalars.count + 2 { break }
                    }
                }
                if let m = matched {
                    for fIdx in fPool[m] { addRow(.merged, fIdx: fIdx, o: o) }
                    r.mergedOutputUnits += 1
                    if o.positiveBounds { r.mergedOutputUnitsPositive += 1 }
                    fPool.removeSubrange(m)
                    oConsumed.insert(oIdx)
                }
            }
            oPool.removeAll { oConsumed.contains($0) }
            // SPLIT: one F-unit whose NFC equals the concatenation of a
            // contiguous O-subrange (≥2 units) — the inverse direction. Not a
            // deficit bucket (it raises the output count); tracked for the
            // accounting identity.
            var fConsumed = Set<Int>()
            for fIdx in fPool {
                let target = nfc(fUnits[fIdx].string)
                guard oPool.count >= 2 else { break }
                var matched: Range<Int>? = nil
                outer2: for start in oPool.indices {
                    var concat = ""
                    for end in start..<oPool.count {
                        concat += oUnits[oPool[end]].string
                        if end - start >= 1, nfc(concat) == target {
                            matched = start..<(end + 1); break outer2
                        }
                        if concat.unicodeScalars.count
                            > fUnits[fIdx].string.unicodeScalars.count + 2 { break }
                    }
                }
                if let m = matched {
                    r.splitFilterUnits += 1
                    r.splitOutputUnits += m.count
                    r.splitOutputUnitsPositive += oPool[m]
                        .filter { oUnits[$0].positiveBounds }.count
                    oPool.removeSubrange(m)
                    fConsumed.insert(fIdx)
                }
            }
            fPool.removeAll { fConsumed.contains($0) }
            // Remaining unmatched F-units: absent from the output string.
            for fIdx in fPool { addRow(.absent, fIdx: fIdx, o: nil) }
            // Remaining unmatched O-units: output-side synthesis.
            for oIdx in oPool {
                if oUnits[oIdx].positiveBounds { r.synthesizedPositive += 1 }
                else { r.synthesizedOther += 1 }
            }
            pendingF = []; pendingO = []
        }

        for (fi, oi) in pairs {
            switch (fi, oi) {
            case let (f?, o?):
                flushGaps()
                let oUnit = oUnits[o]
                if oUnit.positiveBounds {
                    r.matchedPositive += 1
                } else if !oUnit.hasSelection {
                    addRow(.nilSelection, fIdx: f, o: oUnit)
                } else {
                    addRow(.zeroBounds, fIdx: f, o: oUnit)
                }
            case let (f?, nil): pendingF.append(f)
            case let (nil, o?): pendingO.append(o)
            default: break
            }
        }
        flushGaps()
        return r
    }

    // MARK: Lineage sequences (probe C)

    /// The two lineage-hash walks as positional string sequences (whitespace
    /// skipped on both sides; nil-selection / zero-bounds skipped output-side)
    /// — element i corresponds to hash ingredient `(string_i, globalPos=i)`.
    static func lineageSequences(
        surviving: [CharacterInfo], page: PDFPage
    ) -> (filter: [String], output: [String]) {
        let f = filterUnits(surviving).map(\.string)
            .filter { !FilterResult.isLineageWhitespace($0) }
        let o = outputUnits(page)
            .filter { $0.positiveBounds && !FilterResult.isLineageWhitespace($0.string) }
            .map(\.string)
        return (f, o)
    }

    // MARK: Coverage (probe D)

    /// Distinct surviving graphemes across the given pages, with Courier and
    /// Menlo coverage verdicts (CTFontGetGlyphsForCharacters over the full
    /// UTF-16 span — the FIX-B segmentation predicate).
    static func coverage(_ survivingPerPage: [[CharacterInfo]]) -> [RealDocCoverageRow] {
        let courier = CTFontCreateWithName("Courier" as CFString, 12.0, nil)
        let menlo = CTFontCreateWithName("Menlo-Regular" as CFString, 12.0, nil)
        var counts: [String: Int] = [:]
        for page in survivingPerPage {
            for c in page { counts[c.character, default: 0] += 1 }
        }
        func covered(_ s: String, _ font: CTFont) -> Bool {
            let utf16 = Array(s.utf16)
            guard !utf16.isEmpty else { return false }
            var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
            return CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count)
        }
        return counts.map { (grapheme, n) in
            RealDocCoverageRow(
                scalarsHex: scalarHex(grapheme),
                occurrences: n,
                courierCovered: covered(grapheme, courier),
                menloCovered: covered(grapheme, menlo))
        }.sorted { $0.scalarsHex < $1.scalarsHex }
    }

    // MARK: S04 probe F — FIX-B emission prediction

    /// One maximal sub-string of a run's text whose graphemes share a
    /// Courier glyph-coverage verdict — the FIX-B Branch-A segmentation
    /// unit. TEST-LOCAL: S04 measured the Branch-A drawing shape against
    /// the real document and DISPROVED its emission premise (see
    /// `fixBEmissionPredictionF`), so this never moved into the
    /// production reconstructor.
    struct CoverageSegment: Equatable {
        let text: String
        let courierCovered: Bool
    }

    /// Split `text` into maximal same-coverage segments. Coverage predicate:
    /// `CTFontGetGlyphsForCharacters` over the grapheme's full UTF-16 span —
    /// the same predicate the EXP-E6.1 probes and the S03 coverage census
    /// use.
    static func courierCoverageSegments(
        of text: String, courier: CTFont
    ) -> [CoverageSegment] {
        var segments: [CoverageSegment] = []
        for grapheme in text {
            let s = String(grapheme)
            let utf16 = Array(s.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: max(utf16.count, 1))
            let covered = !utf16.isEmpty
                && CTFontGetGlyphsForCharacters(courier, utf16, &glyphs, utf16.count)
            if let last = segments.last, last.courierCovered == covered {
                segments[segments.count - 1] = CoverageSegment(
                    text: last.text + s, courierCovered: covered)
            } else {
                segments.append(CoverageSegment(text: s, courierCovered: covered))
            }
        }
        return segments
    }

    /// Redraw every page's surviving set with the session-04 FIX-B drawing
    /// shape — per-run coverage segmentation, explicit Courier for covered
    /// segments, explicit Menlo-Regular for the rest, each segment its own
    /// CTLine at the cumulative typographic advance from the run's snapped
    /// origin — into a throwaway CGPDFContext. Test-local: the production
    /// reconstructor draw path is NOT exercised. Measures the would-be
    /// post-FIX-B font-emission picture for the real document's actual
    /// content (the EXP-E6.1 scenarios measured explicit-font emission on
    /// synthetic ASCII/Latin-1 only).
    static func segmentedRedrawPDF(
        _ survivingPerPage: [[CharacterInfo]], pageBoxes: [CGRect]
    ) -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rdseg_\(UUID().uuidString).pdf")
        var box0 = pageBoxes.first ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box0, nil) else { return Data() }
        let size = TextLayerReconstructor.baseFontSize
        let courier = CTFontCreateWithName("Courier" as CFString, size, nil)
        let menlo = CTFontCreateWithName("Menlo-Regular" as CFString, size, nil)
        for (pi, surviving) in survivingPerPage.enumerated() {
            var box = pi < pageBoxes.count ? pageBoxes[pi] : box0
            let info = [kCGPDFContextMediaBox as String:
                            NSData(bytes: &box, length: MemoryLayout<CGRect>.size)]
            ctx.beginPDFPage(info as CFDictionary)
            ctx.setTextDrawingMode(.invisible)
            for run in TextLayerReconstructor.groupIntoRuns(surviving) {
                ctx.saveGState()
                ctx.textMatrix = .identity
                var x = run.origin.x
                for seg in courierCoverageSegments(of: run.text, courier: courier) {
                    let font = seg.courierCovered ? courier : menlo
                    let line = CTLineCreateWithAttributedString(NSAttributedString(
                        string: seg.text, attributes: [.font: font]))
                    ctx.textPosition = CGPoint(x: x, y: run.origin.y)
                    CTLineDraw(line, ctx)
                    x += CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                }
                ctx.restoreGState()
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? Data(contentsOf: url)) ?? Data()
    }

    // MARK: S06 — J-12 engineered source-metric pitch (R1, approved 2026-06-09)

    /// Natural CoreText advance of one composed grapheme in the accepted
    /// family's own font at `pointSize` — the J-13/N1 acceptance arm's
    /// reference value. Glyph resolution uses the family font directly; a
    /// grapheme the family does not cover has no natural advance (nil).
    /// Combining marks contribute their own (usually zero) advances, so a
    /// composed cluster's value approximates its base glyph's advance.
    static func naturalFamilyAdvance(
        _ grapheme: String, family: String, pointSize: Double
    ) -> Double? {
        let name = family.lowercased().contains("menlo") ? "Menlo-Regular" : "Courier"
        let font = CTFontCreateWithName(name as CFString, CGFloat(pointSize), nil)
        let utf16 = Array(grapheme.utf16)
        guard !utf16.isEmpty else { return nil }
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count) else {
            return nil
        }
        var advances = [CGSize](repeating: .zero, count: utf16.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, utf16.count)
        return advances.reduce(0.0) { $0 + Double($1.width) }
    }

    /// S06 — canonical-order walks (the J-12 SVT-2 re-anchoring candidate):
    /// both sides order composed units by a DETERMINISTIC geometric rule —
    /// Y bands via a single-linkage sweep (descending; a new band opens when
    /// the gap to the previous Y exceeds `bandTolerance`), X ascending
    /// within a band — so the lineage comparison no longer depends on
    /// PDFKit's composition heuristics (which re-order multi-baseline form
    /// rows unpredictably; measured rounds 2–5).
    static let bandTolerance = 1.5

    /// Group sorted-descending Y values into sweep bands and return each
    /// input index's band ordinal.
    static func yBands(_ ys: [Double]) -> [Int] {
        let order = ys.indices.sorted { ys[$0] > ys[$1] }
        var band = [Int](repeating: 0, count: ys.count)
        var current = 0
        var prevY = Double.nan
        for idx in order {
            if !prevY.isNaN, prevY - ys[idx] > bandTolerance { current += 1 }
            band[idx] = current
            prevY = ys[idx]
        }
        return band
    }

    /// Filter-side canonical walk over the DRAWN layout: runGroups at their
    /// drawn Y, banded by the sweep, X ascending within a band; each band's
    /// concatenated text re-segmented as composed units (mirroring how
    /// PDFKit composes a drawn line); whitespace skipped.
    static func canonicalFilterWalk(_ surviving: [CharacterInfo]) -> [String] {
        let groups = runGroups(surviving)
        guard !groups.isEmpty else { return [] }
        let ys = groups.map { Double(surviving[$0[0]].bounds.origin.y) }
        let xs = groups.map { Double(surviving[$0[0]].bounds.minX) }
        let bands = yBands(ys)
        let order = groups.indices.sorted {
            bands[$0] != bands[$1] ? bands[$0] < bands[$1] : xs[$0] < xs[$1]
        }
        var out: [String] = []
        var i = 0
        while i < order.count {
            var text = ""
            let b = bands[order[i]]
            while i < order.count, bands[order[i]] == b {
                text += groups[order[i]].map { surviving[$0].character }.joined()
                i += 1
            }
            let ns = text as NSString
            var off = 0
            while off < ns.length {
                let r = ns.rangeOfComposedCharacterSequence(at: off)
                let s = ns.substring(with: r)
                off += max(r.length, 1)
                if !FilterResult.isLineageWhitespace(s) { out.append(s) }
            }
        }
        return out
    }

    /// Output-side canonical walk: positive-bounds non-whitespace composed
    /// units, banded by the same Y sweep over selection minY, X ascending
    /// within a band.
    static func canonicalOutputUnits(_ page: PDFPage) -> [RealDocOutputUnit] {
        let units = outputUnits(page).filter {
            $0.positiveBounds && !FilterResult.isLineageWhitespace($0.string)
        }
        guard !units.isEmpty else { return [] }
        let bands = yBands(units.map { Double($0.bounds.minY) })
        return units.indices.sorted {
            bands[$0] != bands[$1]
                ? bands[$0] < bands[$1]
                : Double(units[$0].bounds.minX) < Double(units[$1].bounds.minX)
        }.map { units[$0] }
    }

    /// S06 — test-local single-page redraw at an ENGINEERED source-metric
    /// pitch (the J-12/R1 design space): each run draws at the font size
    /// whose Courier advance reproduces the run's TOTAL source width
    /// (`sizeRaw = Σ memberWidths / (composedLength × 0.60009765625)`),
    /// quantized round-to-nearest to `step` (step 0 = unquantized
    /// diagnostic), origin floor-snapped to the run's OWN grid, Y source-
    /// aligned. `perLine` pools the sizing across same-line runs (one pitch
    /// per line — fewer distinct sizes). `fitClamp` steps a run's size down
    /// while its span would end less than one full cell inside the page
    /// box. Sum-matched sizing keeps each drawn run's extent at its source
    /// extent (± len × step×0.6/2 quantization drift), which is the
    /// property the S05-B order probes measured PDFKit's reading order
    /// keying on. CONTENT-DEPENDENT geometry (J-12): the quantized size
    /// set is the bounded leakage channel the §5C.4 amendment documents.
    static func engineeredPitchRedrawPDF(
        _ surviving: [CharacterInfo], pageBox: CGRect,
        step: Double, perLine: Bool, fitClamp: Bool,
        capToHeight: Bool = false, monotonicOrigins: Bool = false,
        bridgeGaps: Bool = false
    ) -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rdeng_\(UUID().uuidString).pdf")
        var box = pageBox
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return Data() }
        let perPt = Double(SandwichVerification.courierAdvancePerPoint)
        ctx.beginPDFPage(nil)
        ctx.setTextDrawingMode(.invisible)

        struct GroupInfo {
            let text: String
            let len: Int
            let rawX: Double
            let y: Double
            let sumW: Double
            let medianH: Double
        }
        let infos: [GroupInfo] = runGroups(surviving).map { members in
            let text = members.map { surviving[$0].character }.joined()
            let heights = members.map { Double(surviving[$0].bounds.height) }.sorted()
            return GroupInfo(
                text: text,
                len: max(SearchableMergeProbe.composedLength(of: text), 1),
                rawX: Double(surviving[members[0]].bounds.minX),
                y: Double(surviving[members[0]].bounds.origin.y),
                sumW: members.reduce(0.0) { $0 + Double(surviving[$1].bounds.width) },
                medianH: heights[heights.count / 2])
        }
        func quantize(_ s: Double) -> Double {
            guard step > 0 else { return s }
            return max(step, (s / step).rounded() * step)
        }
        var sizes = [Double](repeating: 12.0, count: infos.count)
        if perLine {
            var i = 0
            while i < infos.count {
                var j = i + 1
                var lenSum = infos[i].len
                var wSum = infos[i].sumW
                var lineHeights = [infos[i].medianH]
                while j < infos.count, abs(infos[j].y - infos[i].y) < 1.0 {
                    lenSum += infos[j].len
                    wSum += infos[j].sumW
                    lineHeights.append(infos[j].medianH)
                    j += 1
                }
                var derived = wSum / (Double(lenSum) * perPt)
                if capToHeight {
                    let sortedH = lineHeights.sorted()
                    derived = min(derived, sortedH[sortedH.count / 2])
                }
                let size = quantize(derived)
                for k in i..<j { sizes[k] = size }
                i = j
            }
        } else {
            for (k, g) in infos.enumerated() {
                var derived = g.sumW / (Double(g.len) * perPt)
                // Wide-flat content (form rules, em-dashes, leader runs):
                // width-derived sizing blows past the line's vertical
                // envelope and the oversized glyphs entangle neighboring
                // lines' selections. The selection HEIGHT tracks the source
                // line height, so it bounds the sane size from above.
                if capToHeight { derived = min(derived, g.medianH) }
                sizes[k] = quantize(derived)
            }
        }
        let pageW = Double(pageBox.maxX)
        if bridgeGaps {
            // One CTLine per LINE: same-line groups merge with the inter-run
            // gap filled by invisible space glyphs at the line's pitch, so
            // every line tiles contiguously — no positive intra-line hole
            // for PDFKit's selection synthesis to smear into a neighboring
            // glyph's bounds. Junction slack (gap not a cell multiple)
            // lands entirely in the bridge spaces. NOTE for production:
            // a bridge must NOT cross a redaction region's span (Layer 6
            // spatial would rightly flag a drawn space inside the region);
            // the production form splits bridges at region rects — this
            // test-local probe draws unsplit bridges.
            var i = 0
            while i < infos.count {
                let y0 = infos[i].y
                var lineIdx = [i]
                var j = i + 1
                while j < infos.count, abs(infos[j].y - y0) < 1.0 {
                    lineIdx.append(j); j += 1
                }
                i = j
                var size = max(sizes[lineIdx[0]], 1.0)
                var text = ""
                var originX = 0.0
                var font = CTFontCreateWithName("Courier" as CFString, CGFloat(size), nil)
                // Assemble at the candidate size; the fit clamp evaluates
                // the ASSEMBLED line (bridge cells can far exceed the run
                // count, so any pre-assembly length estimate under-counts —
                // measured round 6: a page-14 top line overran and clipped
                // its trailing glyph). The cursor tracks the CTLine's
                // ACTUAL typographic layout — encoding-external glyphs
                // (U+2248 etc.) advance at natural non-0.6-em widths, so a
                // composedLength × cw estimate drifts.
                while true {
                    let cw = perPt * size
                    font = CTFontCreateWithName("Courier" as CFString, CGFloat(size), nil)
                    let attrs = [NSAttributedString.Key(
                        kCTFontAttributeName as String): font]
                    func drawnWidth(_ s: String) -> Double {
                        let l = CTLineCreateWithAttributedString(
                            NSAttributedString(string: s, attributes: attrs))
                        return CTLineGetTypographicBounds(l, nil, nil, nil)
                    }
                    originX = (infos[lineIdx[0]].rawX / cw).rounded(.down) * cw
                    text = ""
                    for k in lineIdx {
                        let g = infos[k]
                        if !text.isEmpty {
                            let target = (g.rawX / cw).rounded(.down) * cw
                            let cursorEnd = originX + drawnWidth(text)
                            let gapCells = max(1, Int(((target - cursorEnd) / cw).rounded()))
                            text += String(repeating: " ", count: gapCells)
                        }
                        text += g.text
                    }
                    guard fitClamp, step > 0, size - step >= 1.0,
                          originX + drawnWidth(text) + cw > pageW else { break }
                    size -= step
                }
                let line = CTLineCreateWithAttributedString(NSAttributedString(
                    string: text,
                    attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
                ctx.textPosition = CGPoint(x: originX, y: y0)
                CTLineDraw(line, ctx)
            }
            ctx.endPDFPage()
            ctx.closePDF()
            defer { try? FileManager.default.removeItem(at: url) }
            return (try? Data(contentsOf: url)) ?? Data()
        }
        var prevEnd = -Double.greatestFiniteMagnitude
        var prevY = Double.greatestFiniteMagnitude
        for (k, g) in infos.enumerated() {
            var size = max(sizes[k], 1.0)
            if fitClamp, step > 0 {
                while size - step >= 1.0 {
                    let cw = perPt * size
                    let snapped = (g.rawX / cw).rounded(.down) * cw
                    if snapped + Double(g.len + 1) * cw <= pageW { break }
                    size -= step
                }
            }
            let cw = perPt * size
            var x = (g.rawX / cw).rounded(.down) * cw
            // Same-line monotonic correction: a run never starts inside the
            // previous run's drawn span (floor-snapping two different grids
            // can otherwise co-locate the boundary cells → sliver
            // selections). runGroups order is Y-desc then X-asc, so the
            // previous group on the same Y is the left neighbor.
            if monotonicOrigins, abs(g.y - prevY) < 1.0 {
                x = max(x, prevEnd)
            }
            prevEnd = x + Double(g.len) * cw
            prevY = g.y
            let font = CTFontCreateWithName("Courier" as CFString, CGFloat(size), nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: g.text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            ctx.textPosition = CGPoint(x: x, y: g.y)
            CTLineDraw(line, ctx)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? Data(contentsOf: url)) ?? Data()
    }

    // MARK: Formatting (per-glyph scope only — never running text)

    /// "U+0041" form for every scalar of a grapheme.
    static func scalarHex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
    }
    static func r4(_ d: Double) -> Double { (d * 10000).rounded() / 10000 }
    static func rect(_ r: CGRect) -> String {
        r.isNull ? "(null)"
            : "(\(r4(Double(r.minX))),\(r4(Double(r.minY))),\(r4(Double(r.width)))x\(r4(Double(r.height))))"
    }
}
