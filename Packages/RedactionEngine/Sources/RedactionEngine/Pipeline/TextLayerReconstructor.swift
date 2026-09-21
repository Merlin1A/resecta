import CoreGraphics
import CoreText
import Foundation

// Draws surviving characters as invisible (rendering mode 3) text in the
// PDF context, positioned over the rasterized page image.
//
// Security: Uses fresh Courier font only (no original document fonts).
// Bland et al. glyph positioning attack vector reduced — Courier has uniform
// advance widths and CTLineDraw produces only simple Tj operators. The J-12
// layout (2026-06-09) derives one quantized pitch per line band from source
// metrics: the content-dependent channel this re-opens is the
// band's quantized size class — bounded bits, redundant with the visible
// raster.

/// Text run: a group of adjacent characters on the same line.
/// Retained for the 12pt-era grid model that probe and
/// unit tests still measure; the production draw path is line-based
/// (`TextLayerLine`) as of J-12.
struct TextRun {
    let origin: CGPoint
    let text: String
}

/// One assembled drawn line (J-12): same-band run groups merged X-ascending
/// with whole-cell bridge spaces, at the band's pooled quantized pitch.
struct TextLayerLine {
    let origin: CGPoint
    let fontSize: CGFloat
    let text: String
}

/// One drawn line with its provenance: for every surviving entry the line
/// draws, the UTF-16 offset of that entry's text inside `line.text`. Bridge
/// spaces have no source entry. The drawn-cell rule
/// (`inRegionDrawnGlyphIndices`) reads this to place a survivor where the
/// writer draws it, which is not its source box.
struct SourcedTextLayerLine {
    let line: TextLayerLine
    let sources: [(entry: Int, utf16Offset: Int)]
}

/// Reconstructs the invisible text layer for Searchable Redaction output.
/// Must be called AFTER the page image has been drawn into the CGContext.
public enum TextLayerReconstructor {

    /// Reference font size. The J-12 layout derives per-band sizes from
    /// source metrics; this constant anchors the verifier's
    /// tolerance scaling (`advanceWidthTolerancePerPoint` = 0.25 / 12) and
    /// the legacy 12pt-era grid model that tests and probes still measure.
    internal static let baseFontSize: CGFloat = 12.0

    /// Per-cell horizontal advance in points at the 12pt reference size.
    /// Courier's monospace advance is `0.60009765625 × fontSize` for every
    /// probed size (CoreText's 16-bit fixed-point representation of Adobe
    /// Font Metrics' 600-units-per-em Courier advance, 600/1000 = 0.6).
    /// The J-12 layout computes each band's cell as
    /// `courierAdvancePerPoint × bandFontSize`; this constant remains the
    /// 12pt-era reference.
    internal static let cellWidth: CGFloat =
        SandwichVerification.courierAdvancePerPoint * baseFontSize

    /// Pitch quantization step (J-12): band sizes round to
    /// the nearest half point. Coarser steps leak fewer content-derived
    /// bits per band and bound the doc-wide distinct-size set (measured:
    /// 17 sizes across the 23-page real-document fixture at 0.5pt).
    internal static let pitchQuantizationStep: CGFloat = 0.5

    /// Lower bound on a derived band size.
    internal static let minimumFontSize: CGFloat = 1.0

    // MARK: - Drawing

    /// Draw surviving characters as invisible (rendering mode 3) text.
    ///
    /// Drawing order: image first (already drawn by caller), then invisible
    /// text on top. Matches standard sandwich PDF structure (ISO 32000).
    ///
    /// - Parameters:
    ///   - context: The CGPDFContext for the current page (between beginPDFPage/endPDFPage).
    ///   - entries: Surviving characters from the character filter, in
    ///     OUTPUT-page (displayed) coordinates.
    ///   - pageSize: The displayed output page size in points. On an
    ///     unrotated page only the width is read (it bounds the
    ///     assembled-line fit clamp); on a rotated page both sides carry the
    ///     entries into the source frame.
    ///   - redactionRects: Redaction rectangles in PDF-point-space (the
    ///     displayed frame); a bridge never crosses one (Layer 6 would
    ///     rightly flag a drawn space inside a region).
    ///   - rotation: The source page's `/Rotate`. On a page stored with a
    ///     rotation the lines are assembled in the SOURCE frame
    ///     (`sourceFrameLines`) and each is drawn under a rotation of the
    ///     graphics state about its displayed origin, so every drawn line
    ///     runs along its source line on the rotated raster and the layer
    ///     reads back in the source's order. Rotation 0 is the unchanged
    ///     path: no transform is emitted.
    ///
    /// Output pages are zero-origin (the canonical coordinate contract), so
    /// the layout works purely in page space: Y stays source-aligned
    /// (per-line origins) and nothing here consumes the page height on an
    /// unrotated page.
    public static func drawInvisibleTextLayer(
        context: CGContext,
        entries: [CharacterInfo],
        pageSize: CGSize,
        redactionRects: [CGRect] = [],
        rotation: Int = 0
    ) {
        guard !entries.isEmpty else { return }

        // PDF Tr mode 3 — text is invisible but selectable
        context.setTextDrawingMode(.invisible)

        let frame = PageFrame(rotation: rotation, displayedSize: pageSize)
        let lines = sourceFrameLines(
            entries, redactionRects: redactionRects, frame: frame
        ).map(\.line)
        for line in lines {
            context.saveGState()
            context.textMatrix = .identity

            // Fresh Courier font instance — no relationship to
            // original document fonts, CMaps, or glyph tables. Designed to
            // close the ASD CMap leakage vector.
            let font = CTFontCreateWithName(
                "Courier" as CFString, line.fontSize, nil)
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let attrString = NSAttributedString(
                string: line.text, attributes: attrs)
            let ctLine = CTLineCreateWithAttributedString(attrString)

            if frame.isUnrotated {
                // Y stays source-aligned so the invisible layer
                // overlays the rasterized image (visible-region search still
                // resolves per-character).
                context.textPosition = line.origin
            } else {
                // The line's origin is a SOURCE-frame point. Rotate the
                // graphics state about its displayed position and draw at
                // zero with an identity text matrix: the glyphs advance
                // along the rotated axis with one per-glyph box each, in
                // draw order, on every rotation. (A rotated TEXT matrix
                // instead reads back paired two-glyph boxes at 90°/270° and
                // loses glyphs at 180° — measured on this platform.)
                let origin = frame.displayedPoint(line.origin)
                context.translateBy(x: origin.x, y: origin.y)
                context.rotate(by: frame.displayedAngle)
                context.textPosition = .zero
            }
            CTLineDraw(ctLine, context)

            context.restoreGState()
        }
    }

    // MARK: - Line layout

    /// Assemble the drawn lines for a page's surviving set.
    ///
    /// J-12 layout (2026-06-09; measured on the committed real-document
    /// fixture, RealDocProbeTests rounds 1–8):
    ///
    ///  1. **Band pooling** — run groups band by the shared Y sweep
    ///     (`SandwichVerification.yBands`); each band draws at ONE pitch,
    ///     so no same-band pitch junctions exist for the spatial-tampering
    ///     lattice to adjudicate.
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
    ///  4. **Quantization** — sizes round to `pitchQuantizationStep`,
    ///     bounding the leakage.
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
        layoutLinesWithSources(
            entries, pageWidth: pageWidth, redactionRects: redactionRects
        ).map(\.line)
    }

    /// `layoutLines` with provenance: the same assembly, each line carrying
    /// which entry every drawn composed character came from.
    static func layoutLinesWithSources(
        _ entries: [CharacterInfo],
        pageWidth: CGFloat,
        redactionRects: [CGRect]
    ) -> [SourcedTextLayerLine] {
        let groups = runMemberGroups(entries)
        guard !groups.isEmpty else { return [] }
        let perPt = SandwichVerification.courierAdvancePerPoint

        struct GroupInfo {
            let members: [Int]
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
                members: members,
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

        var result: [SourcedTextLayerLine] = []
        for bi in 0..<bandCount {
            let order = bandGroups[bi].sorted { infos[$0].rawX < infos[$1].rawX }
            guard !order.isEmpty else { continue }

            // Band pitch: sum-matched, height-capped, quantized.
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

            func assemble(_ size: CGFloat)
                -> (lines: [SourcedTextLayerLine], maxEndX: CGFloat) {
                let cw = perPt * size
                let font = CTFontCreateWithName("Courier" as CFString, size, nil)
                let attrs: [NSAttributedString.Key: Any] = [.font: font]
                func drawnWidth(_ s: String) -> CGFloat {
                    guard !s.isEmpty else { return 0 }
                    let l = CTLineCreateWithAttributedString(
                        NSAttributedString(string: s, attributes: attrs))
                    return CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
                }
                var lines: [SourcedTextLayerLine] = []
                var maxEndX: CGFloat = 0
                var text = ""
                var sources: [(entry: Int, utf16Offset: Int)] = []
                var originX: CGFloat = 0
                var lineY: CGFloat = 0
                var yLo: CGFloat = 0
                var yHi: CGFloat = 0
                // Append a group's text to the line under assembly, recording
                // each member's UTF-16 offset inside the line text.
                func append(_ g: GroupInfo) {
                    var offset = (text as NSString).length
                    for m in g.members {
                        sources.append((m, offset))
                        offset += (entries[m].character as NSString).length
                    }
                    text += g.text
                }
                func close() {
                    guard !text.isEmpty else { return }
                    maxEndX = max(maxEndX, originX + drawnWidth(text))
                    lines.append(SourcedTextLayerLine(
                        line: TextLayerLine(
                            origin: CGPoint(x: originX, y: lineY),
                            fontSize: size, text: text),
                        sources: sources))
                    text = ""
                    sources = []
                }
                for gi in order {
                    let g = infos[gi]
                    let target = (g.rawX / cw).rounded(.down) * cw
                    if text.isEmpty {
                        originX = target
                        lineY = g.y
                        yLo = g.yMin
                        yHi = g.yMax
                        append(g)
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
                        // A bridge never crosses a redaction rect —
                        // the drawn line splits at the region instead.
                        close()
                        originX = target
                        lineY = g.y
                        yLo = g.yMin
                        yHi = g.yMax
                        append(g)
                    } else {
                        let gapCells = max(
                            1, Int(((target - cursorEnd) / cw).rounded()))
                        text += String(repeating: " ", count: gapCells)
                        yLo = min(yLo, g.yMin)
                        yHi = max(yHi, g.yMax)
                        append(g)
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

    /// The line assembly in the page's SOURCE frame. On an unrotated page
    /// this is `layoutLinesWithSources` as is. On a page stored with a
    /// rotation the entries' bounds and the redaction rects are carried into
    /// the source frame first — every source line is horizontal there, so
    /// the assembler's contract holds (one band per source line, one pitch
    /// per band, bridges along the line, the fit clamp against the SOURCE
    /// page width) — and the lines come back with SOURCE-frame origins for
    /// the caller to rotate. The horizontal assembler run on the displayed
    /// frame of a 90°/270° page saw every source line as a vertical run,
    /// pooled glyphs of many source lines into each band and ran the
    /// assembled line off the page.
    static func sourceFrameLines(
        _ entries: [CharacterInfo],
        redactionRects: [CGRect],
        frame: PageFrame
    ) -> [SourcedTextLayerLine] {
        guard !frame.isUnrotated else {
            return layoutLinesWithSources(
                entries, pageWidth: frame.displayedSize.width,
                redactionRects: redactionRects)
        }
        return layoutLinesWithSources(
            entries.map(frame.sourceEntry),
            pageWidth: frame.sourceSize.width,
            redactionRects: redactionRects.map(frame.sourceRect))
    }

    // MARK: - The drawn-cell rule

    /// Upper bound on re-flow passes of `validateSurvivors`. A pass that
    /// continues has dropped at least one entry, so the loop ends on its own;
    /// the bound only caps a pathological page.
    static let drawnCellRulePassLimit = 16

    /// Indices of `entries` whose DRAWN glyph cell is centred inside an
    /// un-expanded redaction region.
    ///
    /// The character filter keeps or drops a glyph on its SOURCE box. The
    /// writer then draws it somewhere else: inside a band every group snaps
    /// its origin LEFT to the band's Courier grid, but the cursor advances by
    /// Courier cells at the band's sum-matched pitch, so where the source
    /// font is narrower than that pitch a group's last glyphs land RIGHT of
    /// their source positions — a label's trailing colon can be drawn into
    /// the value box beside it although its source box clears the filter's
    /// halo, and Layer 6 then (correctly) reports a drawn glyph inside a
    /// region. This rule places each survivor where the writer will draw it —
    /// the line's origin plus the CTLine's advance to that glyph at the band
    /// pitch, vertically the Courier line box shrunk to its glyph core by the
    /// same descent fraction Layer 6 applies to a read-back box — and returns
    /// every entry whose core centre lies inside a region (the polygon when
    /// the shape carries one, else the rect: the centre test Layer 6 runs).
    /// A cell that only crosses a region edge is NOT returned: that is
    /// Layer 6's graze note, a positional observation about content that
    /// stays outside.
    ///
    /// The rule reads the frame the entries are given in — the displayed
    /// frame of an unrotated page, or the source frame a rotated page's
    /// entries are carried into by `inRegionDrawnGlyphIndices(entries:regionShapes:frame:)`.
    static func inRegionDrawnGlyphIndices(
        entries: [CharacterInfo],
        pageWidth: CGFloat,
        regionShapes: [RegionShape]
    ) -> IndexSet {
        guard !entries.isEmpty, !regionShapes.isEmpty else { return IndexSet() }
        let rects = regionShapes.map(\.bounds)
        var hits = IndexSet()
        for sourced in layoutLinesWithSources(
            entries, pageWidth: pageWidth, redactionRects: rects
        ) {
            let line = sourced.line
            let font = CTFontCreateWithName("Courier" as CFString, line.fontSize, nil)
            let ascent = CTFontGetAscent(font)
            let descent = CTFontGetDescent(font)
            let fraction = SandwichVerification.descentFraction(
                family: "Courier", pointSize: line.fontSize)
            let ctLine = CTLineCreateWithAttributedString(
                NSAttributedString(string: line.text, attributes: [.font: font]))
            for (entry, offset) in sourced.sources {
                let length = (entries[entry].character as NSString).length
                let x0 = CGFloat(CTLineGetOffsetForStringIndex(ctLine, offset, nil))
                let x1 = CGFloat(CTLineGetOffsetForStringIndex(ctLine, offset + length, nil))
                let cell = CGRect(
                    x: line.origin.x + x0, y: line.origin.y - descent,
                    width: x1 - x0, height: ascent + descent)
                let core = cell.insetBy(dx: 0, dy: fraction * cell.height)
                let centre = CGPoint(x: core.midX, y: core.midY)
                let inside = regionShapes.contains { shape in
                    if let vertices = shape.polygonVertices {
                        return SandwichVerification.polygonContainsPoint(
                            centre, vertices: vertices)
                    }
                    return shape.bounds.contains(centre)
                }
                if inside { hits.insert(entry) }
            }
        }
        return hits
    }

    /// The drawn-cell rule in the page's SOURCE frame: on a page stored
    /// with a rotation the entries and the shapes are carried there first
    /// (a rigid map — the drawn cell, its core and the centre test read the
    /// same in either frame), so the rule sees the layout the writer draws.
    static func inRegionDrawnGlyphIndices(
        entries: [CharacterInfo],
        regionShapes: [RegionShape],
        frame: PageFrame
    ) -> IndexSet {
        guard !frame.isUnrotated else {
            return inRegionDrawnGlyphIndices(
                entries: entries, pageWidth: frame.displayedSize.width,
                regionShapes: regionShapes)
        }
        return inRegionDrawnGlyphIndices(
            entries: entries.map(frame.sourceEntry),
            pageWidth: frame.sourceSize.width,
            regionShapes: regionShapes.map(frame.sourceShape))
    }

    /// Rect-only form of `inRegionDrawnGlyphIndices(entries:pageWidth:regionShapes:)`.
    static func inRegionDrawnGlyphIndices(
        entries: [CharacterInfo],
        pageWidth: CGFloat,
        redactionRects: [CGRect]
    ) -> IndexSet {
        inRegionDrawnGlyphIndices(
            entries: entries, pageWidth: pageWidth,
            regionShapes: redactionRects.map {
                RegionShape(
                    expandedBounds: $0.insetBy(
                        dx: -safetyMarginPoints, dy: -safetyMarginPoints),
                    polygonVertices: nil, bounds: $0)
            })
    }

    /// The drawn-cell rule applied to a filter result: every survivor the rule
    /// returns is dropped (counted into `excludedCount`) and the layout
    /// re-flowed, until no drawn cell is centred inside a region — so the
    /// digest, the drawn layer and Layer 6 agree by construction. Runs on the
    /// production path (`PageRasterizer`) before the digest is taken; the
    /// test pipeline mirrors it. Over-redaction is safe, under-redaction is a
    /// breach: a dropped glyph is one the searchable layer would otherwise
    /// have placed inside a redaction.
    ///
    /// Runs in the page's SOURCE frame (`frame`): on a page stored with a
    /// rotation the layout the writer draws is the source-frame assembly,
    /// so the rule reads that assembly and drops what it would draw inside
    /// a region there — nothing more. (The former displayed-frame assembly
    /// of such a page displaced glyphs by the hundreds; the rule was gated
    /// off it until the layout was faithful.)
    static func validateSurvivors(
        _ result: FilterResult,
        regionShapes: [RegionShape],
        frame: PageFrame
    ) -> (result: FilterResult, dropped: Int) {
        var surviving = result.surviving
        var dropped = 0
        var passes = 0
        while passes < drawnCellRulePassLimit {
            let hits = inRegionDrawnGlyphIndices(
                entries: surviving, regionShapes: regionShapes, frame: frame)
            if hits.isEmpty { break }
            surviving = surviving.enumerated()
                .filter { !hits.contains($0.offset) }
                .map(\.element)
            dropped += hits.count
            passes += 1
        }
        return (
            FilterResult(
                surviving: surviving,
                totalCharacters: result.totalCharacters,
                excludedCount: result.excludedCount + dropped),
            dropped)
    }

    // MARK: - Text Run Grouping

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
