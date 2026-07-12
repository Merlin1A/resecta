import CoreGraphics
import CoreText
import Foundation

// ENGINE §5C — Invisible text layer reconstruction.
// Draws surviving characters as invisible (rendering mode 3) text in the
// PDF context, positioned over the rasterized page image.
//
// Security: Uses fresh Courier font only (no original document fonts).
// Bland et al. glyph positioning attack vector reduced — Courier has uniform
// advance widths and CTLineDraw produces only simple Tj operators. The J-12
// layout (2026-06-09) derives one quantized pitch per line band from source
// metrics (see §5C.2): the content-dependent channel this re-opens is the
// band's quantized size class — bounded bits, redundant with the visible
// raster — analyzed in §5C.4.

/// Text run: a group of adjacent characters on the same line.
/// See ENGINE §5C.1. Retained for the 12pt-era grid model that probe and
/// unit tests still measure; the production draw path is line-based
/// (`TextLayerLine`) as of J-12.
struct TextRun {
    let origin: CGPoint
    let text: String
}

/// One assembled drawn line (J-12): same-band run groups merged X-ascending
/// with whole-cell bridge spaces, at the band's pooled quantized pitch.
/// See ENGINE §5C.1.
struct TextLayerLine {
    let origin: CGPoint
    let fontSize: CGFloat
    let text: String
}

/// Reconstructs the invisible text layer for Searchable Redaction output.
/// Must be called AFTER the page image has been drawn into the CGContext.
/// See ENGINE §5C.1 for the drawing specification.
public enum TextLayerReconstructor {

    /// Reference font size. The J-12 layout derives per-band sizes from
    /// source metrics (§5C.2); this constant anchors the verifier's
    /// tolerance scaling (`advanceWidthTolerancePerPoint` = 0.25 / 12) and
    /// the legacy 12pt-era grid model that tests and probes still measure.
    internal static let baseFontSize: CGFloat = 12.0

    /// Per-cell horizontal advance in points at the 12pt reference size.
    /// Courier's monospace advance is `0.60009765625 × fontSize` for every
    /// probed size (CoreText's 16-bit fixed-point representation of Adobe
    /// Font Metrics' 600-units-per-em Courier advance, 600/1000 = 0.6).
    /// The J-12 layout computes each band's cell as
    /// `courierAdvancePerPoint × bandFontSize`; this constant remains the
    /// 12pt-era reference. ENGINE §5C.1.
    internal static let cellWidth: CGFloat =
        SandwichVerification.courierAdvancePerPoint * baseFontSize

    /// Pitch quantization step (J-12, §5C.2/§5C.4): band sizes round to
    /// the nearest half point. Coarser steps leak fewer content-derived
    /// bits per band and bound the doc-wide distinct-size set (measured:
    /// 17 sizes across the 23-page real-document fixture at 0.5pt).
    internal static let pitchQuantizationStep: CGFloat = 0.5

    /// Lower bound on a derived band size.
    internal static let minimumFontSize: CGFloat = 1.0

    // MARK: - Drawing (ENGINE §5C.1, J-12)

    /// Draw surviving characters as invisible (rendering mode 3) text.
    ///
    /// Drawing order: image first (already drawn by caller), then invisible
    /// text on top. Matches standard sandwich PDF structure (ISO 32000).
    /// See ENGINE §5C.3.
    ///
    /// - Parameters:
    ///   - context: The CGPDFContext for the current page (between beginPDFPage/endPDFPage).
    ///   - entries: Surviving characters from the character filter.
    ///   - pageWidth: Width of the output page in points — bounds the
    ///     assembled-line fit clamp (§5C.2).
    ///   - redactionRects: Redaction rectangles in PDF-point-space; a
    ///     bridge never crosses one (§5C.1 — Layer 6 would rightly flag a
    ///     drawn space inside a region).
    ///
    /// The dead `pageHeight` parameter is removed — Y stays
    /// source-aligned (per-line origins) and nothing in this method consumed
    /// page height. Output pages are zero-origin (the canonical coordinate
    /// contract), so the layout works purely in output-page space.
    public static func drawInvisibleTextLayer(
        context: CGContext,
        entries: [CharacterInfo],
        pageWidth: CGFloat,
        redactionRects: [CGRect] = []
    ) {
        guard !entries.isEmpty else { return }

        // PDF Tr mode 3 — text is invisible but selectable
        context.setTextDrawingMode(.invisible)  // See ENGINE §5C.1

        let lines = layoutLines(
            entries, pageWidth: pageWidth, redactionRects: redactionRects)
        for line in lines {
            context.saveGState()
            context.textMatrix = .identity

            // ENGINE §5C.3: fresh Courier font instance — no relationship to
            // original document fonts, CMaps, or glyph tables. Designed to
            // close the ASD CMap leakage vector.
            let font = CTFontCreateWithName(
                "Courier" as CFString, line.fontSize, nil)
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let attrString = NSAttributedString(
                string: line.text, attributes: attrs)
            let ctLine = CTLineCreateWithAttributedString(attrString)

            // TL-3-1: Y stays source-aligned so the invisible layer
            // overlays the rasterized image (visible-region search still
            // resolves per-character).
            context.textPosition = line.origin
            CTLineDraw(ctLine, context)

            context.restoreGState()
        }
    }

    // MARK: - Line layout (ENGINE §5C.1/§5C.2, J-12)

    /// Assemble the drawn lines for a page's surviving set.
    ///
    /// J-12 layout (2026-06-09; measured on the committed real-document
    /// fixture, RealDocProbeTests S06 rounds 1–8):
    ///
    ///  1. **Band pooling** — run groups band by the shared Y sweep
    ///     (`SandwichVerification.yBands`); each band draws at ONE pitch,
    ///     so no same-band pitch junctions exist for the SVT-1 lattice to
    ///     adjudicate.
    ///  2. **Sum-matched sizing** — the band's raw size reproduces its
    ///     total source glyph width (`Σ widths / (Σ composedLen × 0.6001)`),
    ///     keeping every drawn extent at its source extent. PDFKit's
    ///     reading order tracks drawn proportions; extent-faithful lines
    ///     keep composition stable.
    ///  3. **Height cap** — the size is capped at the band's median glyph
    ///     height: width-derived sizing on wide-flat content (form rules,
    ///     em-dashes, leader runs) otherwise blows past the line's
    ///     vertical envelope and the oversized glyphs entangle neighboring
    ///     lines' selections.
    ///  4. **Quantization** — sizes round to `pitchQuantizationStep`
    ///     (§5C.4 leakage bound).
    ///  5. **Bridging** — same-band groups merge X-ascending into one
    ///     line, inter-group gaps filled with whole-cell invisible spaces
    ///     (count = the snapped gap), so every line tiles contiguously
    ///     and no intra-line hole exists for PDFKit's selection synthesis
    ///     to smear into a neighboring glyph's bounds. The cursor tracks
    ///     the CTLine's actual typographic layout (encoding-external
    ///     glyphs advance at natural non-0.6-em widths). A bridge never
    ///     crosses a redaction rect — the line splits there instead.
    ///  6. **Fit clamp** — if any assembled line would end less than one
    ///     cell inside the page box, the whole band steps down one
    ///     quantization step and re-assembles.
    static func layoutLines(
        _ entries: [CharacterInfo],
        pageWidth: CGFloat,
        redactionRects: [CGRect]
    ) -> [TextLayerLine] {
        let groups = runMemberGroups(entries)
        guard !groups.isEmpty else { return [] }
        let perPt = SandwichVerification.courierAdvancePerPoint

        struct GroupInfo {
            let text: String
            let composedLen: Int
            let rawX: CGFloat
            let y: CGFloat
            let yMin: CGFloat
            let yMax: CGFloat
            let sumW: CGFloat
            let heights: [CGFloat]
        }
        let infos: [GroupInfo] = groups.map { members in
            let text = members.map { entries[$0].character }.joined()
            let ns = text as NSString
            var len = 0
            var off = 0
            while off < ns.length {
                let r = ns.rangeOfComposedCharacterSequence(at: off)
                off += max(r.length, 1)
                len += 1
            }
            let first = entries[members[0]].bounds
            return GroupInfo(
                text: text,
                composedLen: max(len, 1),
                rawX: first.minX,
                y: first.origin.y,
                yMin: members.map { entries[$0].bounds.minY }.min() ?? first.minY,
                yMax: members.map { entries[$0].bounds.maxY }.max() ?? first.maxY,
                sumW: members.reduce(0) { $0 + entries[$1].bounds.width },
                heights: members.map { entries[$0].bounds.height })
        }

        let bands = SandwichVerification.yBands(infos.map(\.y))
        let bandCount = (bands.max() ?? 0) + 1
        var bandGroups: [[Int]] = Array(repeating: [], count: bandCount)
        for (gi, b) in bands.enumerated() { bandGroups[b].append(gi) }

        var result: [TextLayerLine] = []
        for bi in 0..<bandCount {
            let order = bandGroups[bi].sorted { infos[$0].rawX < infos[$1].rawX }
            guard !order.isEmpty else { continue }

            // Band pitch: sum-matched, height-capped, quantized (§5C.2).
            let lenSum = order.reduce(0) { $0 + infos[$1].composedLen }
            let wSum = order.reduce(CGFloat(0)) { $0 + infos[$1].sumW }
            var derived = wSum / (CGFloat(max(lenSum, 1)) * perPt)
            let allHeights = order.flatMap { infos[$0].heights }.sorted()
            if !allHeights.isEmpty {
                derived = min(derived, allHeights[allHeights.count / 2])
            }
            var size = max(
                (derived / pitchQuantizationStep).rounded() * pitchQuantizationStep,
                minimumFontSize)

            func assemble(_ size: CGFloat) -> (lines: [TextLayerLine], maxEndX: CGFloat) {
                let cw = perPt * size
                let font = CTFontCreateWithName("Courier" as CFString, size, nil)
                let attrs: [NSAttributedString.Key: Any] = [.font: font]
                func drawnWidth(_ s: String) -> CGFloat {
                    guard !s.isEmpty else { return 0 }
                    let l = CTLineCreateWithAttributedString(
                        NSAttributedString(string: s, attributes: attrs))
                    return CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
                }
                var lines: [TextLayerLine] = []
                var maxEndX: CGFloat = 0
                var text = ""
                var originX: CGFloat = 0
                var lineY: CGFloat = 0
                var yLo: CGFloat = 0
                var yHi: CGFloat = 0
                func close() {
                    guard !text.isEmpty else { return }
                    maxEndX = max(maxEndX, originX + drawnWidth(text))
                    lines.append(TextLayerLine(
                        origin: CGPoint(x: originX, y: lineY),
                        fontSize: size, text: text))
                    text = ""
                }
                for gi in order {
                    let g = infos[gi]
                    let target = (g.rawX / cw).rounded(.down) * cw
                    if text.isEmpty {
                        originX = target
                        lineY = g.y
                        yLo = g.yMin
                        yHi = g.yMax
                        text = g.text
                        continue
                    }
                    let cursorEnd = originX + drawnWidth(text)
                    let gapRect = CGRect(
                        x: cursorEnd,
                        y: min(yLo, g.yMin),
                        width: max(target - cursorEnd, 0),
                        height: max(yHi, g.yMax) - min(yLo, g.yMin))
                    if gapRect.width > 0,
                       redactionRects.contains(where: { $0.intersects(gapRect) }) {
                        // §5C.1: a bridge never crosses a redaction rect —
                        // the drawn line splits at the region instead.
                        close()
                        originX = target
                        lineY = g.y
                        yLo = g.yMin
                        yHi = g.yMax
                        text = g.text
                    } else {
                        let gapCells = max(
                            1, Int(((target - cursorEnd) / cw).rounded()))
                        text += String(repeating: " ", count: gapCells) + g.text
                        yLo = min(yLo, g.yMin)
                        yHi = max(yHi, g.yMax)
                    }
                }
                close()
                return (lines, maxEndX)
            }

            var assembled = assemble(size)
            while size - pitchQuantizationStep >= minimumFontSize,
                  assembled.maxEndX + perPt * size > pageWidth {
                size -= pitchQuantizationStep
                assembled = assemble(size)
            }
            result.append(contentsOf: assembled.lines)
        }
        return result
    }

    // MARK: - Text Run Grouping (ENGINE §5C.1)

    /// Group characters into contiguous member-index groups.
    /// Characters on the same line that are close together are merged.
    ///
    /// Sorting: bottom-to-top (higher midY first = lower on page in PDF coords),
    /// left-to-right. Adjacent characters within 1.5× character width are grouped.
    /// This sort + adjacency rule is the shared run definition: the J-12
    /// line layout, the filter-side lineage walk
    /// (`FilterResult.computeLineageHash`), and the legacy `groupIntoRuns`
    /// all derive from it.
    ///
    /// The same-line test uses a SYMMETRIC per-pair line height —
    /// `min(a.height, b.height) × 0.5` at both comparison sites. The prior
    /// form took the threshold from one side of the pair (sort comparator) and
    /// from a single page-global height (the first sorted glyph's height) in
    /// the grouping loop; on a page mixing font sizes a tall heading glyph
    /// inflated the page-global threshold and over-merged the closely-spaced
    /// small body lines beneath it. Using the smaller of each pair's heights
    /// scopes the threshold to the glyphs actually being compared and makes
    /// the comparator order-independent. For a single-size page the value is
    /// identical to the old form (min == both heights), so layout is unchanged.
    static func runMemberGroups(_ entries: [CharacterInfo]) -> [[Int]] {
        guard !entries.isEmpty else { return [] }

        let sortedIdx = entries.indices.sorted {
            let a = entries[$0], b = entries[$1]
            if abs(a.bounds.midY - b.bounds.midY)
                > min(a.bounds.height, b.bounds.height) * 0.5 {
                return a.bounds.midY > b.bounds.midY
            }
            return a.bounds.minX < b.bounds.minX
        }

        var groups: [[Int]] = []
        var current: [Int] = [sortedIdx[0]]
        for i in 1..<sortedIdx.count {
            let prev = entries[sortedIdx[i - 1]], curr = entries[sortedIdx[i]]
            let sameLine = abs(prev.bounds.midY - curr.bounds.midY)
                < min(prev.bounds.height, curr.bounds.height) * 0.5
            let adjacent = (curr.bounds.minX - prev.bounds.maxX) < prev.bounds.width * 1.5
            if sameLine && adjacent {
                current.append(sortedIdx[i])
            } else {
                groups.append(current)
                current = [sortedIdx[i]]
            }
        }
        groups.append(current)
        return groups
    }

    /// Legacy run view over `runMemberGroups` (12pt-era grid model): run
    /// origin X snaps to the GLOBAL reference cell grid. The production
    /// draw path no longer consumes this — `layoutLines` snaps each band
    /// to its own derived grid — but the run definition itself (sort +
    /// adjacency) is unchanged and tests/probes measuring the run
    /// structure still read it.
    static func groupIntoRuns(_ entries: [CharacterInfo]) -> [TextRun] {
        runMemberGroups(entries).map { members in
            TextRun(
                origin: snappedOrigin(entries[members[0]].bounds.origin),
                text: members.map { entries[$0].character }.joined())
        }
    }

    /// Snap an origin's X coordinate to the 12pt-era reference cell grid.
    /// Y is left unmodified. Legacy: the J-12 layout snaps to each band's
    /// own grid (`courierAdvancePerPoint × bandSize`) inside `layoutLines`.
    static func snappedOrigin(_ origin: CGPoint) -> CGPoint {
        CGPoint(x: floor(origin.x / cellWidth) * cellWidth, y: origin.y)
    }
}
